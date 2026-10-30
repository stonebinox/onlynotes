# Recording

**Status:** Current. Recorder rewrite (bd `OnlyNotes-awy.1`) and PTS alignment (bd `OnlyNotes-e3l`) are **unverified on a real recording**.
**Last verified:** 2026-10-29 (code only)
**Source:** `OnlyNotes/Services/AudioRecorder.swift`, `OnlyNotes/AppState.swift`, `OnlyNotes/OnlyNotes.entitlements`, `OnlyNotes/Info.plist`

## Mechanism

`RecordingSession` (an `SCStreamDelegate`/`SCStreamOutput`, one per recording, in `AudioRecorder.swift`) captures with ScreenCaptureKit:

- Filter: first display from `SCShareableContent`, no excluded apps — i.e. audio from **all** apps (`RecordingSession.startStream`). `excludesCurrentProcessAudio = true`.
- Config: `capturesAudio = true`, `captureMicrophone = true` only on macOS 15+, `sampleRate = 48000`, `channelCount = 1`, video reduced to 2×2 px at 1 fps and ignored.
- Outputs: `.audio` → system file; `.microphone` (macOS 15+ only) → mic file; `.screen` → discarded.
- Permission: `AppState.startRecording` calls `CGPreflightScreenCaptureAccess`; if missing it requests access and throws `RecorderError.screenCapturePermissionDenied` (user must restart the app after granting).

## Files

| File | Path |
|---|---|
| System audio | `~/Library/Application Support/OnlyNotes/Recordings/recording_<yyyy-MM-dd_HH-mm-ss>.wav` |
| Mic audio | same name with `_mic.wav` suffix |

Both: 16 kHz, mono, 16-bit PCM WAV (`RecordingSession.wavSettings`). The note stores only the system path (`MeetingAttachment.audioFilePath`). The mic path is **not persisted** (bd `OnlyNotes-uc3`).

If `startCapture()` fails with `SCStreamError.Code.failedToStartMicrophoneCapture` (macOS 15+, -3820), `startStream()` records mic-track damage and retries once with a stream built without the microphone (`makeStream(includeMic: false)`), so system audio is still recorded.

On macOS 14 the mic file is created but never written beyond the header; `AppState.process` skips mic files ≤ 4096 bytes.

## Per-buffer processing (`writeSampleBuffer`) — rewritten by OnlyNotes-awy.1 (UNVERIFIED on a real recording)

1. One `AVAudioConverter` **per track**, cached and recreated only when the source `AVAudioFormat` changes, so resampler state carries across buffers. Each buffer is fed as one input then `.noDataNow`; `.endOfStream` is used only to flush the resampler tail, once when the source format changes (before the converter is replaced) and once per track in finalize. Output buffer has +256 frames headroom; exactly `frameLength` frames are written.
2. **No limiter / gain change** anywhere in the recorder. Float32 → Int16 is a clamp only (NaN → 0).
3. **Damage** (counted per track as count + first error message) is exactly: converter `.error` status or error, converter/source/output/Int16 buffer allocation failures, sample-buffer copy failures, missing format description, malformed sample buffers (AudioBufferList count mismatch, nil data, or a buffer whose byte size is not numSamples × bytes-per-frame; the buffer is skipped), silence-buffer allocation/channel-data failures, file write failures (including silence writes), and a failed `stopCapture()` (counted on the system track). A conversion that yields zero output frames is skipped, not counted. Written-frame counters only advance after a successful write.
4. **PTS padding** (from `71c3f6a`) is behind `RecordingSession.ptsPaddingEnabled`, **off by default**: the PTS-vs-written relation is unproven, and padding on a wrong assumption would itself inject silence/misalignment. It stays off until a ~30 s diagnostic recording shows PTS and host clock agree. While off, the would-be padding (`wouldPadFrames`) and max drift (`maxDriftFrames`) are still computed into the diagnostics.
5. Everything is guarded by the session's `lock`; sample handlers run on the session's queues (`systemQueue`, `micQueue`).

## Lifecycle: one session per recording

- `RecordingSession` (final class) owns everything about one recording: both tracks (files, cached converters, diagnostics, PTS anchor), its `SCStream`, its startup `Task`, `captureStartUptime` / `recordingStartEpochMs` / `hostClockAtCaptureStartSeconds`, its file URLs and its `lock`. It is the stream's `SCStreamOutput` and `SCStreamDelegate`, so every sample buffer and every `didStopWithError` reaches the session that created the stream; once a session has finalized its files are closed and late callbacks are no-ops. Recording file names get a `_2`, `_3`… suffix if the name (or its `_mic` sibling) already exists.
- `finish(reason:)` is idempotent. The first call (user stop, stream error, or startup failure) creates the single finalize `Task`; later calls return. Finalize: await the startup task, bounded to 10 s (on timeout the startup task is cancelled and marked abandoned under the session lock; a late `startStream()` assigns nothing, sets no capture timestamps, and stops any stream it started itself, and finalize also sets the flag before reading the stream; this is a startup failure: no result, message "Audio capture did not start within 10 s; nothing was recorded.", and the session's stream, if one exists, is still stopped and the files closed) → `stopCapture()` raced against a 5 s timeout (failure/timeout = system-track damage; also stops a stream whose `startCapture()` threw) → drain both handler queues → flush converters, close files → write the `_diag.json` sidecar and console line → build `RecordingResult` (nil if capture never started) → hop to the main actor and call back the recorder once.
- `AudioRecorder` (`@MainActor`) holds only `currentSession`, `isRecording`, `elapsedTime`, the timer and one callback, `onRecordingFinished(result, message)`. `startRecording()` throws `RecorderError.busy` ("Still finishing the previous recording — try again in a moment.") while `currentSession != nil`; `stopRecording()` just requests `finish(.user)` and returns nothing. `currentSession` is cleared on the main actor in the same step that delivers the result, so a new recording cannot start before the previous one has delivered, and nothing from an old session can touch a new one. `isRecording` stays true from Record until that delivery.
- `AppState.stopAndProcess` sets `isProcessing`, stores `onNoteSaved` as pending and calls `recorder.stopRecording()`. `AppState`'s single `onRecordingFinished` handler captures/clears `liveNotes`, takes the pending `onNoteSaved`, and with a result runs `process(...)` (message becomes `extraWarning`); with no result it sets `processingError = message` and `isProcessing = false`. `AppState.startRecording` just propagates `busy` (no UI for it yet).
- Messages: nil for a user stop; "Recording was interrupted (audio capture stopped unexpectedly); the note contains audio up to that point." for a stream error that produced a result; for no result, the `startCapture` error text or "Recording stopped before audio capture started; nothing was recorded.".

## Result and diagnostics

- `RecordingResult.duration` is capture-based (startCapture() completing → stop), not the UI timer. It and `finalSkewSeconds` are measured on the monotonic `ProcessInfo.systemUptime` clock, not wall-clock `Date()`; only `recordingStartEpochMs` is Unix wall-clock.
- `RecordingDiagnostics.recordingStartEpochMs`: Unix wall-clock ms at `startCapture()` completion; separate from host-clock/PTS values. Not duplicated on `RecordingResult`.
- `hostClockAtCaptureStartSeconds` (in `RecordingDiagnostics`): host-clock seconds when `startCapture()` completed. Measurement only: a 30 s diagnostic recording compares each track's `firstPTSSeconds` against it and against `hostClockAnchorSeconds` (pre-start). No validator; padding is not auto-enabled.
- `RecordingDiagnostics` (per track: first PTS, host-clock anchor, expected frames from PTS span, written frames, decoded duration, padding frames, would-pad frames, max drift, `finalSkewSeconds` (decoded duration minus capture duration; measurement only, no correction), damage count + first error) is returned in `RecordingResult` and written to `<system file name>_diag.json` next to the system WAV; one summary line is printed at stop.
- `RecordingResult.warningText` builds the warning: damage ("Recording had N audio write/convert errors; transcript may have gaps.") and/or mic missing (0 mic frames: "Microphone recorded no audio; your own speech is not in this transcript."), one combined string. `AppState.process` sets it as `processingError` on the success path, and on the failure path appends it to the API error. Nothing is persisted on `Note`/`MeetingAttachment` (later task). UNVERIFIED: on macOS 14 the mic stream is not added, so this warning would fire on every recording there.

## Failure behaviour

- Startup failure (`SCShareableContent`, `addStreamOutput`, `startCapture` throws) → the startup task records the error and calls `finish(.startupFailure)`; finalize stops the session's own stream (logged), closes files, and delivers `(nil, error text)` → `AppState.processingError`, no note (nothing captured).
- `didStopWithError` → local notification "Recording Interrupted" (only if that call started the finalize), then the same finalize; there is no resume. The recording up to that point becomes a note through the same `process(...)`, and `processingError` combines the interruption text with any damage/mic warning.
- A stop that races a stream error or startup failure is harmless: `finish` is idempotent and the one result is delivered once, with the pending `onNoteSaved` if any.
- The converter is drained in loops (`writeSampleBuffer` while the output buffer comes back full; `flushConverter` until `.endOfStream`); mid-stream `.endOfStream` is recorded as damage.
- UNVERIFIED on a real recording: stop-during-startup, stream error mid-recording, and a start immediately after stop (expect `busy` until delivery).

## Known problems

- Mic ~15 dB below system (bd `OnlyNotes-rfn`); crackle (bd `OnlyNotes-1b2`); playback ignores mic (bd `OnlyNotes-isf`). See [../known-issues.md](../known-issues.md).
- Speaker-mode leakage (remote voices also reaching the mic) is mentioned in bd `e3l` as a follow-up with no task.

## History

| Date | Change |
|---|---|
| 2026-05-03 | `acbcfb6`: AVAudioEngine mic-only → SCStream dual capture, mixed to one WAV |
| 2026-05-05 | `076cee9`: mic and system written to separate WAVs (see [DEC-003](../decisions/DEC-003-separate-mic-system-tracks.md)) |
| 2026-05-07 | `0451236`: soft limiter replaces peak normalization |
| 2026-09-04 | `71c3f6a`: PTS-anchored single clock for both tracks |
| 2026-10-29 | OnlyNotes-awy.1: cached converter, limiter removed, checked writes, async stop ordering, diagnostics sidecar, PTS padding off by default (pending real-use verification) |

PTS padding stays off (`ptsPaddingEnabled`) unless a ~30 s diagnostic shows `maxDriftFrames` < 1600 (0.1 s) on both tracks and |mic.finalSkewSeconds - system.finalSkewSeconds| < 0.1 s.
