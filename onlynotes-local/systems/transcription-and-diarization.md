# Transcription and Diarization

**Status:** Current code path. The nq8 retry / no-partial-track / mic-recovery change is **implemented, pending Phase 5 on real recordings**. **Unverified on a real recording** (bd `OnlyNotes-pn6`, `OnlyNotes-e3l`, both in progress).
**Last verified:** 2026-11-04
**Source:** `OnlyNotes/AppState.swift`, `OnlyNotes/Services/DiarizedTranscriptionService.swift`, `OnlyNotes/Services/WhisperTranscriptionService.swift`, `OnlyNotes/Services/MeetingActionExecutor.swift`, `OnlyNotes/Services/OpenAIService.swift`

## Live pipeline

Entry points, all using the same diarization call (`speakerTagOffset: 2`):

| Entry | Code | Audio used |
|---|---|---|
| Stop recording | `AppState.stopAndProcess` → `AppState.process` | System WAV (diarized) + mic WAV (raw) |
| Import audio into a note | `AppState.importAudio` | One file, diarized; no mic track |
| Chat action `retranscribe` | `MeetingActionExecutor.execute` | `audioFilePath` (system WAV) diarized, plus the mic sibling `<system path minus extension>_mic.wav` if it exists and is > 4096 bytes (transcribed like live processing, tag 1); resets `speakers` to `[:]`; regenerates summary and title. Imported audio has no mic sibling, so it stays system-only |

### Stop-and-process steps

1. System WAV → `DiarizedTranscriptionService.transcribe(audioURL:speakerTagOffset: 2)`. A failure here fails the whole job (a note without transcript is saved and the error shown).
2. Mic WAV, if it exists and is > 4096 bytes → a log line, then `WhisperTranscriptionService.transcribeRaw`; every segment gets `speakerTag = 1`. A mic failure (after retries) is non-fatal: the system segments are kept, one tag-0 marker segment ("⚠️ Your microphone could not be transcribed (<error>). Your side of the conversation is missing. The audio is kept: use Retranscribe this meeting to try again.") is appended at the end, the same text is added to `processingError` (joined with any existing warnings), and the summary still runs. Missing or tiny mic files add no marker.
3. `systemSegments + micSegments` sorted by `startTime`.
4. `OpenAIService.summarize` (`gpt-4o`) with segments and live notes → title, summary, action items.
5. Save `Note` + `MeetingAttachment`.

Speaker tag convention: **1 = mic (the local user)**, **≥ 2 = system-audio speakers**, 0 = warning marker (mic-failure marker, `WhisperTranscriptionService.micFailureMarker`).

## `DiarizedTranscriptionService`

| Item | Value (from code) |
|---|---|
| Model | `gpt-4o-transcribe-diarize` |
| Endpoint | `POST https://api.openai.com/v1/audio/transcriptions` (multipart) |
| Fields | `response_format=diarized_json`, `chunking_strategy=auto`, `file` |
| Timeout | 300 s |
| Pre-processing | Transcode to mono AAC/M4A, 16 kHz, 32 kbps (`AVAssetWriter`). ~0.24 MB/min. On transcode failure the original file is sent. |
| Single-call condition | Both: transcoded size < `singleCallMaxFileSize` (24 × 1024 × 1024 bytes) AND original loaded duration <= `singleCallMaxDuration` (1399 s; the API rejects audio over 1400 s). See [DEC-007](../decisions/DEC-007-single-call-duration-guard.md) |
| Chunked fallback | Used when either condition fails: target 345 s per chunk, search ±60 s for silence, minimum chunk 60 s |
| Silence detection | 30 ms RMS windows; silent if energy ≤ 0.20 × median; a run needs ≥ 200 ms; cut at the run centre nearest the target; hard cut at the target if none; uniform cuts if detection throws |
| Chunk export | `AVAssetExportPresetAppleM4A`, unique temp dir per job |
| Speaker tags | Labels mapped to ints in first-seen order starting at `speakerTagBase`; chunk *i* uses `speakerTagOffset + i × 50` (`speakerNamespaceStride`) |
| Timestamps | `start`/`end` read as seconds; values ≥ 10000 are divided by 1000 (defensive; flagged in pn6); chunk start offset added; `end ≥ start + 0.01` |
| Dropped segments | Empty text or missing `speaker` are dropped and counted in the log |
| Failures | Every request goes through the shared retry (below). Single call: error propagates. Chunked: the first chunk that still fails stops the loop and throws `transcriptionFailed` naming the chunk number/total, its mm:ss–mm:ss range and the final error; **no partial segments are returned** (DEC-008). `!allSegments.isEmpty` still guards the all-empty case |
| Retry | `performTranscriptionRequest` (file scope in `DiarizedTranscriptionService.swift`, also used by the mic service): 5 attempts, sleeps 5/15/30/60 s (`Task.sleep`). Retries only URLError codes timedOut, networkConnectionLost, notConnectedToInternet, cannotConnectToHost, cannotFindHost, dnsLookupFailed, secureConnectionFailed and HTTP 408, 429, 500–599 (classified on the integer status). Cancellation and other 4xx/parse/export errors throw immediately. Each failed attempt logs `<label> attempt k/5 failed after <s>s: URLError <code>` or `HTTP <status>`. Budget: about 5 × 300 s timeout + 110 s ≈ 1,610 s per request, per chunk |

Single-call is the intended case for recordings within both limits: one call → one consistent speaker namespace. Recordings over 1399 s are chunked even though their AAC is far below 24 MiB.

## Mic transcription (`WhisperTranscriptionService.transcribeRaw`)

Despite the class name, the live model is **`gpt-4o-mini-transcribe-2025-12-15`** (same `/v1/audio/transcriptions` endpoint, `response_format=json`). That model returns text without segment timestamps (bd `pn6`, `66z`, `bfe`), so the parser falls back to one segment per chunk (`startTime = chunk offset`, `endTime = offset + 0.01`).

- Chunks: 720 s with 20 s overlap (`.m4a` via `AVAssetExportPresetAppleM4A`, files named `chunk_<jobUUID>_<start>.m4a` in the temp dir, so concurrent jobs do not collide). Audio ≤ 740 s is sent whole (`splitAudio` returns the source URL).
- Each chunk request uses the shared retry. If any chunk still fails, `transcribeRaw` throws; it never returns a partial track. A `defer` removes the chunk files but never the source URL (the earlier code deleted the mic WAV for audio ≤ 740 s, bd `mi5`); `splitAudio` cleans up already-exported chunks if an export throws.
- `transcribeRaw` does **not** de-duplicate the 20 s overlaps.
- Response handling: a `segments` array is mapped as before (an empty array gives zero segments). Otherwise a top-level `text` string is used: non-empty text becomes the one coarse segment, empty or whitespace-only text is a successful zero-segment parse (the chunk does not fail and is not retried). Only a response with neither `segments` nor `text` throws `parseError`. Measured: 11 s of synthetic near-silence sent to `gpt-4o-mini-transcribe-2025-12-15` with `response_format=json` returned HTTP 200 `{"text":"","usage":...}` (2 of 2 runs, 2026-11-04). The real 22:00:51 call lost its whole mic track with "No 'segments' key in response. Top-level keys: text, usage". "No speech" is confirmed only for synthetic silence, not for arbitrary empty responses.
- If every chunk returns zero segments, `transcribeRaw` throws `transcriptionFailed("No transcript segments returned for any mic chunk")`, so the tag-0 microphone marker still appears instead of a silently empty mic track.

## Dead code still in the tree

| Symbol | State |
|---|---|
| `WhisperTranscriptionService.transcribe(audioURL:)`, `transcribe(systemURL:micURL:)`, `inferSpeakers` (`gpt-4o` text-based speaker guess), `dedupeOverlap` | No live callers; only `transcribeRaw` is used |
| `OpenAIService.consolidateSpeakerTags` | Removed from the live path in `71c3f6a` (corrupted attribution); function remains |
| `AppState.assemblyAIKey` | Declared, no UI, no use |

Do not wire these back in without superseding [DEC-004](../decisions/DEC-004-single-call-diarization.md) (itself partly superseded by [DEC-007](../decisions/DEC-007-single-call-duration-guard.md)).

## What is not verified

- Output quality and speaker count on real calls (pn6, e3l).
- That the diarizer's `speaker` labels are strings handled by the parser, and that timestamps are seconds (pn6).
- The ~2000 output-token concern from pn6 was answered by measurement for this request shape (734.8 s → 23,011 tokens; 1350 s → 42,308 tokens, last segment end 1350.9 s, max gap 0.7 s; synthetic audio, 2026-11-03). Real-call coverage of the chunked path is still to be checked (bd `OnlyNotes-aig`).
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
| 2026-11-03 | bd `OnlyNotes-aig` | A 1457 s recording took the single-call path (size only) and saved an empty fallback note; API rejects audio over 1400 s. Duration guard (<= 1399 s) restored: [DEC-007](../decisions/DEC-007-single-call-duration-guard.md) |

Rationale for each step is in [DEC-002](../decisions/DEC-002-local-storage-cloud-processing.md), [DEC-003](../decisions/DEC-003-separate-mic-system-tracks.md), [DEC-004](../decisions/DEC-004-single-call-diarization.md) and [DEC-007](../decisions/DEC-007-single-call-duration-guard.md).

### Why AssemblyAI was dropped (do not revive without new evidence)

AssemblyAI's own transcript text was rejected earlier for poor content quality and weak multilingual handling (bd `45v`, `pn6`), so only its speaker turns were used. Applying those turns to OpenAI's single untimestamped text blob per chunk required slicing the text by character-count proportion, an invalid alignment that produced garbled, run-on, misattributed text on real recordings (bd `pn6`). The consolidation pass that followed (`st3`) was later shown to corrupt attribution (commit `71c3f6a`).
