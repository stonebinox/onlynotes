# DEC-007: Single-call diarization requires a duration guard

**Status:** Accepted — pending live verification (bd `OnlyNotes-aig`). Supersedes the routing rule in [DEC-004](DEC-004-single-call-diarization.md).
**Date:** 2026-11-03
**Deciders:** Anoop Santhanam
**Last verified:** 2026-11-03
**Source:** `OnlyNotes/Services/DiarizedTranscriptionService.swift`, bd `OnlyNotes-aig`

## Context

DEC-004 chose single-call diarization for any transcoded file under 24 MiB (about 105 min at 32 kbps). bd `e3l` removed the earlier duration limit. The first long run of that path, a 1457 s system track (about 5.8 MB), took the single call and saved an empty fallback note.

Measured 2026-11-03 with synthetic audio (model `gpt-4o-transcribe-diarize`, `response_format=diarized_json`, `chunking_strategy=auto`, mono AAC 32 kbps):

| Audio | Result |
|---|---|
| 1450 s | HTTP 400: "audio duration 1450.044 seconds is longer than 1400 seconds which is the maximum for this model" |
| 734.8 s | HTTP 200, last segment end 734.7 s, 23,011 output tokens |
| 1350 s | HTTP 200, last segment end 1350.9 s, max gap between segments 0.7 s, 42,308 output tokens |

The pn6 concern about a ~2000 output-token cap is therefore not a hard limit for this request shape.

## Decision

- Use the single call only when both hold: transcoded size < 24 MiB (unchanged, strict) AND the original loaded duration <= `singleCallMaxDuration` = 1399 s.
- Otherwise use the existing silence-split chunked path, unchanged.
- 1399 s is a rounded-up margin below the 1400 s API limit over the observed 44 ms local/API duration difference.
- The 540 s guard proposed from the 2000-token concern is not restored (rejected by the 734.8 s and 1350 s measurements).

## Consequences

**Positive:**
- Recordings over about 23 min no longer fail with HTTP 400.

**Negative:**
- Recordings over 1399 s get per-chunk speaker namespaces (more speaker tags than real speakers) and the chunked path silently skipped failed chunks (bd `OnlyNotes-nq8`; superseded by [DEC-008](DEC-008-no-partial-transcripts.md): retry, then fail the whole track visibly).
- Based on synthetic audio; real-call chunked coverage is still to be verified.

**Revisit when:** OpenAI changes the 1400 s limit or the model; the engine is replaced (bd `OnlyNotes-awy`); cross-chunk speaker identity is added.

## Alternatives considered

| Option | Why rejected / not chosen |
|---|---|
| Restore a 540 s single-call guard | Based on a ~2000-token cap; 734.8 s and 1350 s calls succeeded with 23,011 and 42,308 output tokens |
| Threshold 1350 s | Needlessly low; 1350 s succeeded with full coverage |
| Catch HTTP 400 and retry chunked | More code; the limit is known up front |

## References

- bd: `OnlyNotes-aig`, `OnlyNotes-nq8`, `OnlyNotes-pn6`, `OnlyNotes-e3l`
- [DEC-004](DEC-004-single-call-diarization.md)
- [../systems/transcription-and-diarization.md](../systems/transcription-and-diarization.md)
