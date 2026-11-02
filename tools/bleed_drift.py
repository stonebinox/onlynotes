"""Detect system->mic bleed when the mic track drifts relative to the system track.

For short mic windows, search the system track over a wide lag range and report the
best normalised correlation and the lag at which it occurs.

usage: bleed_drift.py <system.wav> <mic.wav>
"""
import sys
import wave
import numpy as np
from scipy.signal import correlate, butter, sosfilt


def load(path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    return sr, x


def main(sys_path, mic_path):
    sr, s = load(sys_path)
    _, m = load(mic_path)
    sos = butter(4, [300, 3400], btype="band", fs=sr, output="sos")
    s, m = sosfilt(sos, s), sosfilt(sos, m)
    win = 3 * sr
    rows = []
    for t in np.arange(30, len(m) / sr - 30, 60):  # one probe per minute
        a0 = int(t * sr)
        a = m[a0 : a0 + win]
        if np.sqrt((a ** 2).mean()) < 10 ** (-50 / 20):
            continue
        reach = int((0.03 * t + 5) * sr)  # allow up to 3% drift either way + 5 s
        lo, hi = max(0, a0 - reach), min(len(s), a0 + win + reach)
        b = s[lo:hi]
        if len(b) <= win:
            continue
        c = correlate(b, a, mode="valid", method="fft")
        cs = np.concatenate(([0.0], np.cumsum(b.astype(np.float64) ** 2)))
        e = cs[win:] - cs[:-win]
        nc = np.abs(c) / (np.sqrt((a ** 2).sum()) * np.sqrt(e) + 1e-9)
        i = int(np.argmax(nc))
        lag = (lo + i - a0) / sr  # +ve: matching system audio is LATER than mic position
        rows.append((t, nc[i], lag))
    rows = np.array(rows)
    strong = rows[rows[:, 1] > 0.3]
    print(f"probes={len(rows)}  corr median={np.median(rows[:,1]):.2f}  probes>0.3={len(strong)}/{len(rows)}")
    if len(strong) >= 3:
        k, b0 = np.polyfit(strong[:, 0], strong[:, 2], 1)
        print(f"lag fit on strong probes: lag(s) = {b0:.2f} + {k*100:.2f}% * t")
        for t, c, lag in strong[:: max(1, len(strong) // 8)]:
            print(f"  t={t/60:5.1f}min corr={c:.2f} lag={lag:+.2f}s")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
