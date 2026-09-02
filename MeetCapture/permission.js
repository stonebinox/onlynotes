// permission.js

const btnGrant = document.getElementById('btnGrant');
const msgEl = document.getElementById('msg');

async function requestMic() {
  btnGrant.disabled = true;
  msgEl.textContent = 'Requesting…';
  msgEl.className = '';

  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    stream.getTracks().forEach(t => t.stop());
    await chrome.storage.local.set({ micGranted: true });
    msgEl.textContent = 'Microphone enabled — you can close this tab and start recording.';
    msgEl.className = 'ok';
  } catch (err) {
    await chrome.storage.local.set({ micGranted: false });
    if (err.name === 'NotAllowedError') {
      msgEl.textContent =
        'Permission denied. If previously blocked, reset it at chrome://settings/content/microphone, then try again.';
    } else {
      msgEl.textContent = 'Could not access microphone: ' + err.message;
    }
    msgEl.className = 'err';
    btnGrant.disabled = false;
  }
}

btnGrant.addEventListener('click', requestMic);
