"""Measure a OnlyNotes recording pair: levels, clipping, activity, and mic<-system bleed.

usage: audio_stats.py <system.wav> <mic.wav>
"""
import sys
import wave
import numpy as np
from scipy.signal import correlate, butter, sosfilt


def load(path):
    with wave.open(path, "rb") as w:
        sr, ch, sw, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    assert sw == 2, f"{path}: sampwidth {sw}"
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return sr, x


def dbfs(v):
    return 20 * np.log10(max(v, 1e-9))


def frame_rms(x, sr, win=0.05):
    n = int(sr * win)
    m = len(x) // n
    return np.sqrt((x[: m * n].reshape(m, n) ** 2).mean(axis=1) + 1e-12)


def main(sys_path, mic_path):
    sr, s = load(sys_path)
    sr2, m = load(mic_path)
    assert sr == sr2
    L = min(len(s), len(m))
    print(f"rate={sr}  sys_dur={len(s)/sr/60:.1f}min  mic_dur={len(m)/sr/60:.1f}min  len_diff={(len(s)-len(m))/sr:.2f}s")
    for name, x in (("system", s), ("mic", m)):
        r = frame_rms(x, sr)
        act = r > 10 ** (-45 / 20)
        print(
            f"{name:6s} rms={dbfs(np.sqrt((x**2).mean())):6.1f}dBFS  active_rms={dbfs(np.median(r[act])) if act.any() else -99:6.1f}dBFS  "
            f"peak={dbfs(np.abs(x).max()):5.1f}dBFS  clip(>=0.99)={(np.abs(x)>=0.99).mean()*100:.3f}%  active={act.mean()*100:.0f}%"
        )
    s, m = s[:L], m[:L]
    rs, rm = frame_rms(s, sr), frame_rms(m, sr)
    th = 10 ** (-45 / 20)
    a_s, a_m = rs > th, rm > th
    print(f"both_active={(a_s & a_m).mean()*100:.0f}%  sys_only={(a_s & ~a_m).mean()*100:.0f}%  mic_only={(~a_s & a_m).mean()*100:.0f}%")

    # Bleed: does the mic contain a delayed copy of the system audio (speakers -> mic)?
    # Band-pass both to speech band, cross-correlate in 20 s windows, lags 0..600 ms (mic after system).
    sos = butter(4, [200, 3500], btype="band", fs=sr, output="sos")
    sf, mf = sosfilt(sos, s), sosfilt(sos, m)
    win, maxlag = 20 * sr, int(0.6 * sr)
    peaks, lags = [], []
    for start in range(0, L - win - maxlag, win):
        a = sf[start : start + win]
        b = mf[start : start + win + maxlag]
        if np.sqrt((a**2).mean()) < 10 ** (-45 / 20):
            continue
        c = correlate(b, a, mode="valid", method="fft")  # lag 0..maxlag
        na = np.sqrt((a**2).sum())
        # normalise by energy of the matching mic segment at each lag (approx with sliding sum)
        e = np.convolve(b**2, np.ones(win), mode="valid")
        nc = c / (na * np.sqrt(e) + 1e-9)
        i = int(np.argmax(np.abs(nc)))
        peaks.append(abs(nc[i]))
        lags.append(i / sr * 1000)
    if peaks:
        p = np.array(peaks)
        lg = np.array(lags)
        strong = p > 0.2
        print(
            f"bleed xcorr over {len(p)} windows: median={np.median(p):.2f}  p90={np.percentile(p,90):.2f}  "
            f"windows>0.2={strong.mean()*100:.0f}%  typical_lag={np.median(lg[strong]) if strong.any() else float('nan'):.0f}ms"
        )


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
