# OnlyNotes

A local-first macOS meeting notes app built with Swift + SwiftUI.

## Project Overview

OnlyNotes records meeting audio, transcribes it with speaker diarization via Google Cloud Speech-to-Text, and generates summaries + AI chat via OpenAI GPT-4o. All data stays local on the user's device.

## Tech Stack

- **Language:** Swift 5
- **UI:** SwiftUI (macOS 14+)
- **Audio:** AVAudioEngine (16kHz mono WAV, drop-resistant with AVAudioEngineConfigurationChange)
- **Transcription:** OpenAI Whisper (chunked, verbose_json) + GPT-4o speaker inference
- **AI:** OpenAI GPT-4o (summarization, AI chat per meeting, speaker diarization)
- **Storage:** JSON file in ~/Library/Application Support/OnlyNotes/
- **Issue Tracking:** bd (beads)

## Project Structure

```
OnlyNotes/
├── OnlyNotes.xcodeproj/
├── OnlyNotes/
│   ├── OnlyNotesApp.swift       # App entry point, menu bar + window scenes
│   ├── AppState.swift           # Shared app state + recorder + processing pipeline
│   ├── Info.plist
│   ├── OnlyNotes.entitlements
│   ├── Models/
│   │   ├── Meeting.swift        # Meeting model + ChatMessage
│   │   └── TranscriptSegment.swift
│   ├── Services/
│   │   ├── AudioRecorder.swift  # AVAudioEngine recording, drop detection
│   │   ├── GoogleSpeechService.swift  # GCS upload + STT transcription
│   │   ├── OpenAIService.swift  # Summarization + AI chat
│   │   └── MeetingStore.swift   # JSON persistence
│   └── Views/
│       ├── ContentView.swift
│       ├── MeetingListView.swift
│       ├── MeetingDetailView.swift  # Summary/speakers/transcript/chat/playback/export
│       ├── MenuBarView.swift
│       └── SettingsView.swift
```

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
4. **Am I about to commit?** → If yes: confirm Codex review passed with zero BLOCKING issues AND build passes.

---

## Development Workflow

### HARD RULE: Claude Never Codes

**Claude MUST NOT write source code directly.** All code changes go through Sonnet, invoked as a CLI subprocess. The ONLY files Claude may edit directly are documentation: `CLAUDE.md`, `AGENTS.md`, memory files.

- **Claude:** analyze, plan, orchestrate, review, commit
- **Sonnet (via CLI):** write and edit Swift source files

### How to Invoke Sonnet

```bash
(unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR; claude -p --model sonnet --dangerously-skip-permissions "PROMPT" 2>&1)
```

For larger prompts, write to a file and pipe it:
```bash
(unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR; cat /tmp/task-prompt.txt | claude -p --model sonnet --dangerously-skip-permissions 2>&1)
```

Always include in the prompt: which files to read, what to change, and the acceptance criteria.

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

### Codex CLI Notes

- **Always use:** `codex exec "PROMPT" --sandbox danger-full-access -o /tmp/output.md`
- **Never use:** `codex review`
- **Why `danger-full-access`:** bd writes to SQLite outside the workdir; default sandbox blocks this

---

## Commit Rules

- Conventional commits: `<type>: <subject>` with optional body
- Types: `feat`, `fix`, `refactor`, `docs`, `style`, `chore`
- **NO AI ATTRIBUTION** — never add "Co-authored-by: Claude" or similar
- **Never push without explicit user consent**
- **Build must pass before every commit**
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

## Key Design Decisions

- **No App Sandbox** — simplifies mic access and file storage for personal use
- **LSUIElement = YES** — menu bar app, no dock icon
- **JSON storage** — flat file, no Core Data overhead
- **No Google Cloud** — transcription is fully OpenAI (Whisper + GPT-4o), no GCS
- **Local audio files kept** — for playback


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
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
