# Documentation Rules

**Status:** Current
**Last verified:** 2026-10-28
**Source:** `onlynotes-local/README.md`, bd `OnlyNotes-90d`

## What goes where

| Content | Location |
|---|---|
| Task status, acceptance criteria, task-level discussion | bd |
| Current architecture, behaviour, constants, on-disk paths | `systems/*.md` |
| Snapshot of what exists / is unverified | `current-state.md` |
| Hard limits vs fixable limitations | `constraints.md` |
| One-line defects with bd links | `known-issues.md` |
| Unresolved questions | `open-questions.md` |
| Why a choice was made, what was rejected | `decisions/DEC-NNN-*.md` |
| Agent role, delegation, review, commit rules | `CLAUDE.md` / `AGENTS.md` (no architecture there beyond a pointer) |
| User's working preferences | Claude memory |

Each fact lives in one place; link instead of copying.

## Header on every doc

```
# Title
**Status:** Current | Experimental | Unverified | Proposed — not implemented | Accepted ...
**Last verified:** YYYY-MM-DD
**Source:** repo-relative paths
```

Update `Last verified` only after re-checking the doc against code, not on unrelated edits.

## Same-commit rule

A code change that alters behaviour, a constant, a model name, an on-disk path, or a limit updates the relevant `systems/` doc (and `current-state.md` / `known-issues.md` if affected) in the same commit.

## Extraction checklist when closing a bd task

- [ ] New or changed behaviour → `systems/` doc.
- [ ] New constraint or limit discovered → `constraints.md`.
- [ ] Defect fixed → remove from `known-issues.md`; defect found and deferred → add with bd ID.
- [ ] Question answered → remove from `open-questions.md` and record the answer where it belongs.
- [ ] Approach chosen, reversed, or rejected → new or superseding ADR.
- [ ] "Verified live" status changed → update `current-state.md` and ADR status (e.g. "Accepted — pending live verification" → "Accepted").

## ADRs

- Use [decisions/decision-template.md](../decisions/decision-template.md); number sequentially; list in [decisions/README.md](../decisions/README.md).
- Do not rewrite an accepted ADR's reasoning. Add a new ADR, set the old one to `Superseded by DEC-NNN`, and link both ways. Typo/link fixes and status updates are fine.

## Never commit

API keys or tokens, `.env`-style files, audio recordings, real transcripts or meeting content, screenshots of real meetings, `timeline.json` captures from real calls. Use invented examples.
