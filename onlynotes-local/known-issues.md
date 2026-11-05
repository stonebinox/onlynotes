# Known Issues

**Status:** Current. Items without a bd ID were found by reading code and have no task yet.
**Last verified:** 2026-10-28
**Source:** `bd list --all`, `OnlyNotes/*`

One line each: symptom → impact. Details live in the bd task.

## Recording

| Issue | Symptom → impact |
|---|---|
| OnlyNotes-rfn | Mic WAV ~15 dB quieter than system WAV → Speaker 1 transcript garbled/unreliable |
| OnlyNotes-1b2 | Crackling on playback → possible ASR degradation. **Addressed by OnlyNotes-awy.1** (cached converter per track, limiter removed); pending real-use verification, not yet confirmed fixed |
| OnlyNotes-84t | `AudioRecorder` swallowed conversion/write failures → silent audio loss. **Addressed by OnlyNotes-awy.1** (damage counted and surfaced as `processingError`); pending real-use verification, not yet confirmed fixed |
| No task | SCStream stop mid-recording ends the session; no resume → audio after that point is not captured (since awy.1, the note is still produced with a warning) |
| OnlyNotes-awy.1 | Recordings made before awy.1: mic WAV is about 1.5% shorter than system WAV (normally 1.47–1.74%; 72-minute call: 63.6 s) → the tracks drift apart, so old recordings stay misaligned and retranscribing won't fix that |
| OnlyNotes-gqz | `try?` at the Record buttons swallows start errors (permission, WAV open, directory creation) → Record appears to do nothing |
| OnlyNotes-ii9 | Menu bar hides Record while a previous meeting is processing → blocks back-to-back recording from the menu bar |
| OnlyNotes-54u | `isProcessing`/`processingError` are shared across recordings → back-to-back recordings can overwrite each other's status |
| OnlyNotes-er0 | Recording warnings appear under the "Transcription failed" alert even when the note saved → misleading |
| OnlyNotes-e6k | After a `stopCapture` timeout the next session can start while the old SCStream may still be running |
| OnlyNotes-awy.4 | Missing frames, partial chunks and empty transcription are not shown as warnings → silent gaps |

## Transcription and diarization

| Issue | Symptom → impact |
|---|---|
| OnlyNotes-pn6, OnlyNotes-e3l | Not live-verified → speaker count/attribution quality unknown on real calls |
| OnlyNotes-awy | OpenAI notice of 2026-08-26: `gpt-4o-transcribe-diarize` and `gpt-4o-mini-transcribe` shut down 2027-02-26 → current transcription stops working then unless the engine is replaced (S3). Re-check the date before relying on it |
| No task | Mic track uses `gpt-4o-mini-transcribe`, which returns text without segment timestamps (pn6, 66z); each mic chunk becomes one segment → Speaker 1 is a coarse block placed at chunk start in the merged transcript |
| OnlyNotes-whz | `transcribeRaw` does not run `dedupeOverlap`; mic chunks overlap by 20 s on recordings > 12 min 20 s → possible repeated text |
| OnlyNotes-nq8 | Addressed in code, **pending Phase 5**: failed chunks are retried (5 attempts), then the track fails visibly (no partial tracks, DEC-008). Worst case about 1,610 s per request (5 × 300 s timeout + 110 s sleeps), independently per failed chunk. Whether offline failures fail fast or reach the 300 s timeout is unmeasured. Also covers empty-text responses (`{"text":""}` is now a zero-segment chunk, not a parse error) and an all-empty mic track (`transcribeRaw` throws, so the tag-0 marker shows); pending Phase 5 on the real 22:00:51 recording |
| No task | Chunked diarization gives each chunk its own speaker tag range (stride 50) → same person gets different tags per chunk |
| OnlyNotes-87j | `dedupeOverlap` removes duplicate text globally → short acknowledgements ("yeah") dropped (only affects the Whisper-service helpers; mic path does not call it today) |
| OnlyNotes-uc3 | Addressed in code, **pending Phase 5**: retranscribe derives and transcribes `<system>_mic.wav`. The path is still not persisted; recordings whose mic file was deleted (e.g. by the old ≤ 740 s cleanup, bd `mi5`) cannot be recovered |
| OnlyNotes-8ru | Addressed in code (chunk files carry a per-job UUID), **pending Phase 5** |
| OnlyNotes-zpv | No per-word timestamps → blocks precise text/timeline alignment |
| OnlyNotes-cyy | Retranscribe resets `speakers` to `[:]` → renamed speakers lost |

## Storage and data

| Issue | Symptom → impact |
|---|---|
| OnlyNotes-kep | `NoteStore.loadAll` returns `[]` on decode failure and `save` then rewrites `notes.json` from that empty list → a corrupt/unreadable file is overwritten on the next save (from code reading; not reproduced) |
| OnlyNotes-97z | `NoteStore.delete` removes only `audioFilePath` (system WAV) → `_mic.wav` stays on disk |
| OnlyNotes-mi5 | Addressed in code, **pending Phase 5**: `transcribeRaw` deleted the source mic WAV after transcribing audio of 740 s or less (the source is its own single chunk). Verified 2026-11-04: 6 of 105 recordings have no `_mic.wav` (e.g. 2026-06-15, 06-17, 06-22 short calls); those files are gone for good |
| OnlyNotes-59a | `NoteStore.save` swallows encode/write errors → a full disk loses a new transcript or a retranscribe result silently (from code reading, Codex review 2026-11-04) |
| OnlyNotes-2b2 | Tag-0 "⚠️" marker segment counts as "Speaker 0" in the speaker list and rename UI |
| OnlyNotes-6k0 | `@AppStorage` keeps OpenAI and Brave keys in `UserDefaults` → keys not in Keychain |
| OnlyNotes-s69 | `assemblyAIKey` still declared in `AppState`, no UI or use → dead setting |

## Playback

| Issue | Symptom → impact |
|---|---|
| OnlyNotes-isf | Playback plays system track only → user never hears their own voice |

## AI and context

| Issue | Symptom → impact |
|---|---|
| OnlyNotes-2vl | Context query = title + last 300 body chars → noisy web results on multi-topic notes |
| OnlyNotes-udn | One chat action per response → compound requests need separate messages |
| No task | Summary, chat and translation send the full transcript with no truncation → very long meetings may exceed model context (not tested) |
| OnlyNotes-2y8 | bd `oc9` calls `gpt-4o` "retired" but summary/chat/translate still use it |

## Repo hygiene

| Issue | Symptom → impact |
|---|---|
| OnlyNotes-4bf | `UserInterfaceState.xcuserstate` tracked → noise in every diff |
| OnlyNotes-yky | Open task to batch `consolidateSpeakerTags` → moot while that function is off the live path (removal: OnlyNotes-s69) |
| OnlyNotes-h3d | `MeetCapture/README.md` disagrees with the code (permissions, signal names, durations) → see [systems/meetcapture.md](systems/meetcapture.md) for actual behaviour |
