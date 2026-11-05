# Meeting Chat and Actions

**Status:** Current
**Last verified:** 2026-10-28
**Source:** `OnlyNotes/Views/MeetingDetailView.swift` (`MeetingChatView`), `OnlyNotes/Services/OpenAIService.swift` (`chatWithMeetingControl`), `OnlyNotes/Services/MeetingActionExecutor.swift`

## Flow

1. User sends a message in the meeting's **Chat** tab. It is appended to `meetingAttachment.chatMessages` and saved.
2. `OpenAIService.chatWithMeetingControl` (`gpt-4o`, `response_format=json_object`) is called with the full history, the resolved transcript, speaker names, tags, `hasAudio`, `hasTranscript`.
3. The model returns `{mode: "answer"|"action", assistantMessage, action}`. If the JSON does not parse, the raw content is shown as an answer.
4. For `mode == "action"`: the assistant message is saved, then `MeetingActionExecutor.execute(action, on: note)` runs against a fresh copy of the note; the mutated note is saved. On error an "Action failed: …" assistant message is saved.

One action per response (no chaining; bd `OnlyNotes-udn`). There is no user confirmation step before an action runs.

## Actions (`MeetingAction.type`)

| Type | Effect | Notes |
|---|---|---|
| `retranscribe` | Re-diarizes `audioFilePath` (system WAV), then transcribes the derived mic sibling `<system path minus extension>_mic.wav` if it exists and is > 4096 bytes (tag 1, merged and sorted like live processing); clears `speakers`, regenerates title/summary/action items | Needs the system audio file. Missing/tiny mic file (e.g. imported audio) → system-only, no marker. Mic failure is non-fatal: system segments plus the tag-0 warning marker are saved. System or summary failure throws and the stored transcript is kept. Pending Phase 5 (bd `uc3`, `nq8`) |
| `regenerate_summary` | Re-summarizes with current speaker names; optional `context` is added as a live note at offset 0 | Updates title, summary, action items |
| `rename_speaker` | Sets `speakers["<tag>"]` | Requires `speakerTag` and non-empty `newName` |
| `add_tag` / `remove_tag` | Updates tags via `Note.setTags` | `remove_tag` lowercases/trims before comparing |
| `translate` | `translateSegments` (batches of 30) rewrites all segment text, then regenerates summary | Replaces original text; no undo; needs segments |
| (other) | `ActionError.unknownAction` | |

Every action sets `updatedAt`. Speaker rename is also available directly in the **Speakers** tab.

## Related UI (`MeetingDetailView`)

Tabs: Summary, Action Items, Speakers, Transcript, Chat, Notes. Header: tags, audio player (`AVAudioPlayer`, system track only), audio export, Markdown export (`buildMarkdown`: summary, action items, notes, transcript with resolved names).

## Risks

- Translation and retranscribe overwrite stored text/speaker names.
- Full transcript is sent on every chat turn; no truncation.
- Model choice (`gpt-4o`) is an open question ([../open-questions.md](../open-questions.md)).
