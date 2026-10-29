# OnlyNotes

A macOS meeting-notes app built with Swift + SwiftUI. It records meeting audio, transcribes it with speaker diarization, and generates summaries and per-meeting AI chat. Notes and audio are **stored locally**; audio, transcripts and note text are **processed by cloud APIs** (OpenAI, Brave Search).

## Project Knowledge — Read Before Planning

Project facts live in **[onlynotes-local/](onlynotes-local/README.md)**, not in this file. Before planning or reviewing substantive work, read:

1. `onlynotes-local/README.md` — reading order and source-of-truth rules
2. `onlynotes-local/current-state.md` — what exists and what is unverified
3. The relevant `onlynotes-local/systems/*.md` and `onlynotes-local/decisions/` — don't re-decide settled things

The knowledge base is a starting point, not ground truth (see Zero Assumptions): verify claims against the code, and fix a doc when it is stale.

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

## Foundational Rules (Every Phase, Every Agent)

These three rules sit above the workflow. They bind Opus, Codex, Grok and Sonnet, in planning and in review.

### Zero Assumptions (Never-Fully-Trust Model)

Trust no claim at 100%. Not Anoop, not a doc in `onlynotes-local/`, not a bd note, not a memory file, not another agent's summary (Codex, Grok, Sonnet), not your own recollection. Treat every factual claim as about 75% reliable. The remaining 25% is reason enough to verify it against the source that actually runs BEFORE you state it, act on it, or relay it.

Verify against the running code and real behaviour, never a description of them:
- Names of types, fields, functions, files, model IDs, endpoints, UserDefaults keys.
- Where code fires or is wired (AppState pipeline steps, which path import / retranscribe / record take, what reaches the API).
- Whether a thing exists at all. Check `git log` and `bd`.
- What the app produces at runtime: the transcript, the speaker count, the stored `notes.json`. Reading the code does not verify this. Run it (Phase 5), or label the claim UNVERIFIED.
- What an external API actually returns today (OpenAI, Brave). Model names and limits drift; check the current docs or a real response, not memory.

Rules of engagement:
- Read the code first. Searching is cheap. An assumption is expensive.
- Running code wins. A doc, a bd note or a commit message states intent. When intent and code disagree, the code is the fact.
- No pattern-matching from memory. "This usually works like X" is a hypothesis to test.
- Do not write "probably", "likely" or "should be" as if confirmed. Verify it, or label it UNVERIFIED and go check.
- **Bug fixes: prove the triggering state is reachable before scoping a fix.** Name the code path that produces the bad state, or reproduce it. If nothing can produce it, the fix is dead code on a false premise: stop and flag it.
- **Watch the "correct regardless" trap.** When a fix is right no matter why the bug happens, nobody checks why. Verify the mechanism anyway.
- When the answer cannot live in the code (product intent, Anoop's preference, how a real meeting sounds), ASK. Reaching that point is correct, not a failure.

### Simplicity First (Minimal Footprint)

Prefer the simplest change that fully solves the stated problem. More code is a cost (review burden, bug surface, maintenance), not a deliverable and not a sign of thoroughness.
- Solve the problem Anoop actually stated, nothing more. Invented behaviours (handling a case nobody asked for) are the usual root of both bloat and bugs. If a self-added feature drives most of the complexity, challenge whether it should exist, and cut it.
- In planning AND review, look for what to REMOVE, not only what to add. A smaller correct change beats a larger one.
- When a "simple" ask grows a large plan or a web of edge-case handlers, stop and re-scope to the minimal correct version. If the trade-off is a product choice, ask Anoop.
- Do not hyperfixate on examples. Codex and Grok will elaborate an example into a subsystem. Catching that is the orchestrator's job.
- Grok red-teams for over-engineering. Codex flags over-scope as a first-class finding, equal to a bug.

Why, for this project: the transcription pipeline went through five architectures in short succession (see `onlynotes-local/decisions/`). Layering (hybrid merges, post-pass consolidation, character slicing) added failure modes faster than it fixed attribution.

### Circuit Breaker: Stop When Conclusions Swing

The workflow drives a change to completion. This rule says when to STOP and decide with Anoop instead. It does not permit skipping a phase.
- **Two reversals = stop.** If a conclusion about the same problem (a root cause, a diagnosis, the direction of a fix) reverses or materially changes two or more times, STOP. Do not produce the next theory. The swing itself is the finding: there is context we do not have (vendor behaviour, how real meetings sound, Anoop's intent). More Codex or Grok passes will not create it.
- **Say it plainly:** "We are going in circles. I think there is context we do not have. I recommend we stop and decide this together."
- **Hand off measured facts, not interpretations.** Keep what was read or measured separate from what is inferred, and label extrapolations.
- This is different from the Phase 1 convergence loop, where each round makes the plan narrower and more correct. The breaker fires when conclusions SWING (A, then not-A, then A), not when a plan keeps getting refined.

---

## ⛔ PRE-FLIGHT CHECK — Read This BEFORE Every Task

**Before touching ANY file, answer these questions. If ANY answer is "no", STOP and fix it.**

1. **Have I kicked off Codex co-scoping?** → If no: `codex exec` FIRST, in the background, before reading code or planning.
2. **Before any Grok run: have I read every code claim in the consensus plan this round, checked it against itself, and replayed Anoop's actual case through it?** → If no: do that first (Phase 1 Step 2a). Grok is not the plan's proofreader.
3. **Has Grok red-teamed the consensus plan, and does every objection have an ACCEPT / REJECT / FILE disposition?** → If no: no Phase 2.
4. **Am I about to edit a source file directly?** → If yes: STOP. Delegate to Sonnet via CLI.
5. **Has Sonnet just finished?** → If yes: kick off the blind Codex review FIRST, before building or committing.
6. **Does this change what the user sees or hears, or what the pipeline produces?** → If yes: Phase 5 (real-use verification) is mandatory before the bd task closes.
7. **Am I about to commit?** → If yes: I must be able to write the commit gate sentence (see Phase 4) truthfully, the build passes, and `onlynotes-local/` reflects the change.

**This applies to everything, no exceptions:** one-line fixes, prompt tweaks, model-name changes, config changes, "quick" follow-ups, and anything Anoop reports from testing. Even if Anoop says "just do it".

**Known failure patterns (from bini, NearlyPerfect and this repo):**
1. **"It's obvious."** Opus finds the root cause while investigating and jumps to "let me fix this", skipping the bd task, Codex and Grok. Codex and Grok catch what Opus misses on obvious bugs too.
2. **"It's urgent."** The app is unusable, so Opus rushes a fix without review. Rushed fixes are the main source of regressions and cascading emergency fixes.
3. **"Opus and Codex already agree."** Skipping Grok because two planners agree. That agreement is exactly the shared-blind-spot signal, when the skeptic is most valuable. Running Grok and then silently ignoring its objections is the same failure.
4. **"It passed review and builds."** Treating review + build as done. In this repo, `pn6` and `e3l` passed Codex review and the build, and neither was run on a real call; the product stayed unusable. Review proves the code is plausible, not that the transcript is right. Phase 5 exists for this.

---

## Development Workflow

**Opus orchestrates. Sonnet implements. Codex co-scopes and reviews. Grok red-teams the plan and the diff.** No agent does another's job.

### HARD RULE: Opus Never Codes

**Opus MUST NOT write source code directly.** All code changes go through Sonnet, invoked as a CLI subprocess. The ONLY files Opus may edit directly are documentation: `CLAUDE.md`, `AGENTS.md`, `onlynotes-local/`, memory files.

### The Bias Firewall (Non-Negotiable)

The value of Codex and Grok comes from their independence. If Opus's conclusions leak into them, you get an echo chamber that confirms Opus's first guess. Every prompt to an independent agent is filtered by one rule:

- **USER-origin context is always fair to pass along:** Anoop's verbatim problem statement, acceptance criteria, reproduction steps, exact error messages, owner decisions, the bd task ID.
- **OPUS-origin (or any prior agent's) analysis is CONTAMINATION, never pass it:** suspected root cause, chosen approach, "the tricky part is X", which files matter, what the fix should look like, what a prior round found.

Applied per agent:
- **Codex co-scope (Phase 1):** Anoop's words only. It forms its own root cause and approach. Codex reads `onlynotes-local/` on its own per `AGENTS.md` and verifies it against the code; that is not a hint from Opus, so don't point Codex at specific KB docs.
- **Grok skeptic (Phase 1):** Anoop's verbatim problem + the consensus plan (the artifact it must critique), and nothing else. Not Opus's private reasoning, not Codex's raw notes, not "here is what I am worried about."
- **Codex re-plan (Phase 1 loop):** the consensus plan + the ACCEPTED Grok objections with severities, and nothing else. Not Opus's preferred resolution.
- **Codex review (Phase 3):** a blind reviewer. bd task ID + the mandatory analysis blocks. It is NOT told what changed, why, or that the approach is correct. Same cold prompt on every re-review.
- **Grok scope-necessity (Phase 3b):** Anoop's verbatim problem + the final consensus plan + the diff. NOT told that Codex passed.

**The consensus plan is the ONE intended exception:** Grok must see it, because critiquing it is the job.

### Phase 1: Planning (Opus + Codex + Grok — Adversarial Trio)

Two constructive planners tend to converge on the same plausible-but-wrong plan; Grok breaks that convergence before any code is written. Phase 1 is a loop, not a one-time pass.

**Step 1 — Independent construction (Opus ∥ Codex, in parallel).**
1. Kick off Codex co-scoping in the background (Anoop's words only, see Codex Invocation Rules):
   ```bash
   codex exec "Co-scope: <Anoop's problem statement, verbatim or lightly paraphrased>. Explore the codebase at ~/Projects/OnlyNotes and give your full independent assessment. Do NOT edit any files. Output analysis and recommendations only." --sandbox danger-full-access -m gpt-5.6-luna -o $S/codex-scope.md 2>&1 < /dev/null
   ```
2. While it runs, Opus reads the code and writes its own plan to `$S/opus-plan.md`.

**Step 2 — Consolidation.** Opus compares the two (what each caught that the other missed, where they genuinely disagree) and writes ONE consensus plan to `$S/consensus-plan.md`.
- **2a. Opus verifies the plan before Grok sees it.** Open every file, function, type and field the plan names and confirm the plan's statement about it. Read the plan against itself for contradictions, dropped fields and unstated orderings. Replay Anoop's actual failing case through the plan step by step. Fix what you find before Grok runs.
- **2b. Scope lock.** The plan opens with a **LOCKED SCOPE** section: Anoop's ask in one paragraph, the list of things that will change, and an explicit **OUT OF SCOPE** list. Round-1 Grok may challenge the scope itself. After round-1 dispositions, Opus confirms the scope with Anoop and locks it. After that, scope changes only with a strong reason (the locked scope cannot fix Anoop's problem) AND Anoop's explicit approval. "I found something new" is not a reason.
- **2c. Name the Phase 5 check in the plan.** Say how the change will be verified in real use (which recording, what result proves it). A plan with no way to verify the outcome is not done.

**Step 3 — Structured skepticism (Grok red-teams the consensus plan).** Run Grok exactly per **Grok Invocation Rules** below. Grok gets Anoop's verbatim problem + the consensus plan inlined, and nothing else.

**Step 4 — Adjudication.** Every Grok objection gets a disposition, recorded in the bd task:
- **ACCEPT:** the plan fails to deliver the LOCKED SCOPE (a bug, a contradiction, a missing piece of the agreed change).
- **REJECT:** with a one-line reason. Rejecting a HIGH-severity objection needs a defensible reason.
- **FILE:** real but out of the locked scope (a new case, extra hardening, an adjacent bug): `bd create` a follow-up and keep the plan unchanged.

No silent drops. Record the plan's size each round; if it grows while the scope is locked, that is scope creep, and the fix is to cut.

**Step 5 — Convergence loop.** If anything was ACCEPTED, Opus does NOT patch the plan itself. Hand Codex ONLY the consensus plan + the accepted objections:
> "You and I built this consensus plan: <plan>. A red-team skeptic raised these objections: <ACCEPTED objections + severities>. Re-plan to address them within the LOCKED SCOPE; do not add anything outside it. Resolve them however you independently judge best. Before you finish, verify every code claim in your plan against the source, and check the plan against itself for contradictions, dropped fields or unstated orderings. Do NOT edit any files. Output the updated plan only."

Then Opus re-consolidates (Step 2a again, plus a scope check that cuts anything elaborated beyond Anoop's ask) and runs Grok again with the round-N line. Repeat until convergence:
- A Grok pass yields no ACCEPTED objection (the rest are REJECTED or FILED, or Grok returns `VERDICT: CONVERGED`).
- Every load-bearing claim is verified against source, or labelled UNVERIFIED with the step that will check it.
- The path is concrete: where it hooks in, what changes, how it fails safe, how Phase 5 verifies it.
- The scope maps to Anoop's ask.

No round cap. Two signals mean stop iterating anyway:
- **Detail, not substance.** A round raises only how-to-execute detail (exact flags, tool quirks, wording). Fold it in with one final Codex re-plan and freeze the plan.
- **Swinging, not converging.** Objections reopen settled parts without new evidence, or the plan flips on the same point. That is the Circuit Breaker: take the open question to Anoop.

When an objection turns on a product choice, ask Anoop and record the answer as a binding owner decision in the plan. Pass owner decisions to Codex and Grok verbatim as user-origin context.

Finalize the converged plan with the full disposition log in the bd task (`bd update <id> --design=...`). **HARD RULE: Wait for Codex AND Grok before Phase 2.** This is an AND gate.

**A changed approach mid-task is new scope.** If the fix direction materially changes after Phase 1 (a probe revealed something, Anoop steered differently), re-run the trio before implementing. Diagnosis (reading, measuring, reproducing) needs no trio; the moment the output becomes "here is the fix", the trio gates it.

### Phase 2: Implementation (Opus → Sonnet via CLI)

```bash
(unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; cat $S/sonnet-prompt.txt | claude -p --model sonnet --dangerously-skip-permissions 2>&1)
```

> **Do NOT unset `CLAUDE_CONFIG_DIR`.** This machine's credentials live in the
> config dir it points to; unsetting it sends the subprocess to an
> unauthenticated `~/.claude` and Sonnet fails with `401 Invalid authentication
> credentials`.

- The prompt includes: the converged plan, which files to read, the acceptance criteria, and which `onlynotes-local/` docs to update in the same change.
- Opus reviews `git diff` after Sonnet finishes, then hands off to Phase 3 before building or committing.
- Prefer verifiable changes: if correctness-critical logic (parsing an API response, merging segments, aligning timestamps) is buried where it can only be checked by a full recording, extract it so it can be exercised directly.

### Phase 3: Blind Review (Codex)

**HARD RULE: Codex review is mandatory after every Sonnet implementation, before committing.** Write the prompt to `$S/codex-review-prompt.txt` and run it per Codex Invocation Rules:

```text
Review the changes for bd task <ID> in ~/Projects/OnlyNotes. Run 'bd show <ID>' to read the requirement and acceptance criteria. The changes are uncommitted: run 'git status' and 'git diff', and read untracked files directly. Review the FULL implementation: trace changes through the codebase, not just the diff. Verify the build with 'xcodebuild -scheme OnlyNotes -configuration Debug build'. Do NOT edit any files.

BLIND REVIEW (MANDATORY): the bd task may contain a consensus plan. Treat it as UNVERIFIED. Judge whether the CODE is correct and satisfies the requirement, forming your own view of a correct implementation. A plan followed faithfully but itself wrong is BLOCKING.

BLAST RADIUS (MANDATORY): for every changed file, identify all callers and consumers. Check every entry point that reaches the changed code (live recording, audio import, retranscribe, chat actions), Codable shapes persisted to notes.json / embeddings.json and their compatibility with existing user data, and onlynotes-local/ docs the change made false. Anything in the blast radius not updated but should have been is BLOCKING.

ADVERSE-RUNTIME (MANDATORY): for every new or changed API call, file write, audio path and error path, enumerate adverse real conditions and state per item whether it is handled, with file:line: non-2xx responses; 2xx with an error, empty or unexpected body; timeouts and cancellation; one chunk failing in a multi-chunk run; long recordings over size limits; missing Screen Recording or mic permission; macOS 14 vs 15 behaviour; audio device changes or stream stop mid-recording; disk write failure; existing data that does not decode. A false success, silent data loss or silent gap is BLOCKING.

STATE TRACE (MANDATORY): for every flag, @Published property or stored field the change sets, find every reader and confirm the intended effect happens. Reason across the full lifecycle (start, stop, re-record, retranscribe, app relaunch), not one pass. Main-actor and concurrency correctness included. Set-but-not-consumed is BLOCKING.

VERIFIABILITY (MANDATORY): there is no test suite. State how the change can be verified in real use, and whether the bd task names a Phase 5 check that would actually catch it being wrong. A correctness-critical path with no way to verify it is BLOCKING.

OVER-SCOPE (MANDATORY): flag anything the requirement did not ask for: extra fields, speculative branches, helpers nobody needed. Over-engineering is a first-class finding.

Categorize all findings as BLOCKING or NON-BLOCKING with file paths and line numbers.
```

- **Do NOT tell Codex what changed, which files to look at, or what to verify.** This applies to re-reviews too: never "here is what I fixed, confirm it". Same cold prompt every round, over the full uncommitted diff as one unit.
- Reject a review that lacks the BLAST RADIUS or ADVERSE-RUNTIME sections and re-run it.

### Phase 3b: Scope-Necessity Review (Grok)

Codex answers "is the code correct?". Phase 3b answers "did this need to be built, and does it still match the agreed scope?"
- **When:** MANDATORY on any non-trivial diff (new functions, abstractions, control flow, more than about 30 changed lines, or a changed persisted data shape). Run once, after Codex's clean pass and before commit. Skippable only on a trivial change, and only if you say so and why.
- **Inputs:** Anoop's verbatim problem + the final consensus plan (with owner decisions) + the diff inlined. NOT told that Codex passed.
- **Mandate:** "Is every part of this diff required by the agreed plan and the user's problem? Name what to REMOVE or simplify. Name anything the plan required that the diff is missing." Keep the foundational mandate lines and rules of engagement.
- **Disposition like Phase 1:** ACCEPT (trim via Sonnet, then a fresh cold Codex review) or REJECT (one-line reason).

### Phase 4: Resolution

1. Opus addresses BLOCKING issues via Sonnet CLI.
2. Re-run the cold Codex review after every fix round until zero BLOCKING issues remain.
3. NON-BLOCKING issues become bd tasks.
4. **Commit gate.** Before `git add` / `git commit`, Opus states in its response:
   > "Codex blind-scoped this and Grok red-teamed the consensus plan with every objection dispositioned; Codex blind-reviewed the current code with zero BLOCKING issues; Grok scope-checked the diff (or: skipped because <reason>); the build passes."

   If that sentence cannot be written truthfully, do not commit.

### Phase 5: Real-Use Verification

**Applies to:** anything that changes what the user sees or hears, or what the pipeline produces: recording, transcription, diarization, summary, chat, storage, playback, UI.

Build and review prove the code is plausible. Only real use proves OnlyNotes works.

1. **Pipeline changes (recording → transcript → summary):** run the changed path on a real recording and check the result against what is known about it: number of speakers, who said which lines, missing or duplicated text, summary accuracy. Record the measured result (not an impression) in the bd task.
2. **UI and playback changes:** run the app and exercise the changed flow; capture a screenshot or describe exactly what was observed.
3. **Live meetings:** Opus cannot sit in a call. When the check needs a live meeting, hand Anoop a short, specific test script (what to do, what to look for) and wait for Anoop's result before closing the bd task.
4. If the check fails, it is a new Phase 1 round for that defect, not a quick patch.
5. A bd task whose Phase 5 check has not passed stays `in_progress`. Say so in the hand-off.

**Skip this phase** only for docs-only, dead-code removal with no behaviour change, or build/config changes with no runtime effect, and say so.

### Codex Invocation Rules

- **Short prompt (a direct argument):**
  ```bash
  codex exec "PROMPT ... Do NOT edit any files." --sandbox danger-full-access -m gpt-5.6-luna -o $S/out.md 2>&1 < /dev/null
  ```
- **Long prompt (plans, reviews):** write it to a file and feed it on stdin with `-`:
  ```bash
  codex exec --sandbox danger-full-access -m gpt-5.6-luna -o $S/out.md - < $S/prompt.txt 2>&1
  ```
  Never `codex exec "$(cat file)"`: backticks and quotes in a plan or diff break the shell quoting.
- **ALWAYS end a direct-argument call with `< /dev/null`.** Without it, a backgrounded `codex exec` can hang forever on "Reading additional input from stdin" and produce nothing.
- **`-m gpt-5.6-luna`:** Anoop's standing model. If a run fails with "model not supported when using Codex with a ChatGPT account", re-pin it and retry.
- **Never use** `codex review`.
- **Why `danger-full-access`:** bd writes to SQLite outside the workdir, and the build needs it.
- **HARD RULE: Codex never codes.** Every Codex prompt includes "Do NOT edit any files." If Codex changed a file, STOP, revert it, and re-run.
- Run Codex with the Bash tool's background mode and wait for the completion notice.

### Grok Invocation Rules

**This is the ONLY way to run Grok. Follow it verbatim.** Every piece exists because a run was silently lost without it (in bini and NearlyPerfect).

1. **Prompt file** `$S/grok-prompt-<task>-rN.txt` (or `-impl` for Phase 3b), built with the Write tool or a quoted heredoc (`<<'EOF'`), never macOS `sed '/x/i ...'`. Sections in this order:

   ```text
   Verified facts you may need (do not spend turns re-deriving them): <inline any facts Grok cannot reach>.
   TURN BUDGET: limit yourself to at most 15 inspection tool calls, then STOP inspecting and write the complete critique. A critique that is never written is worthless.

   You are the red-team skeptic on a planning trio. Produce your FULL critique in THIS response. Do NOT edit any files. Do NOT install, delete, start, or change anything.

   THE PROBLEM (verbatim from the user):
   <Anoop's words, verbatim>

   THE CONSENSUS PLAN (critique this):
   ----
   <full consensus plan text, inlined, never a path>
   ----

   <Round 2+ only:> This is round N of a convergence loop: the plan was revised after prior skeptic passes. The LOCKED SCOPE section was agreed with the owner and is fixed. Judge only whether THIS plan correctly delivers that scope. Raise only material in-scope problems that remain or that the revision introduced; list anything outside the locked scope separately under OUT-OF-SCOPE FOLLOW-UPS. Do not reopen settled parts without new evidence. If it is sound, say so.

   YOUR MANDATE: find where this plan is wrong, do not restate it.
   - ZERO ASSUMPTIONS (foundational): ground every objection in the code or the plan text, never memory. Treat each of the plan's load-bearing claims as about 75% reliable: name the ones that are unverified yet decisive, and say what source would confirm them. Label any uncertain claim of your own as UNVERIFIED.
   - NO OVER-COMPLICATION (foundational): judge the plan by its footprint. Flag invented scope, speculative handlers, cases nobody asked for, and code for its own sake as first-class findings, equal to bugs. Say explicitly what to REMOVE.
   - SCOPE (foundational): round 1, challenge the LOCKED SCOPE itself. Round 2+, the scope is locked: attack only whether the plan delivers it. Tag every objection IN-SCOPE or OUT-OF-SCOPE.
   - VERIFIABILITY: does the plan's Phase 5 check actually prove the user's problem is solved on a real recording? Could the change pass that check and still be wrong?
   - ASSUMPTIONS: what does the plan take for granted that may be false? Unstated assumptions are your highest-value target.
   - ROOT CAUSE: is it fixing the real problem or a symptom?
   - FAILURE MODES: edge cases, races, error paths and blast radius the plan does not handle.
   - SIMPLER PATH: is there a materially simpler approach?
   - STRONGEST PARTS: name what the plan gets RIGHT, so it is kept.

   RULES OF ENGAGEMENT (structured skepticism, NOT contrarianism):
   - Every objection MUST carry: a concrete reason, a severity (HIGH/MED/LOW), what evidence would change your mind, and a concrete counter-proposal.
   - Do NOT manufacture objections to seem thorough. If the plan is sound, say so and why.
   - Do NOT bikeshed style, naming or formatting.
   - You exist to make the plan correct, not to win an argument.

   End with a line: VERDICT: CONVERGED or VERDICT: RE-PLAN REQUIRED (N material in-scope objections).
   ```

2. **Check the file before running.** This must hit every section:
   ```bash
   grep -nE "^TURN BUDGET|^You are the red-team|Do NOT edit any files|^THE PROBLEM|^THE CONSENSUS PLAN|LOCKED SCOPE|^YOUR MANDATE|SCOPE \(foundational\)|^End with" $S/grok-prompt-<task>-rN.txt
   ```
3. **Run** in the background from the repo root:
   ```bash
   cd ~/Projects/OnlyNotes && grok --prompt-file $S/grok-prompt-<task>-rN.txt --permission-mode auto -m grok-4.6 --max-turns 80 > $S/grok-skeptic-<task>-rN.md 2>&1 < /dev/null
   ```
4. **Verify it wrote a critique. Exit 0 means nothing.** The output must contain objections and a `VERDICT:` line. A few-hundred-byte file with only "I'll inspect..." is a dead run.
5. **If it died, diagnose before re-running:** `grok sessions list`, then `grok export <session-id>`, and read the last tool call before the transcript stops. Add a rule for it here.

Why each piece is there:
- **`--permission-mode auto`, never `plan` or `dontAsk`.** `plan` emits a planning preamble and exits. `dontAsk` silently ends the session on any shell command that is not auto-approved. `auto` runs read-only inspection and politely refuses risky commands. Read-only-ness comes from "Do NOT edit any files" in the prompt.
- **`--prompt-file`, never `-p`.** Multi-KB inline prompts break on shell quoting.
- **`--max-turns 80` + the TURN BUDGET line** stop Grok from inspecting forever and never writing.
- **Inline the plan and key facts.** Otherwise Grok burns turns hunting for files.
- **`-m grok-4.6`** pins the model. Grok has no `-o`: redirect stdout.
- **Waiting:** use the Bash tool's background mode and wait for the completion notice. Never a `pgrep -f grok` loop (it matches its own command line). Do NOT `TaskStop` a concurrent Grok run: sessions share a leader socket.
- **HARD RULE: Grok never codes and never rubber-stamps.**

### `$S` — Scratch Directory

`$S` is the session scratchpad directory when Claude Code provides one; otherwise `/tmp/onlynotes`. All plans, prompts and agent outputs go there, never into the repo tree.

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
bd update OnlyNotes-xxx --design="..."   # Consensus plan + disposition log
bd close OnlyNotes-xxx                # Mark complete (only after Phase 5 passes)
```

Create the bd task AFTER Codex co-scoping and BEFORE Grok runs, so dispositions have a home.


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
3. **Update issue status** - Close finished work (Phase 5 passed), update in-progress items
4. **Commit** - All changes committed locally
5. **Ask before pushing** - Ask the user, every time, before running:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # should show "up to date with origin"
   ```
   If the user approves and a push fails, resolve and retry.
6. **Hand off** - Provide context for next session, including anything left unpushed or awaiting Phase 5
<!-- END BEADS INTEGRATION -->
