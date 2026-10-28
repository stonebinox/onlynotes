# Notes and Storage

**Status:** Current
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/Models/Note.swift`, `OnlyNotes/Models/TranscriptSegment.swift`, `OnlyNotes/Services/NoteStore.swift`, `OnlyNotes/Services/EmbeddingService.swift`, `OnlyNotes/Models/Meeting.swift`, `OnlyNotes/Services/MeetingStore.swift`

## Data model

| Type | Fields | Notes |
|---|---|---|
| `Note` | `id`, `title`, `body`, `tags`, `createdAt`, `updatedAt`, `meetingAttachment?` | Top-level entity. `isMeetingNote` = attachment present. `setTags` trims, lowercases, dedupes. Custom decoder defaults missing fields. |
| `MeetingAttachment` | `segments`, `speakers` (`"<tag>"` → name), `summary`, `actionItems`, `chatMessages`, `duration`, `audioFilePath?`, `notes` | Optional per note. `transcript(resolvingNames:)` renders `Name: text` lines. |
| `TranscriptSegment` | `id`, `speakerTag: Int`, `text`, `startTime`, `endTime` | Tag 1 = mic, tags ≥ 2 = system speakers, 0 = system/warning marker. |
| `MeetingNote` | `id`, `timestampOffset`, `text` | Live notes taken while recording. |
| `ChatMessage` | `id`, `role` (`"user"`/`"assistant"`), `content` | Stored inside the attachment. |
| `ContextResult`, `WebAnswer`, `WebContextState` | in-memory only | `Models/ContextResult.swift`; not persisted. |

## Files that are not live code

- `Models/Meeting.swift` — one comment line: "Replaced by Note.swift". No types.
- `Services/MeetingStore.swift` — one comment line: "MeetingStore replaced by NoteStore.swift". No types.

They are placeholders kept in the Xcode project. `Meeting*`-named view files (`MeetingDetailView`, `MeetingListView`) are **live** and operate on `Note`.

## `NoteStore` (`NoteStore.shared`)

| Aspect | Behaviour |
|---|---|
| Location | `~/Library/Application Support/OnlyNotes/notes.json` |
| Format | `{ "schemaVersion": 1, "notes": [Note] }`, pretty-printed JSON, ISO-8601 dates, atomic write |
| Save | Load all → replace by `id` or insert at index 0 → rewrite whole file |
| Delete | Removes the note, its embedding, and `audioFilePath` (system WAV only) |
| Load failure | `loadAll` returns `[]` and sets `loadError`; `AppState` surfaces it. Because `save` starts from `loadAll`, a later save would write a file containing only the new note (code reading; see [known-issues](../known-issues.md)) |

### Legacy migration

`migrateIfNeeded()` runs in `AppState.init`:

1. If `notes.json` decodes with `schemaVersion >= 1`, stop.
2. If no `meetings.json`, stop (fresh install).
3. Copy `meetings.json` → `meetings.backup.json` (overwriting an old backup). If the copy fails, abort and set `migrationError`.
4. Decode `[LegacyMeeting]` (ISO-8601 dates); on failure abort with `migrationError`, data untouched.
5. Convert each to a `Note` with a `MeetingAttachment` and write `notes.json`.

`meetings.json` is not deleted.

## Other on-disk data

| Path (under `~/Library/Application Support/OnlyNotes/`) | Content |
|---|---|
| `embeddings.json` | `[noteID: {noteID, digest, vector[Float], updatedAt}]`, `text-embedding-3-small`. Recomputed when the SHA-256 digest of title + body + summary + first 50 segments changes. Pruned on `loadNotes` and removed on delete. |
| `Recordings/` | WAV files from live recordings ([recording.md](recording.md)) |
| `ImportedAudio/<noteID>.<ext>` | Copy of an imported audio file; an existing file with the same name is replaced |

`UserDefaults` (`@AppStorage`): `openAIKey`, `braveSearchAPIKey`, `assemblyAIKey` (unused), `appearanceMode`.

## Persisted vs recomputed

Persisted: notes, attachments (including segments, summary, chat, speaker names), audio files, embeddings. Recomputed each session: context results, web answers, search state. Mic audio path and diarizer raw output are not kept.

## Save paths

`AppState.saveNote` → `NoteStore.save` → `loadNotes` (reloads and re-indexes all notes in the background: embedding fetch is skipped when the digest matches). The note editor autosaves 0.8 s after edits (`ContentView.scheduleSave`).
