# MeetCapture (Chrome extension POC)

**Status:** Experimental / **Unverified**. Not integrated with the Mac app. Manual evaluation (bd `OnlyNotes-9zy.1`, in progress) has not been done.
**Last verified:** 2026-10-28
**Source:** `MeetCapture/manifest.json`, `MeetCapture/background.js`, `MeetCapture/offscreen.js`, `MeetCapture/content.js`, `MeetCapture/popup.js`, `MeetCapture/permission.js`, `MeetCapture/README.md`, bd `OnlyNotes-9zy`, `OnlyNotes-9zy.1`, `OnlyNotes-jwq`

## Purpose

Answer one question: is Google Meet's UI active-speaker signal accurate enough to attribute a transcript? The POC only records data for manual comparison. Meet's DOM is undocumented; the UI is **evidence, not ground truth** (it cannot represent overlap, pinning, presentation mode, and has detection delay — bd `9zy`).

## What exists (current)

- Manifest V3, `minimum_chrome_version` 116, version 0.1.0.
- Manifest permissions: `tabCapture`, `offscreen`, `storage`, `downloads`; host `https://meet.google.com/*`. (`MeetCapture/README.md` also lists `activeTab` and `scripting`; the manifest does not declare them.)
- `popup.js`: Start/Stop; requires the active tab to be on `https://meet.google.com/`; "Enable microphone (optional)" opens `permission.html`, which calls `getUserMedia` and stores `micGranted`.
- `background.js` (service worker): creates the offscreen document, gets a tab-capture stream ID, stores `startEpochMs`, tells the content script to start, merges events (dedupe by `tMs|participantKey`) on stop.
- `offscreen.js`: tab stream via `getUserMedia` (`chromeMediaSource: 'tab'`) routed to an `AudioContext` destination so the call stays audible; mic via `getUserMedia` if available (error recorded as `micError`); two `MediaRecorder`s (`audio/webm;codecs=opus` preferred, 1 s timeslice); downloads three files on stop.
- `content.js`: 250 ms poll + `MutationObserver`; tries three selector heuristics; 300 ms flap suppression; a heartbeat event every 5 s when no speaker is detected.

## Output (Downloads folder)

| File | Content |
|---|---|
| `tab-audio.webm` | Meet tab audio (all participants + shared audio) |
| `mic-audio.webm` | Local mic, only if mic access succeeded |
| `timeline.json` | `startEpochMs`, `audioT0`, `perfT0`, recorder start/stop epoch ms, `tabDurationSec`, `micDurationSec` (wall-clock differences, not decoded durations), `participants[]`, `events[]` (`tMs`, `participantKey`, `name`, `signal`), optional `micError` |

Signal values emitted by the code: `speaking-bars`, `tile-highlight`, `dominant-speaker`, `no-active-speaker-detected`. (`MeetCapture/README.md` lists `mic-icon` instead of `dominant-speaker`; the code is authoritative.)

## Unverified

- All selectors in `content.js` (`[data-is-speaking="true"]`, `[data-active-speaker="true"]`, `[data-participant-id][data-is-dominant-speaker="true"]`, etc.) are guesses; the file comments say they are unverified against live Meet. Expect mostly heartbeat events until tuned.
- Whether tab and mic recorders and the event clock align well enough for attribution.
- Behaviour on long calls, screen share, pinned tiles, join/leave.
- The 1 s `MediaRecorder` timeslice keeps chunks in memory until stop (no chunk-to-storage persistence).

## Does not exist (do not describe as implemented)

Localhost bridge, authentication, upload/ingestion in the Mac app, transcript alignment, participant-name attribution, confidence scores, Zoom support, any change to `Note`/`MeetingAttachment`. The architecture in bd `OnlyNotes-9zy` (loopback bridge, token in Keychain, `SpeakerActivityInterval` timeline, word-level alignment needing `OnlyNotes-zpv`) is **Proposed — not implemented**. Alternative: WebRTC per-track capture (bd `OnlyNotes-jwq`), only if the UI timeline proves insufficient.

## How to run

Load unpacked from `chrome://extensions` pointing at `MeetCapture/`; see `MeetCapture/README.md` for steps and the evaluation procedure. Do not commit the downloaded files (they contain real meeting audio and names).

See [DEC-006](../decisions/DEC-006-meetcapture-measurement-first-poc.md).
