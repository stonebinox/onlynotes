# Transcription and Diarization

**Status:** Current code path. **Unverified on a real recording** (bd `OnlyNotes-pn6`, `OnlyNotes-e3l`, both in progress).
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/AppState.swift`, `OnlyNotes/Services/DiarizedTranscriptionService.swift`, `OnlyNotes/Services/WhisperTranscriptionService.swift`, `OnlyNotes/Services/MeetingActionExecutor.swift`, `OnlyNotes/Services/OpenAIService.swift`

## Live pipeline

Entry points, all using the same diarization call (`speakerTagOffset: 2`):

| Entry | Code | Audio used |
|---|---|---|
| Stop recording | `AppState.stopAndProcess` (`AppState.swift:92`) | System WAV (diarized) + mic WAV (raw) |
| Import audio into a note | `AppState.importAudio` (`AppState.swift:174`) | One file, diarized; no mic track |
| Chat action `retranscribe` | `MeetingActionExecutor.execute` | `audioFilePath` (system WAV) only; resets `speakers` to `[:]`; regenerates summary and title |

### Stop-and-process steps

1. System WAV → `DiarizedTranscriptionService.transcribe(audioURL:speakerTagOffset: 2)`. A failure here fails the whole job (a note without transcript is saved and the error shown).
2. Mic WAV, if it exists and is > 4096 bytes → `WhisperTranscriptionService.transcribeRaw`; every segment gets `speakerTag = 1`. A mic failure is logged and ignored.
3. `systemSegments + micSegments` sorted by `startTime`.
4. `OpenAIService.summarize` (`gpt-4o`) with segments and live notes → title, summary, action items.
5. Save `Note` + `MeetingAttachment`.

Speaker tag convention: **1 = mic (the local user)**, **≥ 2 = system-audio speakers**, 0 = warning marker (Whisper partial-failure marker).

## `DiarizedTranscriptionService`

| Item | Value (from code) |
|---|---|
| Model | `gpt-4o-transcribe-diarize` |
| Endpoint | `POST https://api.openai.com/v1/audio/transcriptions` (multipart) |
| Fields | `response_format=diarized_json`, `chunking_strategy=auto`, `file` |
| Timeout | 300 s |
| Pre-processing | Transcode to mono AAC/M4A, 16 kHz, 32 kbps (`AVAssetWriter`). ~0.24 MB/min → 60 min ≈ 14 MB; ~105 min reaches the limit. On transcode failure the original file is sent. |
| Single-call threshold | `singleCallMaxFileSize` = 24 × 1024 × 1024 bytes of the (transcoded) file |
| Chunked fallback | Used only above the threshold: target 345 s per chunk, search ±60 s for silence, minimum chunk 60 s |
| Silence detection | 30 ms RMS windows; silent if energy ≤ 0.20 × median; a run needs ≥ 200 ms; cut at the run centre nearest the target; hard cut at the target if none; uniform cuts if detection throws |
| Chunk export | `AVAssetExportPresetAppleM4A`, unique temp dir per job |
| Speaker tags | Labels mapped to ints in first-seen order starting at `speakerTagBase`; chunk *i* uses `speakerTagOffset + i × 50` (`speakerNamespaceStride`) |
| Timestamps | `start`/`end` read as seconds; values ≥ 10000 are divided by 1000 (defensive; flagged in pn6); chunk start offset added; `end ≥ start + 0.01` |
| Dropped segments | Empty text or missing `speaker` are dropped and counted in the log |
| Failures | Single call: error propagates. Chunked: a failed chunk is logged and **skipped**; error only if all chunks fail |

Single-call is the intended normal case: one call → one consistent speaker namespace.

## Mic transcription (`WhisperTranscriptionService.transcribeRaw`)

Despite the class name, the live model is **`gpt-4o-mini-transcribe-2025-12-15`** (same `/v1/audio/transcriptions` endpoint, `response_format=json`). That model returns text without segment timestamps (bd `pn6`, `66z`, `bfe`), so the parser falls back to one segment per chunk (`startTime = chunk offset`, `endTime = offset + 0.01`).

- Chunks: 720 s with 20 s overlap (`.m4a` via `AVAssetExportPresetAppleM4A`, files named `chunk_<start>.m4a` in the shared temp dir). Audio ≤ 740 s is sent whole.
- On a chunk error it stops, keeps earlier chunks, and appends a tag-0 marker segment "⚠️ Chunk i/n failed… Saving partial transcript."
- `transcribeRaw` does **not** de-duplicate the 20 s overlaps.

## Dead code still in the tree

| Symbol | State |
|---|---|
| `WhisperTranscriptionService.transcribe(audioURL:)`, `transcribe(systemURL:micURL:)`, `inferSpeakers` (`gpt-4o` text-based speaker guess), `dedupeOverlap` | No live callers; only `transcribeRaw` is used |
| `OpenAIService.consolidateSpeakerTags` | Removed from the live path in `71c3f6a` (corrupted attribution); function remains |
| `AppState.assemblyAIKey` | Declared, no UI, no use |

Do not wire these back in without superseding [DEC-004](../decisions/DEC-004-single-call-diarization.md).

## What is not verified

- Output quality and speaker count on real calls (pn6, e3l).
- That the diarizer's `speaker` labels are strings handled by the parser, and that timestamps are seconds (pn6).
- That a single request for a long recording is not truncated by the output-token cap noted in pn6 (see [../open-questions.md](../open-questions.md)).
- That mic/system PTS alignment is correct (e3l; see [recording.md](recording.md)).

## History (why the code looks like this)

| Date | Commit / bd | Event |
|---|---|---|
| 2026-05-02 | `76e0639`, `416e033`, `f98f3b9` | Initial Google Cloud Speech-to-Text with diarization; moved to GCS + `longrunningrecognize`, then service-account JWT auth |
| 2026-05-02 | `ba0cd48` | Google STT/GCS removed. 12-min chunks with 20 s overlap through `whisper-1` (`verbose_json`) + a `gpt-4o` pass to assign speaker IDs. Settings reduced to OpenAI + Brave ("single API key covers the full pipeline") |
| 2026-05-05 | `076cee9` | Separate mic/system WAVs; mic = Speaker 1, system = Speaker 2; no GPT inference needed to identify the local user |
| 2026-06-01 | `0f7c03c`, `271b699` (`bfe`) | Model moved to `gpt-4o-mini-transcribe` (multilingual); `verbose_json` dropped, text-only responses handled |
| 2026-06-01 | `63df9f1` (`c62`), `4a1830f` (`45v`) | AssemblyAI diarization for system audio; then a hybrid: AssemblyAI speaker turns + OpenAI text |
| 2026-06-04 | `7a079ca` (`2kz`) | `gpt-4o` speaker-inference pass added after the hybrid |
| 2026-06-17 | `d47aba3` (`66z`), `14cd444` (`st3`) | Because OpenAI returned one blob per chunk, text was sliced across AssemblyAI turns by character proportion; `consolidateSpeakerTags` added because AssemblyAI over-fragmented speakers |
| 2026-09-02 | `6810e66` (`pn6`) | Hybrid and `mergeSpeakerLabels` deleted; `gpt-4o-transcribe-diarize` introduced (single call ≤ 9 min / 24 MB, else silence-split with consolidation) |
| 2026-09-04 | `71c3f6a` (`e3l`) | PTS single-clock alignment; AAC transcode so most calls are one request; `consolidateSpeakerTags` removed from live path |

Rationale for each step is in [DEC-002](../decisions/DEC-002-local-storage-cloud-processing.md), [DEC-003](../decisions/DEC-003-separate-mic-system-tracks.md) and [DEC-004](../decisions/DEC-004-single-call-diarization.md).

### Why AssemblyAI was dropped (do not revive without new evidence)

AssemblyAI's own transcript text was rejected earlier for poor content quality and weak multilingual handling (bd `45v`, `pn6`), so only its speaker turns were used. Applying those turns to OpenAI's single untimestamped text blob per chunk required slicing the text by character-count proportion, an invalid alignment that produced garbled, run-on, misattributed text on real recordings (bd `pn6`). The consolidation pass that followed (`st3`) was later shown to corrupt attribution (commit `71c3f6a`).
