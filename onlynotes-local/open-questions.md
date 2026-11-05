# Open Questions

**Status:** Current
**Last verified:** 2026-10-28
**Source:** `bd list --all`, `OnlyNotes/*`, `MeetCapture/*`

## Transcription and diarization

| Question | Tracking |
|---|---|
| Does `gpt-4o-transcribe-diarize` give coherent per-speaker text on a real 20–40 min recording? | `OnlyNotes-pn6` |
| Does the API's `speaker` label format match `parseDiarizedResponse` (it maps any string in first-seen order)? | `OnlyNotes-pn6` |
| Are API `start`/`end` values seconds? The parser treats values ≥ 10000 as milliseconds, which would misfire on a > 2.7 h recording in seconds. | `OnlyNotes-pn6` |
| Does PTS-anchored alignment fix swapped/misordered lines, and is the speaker count right (2 people → 2)? | `OnlyNotes-e3l` |
| How should speaker identity persist across chunks for recordings that exceed either single-call condition (>= 24 MiB or > 1399 s)? | e3l follow-up (no task); `known_speaker_references` mentioned in pn6 |
| How should speaker-mode leakage (remote voices picked up by the mic) be de-bled? | `OnlyNotes-awy` S3/S4 |
| Which engine replaces the OpenAI models before the 2027-02-26 shutdown? FluidAudio is first to test; the choice waits for spike evidence. | `OnlyNotes-awy` S3 |
| Should `known_speaker_references` (up to 4 clips) be used? | pn6 follow-up (no task) |
| Should per-word timestamps be pursued? | `OnlyNotes-zpv` |

## Recording and playback

| Question | Tracking |
|---|---|
| Why is the mic captured ~15 dB low, and should gain be corrected at capture or before transcription? | `OnlyNotes-rfn` |
| Did the cached converter (awy.1) remove the crackle and the mic-length shortfall? Needs a real recording. | `OnlyNotes-awy.1`, `OnlyNotes-1b2` |
| Do PTS and the host clock agree closely enough to turn PTS padding on? Needs the 30 s diagnostic. | `OnlyNotes-awy.1` |
| Should playback mix mic + system or play both? | `OnlyNotes-isf` |
| Should the mic audio path be persisted for playback? (Retranscribe now derives it.) | `OnlyNotes-uc3`, `OnlyNotes-isf` |

## MeetCapture

| Question | Tracking |
|---|---|
| Is Meet's UI active-speaker evidence accurate enough to attribute a transcript? (Go/no-go needs 5–10 real calls incl. screen share, pinned tile, join/leave, overlap, long call.) | `OnlyNotes-9zy.1` |
| If not, escalate to WebRTC per-track capture and/or local transcription on a Raspberry Pi? | `OnlyNotes-jwq` |
| Do the DOM selectors in `content.js` match anything in live Meet? One 7-minute test matched nothing (see [systems/meetcapture.md](systems/meetcapture.md)). Which signals work today? | `OnlyNotes-awy.3` |
| How would the Mac app ingest the speaker timeline? The `awy` plan excludes a localhost bridge and extension media capture; details are re-planned after `awy.3`. | `OnlyNotes-awy` |

## AI and context

| Question | Tracking |
|---|---|
| bd `oc9` describes `gpt-4o` as "retired", yet `OpenAIService` still uses `gpt-4o` for summary, chat, translation (lines 114, 164, 231, 307). Do these calls still succeed, and should the model change? | `OnlyNotes-2y8` |
| Should context queries extract topics instead of using the last 300 characters? | `OnlyNotes-2vl` |
| Should chat support multi-step action chains? | `OnlyNotes-udn` |

## Process

| Question | Tracking |
|---|---|
| Root `CLAUDE.md`/`AGENTS.md` still need stale-content cleanup and a push-rule fix (this KB is the replacement source of truth). | `OnlyNotes-90d` |
