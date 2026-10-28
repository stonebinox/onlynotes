# OnlyNotes Knowledge Base

**Status:** Current (maintained alongside code)
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/`, `MeetCapture/`, `bd list --all`, `git log`

## What OnlyNotes is

- A macOS 14+ menu-bar + window app (Swift 5 / SwiftUI) for notes and meeting notes.
- Records system audio (and, on macOS 15+, the microphone) via ScreenCaptureKit, transcribes with speaker labels through OpenAI, and summarizes with OpenAI.
- Notes and audio are **stored locally** (JSON + WAV under `~/Library/Application Support/OnlyNotes/`). Processing is **not local**: audio, transcripts and note text go to OpenAI; note-derived search queries go to Brave Search and OpenAI.
- `MeetCapture/` is a separate, unverified Chrome-extension proof of concept. It is not connected to the app.

## Reading order for agents

1. [current-state.md](current-state.md) — what exists, what is unverified.
2. [system-map.md](system-map.md) — end-to-end flow.
3. [constraints.md](constraints.md) and [known-issues.md](known-issues.md) — limits and open defects.
4. The relevant file in `systems/` for the area you are touching.
5. [decisions/README.md](decisions/README.md) — settled choices and rejected approaches. Do not re-decide these without superseding the ADR.
6. [open-questions.md](open-questions.md) — unresolved items; flag them rather than assuming.

## Folder map

| Path | Contents |
|---|---|
| `current-state.md` | Snapshot of capabilities and verification status |
| `system-map.md` | Data flow, room-recorder path vs MeetCapture |
| `constraints.md` | Hard constraints vs current limitations |
| `known-issues.md` | Symptom + impact, linked to bd IDs |
| `open-questions.md` | Unresolved questions, linked to bd IDs |
| `systems/` | One file per subsystem (recording, transcription, storage, AI/context, chat actions, MeetCapture) |
| `decisions/` | ADRs (`DEC-NNN`), template, index |
| `process/documentation-rules.md` | How this folder is maintained |

## Source-of-truth table

| Kind of information | Lives in |
|---|---|
| Tasks, status, task-level rationale | bd (beads): `bd list`, `bd show <id>` |
| Durable facts: architecture, constraints, decisions, failure modes | `onlynotes-local/` |
| Agent role and workflow (who codes, who reviews, commit rules) | `CLAUDE.md`, `AGENTS.md` |
| User's working preferences | Claude memory |
| Cross-session notes for beads | `bd remember` |

## Rule: verify, then fix

Treat every claim here as a pointer, not proof. Before relying on a claim, check it against the code (paths and symbols are cited). If a doc is stale or wrong, fix it in the same change that discovers it, and update `Last verified`. Never commit secrets, API keys, recordings, or real transcripts to this folder (see [process/documentation-rules.md](process/documentation-rules.md)).
