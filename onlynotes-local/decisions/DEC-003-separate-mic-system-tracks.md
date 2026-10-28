# DEC-003: Separate mic and system audio tracks

**Status:** Accepted — pending live verification (clock alignment, bd `OnlyNotes-e3l`)
**Date:** 2026-05-05 (separation); 2026-09-04 (single clock)
**Deciders:** Anoop Santhanam
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/Services/AudioRecorder.swift`, `OnlyNotes/AppState.swift`, commits `acbcfb6`, `076cee9`, `71c3f6a`, bd `OnlyNotes-e3l`, `OnlyNotes-rfn`, `OnlyNotes-isf`, `OnlyNotes-uc3`

## Context

The first ScreenCaptureKit version (`acbcfb6`) mixed mic and system audio into one WAV and relied on transcription plus a `gpt-4o` text pass to work out who spoke. In a call the local user is only on the mic and remote participants are only on the system output, so the capture source already identifies "me".

## Decision

- Write two WAVs: system audio (remote participants) and mic (the local user).
- Transcribe separately: system → diarized speakers with tags ≥ 2; mic → **Speaker 1**. Tag 1 is reserved for the mic everywhere.
- Both tracks share one clock: each buffer's presentation timestamp is compared with a host-clock anchor captured before capture starts, and silence is padded so frame N means the same absolute time in both files. Segments are merged by `startTime`.
- The note keeps only the system WAV path for playback and retranscribe.

## Consequences

**Positive:**
- The local speaker needs no inference; the diarizer only separates remote voices.
- Source-channel identity is not affected by text-only guessing errors.

**Negative:**
- Mic capture requires macOS 15+ (`#available(macOS 15.0, *)`); on macOS 14 only the system track exists.
- Mic level is ~15 dB low (`rfn`), producing poor Speaker 1 text.
- Speaker-mode leakage (remote voices on the mic) is unaddressed (follow-up in `e3l`, no task).
- Mic path is not persisted (`uc3`) and playback omits the mic (`isf`).
- Whole-display capture takes audio from every app.
- Alignment correctness is **unverified** on a real call.

## Alternatives considered

| Option | Why rejected / not chosen |
|---|---|
| One mixed WAV (`acbcfb6`) | Loses source identity; requires inferring the local speaker acoustically/textually |
| Single track + `gpt-4o` speaker inference (`ba0cd48`, `2kz`) | Text-only inference; replaced once separate tracks existed |
| Peak-normalizing each stream to level-match them (`acbcfb6`, `0s0`) | Caused gain pumping; replaced by a soft limiter in `0451236` |
| Independent clocks per track (before `71c3f6a`) | Produced mis-ordered/swapped lines (bd `e3l`) |
| Post-hoc `consolidateSpeakerTags` merge across tracks | Corrupted attribution; removed from live path in `71c3f6a` |

## References

- bd: `OnlyNotes-e3l` (in progress), `OnlyNotes-rfn`, `OnlyNotes-isf`, `OnlyNotes-uc3`
- [../systems/recording.md](../systems/recording.md)
