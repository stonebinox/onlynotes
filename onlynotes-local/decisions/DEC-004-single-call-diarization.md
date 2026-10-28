# DEC-004: Single-call OpenAI diarization

**Status:** Accepted — pending live verification (bd `OnlyNotes-pn6` and `OnlyNotes-e3l` still in progress)
**Date:** 2026-09-02 (model swap); 2026-09-04 (single-call, AAC transcode)
**Deciders:** Anoop Santhanam
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/Services/DiarizedTranscriptionService.swift`, `OnlyNotes/AppState.swift`, commits `6810e66`, `71c3f6a`, bd `OnlyNotes-pn6`, `OnlyNotes-e3l`

## Context

Real recordings gave incoherent transcripts. Root cause (bd `pn6`, confirmed by Codex and code reading): `gpt-4o-mini-transcribe` returns one text blob per chunk with no timestamps, and the hybrid merge sliced it across AssemblyAI speaker turns by character-count proportion, an invalid alignment. AssemblyAI's own text had been rejected for quality. Later (bd `e3l`): wrong speaker count (2 people → 3) and swapped lines, caused by separate clocks, a text-only GPT remap, and per-chunk speaker namespaces in multi-chunk runs.

## Decision

- Use OpenAI `gpt-4o-transcribe-diarize` (`response_format=diarized_json`, `chunking_strategy=auto`) for system audio: text, speaker labels and timestamps from one call.
- Transcode first to mono AAC at 32 kbps / 16 kHz so typical calls (< ~105 min) are **one request** under the 24 MB threshold, giving one speaker namespace.
- Chunk only when the file exceeds the threshold: silence-aware cuts (~345 s target), each chunk with its own tag range.
- Do not run `consolidateSpeakerTags` or any text-based remap in the live path.
- Apply the same service to recording, import and retranscribe.

## Consequences

**Positive:**
- Removes the character-slicing merge and the AssemblyAI dependency.
- Fewer API calls and no phantom speakers for single-call recordings.

**Negative:**
- Unverified: coherence, label format, timestamp units, and whether a long single request hits the ~2000 output-token cap noted in pn6 ([open questions](../open-questions.md)).
- Chunked path (> ~105 min) has no cross-chunk speaker identity and skips failed chunks silently.
- Leaves unused code behind (`consolidateSpeakerTags`, `inferSpeakers`, `assemblyAIKey`).
- Single point of failure on one vendor model.

**Revisit when:** live verification shows wrong counts/attribution; the OpenAI limits or model change; `known_speaker_references` (up to 4 clips, per pn6) becomes worth using for cross-chunk identity; or per-track capture (MeetCapture/WebRTC) supersedes acoustic diarization.

## Alternatives considered

| Option | Why rejected / not chosen |
|---|---|
| AssemblyAI diarization + OpenAI text, merged by timestamp (`45v`) | Required aligning two providers; OpenAI gave no timestamps |
| Same, with text sliced by AssemblyAI character proportion (`66z`) | Produced garbled, misattributed, run-on text (`pn6`) |
| AssemblyAI for text and speakers | Poor text quality and multilingual handling (`45v`, `pn6`) |
| `gpt-4o` speaker inference over plain transcript (`2kz`) | Text-only; replaced |
| `consolidateSpeakerTags` post-pass (`st3`) | Added for AssemblyAI over-fragmentation, later found to corrupt attribution (`71c3f6a`) |
| Always silence-chunk (first `6810e66` design: single call only ≤ 9 min) | Per-chunk speaker namespaces manufactured phantom speakers (`e3l`) |
| `whisper-1` with `verbose_json` for timestamps | Loses multilingual quality (`zpv`) |
| Local pyannote/Whisper on a Raspberry Pi | Proposed in `jwq`; not implemented |

## References

- bd: `OnlyNotes-pn6`, `OnlyNotes-e3l`, `OnlyNotes-45v`, `OnlyNotes-66z`, `OnlyNotes-st3`, `OnlyNotes-zpv`
- [../systems/transcription-and-diarization.md](../systems/transcription-and-diarization.md)
