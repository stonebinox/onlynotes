// background.js — MV3 service worker
// Coordinates recording start/stop between popup, offscreen doc, and content script.

const OFFSCREEN_URL = chrome.runtime.getURL('offscreen.html');

let recordingTabId = null;
let speakerEvents = []; // accumulated from content script

// ── Offscreen document lifecycle ─────────────────────────────────────────────

async function ensureOffscreen() {
  // chrome.offscreen.hasDocument() requires Chrome 150+; use getContexts() instead (Chrome 116+)
  const contexts = await chrome.runtime.getContexts({
    contextTypes: ['OFFSCREEN_DOCUMENT'],
    documentUrls: [OFFSCREEN_URL]
  });
  if (contexts.length === 0) {
    try {
      await chrome.offscreen.createDocument({
        url: OFFSCREEN_URL,
        reasons: ['USER_MEDIA'],
        justification: 'Record tab audio and microphone for speaker timeline measurement'
      });
    } catch (e) {
      // Treat concurrent-create race as success
      if (!e.message.includes('Only a single offscreen document')) throw e;
    }
  }
}

async function closeOffscreen() {
  const contexts = await chrome.runtime.getContexts({
    contextTypes: ['OFFSCREEN_DOCUMENT'],
    documentUrls: [OFFSCREEN_URL]
  });
  if (contexts.length > 0) {
    await chrome.offscreen.closeDocument();
  }
}

// ── Message router ────────────────────────────────────────────────────────────

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type === 'START_RECORDING') {
    handleStart(msg.tabId).then(r => sendResponse(r)).catch(e => sendResponse({ ok: false, error: e.message }));
    return true; // async
  }
  if (msg.type === 'STOP_RECORDING') {
    handleStop().then(r => sendResponse(r)).catch(e => sendResponse({ ok: false, error: e.message }));
    return true;
  }
  if (msg.type === 'SPEAKER_EVENT') {
    // Forwarded from content script
    speakerEvents.push(msg.event);
    return false;
  }
  if (msg.type === 'GET_SPEAKER_EVENTS') {
    sendResponse({ events: speakerEvents });
    return false;
  }
});

// ── Start flow ────────────────────────────────────────────────────────────────

async function handleStart(tabId) {
  recordingTabId = tabId;
  speakerEvents = [];

  // Ensure offscreen doc exists BEFORE obtaining the stream ID (stream IDs are single-use,
  // expire in seconds — deliver immediately after obtaining)
  await ensureOffscreen();

  // Obtain a tab-capture stream ID for the target tab
  const streamId = await new Promise((resolve, reject) => {
    chrome.tabCapture.getMediaStreamId({ targetTabId: tabId }, id => {
      if (chrome.runtime.lastError) {
        reject(new Error(chrome.runtime.lastError.message));
      } else {
        resolve(id);
      }
    });
  });

  const startEpochMs = Date.now();
  await chrome.storage.local.set({ startEpochMs, recordingTabId: tabId });

  // Deliver streamId to offscreen doc immediately — no other work between getMediaStreamId and this send
  let startResp;
  try {
    startResp = await chrome.runtime.sendMessage({
      type: 'OFFSCREEN_START',
      streamId,
      startEpochMs
    });
  } catch (e) {
    await chrome.storage.local.remove(['startEpochMs', 'recordingTabId']);
    await closeOffscreen().catch(() => {});
    recordingTabId = null;
    throw e;
  }

  if (!startResp || !startResp.ok) {
    await chrome.storage.local.remove(['startEpochMs', 'recordingTabId']);
    await closeOffscreen().catch(() => {});
    recordingTabId = null;
    throw new Error(startResp ? startResp.error : 'offscreen failed to start');
  }

  // Tell content script to start accumulating (non-critical — content script may not be ready)
  try {
    await chrome.tabs.sendMessage(tabId, { type: 'START_OBSERVATION', startEpochMs });
  } catch (_) {}

  return { ok: true };
}

// ── Stop flow ─────────────────────────────────────────────────────────────────

async function handleStop() {
  // Ask content script for its buffered events
  let contentEvents = [];
  if (recordingTabId) {
    try {
      const resp = await chrome.tabs.sendMessage(recordingTabId, { type: 'GET_EVENTS' });
      if (resp && resp.events) contentEvents = resp.events;
    } catch (_) {}
  }

  // Merge with any events forwarded via runtime message
  const merged = mergeEvents([...speakerEvents, ...contentEvents]);

  // Ask offscreen doc to finalise and save files; only resolves after all downloads complete
  await chrome.runtime.sendMessage({
    type: 'OFFSCREEN_STOP',
    speakerEvents: merged
  });

  await chrome.storage.local.remove(['startEpochMs', 'recordingTabId']);
  recordingTabId = null;
  speakerEvents = [];

  await closeOffscreen().catch(() => {});

  return { ok: true };
}

// Deduplicate events by tMs+participantKey, keep chronological order
function mergeEvents(events) {
  const seen = new Set();
  return events
    .sort((a, b) => a.tMs - b.tMs)
    .filter(e => {
      const key = `${e.tMs}|${e.participantKey}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}
