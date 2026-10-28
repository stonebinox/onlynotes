# System Map

**Status:** Current for the room-recorder path; MeetCapture path is a POC with no app integration
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/AppState.swift`, `OnlyNotes/Services/*`, `MeetCapture/*`

## Path A — room recorder (the live path)

```
Menu bar / MenuBarView ── AppState.startRecording
   │  (Screen Recording permission check)
   ▼
AudioRecorder (SCStream, display-wide system audio + mic on macOS 15+)
   ├── recording_<ts>.wav        system audio, 16 kHz mono Int16
   └── recording_<ts>_mic.wav    mic, 16 kHz mono Int16 (PTS-aligned silence padding)
   ▼  AppState.stopAndProcess
   ├── system WAV → DiarizedTranscriptionService  → segments, tags 2…
   │      (AAC 32 kbps transcode → one gpt-4o-transcribe-diarize call if < 24 MB, else silence-split chunks)
   ├── mic WAV (if > 4096 bytes) → WhisperTranscriptionService.transcribeRaw → segments, tag 1
   ▼
 merge sorted by startTime ──► OpenAIService.summarize (gpt-4o) ──► title, summary, action items
   ▼
 Note + MeetingAttachment ──► NoteStore ──► ~/Library/Application Support/OnlyNotes/notes.json
   ▼  AppState.loadNotes / saveNote
 EmbeddingService ──► embeddings.json (text-embedding-3-small)
```

Downstream of storage:

- Detail view: playback of `audioFilePath` (system WAV only), speaker rename, export, tags.
- Chat: `chatWithMeetingControl` → optional action → `MeetingActionExecutor` → mutated note saved.
- Note editor context panel: tags + embeddings + Brave search → OpenAI synthesis.
- Import: `AppState.importAudio` copies the file to `ImportedAudio/`, runs diarization + summary, updates the existing note.

On any processing error `stopAndProcess` still saves a note (title `Meeting <date>`) with the system audio path and no transcript, and shows the error.

## Path B — MeetCapture (POC, not connected)

```
Chrome popup ─► background.js ─► offscreen.js (tabCapture + optional mic → 2 MediaRecorders)
content.js (Meet DOM heuristics) ─► speaker events ─┐
                                                   ▼
            Downloads: tab-audio.webm, mic-audio.webm, timeline.json   (manual evaluation only)
```

Nothing reads these files in the Mac app. Proposed (bd epic `OnlyNotes-9zy`, **not implemented**): localhost bridge, ingestion path, alignment of a named speaker timeline with transcript. See [systems/meetcapture.md](systems/meetcapture.md).

## External services

| Service | Used for | Data sent |
|---|---|---|
| OpenAI `/v1/audio/transcriptions` | Diarized system transcript; mic transcript | Audio (AAC or WAV/M4A chunks) |
| OpenAI `/v1/chat/completions` | Summary, chat, translation, web-answer synthesis | Transcript, notes, chat history, search results |
| OpenAI `/v1/embeddings` | Semantic note search | Note title/body/summary/first transcript segments; context queries |
| Brave Search `/res/v1/web/search` | "From the web" context | Query = note title + last 300 body chars (clamped) |

## Files on disk (under `~/Library/Application Support/OnlyNotes/`)

`notes.json`, `meetings.json` (legacy, read once), `meetings.backup.json`, `embeddings.json`, `Recordings/`, `ImportedAudio/`. API keys are in `UserDefaults` (`@AppStorage`: `openAIKey`, `braveSearchAPIKey`, unused `assemblyAIKey`).
