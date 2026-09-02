# MeetCapture

Proof-of-concept Chrome extension to measure Google Meet's UI speaker-detection quality.
Records (1) the Meet tab audio, (2) your local mic, and (3) a timestamped speaker-change timeline — all aligned to the same clock — so you can compare the UI's active-speaker signal against the real audio.

---

## Permissions

| Permission | Why |
|---|---|
| `tabCapture` | Capture Meet tab audio |
| `offscreen` | Run MediaRecorder in an offscreen document (required by MV3) |
| `storage` | Share the session start timestamp between service worker and content script |
| `activeTab` | Identify the active Meet tab when Start is clicked |
| `scripting` | Programmatically send messages to the content script |
| Host: `https://meet.google.com/*` | Inject content script into Meet |

---

## Load unpacked in Chrome

1. Open **chrome://extensions**
2. Enable **Developer mode** (top-right toggle)
3. Click **Load unpacked**
4. Select the `MeetCapture/` folder (the one containing `manifest.json`)
5. The extension icon appears in the toolbar. Pin it for easy access.

---

## How to run a measurement session

1. Join or start a Google Meet call in a Chrome tab.
2. Click the **MeetCapture** toolbar icon — the popup opens.
3. *(Optional)* Click **Enable microphone (optional)** to also capture your own voice.
   - This opens a dedicated tab that prompts for mic access.
   - The mic track is **not required** — tab audio and the speaker timeline are always recorded regardless of mic permission.
   - If the browser shows no prompt (mic was previously blocked), reset mic access for the extension at **chrome://settings/content/microphone**, then try again.
   - Once granted, the popup shows **Mic: enabled** next to the button.
4. Click **Start**.
   - The popup status changes to **recording…**
   - You should still hear all call audio normally (tab audio is routed back to the speaker).
5. Run the meeting as usual for as long as you want to measure.
6. Click **Stop**.
   - The popup shows **saved to Downloads**.
   - Files appear in your Downloads folder within a few seconds (`tab-audio.webm`, `timeline.json`, and `mic-audio.webm` if mic was enabled).

---

## Output files

| File | Contents |
|---|---|
| `tab-audio.webm` | Everything you hear in the Meet tab (all participants + any shared audio) — always recorded |
| `timeline.json` | Speaker-change events with session-relative timestamps + clock checkpoints — always recorded |
| `mic-audio.webm` | Your local microphone only — recorded only if mic permission was granted before Start |

### timeline.json schema

```jsonc
{
  "startEpochMs": 1717000000000,   // wall-clock epoch at recording start
  "audioT0": 0.123,                // AudioContext.currentTime at start (offscreen doc)
  "perfT0": 9876.5,                // performance.now() at start (offscreen doc)
  "tabDurationSec": 182.4,         // decoded duration of tab-audio.webm
  "micDurationSec": 182.1,         // decoded duration of mic-audio.webm
  "participants": [
    { "participantKey": "abc123", "name": "Alice" },
    { "participantKey": "def456", "name": "Bob" }
  ],
  "events": [
    {
      "tMs": 4200,           // ms since startEpochMs → seek to 4.2 s in audio files
      "participantKey": "abc123",
      "name": "Alice",
      "signal": "speaking-bars"   // which DOM heuristic fired
    }
  ]
}
```

Signal values and what they mean:

| Signal | DOM heuristic used |
|---|---|
| `speaking-bars` | Animated equalizer / element with a speaking-state attribute inside a tile |
| `tile-highlight` | Active-speaker border/ring or active-tile class |
| `mic-icon` | Pinned, spotlight, or dominant-speaker attribute on a tile |
| `no-active-speaker-detected` | Periodic heartbeat — no heuristic matched |

---

## How to evaluate

1. Open `tab-audio.webm` in any audio player (QuickTime, VLC, Audacity, etc.).
2. Open `timeline.json` in a text editor or `jq`.
3. For each event, seek the audio file to `tMs / 1000` seconds.
4. Listen: does the transition in the file match the event's `name`?
5. Note which `signal` value fired and how reliable it was.

The `no-active-speaker-detected` heartbeats reveal gaps in the heuristics — every 5 seconds where Meet shows nobody active.

### Alignment note

Both audio files and the timeline share `startEpochMs` as their common epoch.
- Audio seek position (seconds) = `tMs / 1000`
- `audioT0` and `perfT0` are included as cross-check anchors if you need to correlate with WebRTC timestamps or other browser APIs.

---

## Architecture notes (for debugging)

```
permission.html / permission.js  (optional, opened via "Enable microphone" button)
  → getUserMedia({audio:true})
  → chrome.storage.local.set({micGranted:true})

popup.js
  → chrome.runtime.sendMessage(START_RECORDING)
    → background.js (service worker)
      → chrome.tabCapture.getMediaStreamId(targetTabId)
      → chrome.offscreen.createDocument(offscreen.html)
      → chrome.runtime.sendMessage(OFFSCREEN_START, streamId)
        → offscreen.js
          → getUserMedia(tab stream)   ← always
          → getUserMedia(mic)          ← attempted; records micError if denied
          → AudioContext: tabSource → destination   ← keeps audio audible
          → MediaRecorder × 1–2 (tab always; mic if granted)
      → chrome.tabs.sendMessage(tabId, START_OBSERVATION)
        → content.js: starts MutationObserver + 250ms poll

popup.js
  → chrome.runtime.sendMessage(STOP_RECORDING)
    → background.js
      → chrome.tabs.sendMessage(GET_EVENTS) → content.js returns buffered events
      → chrome.runtime.sendMessage(OFFSCREEN_STOP, mergedEvents)
        → offscreen.js
          → stop both MediaRecorders
          → decode durations
          → saveBlob(tab-audio.webm)
          → saveBlob(mic-audio.webm)
          → saveBlob(timeline.json)
```

Meet's DOM is undocumented and changes without notice. The content script tries multiple selector strategies and records which one fired per event. If all selectors stop working after a Meet update, check the `signal` field distribution in `timeline.json` — a flood of `no-active-speaker-detected` heartbeats means the selectors need updating.
