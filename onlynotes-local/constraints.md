# Constraints

**Status:** Current
**Last verified:** 2026-10-28
**Source:** `OnlyNotes.xcodeproj/project.pbxproj`, `OnlyNotes/OnlyNotes.entitlements`, `OnlyNotes/Info.plist`, `OnlyNotes/Services/*`, bd `pn6`, `vza`, `oc9`

## Hard constraints (externally imposed or deliberate)

| Constraint | Detail | Source |
|---|---|---|
| macOS 14.0+ | `MACOSX_DEPLOYMENT_TARGET = 14.0`; Swift 5; SwiftUI | `project.pbxproj` |
| Menu-bar app | `INFOPLIST_KEY_LSUIElement = YES` (no Dock icon) | `project.pbxproj` |
| Screen Recording permission | Required; `AppState.startRecording` throws `RecorderError.screenCapturePermissionDenied` if missing; user must restart the app after granting | `AppState.swift:83`, `AudioRecorder.swift` |
| Mic capture needs macOS 15+ | `captureMicrophone` and `.microphone` output are behind `#available(macOS 15.0, *)`; on macOS 14 the mic WAV stays header-only and is skipped (< 4096 bytes) | `AudioRecorder.swift:101,115`, `AppState.swift:108-111` |
| No App Sandbox | `com.apple.security.app-sandbox = false`; `network.client` and `device.audio-input` = true | `OnlyNotes.entitlements` |
| Whole-display audio capture | Filter is the first display with no exclusions, so audio from every app is captured (own process excluded) | `AudioRecorder.startStream` |
| Audio format | 16 kHz mono Int16 WAV | `AudioRecorder.wavSettings` |
| OpenAI diarize request limits | 25 MB/file and ~2000 output tokens (per pn6, checked against OpenAI docs 2026-09); code uses a 24 MB threshold | bd `pn6`; `DiarizedTranscriptionService.swift:12` |
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
| Chunked (> 24 MB) diarization has per-chunk speaker namespaces; no cross-chunk identity | [open-questions.md](open-questions.md) |
| No action chaining in chat (one action per response) | `OnlyNotes-udn` |
| API keys stored in `UserDefaults`, not Keychain | [known-issues.md](known-issues.md) |
| No automated tests | `CLAUDE.md` |
