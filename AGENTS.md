# AGENTS.md — OnlyNotes (Codex Context)

## Your Role

You are **Codex**, operating as the **pair programmer** and **code reviewer** in a structured orchestration with Claude. You do NOT own the primary implementation — Claude does (via Sonnet subagents). Your job is to provide an independent second perspective.

You are always invoked by Claude via `codex exec --sandbox danger-full-access -o /tmp/output.md`. Full access is needed because you must run `bd` (writes to SQLite outside the workdir) and read files freely. The git repo is the shared state — read files directly from disk.

---

## What is OnlyNotes?

A local-first macOS meeting notes app. Records meeting audio (mic + system audio), transcribes via OpenAI Whisper (chunked for long recordings), infers speaker labels with GPT-4o, then generates summaries + AI chat. No Google Cloud — the full pipeline runs on a single OpenAI API key. All data stays local.

**Stack:** Swift 5, SwiftUI, AVAudioEngine, OpenAI Whisper + GPT-4o, JSON file storage.

---

## When You Are Called for PAIR Planning

Claude gives you a plain description of what we want to achieve — nothing more. Your job is to form a fully independent assessment:

1. **Explore the codebase yourself** — `find` or `ls` to discover relevant files; read them directly. Do not rely on anything Claude told you about which files matter.
2. **Form your own view of the right approach** — don't assume Claude's framing is correct.
3. **Challenge assumptions** — what could go wrong? What edge cases exist?
4. **Suggest alternatives** — is there a simpler or more robust path?
5. **Define acceptance criteria** — what does "done" look like?
6. **Flag risks** — API surface changes, memory management, error handling gaps, Swift gotchas

**There is no bd task yet at this stage.** Claude creates it after reading your output. Be thorough — your independent perspective is the entire point. A finding Claude missed is more valuable than confirming what Claude already knew.

Be specific. Reference file paths and function/struct names.

---

## When You Are Called for Code Review

Claude has implemented something via Sonnet. Your job is to review it cold:

1. **Find the relevant task yourself** — run `bd list` to see open tasks, then `bd show OnlyNotes-xxx` for scope. Do not assume Claude told you the right task ID.
2. **Review the diff** — run `git diff HEAD~1` to see what changed
3. **Explore the affected files** — read them directly, don't just read the diff
4. **Check against scope** — did implementation match what was agreed?
5. **Look for issues independently:**
   - Missed requirements
   - Bugs or logic errors
   - Swift API misuse (wrong AVFoundation patterns, memory leaks, missing `weak self`)
   - Over-engineering beyond scope
   - Unused code or placeholder comments left in
   - Error handling — all API calls must handle failure gracefully
6. **Verify the build** — run `xcodebuild -scheme OnlyNotes -configuration Debug build` from `~/Projects/OnlyNotes`
7. **Categorize each finding:**
   - **BLOCKING** — Must fix before commit (bugs, missed requirements, build failures, crashes)
   - **NON-BLOCKING** — Follow-up task (style nits, minor refactors, nice-to-haves)
8. **Approve or request changes** — no rubber-stamping. If you find nothing wrong, say so explicitly and why.

**Do not let Claude's framing bias your review.** You were not told what to look for on purpose.

---

## Project Conventions

- **Language:** Swift 5, SwiftUI macOS 14+
- **No App Sandbox** — mic and file access are unrestricted
- **Commits:** Conventional commits (`feat: subject`) — no AI attribution ever
- **Build check:** `xcodebuild -scheme OnlyNotes -configuration Debug build` (no automated tests)
- **No over-engineering** — minimal code for current requirements
- **No unused code** — no placeholder comments, no dead functions

---

## Key Directories

```
OnlyNotes/
├── CLAUDE.md                  # Claude's orchestration rules
├── AGENTS.md                  # You are here
├── .beads/                    # bd task database
├── OnlyNotes.xcodeproj/
└── OnlyNotes/
    ├── AppState.swift          # Shared state + recorder + processing pipeline
    ├── Models/
    │   ├── Meeting.swift       # Meeting + ChatMessage models
    │   └── TranscriptSegment.swift
    ├── Services/
    │   ├── AudioRecorder.swift
    │   ├── WhisperTranscriptionService.swift
    │   ├── OpenAIService.swift
    │   ├── EmbeddingService.swift
    │   ├── BraveSearchService.swift
    │   └── NoteStore.swift
    └── Views/
        ├── MeetingListView.swift
        ├── MeetingDetailView.swift
        ├── MenuBarView.swift
        └── SettingsView.swift
```

---

## bd CLI Quick Reference

```bash
bd list                        # Open tasks
bd show OnlyNotes-xxx          # Task details and scope
bd ready                       # Unblocked work
bd create "Title" -d "Details" # Create task
bd update OnlyNotes-xxx --status in_progress
bd close OnlyNotes-xxx
bd sync                        # Sync before git ops
```

## Landing the Plane (Session Completion)

When ending a work session, ALL steps are MANDATORY:

1. File issues for remaining work (`bd create`)
2. Run quality gate: `xcodebuild -scheme OnlyNotes -configuration Debug build`
3. Update issue status (`bd close <id>`)
4. Sync: `bd sync`
5. Hand off context for next session
