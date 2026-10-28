# Current State

**Status:** Current. Diarization (pn6, e3l) and MeetCapture (9zy.1) are **not live-verified**.
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/AppState.swift`, `OnlyNotes/Services/*`, `MeetCapture/*`, bd (`pn6`, `e3l`, `9zy.1`, `90d`)

## Implemented in the macOS app

| Capability | Status | Where |
|---|---|---|
| Menu-bar record/stop, main window, Settings (OpenAI key, Brave key, appearance) | Working | `OnlyNotesApp.swift`, `MenuBarView.swift`, `SettingsView.swift` |
| Plain notes (title, body, tags) with autosave, Markdown export | Working | `ContentView.swift` (`NoteEditorView`), `Note.swift` |
| Meeting recording: system audio + mic to two 16 kHz mono WAVs | Working; mic needs macOS 15+; mic is ~15 dB quiet (bd `OnlyNotes-rfn`) | `AudioRecorder.swift` |
| Live timestamped notes during recording | Working | `AppState.addLiveNote`, `LiveNotepadView` |
| Transcription of system audio with speaker labels (`gpt-4o-transcribe-diarize`) | **Unverified live** (pn6, e3l) | `DiarizedTranscriptionService.swift` |
| Mic transcription as Speaker 1 (`gpt-4o-mini-transcribe-2025-12-15`) | Implemented; quality limited | `WhisperTranscriptionService.transcribeRaw` |
| Summary, title, action items (`gpt-4o`) | Implemented | `OpenAIService.summarize` |
| Audio import into a note (same diarization path) | Implemented | `AppState.importAudio` |
| Speaker rename, tags, regenerate summary, Markdown export, audio export, playback | Implemented; playback is system track only (bd `OnlyNotes-isf`) | `MeetingDetailView.swift` |
| Per-meeting AI chat with action execution (retranscribe, regenerate summary, rename speaker, add/remove tag, translate) | Implemented | `OpenAIService.chatWithMeetingControl`, `MeetingActionExecutor.swift` |
| Note context panel: tag matches, semantic search (embeddings), "From the web" (Brave + OpenAI synthesis) | Implemented | `ContentView.swift`, `EmbeddingService.swift`, `BraveSearchService.swift` |
| Storage: versioned `notes.json`, one-time migration from `meetings.json` | Implemented | `NoteStore.swift` |

## Experimental / not integrated

- **MeetCapture** (`MeetCapture/`): MV3 Chrome extension POC that downloads `tab-audio.webm`, optional `mic-audio.webm`, and `timeline.json`. DOM selectors are unverified against live Meet. There is **no** bridge, ingestion, alignment or participant attribution in the Mac app. See [systems/meetcapture.md](systems/meetcapture.md).

## Not live-verified (bd still in progress)

| Task | What is unverified |
|---|---|
| `OnlyNotes-pn6` | Coherent per-speaker output on a real 20–40 min recording; diarizer label format matches the parser; timestamp units are seconds |
| `OnlyNotes-e3l` | Correct speaker count, no text duplicated across speakers, user's lines attributed to user after PTS alignment |
| `OnlyNotes-9zy.1` | Everything about MeetCapture accuracy (manual evaluation on 5–10 real calls not done) |

Both pn6 and e3l passed Codex review with zero blocking findings and build; neither has been run on a real call.

## Removed / not live

Google Cloud STT/GCS, AssemblyAI, Brave Answers, character-proportional text slicing, and the GPT-4o speaker-consolidation pass are not part of the live pipeline. See [decisions/DEC-002](decisions/DEC-002-local-storage-cloud-processing.md) and [DEC-004](decisions/DEC-004-single-call-diarization.md). Dead code that remains in the tree is listed in [systems/transcription-and-diarization.md](systems/transcription-and-diarization.md#dead-code-still-in-the-tree).

## Build and tests

`xcodebuild -scheme OnlyNotes -configuration Debug build` (from `CLAUDE.md`). There is no automated test suite.
