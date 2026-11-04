# Constraints

**Status:** Current
**Last verified:** 2026-10-28
**Source:** `OnlyNotes.xcodeproj/project.pbxproj`, `OnlyNotes/OnlyNotes.entitlements`, `OnlyNotes/Info.plist`, `OnlyNotes/Services/*`, bd `pn6`, `vza`, `oc9`

## Hard constraints (externally imposed or deliberate)

| Constraint | Detail | Source |
|---|---|---|
| macOS 14.0+ | `MACOSX_DEPLOYMENT_TARGET = 14.0`; Swift 5; SwiftUI | `project.pbxproj` |
| Menu-bar app | `INFOPLIST_KEY_LSUIElement = YES` (no Dock icon) | `project.pbxproj` |
| Screen Recording permission | Required; `AppState.startRecording` throws `RecorderError.screenCapturePermissionDenied` if missing; user must restart the app after granting | `AppState.startRecording`, `AudioRecorder` |
| Mic capture needs macOS 15+ | `captureMicrophone` and `.microphone` output are behind `#available(macOS 15.0, *)`; on macOS 14 the mic WAV stays header-only and is skipped (<= 4096 bytes) | `RecordingSession.startStream`, `AppState.process` (mic file size check) |
| No App Sandbox | `com.apple.security.app-sandbox = false`; `network.client` and `device.audio-input` = true | `OnlyNotes.entitlements` |
| Whole-display audio capture | Filter is the first display with no exclusions, so audio from every app is captured (own process excluded) | `RecordingSession.startStream` |
| Audio format | 16 kHz mono Int16 WAV | `RecordingSession.wavSettings` |
| OpenAI diarize request limits | API limits: 25 MB/file and 1400 s of audio per request (1450 s → HTTP 400 "longer than 1400 seconds", measured 2026-11-03). App thresholds: single call only if the transcoded file is < 24 MiB and the original duration is <= 1399 s. The ~2000-token output cap from pn6 is not a hard limit for this request shape: 734.8 s returned 23,011 output tokens and 1350 s returned 42,308 | bd `pn6`, `OnlyNotes-aig`; [DEC-007](decisions/DEC-007-single-call-duration-guard.md); `DiarizedTranscriptionService.swift` (`singleCallMaxFileSize`, `singleCallMaxDuration`) |
| Brave query limits | Max 50 words and 400 characters (51 words → HTTP 422); code sends `count=5`, `extra_snippets=true` | bd `vza`; `BraveSearchService.swift` |
| Data leaves the device | Audio, transcripts, note text and derived queries are sent to OpenAI and Brave (see [system-map.md](system-map.md)). Storage is local; processing is not | code |
| Recording consent | The app records other participants' audio; consent norms are the user's responsibility | bd `9zy`, `jwq` |
| No secrets/recordings/transcripts in the repo | See [process/documentation-rules.md](process/documentation-rules.md) | — |

## Current limitations (fixable, tracked)

| Limitation | Tracking |
|---|---|
| Mic level ~15 dB below system audio | bd `OnlyNotes-rfn` |
| Playback excludes the mic track | bd `OnlyNotes-isf` |
| Mic path not persisted; retranscribe uses system audio only | bd `OnlyNotes-uc3` |
| Chunked (>= 24 MiB or > 1399 s) diarization has per-chunk speaker namespaces; no cross-chunk identity | [open-questions.md](open-questions.md) |
| No action chaining in chat (one action per response) | `OnlyNotes-udn` |
| API keys stored in `UserDefaults`, not Keychain | [known-issues.md](known-issues.md) |
| No automated tests | `CLAUDE.md` |
