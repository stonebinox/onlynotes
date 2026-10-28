# DEC-001: Note-first model with versioned JSON storage

**Status:** Accepted
**Date:** 2026-05-02
**Deciders:** Anoop Santhanam
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/Models/Note.swift`, `OnlyNotes/Services/NoteStore.swift`, `CLAUDE.md` (Key Design Decisions), commit `45cdce6`

## Context

The app began as a meeting-only recorder with a `Meeting` entity stored in `meetings.json`. The product became a general note-taking app (typed notes, tags, a context panel) in which a meeting is one kind of note. Storage needed to stay simple for a personal, single-user app.

## Decision

- `Note` is the top-level entity; meeting data lives in an optional `MeetingAttachment`.
- Notes are stored as one JSON file, `~/Library/Application Support/OnlyNotes/notes.json`, wrapped in `{schemaVersion, notes}`.
- Decoders use `decodeIfPresent`/defaults so older or partial files still load.
- A one-time migration converts `meetings.json` → `notes.json`, backing up to `meetings.backup.json` first and aborting if the backup fails.
- `Meeting.swift` and `MeetingStore.swift` remain only as comment-only placeholders.

## Consequences

**Positive:**
- No database dependency; file is human-readable and easy to back up.
- Schema evolution is additive (new optional fields).
- Migration is non-destructive (`meetings.json` is left in place).

**Negative:**
- Every save rewrites the whole file; chat and segments grow it.
- No concurrency control beyond atomic writes.
- A decode failure makes `loadAll` return `[]`, and a later `save` can overwrite the file (see [../known-issues.md](../known-issues.md)).
- `schemaVersion` is checked as `>= 1` only; there is no multi-version migration framework yet.

## Alternatives considered

| Option | Why rejected / not chosen |
|---|---|
| Keep meeting-only `Meeting` entity | Does not support plain notes, tags, or context panel |
| Core Data / SQLite | `CLAUDE.md` records "JSON storage — flat file, no Core Data overhead"; no further analysis is recorded in bd or git |

## References

- Commit `45cdce6` (note-first architecture, migration); `44f73a9` (storage hardening, embeddings)
- [../systems/notes-and-storage.md](../systems/notes-and-storage.md)
