// popup.js

const statusEl = document.getElementById('status');
const btnStart = document.getElementById('btnStart');
const btnStop = document.getElementById('btnStop');

function setStatus(text, cls) {
  statusEl.textContent = text;
  statusEl.className = cls || '';
}

function setRecording(isRecording) {
  btnStart.disabled = isRecording;
  btnStop.disabled = !isRecording;
}

// Restore UI state if we were already recording
chrome.storage.local.get('recordingTabId', ({ recordingTabId }) => {
  if (recordingTabId) {
    setStatus('recording…', 'recording');
    setRecording(true);
  }
});

btnStart.addEventListener('click', async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

  if (!tab || !tab.url || !tab.url.startsWith('https://meet.google.com/')) {
    setStatus('Open a Google Meet tab first', 'error');
    return;
  }

  setStatus('starting…', '');
  btnStart.disabled = true;

  // Request mic permission from this visible page so the offscreen doc can capture it.
  // The grant persists for the extension origin; tracks are stopped immediately.
  try {
    const micStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    micStream.getTracks().forEach(t => t.stop());
  } catch (_) {
    setStatus('Microphone access denied — allow mic and try again', 'error');
    btnStart.disabled = false;
    return;
  }

  const resp = await chrome.runtime.sendMessage({ type: 'START_RECORDING', tabId: tab.id });

  if (resp && resp.ok) {
    setStatus('recording…', 'recording');
    setRecording(true);
  } else {
    setStatus('Error: ' + (resp && resp.error ? resp.error : 'unknown'), 'error');
    btnStart.disabled = false;
  }
});

btnStop.addEventListener('click', async () => {
  setStatus('stopping…', '');
  btnStop.disabled = true;

  const resp = await chrome.runtime.sendMessage({ type: 'STOP_RECORDING' });

  if (resp && resp.ok) {
    setStatus('saved to Downloads', 'saved');
    setRecording(false);
  } else {
    setStatus('Error: ' + (resp && resp.error ? resp.error : 'unknown'), 'error');
    btnStop.disabled = false;
  }
});
