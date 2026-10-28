# DEC-006: MeetCapture as a measurement-first POC

**Status:** Accepted — pending live verification (bd `OnlyNotes-9zy.1` in progress; epic `OnlyNotes-9zy` open)
**Date:** 2026-09-02
**Deciders:** Anoop Santhanam
**Last verified:** 2026-10-28
**Source:** `MeetCapture/*`, commits `c8a9149`, `da05046`, bd `OnlyNotes-9zy`, `OnlyNotes-9zy.1`, `OnlyNotes-jwq`, `OnlyNotes-rfn`

## Context

Most of the user's calls are Google Meet. An OS-level recorder has weak mic gain (`rfn`), guessed attribution, and no participant names. A Chrome extension can capture the Meet tab and the mic as separate tracks and observe Meet's UI for who is speaking. Independent scoping (bd `9zy`) warned that the UI signal is evidence, not ground truth: undocumented DOM, affected by pinning and presentation mode, cannot represent simultaneous speakers, ~100 ms detection delay.

## Decision

- Build only a POC that records `tab-audio.webm`, optional `mic-audio.webm`, and `timeline.json`, then **measure** UI evidence quality manually on 5–10 real calls (screen share, pinned tile, join/leave, overlap, long call) before building anything else.
- Explicitly out of scope for the POC: localhost bridge, Mac-app ingestion, ASR/alignment, name-correction UI, Zoom.
- If measurement passes, the proposed next steps (**not implemented**) are an authenticated loopback bridge, a first-class ingestion path (not `importAudio`), a speaker timeline model, and conservative attribution with confidence and an Unknown/Multiple outcome. If it fails, escalate to WebRTC per-track capture (`jwq`).

## Consequences

**Positive:**
- Cheap test of the one unknown that gates the epic.
- Does not change the Mac app or its data model.

**Negative:**
- Selectors in `content.js` are unverified guesses; first runs may yield mostly heartbeat events.
- Manual evaluation is required; there is no automated accuracy metric.
- Covers Meet in Chrome only; room recordings still use the app recorder with its mic problems.

## Alternatives considered

| Option | Why rejected / not chosen |
|---|---|
| WebRTC `RTCPeerConnection` hook for per-participant tracks (`jwq`) | Higher accuracy and overlap-safe, but far more brittle (depends on Meet internals); kept as escalation only |
| `tabCapture` mixed audio only (rejected in `jwq` as "back to square one") | Chosen for the POC anyway, combined with a separate mic track and the UI timeline; `9zy` (later) accepts best-effort attribution |
| Google Meet Media API | Workspace/enterprise oriented, needs app approval (`jwq`); revisit if on Workspace |
| Scrape Meet live captions | Mediocre ASR text; usable only as a speaker/timing layer (`jwq`) |
| Acoustic diarization (pyannote) | Weaker on similar voices and overlap (`jwq`) |
| Build the full pipeline first | Would waste effort if UI evidence is poor |

## References

- bd: `OnlyNotes-9zy`, `OnlyNotes-9zy.1`, `OnlyNotes-jwq`, `OnlyNotes-zpv`, `OnlyNotes-rfn`
- [../systems/meetcapture.md](../systems/meetcapture.md)
