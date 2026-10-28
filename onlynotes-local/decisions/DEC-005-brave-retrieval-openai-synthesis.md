# DEC-005: Brave retrieval + OpenAI synthesis for web context

**Status:** Accepted
**Date:** 2026-07-15
**Deciders:** Anoop Santhanam
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/Services/BraveSearchService.swift`, `OnlyNotes/Services/OpenAIService.swift` (`synthesizeWebAnswer`), `OnlyNotes/Views/ContentView.swift`, commits `0e77266`, `1f97476`, `f2df6d1`, bd `OnlyNotes-kmv`, `OnlyNotes-oc9`, `OnlyNotes-vza`

## Context

The note editor's "From the web" panel first used raw Brave results, then Brave's Answers API (`kmv`, 2026-06-04: `POST /res/v1/chat/completions`). In July the Answers path failed: model `brave-default` was invalid (HTTP 422) and the current Brave plan did not include the option (HTTP 400 `OPTION_NOT_IN_PLAN`), while plain web search worked on the plan (`oc9`).

## Decision

- Brave is **retrieval only**: `GET /res/v1/web/search`, `count=5`, `extra_snippets=true`, query clamped to 50 words and 400 characters (Brave returns 422 beyond that; verified 51 words → 422, 50 → 200, bd `vza`).
- OpenAI performs grounded synthesis with the pinned snapshot `gpt-5.4-mini-2026-03-17` (chosen over `gpt-5.6-terra` for cost: $0.75/$4.50 per 1M tokens, per bd `oc9`; supports `json_object`).
- The model returns `{answer, citations: [indices]}`; indices are validated against the Brave results and mapped to real URLs, so citations can only point to retrieved pages.
- UI states are explicit: disabled (no Brave key), failed (incl. no OpenAI key), no results, answer.

## Consequences

**Positive:**
- Works on the current Brave plan; citations are constrained to retrieved URLs.
- Clear failure states.

**Negative:**
- Needs two keys and two vendors; note text is sent to both.
- Query quality depends on title + last 300 body characters (`OnlyNotes-2vl`).
- A pinned model snapshot can be retired.

## Alternatives considered

| Option | Why rejected / not chosen |
|---|---|
| Raw Brave results only | Replaced by summarized answers in `kmv` for usefulness |
| Brave Answers API (`kmv`, `0e77266`) | Invalid model (422) and not in plan (400) |
| `gpt-5.6-terra` for synthesis | More expensive; user chose `gpt-5.4-mini-2026-03-17` |
| Sending unclamped queries | Brave 422 above 50 words / 400 chars |

## References

- bd: `OnlyNotes-kmv`, `OnlyNotes-oc9`, `OnlyNotes-vza`, `OnlyNotes-1lk`, `OnlyNotes-55j`
- [../systems/ai-and-context.md](../systems/ai-and-context.md)
