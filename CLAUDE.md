# OnlyNotes

A local-first macOS meeting notes app built with Swift + SwiftUI.

## Project Overview

OnlyNotes captures meeting audio, transcribes it using OpenAI Whisper, and generates summaries with action items using GPT-4o. All data stays local on the user's device.

## Tech Stack

- **Language:** Swift 5
- **UI:** SwiftUI (macOS 14+)
- **Audio:** AVAudioEngine for mic recording
- **AI:** OpenAI API (Whisper for transcription, GPT-4o for summaries)
- **Storage:** JSON file in ~/Library/Application Support/OnlyNotes/
- **Issue Tracking:** bd (beads)

## Project Structure

```
OnlyNotes/
├── OnlyNotes.xcodeproj/
├── OnlyNotes/
│   ├── OnlyNotesApp.swift       # App entry point, menu bar + window scenes
│   ├── AppState.swift            # Shared app state (ObservableObject)
│   ├── Info.plist
│   ├── OnlyNotes.entitlements
│   ├── Models/
│   │   └── Meeting.swift         # Meeting data model
│   ├── Services/
│   │   ├── AudioRecorder.swift   # Mic recording via AVAudioEngine
│   │   ├── OpenAIService.swift   # Whisper transcription + GPT summarization
│   │   └── MeetingStore.swift    # JSON persistence
│   └── Views/
│       ├── ContentView.swift     # Main NavigationSplitView
│       ├── MeetingListView.swift # Sidebar with recording controls + meeting list
│       ├── MeetingDetailView.swift # Summary/action items/transcript tabs
│       ├── MenuBarView.swift     # Menu bar dropdown
│       └── SettingsView.swift    # API key configuration
```

## Build & Run

```bash
cd OnlyNotes
xcodebuild -scheme OnlyNotes -configuration Debug build
# Or open OnlyNotes.xcodeproj in Xcode
```

## Key Design Decisions

- **No App Sandbox** — simplifies mic access and file storage for personal use
- **LSUIElement = YES** — app lives in menu bar, no dock icon
- **JSON storage** — simple flat file, no Core Data overhead for this use case
- **OpenAI API key stored in UserDefaults** — acceptable for personal app, would need Keychain for distribution

## Commit Rules

- Conventional commits: `<type>: <subject>` with optional body
- Types: `feat`, `fix`, `refactor`, `docs`, `style`, `test`, `chore`
- **NO AI ATTRIBUTION** — never add "Co-authored-by: Claude" or similar
- **Never push without explicit user consent**
- **All builds must pass before any commit**
- Commit at meaningful milestones, don't batch unrelated changes

## Task Management

- Use `bd` CLI for task tracking (`.beads/` directory)
- `bd ready` — show unblocked work
- `bd create "Title" -d "Details"` — create a task
- `bd close <id>` — mark complete

## Working Conventions

- Keep code simple and readable — user is learning Swift
- Prefer clear, explicit code over clever abstractions
- No over-engineering — minimal code for the current requirement
- No unused code or placeholder comments
- Test builds with `xcodebuild` before considering done
