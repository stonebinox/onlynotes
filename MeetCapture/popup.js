// popup.js

const statusEl = document.getElementById('status');
const btnStart = document.getElementById('btnStart');
const btnStop = document.getElementById('btnStop');
const micStatusEl = document.getElementById('micStatus');
const btnMicPermission = document.getElementById('btnMicPermission');

function setStatus(text, cls) {
  statusEl.textContent = text;
  statusEl.className = cls || '';
}

function setRecording(isRecording) {
  btnStart.disabled = isRecording;
  btnStop.disabled = !isRecording;
}

function updateMicStatus(granted) {
  micStatusEl.textContent = granted
    ? 'Mic: enabled'
    : 'Mic: not enabled (tab audio still records)';
  micStatusEl.className = granted ? 'mic-on' : 'mic-off';
}

// Restore UI state and mic status on popup open
chrome.storage.local.get(['recordingTabId', 'micGranted'], ({ recordingTabId, micGranted }) => {
  if (recordingTabId) {
    setStatus('recording…', 'recording');
    setRecording(true);
  }
  updateMicStatus(!!micGranted);
});

btnMicPermission.addEventListener('click', () => {
  chrome.tabs.create({ url: chrome.runtime.getURL('permission.html') });
});

btnStart.addEventListener('click', async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

  if (!tab || !tab.url || !tab.url.startsWith('https://meet.google.com/')) {
    setStatus('Open a Google Meet tab first', 'error');
    return;
  }

  setStatus('starting…', '');
  btnStart.disabled = true;

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
