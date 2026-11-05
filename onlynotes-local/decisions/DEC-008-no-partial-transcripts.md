# DEC-008: Retry, then fail visibly: no partial transcripts per track

**Status:** Accepted — pending live verification
**Date:** 2026-11-04
**Deciders:** Anoop Santhanam
**Last verified:** 2026-11-04
**Source:** `OnlyNotes/Services/DiarizedTranscriptionService.swift`, `OnlyNotes/Services/WhisperTranscriptionService.swift`, `OnlyNotes/AppState.swift`, `OnlyNotes/Services/MeetingActionExecutor.swift`

## Context

A 1869 s recording took the chunked path; one chunk failed with a connection-lost error and three more failed shortly after during a network outage of about 32 s. Each failure was logged and skipped, with no retry, so about 23 minutes of remote speech were missing from the saved transcript with no warning. The mic path stopped at the first failed chunk and returned a partial transcript, and its cleanup could delete the source mic WAV for recordings of 740 s or less. Retranscribe never touched the mic track.

## Decision

- Every transcription request is retried by one shared helper (5 attempts, 5/15/30/60 s sleeps, transient URLError codes and HTTP 408/429/5xx only).
- A track is all-or-nothing. If a chunk still fails after retries the whole track fails; no partial segments are returned (owner, D12: "i agree, it should retry the whole transcript if it fails a part").
- A failed system track stays fatal (existing fallback note). A failed mic track keeps the system transcript and shows a visible tag-0 marker saying the owner's side is missing (owner, D13: "B plus fix retranscribe").
- Retranscribe also transcribes the mic track. The mic path is not persisted; it is derived as `<system path minus extension>_mic.wav`, which also covers existing notes.
- An empty-text mic chunk response is a successful zero-segment parse, so it does not fail the track. "No speech" is confirmed only for synthetic silence. If every mic chunk is empty, `transcribeRaw` still throws, so the visible tag-0 marker path is kept.
- Cleanup never deletes the source audio file (bd `mi5`); a UI choice to delete audio is a separate task (bd `c4c`).

## Consequences

**Positive:**
- No silent gaps; a failure is retried and, if it persists, visible.
- A failed mic can be recovered with Retranscribe without re-recording.

**Negative:**
- Worst case about 1,610 s per request (5 × 300 s timeout + 110 s sleeps), independently for each failing chunk of a long recording.
- One persistently failing chunk discards the whole system track's result for that run (the audio is kept).
- Recovery depends on the `_mic.wav` file still existing.

## Alternatives considered

| Option | Why rejected / not chosen |
|---|---|
| Insert a gap marker and keep partial segments | Owner wants no parts of the conversation dropping out; partial tracks hide how much is missing |
| Make mic failure fatal | Discards a good system transcript |
| Persist `micAudioFilePath` and a transcription warning on the note | Persisted-shape change and a new banner; derivation and the existing tag-0 marker are enough |

## References

- bd: `OnlyNotes-nq8`, `OnlyNotes-uc3`, `OnlyNotes-mi5`, `OnlyNotes-8ru`, `OnlyNotes-c4c`
- Docs: [../systems/transcription-and-diarization.md](../systems/transcription-and-diarization.md), [../systems/meeting-chat-actions.md](../systems/meeting-chat-actions.md)
