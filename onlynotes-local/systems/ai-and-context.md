# AI and Context

**Status:** Current. Web-context and embeddings paths were fixed and verified per their closed bd tasks (`oc9`, `vza`); the transcript-model question in [../open-questions.md](../open-questions.md) is open.
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/Services/OpenAIService.swift`, `OnlyNotes/Services/BraveSearchService.swift`, `OnlyNotes/Services/EmbeddingService.swift`, `OnlyNotes/Models/ContextResult.swift`, `OnlyNotes/Views/ContentView.swift`, `OnlyNotes/Views/SettingsView.swift`

## OpenAI usage

All calls: `Authorization: Bearer <openAIKey>`, `https://api.openai.com/v1/...`.

| Purpose | Endpoint | Model | Code |
|---|---|---|---|
| Summary (title, summary, action items; JSON) | `/chat/completions` | `gpt-4o` | `OpenAIService.summarizeTranscript` |
| Plain chat | `/chat/completions` | `gpt-4o` | `OpenAIService.chat` (not called by current views) |
| Chat with action control (JSON) | `/chat/completions` | `gpt-4o` | `chatWithMeetingControl` |
| Translate segments (batches of 30, JSON) | `/chat/completions` | `gpt-4o` | `translateSegments` |
| Web answer synthesis (JSON) | `/chat/completions` | `gpt-5.4-mini-2026-03-17` (pinned, `webAnswerModel`) | `synthesizeWebAnswer` |
| Embeddings | `/embeddings` | `text-embedding-3-small` | `EmbeddingService` |
| Diarized transcription | `/audio/transcriptions` | `gpt-4o-transcribe-diarize` | [transcription-and-diarization.md](transcription-and-diarization.md) |
| Mic transcription | `/audio/transcriptions` | `gpt-4o-mini-transcribe-2025-12-15` | same |

Summary input: `Speaker N: text` lines (display names applied when `speakers` is given) plus live notes as `mm:ss - text` with an instruction not to invent facts. There is no truncation or chunking of long transcripts. Whether `gpt-4o` is still available is an open question.

Which key is needed: recording, import, summary, chat, translation, embeddings → OpenAI. "From the web" → both OpenAI and Brave.

## "From the web" note context

Pipeline in `NoteEditorView.refreshContext`:

1. Query = note title + last 300 characters of body (`buildQuery`). Refresh triggers: sentence end (`. `, `? `, `! `, newline) or 1.5 s idle; title edits debounced 1.5 s; identical query + tag set is skipped (cache key); needs > 20 characters of body to trigger from the body (bd `1lk`, `55j`).
2. `BraveSearchService.search`: `GET https://api.search.brave.com/res/v1/web/search`, `X-Subscription-Token`, `count=5`, `extra_snippets=true`, 10 s timeout; query clamped to the first 50 words, then 400 characters (bd `vza`). Brave is **retrieval only**; results carry title, URL, description.
3. `OpenAIService.synthesizeWebAnswer`: sends the numbered results; expects `{"answer": "...", "citations": [1-based ints]}`; answers in 2–4 sentences from the supplied results only. Citation indices are validated against the result list and de-duplicated by URL; invalid indices are dropped.
4. `WebContextState`: `.idle`, `.disabled` (no Brave key), `.failed(msg)` (e.g. no OpenAI key or HTTP/parse error), `.noResults`, `.loading`, `.answer`.

Why not Brave Answers: see [DEC-005](../decisions/DEC-005-brave-retrieval-openai-synthesis.md).

## Internal context

- **Tag overlap** (`EmbeddingService.findByTags`): notes sharing a tag, score = shared / current tags, top 5, excluding the current note.
- **Semantic** (`findSimilar`): embeds the query, cosine similarity against stored vectors, threshold > 0.3, top 5.
- Results are merged by note ID keeping the highest score. Click-to-insert adds the snippet and a link (`onlynotes://note/<uuid>` for notes, or the URL for web results) to the note body (bd `onu`).
- Index content: title, body, summary, first 100 transcript segments; staleness digest uses the first 50 segments, so edits to segments 51–100 do not trigger re-embedding.
- `EmbeddingService.indexNote` runs on every `loadNotes` for all notes (skipped when the digest matches); failures are silent.

## Privacy

| Data | Sent to |
|---|---|
| Meeting audio | OpenAI (transcription) |
| Transcripts, live notes, chat history | OpenAI (summary, chat, translation) |
| Note title/body/summary/transcript start | OpenAI (embeddings) |
| Context query (title + last 300 body chars) | OpenAI (embedding, then synthesis alongside search results) and Brave (search; clamped to 50 words / 400 chars) |

Storage is local. "All data stays local" is **not** true for this app.

## Bd history

`1s7` (semantic search wiring), `u7b` (explicit web states), `kmv` (Brave Answers, since replaced), `oc9` (Brave search + OpenAI synthesis), `vza` (query limits), `1lk`/`55j` (debounce, cache).
