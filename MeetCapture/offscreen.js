// offscreen.js — runs in the offscreen document (has DOM + full media APIs)
// Handles all getUserMedia, AudioContext, and MediaRecorder work.

let audioCtx = null;
let tabRecorder = null;
let micRecorder = null;
let tabStream = null;
let micStream = null;
let tabChunks = [];
let micChunks = [];
let startEpochMs = null;
let audioT0 = null;
let perfT0 = null;
let tabRecorderStartMs = null;
let tabRecorderStopMs = null;
let micRecorderStartMs = null;
let micRecorderStopMs = null;
let pendingMicError = null;

// ── Message router ────────────────────────────────────────────────────────────

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === 'OFFSCREEN_START') {
    startCapture(msg.streamId, msg.startEpochMs)
      .then(() => sendResponse({ ok: true }))
      .catch(e => sendResponse({ ok: false, error: e.message }));
    return true;
  }
  if (msg.type === 'OFFSCREEN_STOP') {
    stopCapture(msg.speakerEvents)
      .then(() => sendResponse({ ok: true }))
      .catch(e => sendResponse({ ok: false, error: e.message }));
    return true;
  }
});

// ── Start capture ─────────────────────────────────────────────────────────────

async function startCapture(streamId, epochMs) {
  startEpochMs = epochMs;
  tabChunks = [];
  micChunks = [];
  tabStream = null;
  micStream = null;
  pendingMicError = null;

  // ── Tab stream ──
  tabStream = await navigator.mediaDevices.getUserMedia({
    audio: {
      mandatory: {
        chromeMediaSource: 'tab',
        chromeMediaSourceId: streamId
      }
    },
    video: false
  });

  // ── Audio routing: tab → destination so the user still hears the call ──
  audioCtx = new AudioContext();
  audioT0 = audioCtx.currentTime;
  perfT0 = performance.now();

  const tabSource = audioCtx.createMediaStreamSource(tabStream);
  tabSource.connect(audioCtx.destination);

  // ── Mic stream — permission was already granted by the popup ──
  try {
    micStream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch (e) {
    // Continue with tab-only recording; surface the error in timeline metadata
    pendingMicError = e.message;
  }

  // ── MediaRecorders ──
  const mimeType = getSupportedMime();

  tabRecorder = new MediaRecorder(tabStream, { mimeType });
  tabRecorder.ondataavailable = e => { if (e.data.size > 0) tabChunks.push(e.data); };
  tabRecorderStartMs = Date.now();
  tabRecorder.start(1000);

  if (micStream) {
    micRecorder = new MediaRecorder(micStream, { mimeType });
    micRecorder.ondataavailable = e => { if (e.data.size > 0) micChunks.push(e.data); };
    micRecorderStartMs = Date.now();
    micRecorder.start(1000);
  }
}

function getSupportedMime() {
  const candidates = [
    'audio/webm;codecs=opus',
    'audio/webm',
    'audio/ogg;codecs=opus'
  ];
  for (const m of candidates) {
    if (MediaRecorder.isTypeSupported(m)) return m;
  }
  return '';
}

// ── Stop capture + save files ─────────────────────────────────────────────────

async function stopCapture(speakerEvents) {
  if (!tabRecorder) return;

  try {
    tabRecorderStopMs = Date.now();
    const tabBlob = await stopRecorder(tabRecorder, tabChunks);

    let micBlob = null;
    if (micRecorder) {
      micRecorderStopMs = Date.now();
      micBlob = await stopRecorder(micRecorder, micChunks);
    }

    // Compute durations from wall-clock timestamps (avoids decoding full audio to PCM)
    const tabDurationSec = tabRecorderStartMs && tabRecorderStopMs
      ? (tabRecorderStopMs - tabRecorderStartMs) / 1000
      : 0;
    const micDurationSec = micRecorderStartMs && micRecorderStopMs
      ? (micRecorderStopMs - micRecorderStartMs) / 1000
      : 0;

    // Build participant list from events
    const participantMap = new Map();
    for (const e of speakerEvents) {
      if (e.participantKey && !participantMap.has(e.participantKey)) {
        participantMap.set(e.participantKey, e.name || '');
      }
    }
    const participants = [...participantMap.entries()].map(([participantKey, name]) => ({ participantKey, name }));

    const timeline = {
      startEpochMs,
      audioT0,
      perfT0,
      tabRecorderStartMs,
      tabRecorderStopMs,
      micRecorderStartMs: micRecorderStartMs || null,
      micRecorderStopMs: micRecorderStopMs || null,
      tabDurationSec,
      micDurationSec,
      participants,
      events: speakerEvents
    };

    if (pendingMicError) {
      timeline.micError = pendingMicError;
    }

    const timelineBlob = new Blob([JSON.stringify(timeline, null, 2)], { type: 'application/json' });

    // Save all files and wait for each to complete before reporting done
    const errors = [];
    await downloadBlob(tabBlob, 'tab-audio.webm').catch(e => errors.push(e.message));
    if (micBlob && micBlob.size > 0) {
      await downloadBlob(micBlob, 'mic-audio.webm').catch(e => errors.push(e.message));
    }
    await downloadBlob(timelineBlob, 'timeline.json').catch(e => errors.push(e.message));

    if (errors.length > 0) {
      throw new Error('Download errors: ' + errors.join('; '));
    }
  } finally {
    // Stop all tracks in every outcome path (privacy + resource cleanup)
    stopAllTracks();
    if (audioCtx) { audioCtx.close(); audioCtx = null; }
    tabRecorder = null;
    micRecorder = null;
    pendingMicError = null;
  }
}

function stopRecorder(recorder, chunks) {
  return new Promise(resolve => {
    if (recorder.state === 'inactive') {
      resolve(new Blob(chunks, { type: recorder.mimeType }));
      return;
    }
    recorder.onstop = () => resolve(new Blob(chunks, { type: recorder.mimeType }));
    recorder.stop();
  });
}

function stopAllTracks() {
  try { if (tabStream) { tabStream.getTracks().forEach(t => t.stop()); tabStream = null; } } catch (_) {}
  try { if (micStream) { micStream.getTracks().forEach(t => t.stop()); micStream = null; } } catch (_) {}
}

// Save a blob via chrome.downloads (tracks completion), falling back to anchor-click
async function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);

  if (chrome.downloads && chrome.downloads.download) {
    return new Promise((resolve, reject) => {
      chrome.downloads.download({ url, filename, saveAs: false }, downloadId => {
        if (chrome.runtime.lastError) {
          // chrome.downloads unavailable in this context — use anchor fallback
          anchorDownload(url, filename);
          setTimeout(() => URL.revokeObjectURL(url), 10000);
          resolve();
          return;
        }

        function onChanged(delta) {
          if (delta.id !== downloadId) return;
          if (!delta.state) return;
          if (delta.state.current === 'complete') {
            chrome.downloads.onChanged.removeListener(onChanged);
            URL.revokeObjectURL(url);
            resolve();
          } else if (delta.state.current === 'interrupted') {
            chrome.downloads.onChanged.removeListener(onChanged);
            URL.revokeObjectURL(url);
            reject(new Error('Download interrupted: ' + filename));
          }
        }

        chrome.downloads.onChanged.addListener(onChanged);
      });
    });
  }

  // Fallback: anchor-click (best-effort, no reliable completion signal)
  anchorDownload(url, filename);
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

function anchorDownload(url, filename) {
  const a = document.getElementById('dl');
  a.href = url;
  a.download = filename;
  a.click();
}
