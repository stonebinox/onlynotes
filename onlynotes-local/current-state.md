# Current State

**Status:** Current. Recorder rewrite (awy.1), diarization (pn6, e3l) and MeetCapture (9zy.1) are **not live-verified**.
**Last verified:** 2026-10-30
**Source:** `OnlyNotes/AppState.swift`, `OnlyNotes/Services/*`, `MeetCapture/*`, bd (`pn6`, `e3l`, `9zy.1`, `90d`)

## Implemented in the macOS app

| Capability | Status | Where |
|---|---|---|
| Menu-bar record/stop, main window, Settings (OpenAI key, Brave key, appearance) | Working | `OnlyNotesApp.swift`, `MenuBarView.swift`, `SettingsView.swift` |
| Plain notes (title, body, tags) with autosave, Markdown export | Working | `ContentView.swift` (`NoteEditorView`), `Note.swift` |
| Meeting recording: system audio + mic to two 16 kHz mono WAVs, `_diag.json` sidecar | **Rewritten, unverified live** (awy.1: cached converter, no limiter, checked writes, session lifecycle); mic needs macOS 15+; mic is ~15 dB quiet (bd `OnlyNotes-rfn`) | `AudioRecorder.swift`, [systems/recording.md](systems/recording.md) |
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

## Next up (waiting on the owner)

Epic: bd `OnlyNotes-awy` (plan and owner decisions D1–D9 are in its design field). S1 is committed (`9823ed6`) but stays `in_progress` until these real-recording checks pass. They need only the OnlyNotes Debug build, not the extension:

1. 30 s on headphones, with audio playing and some talking. Passes if `maxDriftFrames` < 1600 and `minDriftFrames` > -1600 on both tracks, and the two tracks' `finalSkewSeconds` differ by < 0.1 s. Otherwise PTS padding stays off.
2. 20 min on headphones, then 3. 20 min on laptop speakers. Each passes with `finalSkewSeconds` within 2 s on both tracks (confirmed by WAV length), `damageCount` 0, no periodic clicks, and a clear mic with no pumping or clipping.
4. Stop, then Record immediately. The second recording starts within seconds and the first still produces a note.

Then: run the S2 scorer (`tools/score.py`, numbers only, not shipped in the app) on a new recording (`awy.2`), hold the live Meet DOM discovery call with 2+ people, about 15 min (`awy.3`), and re-plan S3–S5 from that evidence.

## Not live-verified (bd still in progress)

| Task | What is unverified |
|---|---|
| `OnlyNotes-awy.1` | Recorder rewrite: no clicks, clear mic, duration within ~2 s, measured skew, 30 s PTS diagnostic (padding stays off unless it passes) |
| `OnlyNotes-pn6` | Coherent per-speaker output on a real 20–40 min recording; diarizer label format matches the parser; timestamp units are seconds |
| `OnlyNotes-e3l` | Correct speaker count, no text duplicated across speakers, user's lines attributed to user after PTS alignment |
| `OnlyNotes-9zy.1` | Everything about MeetCapture accuracy (manual evaluation on 5–10 real calls not done) |

Both pn6 and e3l passed Codex review with zero blocking findings and build; neither has been run on a real call.

## Removed / not live

Google Cloud STT/GCS, AssemblyAI, Brave Answers, character-proportional text slicing, and the GPT-4o speaker-consolidation pass are not part of the live pipeline. See [decisions/DEC-002](decisions/DEC-002-local-storage-cloud-processing.md) and [DEC-004](decisions/DEC-004-single-call-diarization.md). Dead code that remains in the tree is listed in [systems/transcription-and-diarization.md](systems/transcription-and-diarization.md#dead-code-still-in-the-tree).

## Build and tests

`xcodebuild -scheme OnlyNotes -configuration Debug build` (from `CLAUDE.md`). There is no automated test suite.
