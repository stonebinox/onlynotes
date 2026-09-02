// content.js — injected into https://meet.google.com/*
// Watches Meet's DOM for active-speaker changes and buffers a timeline.
// Deliberately defensive: all DOM access is wrapped, errors are swallowed.

(function () {
  'use strict';

  // ── State ──────────────────────────────────────────────────────────────────

  let startEpochMs = null;
  let events = [];
  let lastParticipantKey = null;
  let lastEventTime = 0;
  const FLAP_THRESHOLD_MS = 300; // ignore speaker changes shorter than this
  const HEARTBEAT_INTERVAL_MS = 5000;

  let pollInterval = null;
  let observer = null;

  // ── Message handler ────────────────────────────────────────────────────────

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg.type === 'START_OBSERVATION') {
      startEpochMs = msg.startEpochMs;
      events = [];
      lastParticipantKey = null;
      lastEventTime = 0;
      startObservation();
      sendResponse({ ok: true });
      return false;
    }
    if (msg.type === 'GET_EVENTS') {
      const snapshot = [...events];
      stopObservation();
      sendResponse({ events: snapshot });
      return false;
    }
  });

  function startObservation() {
    if (!pollInterval) {
      pollInterval = setInterval(tick, 250);
    }
    if (!observer) {
      try {
        observer = new MutationObserver(() => {
          try { tick(); } catch (_) {}
        });
        observer.observe(document.body, { subtree: true, attributes: true, attributeFilter: [
          'class', 'data-is-speaking', 'data-speaking', 'data-active-speaker',
          'data-is-active-speaker', 'data-is-dominant-speaker', 'aria-label'
        ]});
      } catch (_) {}
    }
  }

  function stopObservation() {
    if (pollInterval) { clearInterval(pollInterval); pollInterval = null; }
    if (observer) { observer.disconnect(); observer = null; }
  }

  // ── Speaker detection ──────────────────────────────────────────────────────

  // Returns { participantKey, name, signal } for the current dominant speaker,
  // or null if none detected.
  function detectActiveSpeaker() {
    try {
      return (
        trySignalSpeakingBars() ||
        trySignalTileHighlight() ||
        trySignalDominantSpeaker() ||
        null
      );
    } catch (_) {
      return null;
    }
  }

  // Heuristic 1: genuine active-speaker data attributes on or near a tile.
  // NOTE: these selectors are unverified against live Meet DOM and are expected
  // to be tuned after the first real run. It is better to detect nothing (emit
  // heartbeats) than to emit false positives.
  function trySignalSpeakingBars() {
    const SELECTORS = [
      '[data-is-speaking="true"]',
      '[data-speaking="true"]',
      '.speaking-indicator'
    ];
    for (const sel of SELECTORS) {
      try {
        const el = document.querySelector(sel);
        if (el) {
          const tile = closestTile(el);
          if (tile) {
            return { ...extractParticipant(tile), signal: 'speaking-bars' };
          }
        }
      } catch (_) {}
    }
    return null;
  }

  // Heuristic 2: explicit active-speaker attribute on a tile element.
  // NOTE: selectors unverified against live Meet DOM — tune after first real run.
  function trySignalTileHighlight() {
    const SELECTORS = [
      '[data-active-speaker="true"]',
      '[data-is-active-speaker="true"]'
    ];
    for (const sel of SELECTORS) {
      try {
        const el = document.querySelector(sel);
        if (el) {
          const tile = closestTile(el) || el;
          const info = extractParticipant(tile);
          if (info.participantKey) {
            return { ...info, signal: 'tile-highlight' };
          }
        }
      } catch (_) {}
    }
    return null;
  }

  // Heuristic 3: dominant-speaker attribute on a participant tile.
  // NOTE: selectors unverified against live Meet DOM — tune after first real run.
  function trySignalDominantSpeaker() {
    const SELECTORS = [
      '[data-participant-id][data-is-dominant-speaker="true"]'
    ];
    for (const sel of SELECTORS) {
      try {
        const el = document.querySelector(sel);
        if (el) {
          const info = extractParticipant(el);
          if (info.participantKey) {
            return { ...info, signal: 'dominant-speaker' };
          }
        }
      } catch (_) {}
    }
    return null;
  }

  // Walk up from el to find the nearest participant tile container
  function closestTile(el) {
    try {
      let cur = el;
      for (let i = 0; i < 10; i++) {
        if (!cur || cur === document.body) break;
        if (cur.dataset && (cur.dataset.participantId || cur.dataset.ssrc)) return cur;
        cur = cur.parentElement;
      }
      return el.closest('[data-participant-id]') || el.closest('[class*="tile"]') || null;
    } catch (_) {
      return null;
    }
  }

  // Extract a stable key + display name from a tile element
  function extractParticipant(tile) {
    try {
      const participantKey =
        tile.dataset.participantId ||
        tile.dataset.ssrc ||
        tile.getAttribute('data-participant-id') ||
        tile.getAttribute('data-ssrc') ||
        null;

      const nameEl =
        tile.querySelector('[class*="name"]') ||
        tile.querySelector('[class*="label"]') ||
        tile.querySelector('span') ||
        null;
      const name = (nameEl ? nameEl.textContent.trim() : '') ||
        tile.getAttribute('aria-label') ||
        participantKey ||
        'unknown';

      return { participantKey, name };
    } catch (_) {
      return { participantKey: null, name: 'unknown' };
    }
  }

  // ── Emit an event ─────────────────────────────────────────────────────────

  function emit(participantKey, name, signal) {
    if (!startEpochMs) return;
    const tMs = Date.now() - startEpochMs;
    const event = { tMs, participantKey, name, signal };
    events.push(event);
    // Forward to background for redundant accumulation
    try {
      chrome.runtime.sendMessage({ type: 'SPEAKER_EVENT', event });
    } catch (_) {}
  }

  // ── Poll loop ──────────────────────────────────────────────────────────────

  function tick() {
    const speaker = detectActiveSpeaker();
    const now = Date.now();

    if (!speaker) {
      // Emit a heartbeat if we haven't logged anything recently
      if (startEpochMs && now - lastEventTime > HEARTBEAT_INTERVAL_MS) {
        emit(null, '', 'no-active-speaker-detected');
        lastEventTime = now;
      }
      return;
    }

    const { participantKey, name, signal } = speaker;

    // Flap suppression: require sustained change for FLAP_THRESHOLD_MS
    if (participantKey === lastParticipantKey) return;

    // If it just changed, wait FLAP_THRESHOLD_MS before committing
    if (now - lastEventTime < FLAP_THRESHOLD_MS && lastParticipantKey !== null) return;

    lastParticipantKey = participantKey;
    lastEventTime = now;
    emit(participantKey, name, signal);
  }

})();
