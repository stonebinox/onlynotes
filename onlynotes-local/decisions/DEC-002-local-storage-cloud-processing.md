# DEC-002: Local storage, OpenAI-only cloud processing

**Status:** Accepted
**Date:** 2026-05-02 (OpenAI-only after Google removal); refined through 2026-09-02
**Deciders:** Anoop Santhanam
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/Services/*`, `OnlyNotes/Views/SettingsView.swift`, commits `ba0cd48`, `63df9f1`, `4a1830f`, `6810e66`, bd `OnlyNotes-45v`, `OnlyNotes-pn6`, `OnlyNotes-jwq`

## Context

The goal is local-first *storage*: notes, audio and embeddings live on the user's Mac. Transcription, summarization and chat use hosted models. Older root docs said "all data stays local" and described a Google Cloud pipeline; both are wrong for the current app.

## Decision

- Persist everything locally under `~/Library/Application Support/OnlyNotes/` (see [DEC-001](DEC-001-note-first-json-storage.md)).
- Do all AI processing through **one provider, OpenAI**, with the user's own API key: transcription + diarization, summaries, chat, translation, embeddings, web-answer synthesis.
- Use **Brave Search** only for web retrieval (queries derived from the note).
- State the privacy reality plainly: audio, transcripts, notes and queries leave the device. See [../systems/ai-and-context.md](../systems/ai-and-context.md).

## Consequences

**Positive:**
- One key covers recording → summary; Settings has only OpenAI and Brave fields.
- No cloud storage bucket, service-account auth or polling code to maintain.

**Negative:**
- Not private: meeting audio is uploaded to OpenAI.
- Provider/model changes (deprecations, limits) affect every feature; bd `oc9` already calls `gpt-4o` "retired" while the code still uses it ([open question](../open-questions.md)).
- Keys sit in `UserDefaults`.

## Alternatives considered (and the migration history)

| Stage | Approach | Outcome |
|---|---|---|
| 1 (2026-05-02) | Google Cloud Speech-to-Text with diarization, later GCS + `longrunningrecognize` and service-account JWT (`76e0639`, `416e033`, `f98f3b9`) | Replaced in `ba0cd48`; commit records the goal "single API key covers the full pipeline". No further reason is recorded. |
| 2 (2026-05-02) | `whisper-1` (`verbose_json`), 12-min chunks with 20 s overlap, then `gpt-4o` to assign speaker IDs | Superseded by separate tracks ([DEC-003](DEC-003-separate-mic-system-tracks.md)); the `gpt-4o` pass guessed speakers from text alone |
| 3 (2026-06-01) | `gpt-4o-mini-transcribe` for multilingual text (`bfe`) | Still used for the mic track; returns no segment timestamps |
| 4 (2026-06-01…06-17) | AssemblyAI diarization on system audio (`c62`), then hybrid AssemblyAI speaker turns + OpenAI text (`45v`), `gpt-4o` inference (`2kz`), character-proportional slicing (`66z`), speaker consolidation (`st3`) | Rejected: AssemblyAI text quality/multilingual weakness; slicing text by character proportion produced garbled, misattributed output (`pn6`) |
| 5 (2026-09-02) | OpenAI `gpt-4o-transcribe-diarize` (`pn6`) | Current; see [DEC-004](DEC-004-single-call-diarization.md) |
| Proposed, not adopted | Local Whisper on a Raspberry Pi to keep audio at home (`OnlyNotes-jwq`, open) | Would change this decision; would need a new ADR |

## References

- bd: `OnlyNotes-45v`, `OnlyNotes-pn6`, `OnlyNotes-jwq`
- [../systems/transcription-and-diarization.md](../systems/transcription-and-diarization.md#history-why-the-code-looks-like-this)
