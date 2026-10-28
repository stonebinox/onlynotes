# Recording

**Status:** Current. PTS alignment (bd `OnlyNotes-e3l`) is **unverified on a real call**.
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/Services/AudioRecorder.swift`, `OnlyNotes/AppState.swift`, `OnlyNotes/OnlyNotes.entitlements`, `OnlyNotes/Info.plist`

## Mechanism

`AudioRecorder` (an `SCStreamDelegate`/`SCStreamOutput`) captures with ScreenCaptureKit:

- Filter: first display from `SCShareableContent`, no excluded apps — i.e. audio from **all** apps (`AudioRecorder.startStream`). `excludesCurrentProcessAudio = true`.
- Config: `capturesAudio = true`, `captureMicrophone = true` only on macOS 15+, `sampleRate = 48000`, `channelCount = 1`, video reduced to 2×2 px at 1 fps and ignored.
- Outputs: `.audio` → system file; `.microphone` (macOS 15+ only) → mic file; `.screen` → discarded.
- Permission: `AppState.startRecording` calls `CGPreflightScreenCaptureAccess`; if missing it requests access and throws `RecorderError.screenCapturePermissionDenied` (user must restart the app after granting).

## Files

| File | Path |
|---|---|
| System audio | `~/Library/Application Support/OnlyNotes/Recordings/recording_<yyyy-MM-dd_HH-mm-ss>.wav` |
| Mic audio | same name with `_mic.wav` suffix |

Both: 16 kHz, mono, 16-bit PCM WAV (`AudioRecorder.wavSettings`). The note stores only the system path (`MeetingAttachment.audioFilePath`). The mic path is **not persisted** (bd `OnlyNotes-uc3`).

On macOS 14 the mic file is created but never written beyond the header; `AppState.stopAndProcess` skips mic files ≤ 4096 bytes.

## Per-buffer processing (`writeSampleBuffer`)

1. Convert the source format to 16 kHz Float32 mono with a **new `AVAudioConverter` per buffer** (suspected cause of crackle, bd `OnlyNotes-1b2`).
2. Soft limiter: if peak > 0.9, scale down to 0.9; never amplifies (commit `0451236` replaced peak normalization that pumped gain; earlier task `OnlyNotes-0s0`).
3. Convert to Int16.
4. **Clock alignment** (commit `71c3f6a`): `sessionStartPTSSeconds` is the host-clock time captured before `startCapture()`. For each buffer, `expectedFrame = (PTS − anchor) × 16000`; if the file has fewer frames written, silence is padded to close the gap. The pad is bounded by wall-clock elapsed + 5 s so a corrupt PTS cannot allocate unbounded silence. Intent: frame N in both WAVs is the same absolute time, so mic and system timestamps are comparable.
5. Writes and counters are guarded by `writeLock`.

Errors in conversion/copy/write are swallowed (`return` / `try?`) with no logging.

## Failure behaviour

- `startStream` failure → `teardown()` and `onUnexpectedStop(error)` → `AppState.processingError`.
- `didStopWithError` while recording → local notification "Recording Interrupted", `teardown()`, `onUnexpectedStop(nil)`. There is no resume.
- `stopRecording` returns `RecordingResult(systemURL, micURL, duration)`; `duration` is the timer's `elapsedTime` (1 s tick).

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
