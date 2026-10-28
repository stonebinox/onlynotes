# OnlyNotes

A macOS meeting-notes app built with Swift + SwiftUI. It records meeting audio, transcribes it with speaker diarization, and generates summaries and per-meeting AI chat. Notes and audio are **stored locally**; audio, transcripts and note text are **processed by cloud APIs** (OpenAI, Brave Search).

## Project Knowledge — Read Before Planning

Project facts live in **[onlynotes-local/](onlynotes-local/README.md)**, not in this file. Before planning or reviewing substantive work, read:

1. `onlynotes-local/README.md` — reading order and source-of-truth rules
2. `onlynotes-local/current-state.md` — what exists and what is unverified
3. The relevant `onlynotes-local/systems/*.md` and `onlynotes-local/decisions/` — don't re-decide settled things

The knowledge base is a starting point, not ground truth: verify claims against the code, and fix a doc when it is stale.

| What | Where |
|------|-------|
| Tasks and task history | `bd` |
| Architecture, state, constraints, decisions | `onlynotes-local/` |
| Claude's role and workflow | this file |
| Codex's role and review rules | `AGENTS.md` |
| The user's working preferences for Claude | Claude memory |

## Build

```bash
xcodebuild -scheme OnlyNotes -configuration Debug build
```

Build must pass before every commit. There is no automated test suite.

---

## ⛔ PRE-FLIGHT CHECK — Read This BEFORE Every Task

**Before touching ANY file, answer these questions. If ANY answer is "no", STOP.**

1. **Have I kicked off Codex co-scoping?** → If no: `codex exec` FIRST, before reading code or planning.
2. **Am I about to edit a source file directly?** → If yes: STOP. Delegate to Sonnet via CLI.
3. **Has Sonnet just finished?** → If yes: kick off Codex review FIRST, before building or committing.
4. **Am I about to commit?** → If yes: confirm Codex review passed with zero BLOCKING issues AND build passes AND `onlynotes-local/` reflects the change.

---

## Development Workflow

### HARD RULE: Claude Never Codes

**Claude MUST NOT write source code directly.** All code changes go through Sonnet, invoked as a CLI subprocess. The ONLY files Claude may edit directly are documentation: `CLAUDE.md`, `AGENTS.md`, `onlynotes-local/`, memory files.

- **Claude:** analyze, plan, orchestrate, review, commit
- **Sonnet (via CLI):** write and edit Swift source files

### How to Invoke Sonnet

```bash
(unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; claude -p --model sonnet --dangerously-skip-permissions "PROMPT" 2>&1)
```

For larger prompts, write to a file and pipe it:
```bash
(unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; cat /tmp/task-prompt.txt | claude -p --model sonnet --dangerously-skip-permissions 2>&1)
```

> **Do NOT unset `CLAUDE_CONFIG_DIR`.** This machine's credentials live in the
> config dir it points to; unsetting it sends the subprocess to an
> unauthenticated `~/.claude` and Sonnet fails with `401 Invalid authentication
> credentials`.

Always include in the prompt: which files to read, what to change, and the acceptance criteria. When the change alters behaviour, architecture or a constraint, tell Sonnet which `onlynotes-local/` docs to update in the same change.

### Four-Phase Workflow

Every task goes through all four phases — no exceptions.

#### Phase 1: Planning (Claude + Codex pair)

Claude describes the goal in plain language to Codex — nothing more. Then invokes:

```bash
codex exec "PLAIN DESCRIPTION OF WHAT WE WANT TO ACHIEVE. Explore the codebase at ~/Projects/OnlyNotes and give your full independent assessment." --sandbox danger-full-access -o /tmp/codex-pair.md
```

**⛔ HARD RULES for Phase 1 — violating any of these is wrong:**
- **NO bd task yet.** The bd task is created AFTER Codex scoping, not before.
- **NO file hints.** Do not tell Codex which files to look at. It must find them itself.
- **NO approach hints.** Do not suggest an implementation strategy. Codex must form its own view.
- **NO pre-digested context.** Don't summarise what you already know. Give Codex a clean slate.
- The goal is a genuine independent second opinion — a pair programmer who might catch what you missed, not a mirror that confirms what you already think.

Codex reads `onlynotes-local/` on its own per `AGENTS.md`, and is told to verify it against the code. That is not a hint from Claude; don't point Codex at specific KB docs in the prompt.

After reading Codex's output, Claude reconciles findings with its own thinking, resolves any disagreements with the user if needed, then creates the bd task with the consolidated plan.

#### Phase 2: Implementation (Claude → Sonnet via CLI)

- Claude delegates all Swift coding to Sonnet via CLI
- Claude verifies the build passes: `xcodebuild -scheme OnlyNotes -configuration Debug build`
- Claude reviews `git diff` after Sonnet finishes
- Claude commits at meaningful milestones

#### Phase 3: Pre-Push Review (Codex reviews)

```bash
codex exec "Review the latest implementation in the OnlyNotes codebase at ~/Projects/OnlyNotes. Run 'bd list' to find the relevant in-progress task, then 'bd show OnlyNotes-xxx' for scope. Run 'git diff HEAD~1' to see what changed. Categorize all findings as BLOCKING or NON-BLOCKING." --sandbox danger-full-access -o /tmp/codex-review.md
```

**⛔ HARD RULES for Phase 3 — violating any of these is wrong:**
- **NO file hints.** Do not tell Codex which files to review.
- **NO issue hints.** Do not tell Codex what to look for or what might be wrong.
- **NO approach hints.** Do not describe how it was implemented.
- Codex must review the diff cold and form its own findings independently.

#### Phase 4: Resolution

- Claude addresses BLOCKING issues via Sonnet CLI
- Re-invoke Codex review if blocking issues were fixed
- NON-BLOCKING issues become new bd tasks
- Before closing the bd task, run the extraction checklist in `onlynotes-local/process/documentation-rules.md`

### Codex CLI Notes

- **Always use:** `codex exec "PROMPT" --sandbox danger-full-access -o /tmp/output.md`
- **Never use:** `codex review`
- **Why `danger-full-access`:** bd writes to SQLite outside the workdir; default sandbox blocks this

---

## Commit Rules

- Conventional commits: `<type>: <subject>` with optional body
- Types: `feat`, `fix`, `refactor`, `docs`, `style`, `chore`
- **NO AI ATTRIBUTION** — never add "Co-authored-by: Claude" or similar
- **Never push without explicit user consent** — ask before every `git push` and `bd dolt push`; consent does not carry over
- **Build must pass before every commit**
- **Update `onlynotes-local/` in the same commit** as the code change it describes
- Commit at meaningful milestones, not in large batches

## Task Management (bd)

```bash
bd ready                              # Show unblocked work
bd list                               # List open tasks
bd create "Title" -d "Details"        # Create task
bd show OnlyNotes-xxx                 # View task details
bd update OnlyNotes-xxx --status in_progress
bd close OnlyNotes-xxx                # Mark complete
bd sync                               # Sync before git ops
```


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Durable project facts go in `onlynotes-local/`; the user's working preferences go in Claude memory; `bd remember` is for short cross-session notes the beads tooling surfaces

## Session Completion

**When ending a work session**, complete these steps:

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Build
3. **Update issue status** - Close finished work, update in-progress items
4. **Commit** - All changes committed locally
5. **Ask before pushing** - Ask the user, every time, before running:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # should show "up to date with origin"
   ```
   If the user approves and a push fails, resolve and retry.
6. **Hand off** - Provide context for next session, including anything left unpushed
<!-- END BEADS INTEGRATION -->
