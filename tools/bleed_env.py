"""Envelope-based bleed test, robust to small misalignment.

Builds 20 ms log-energy envelopes of both tracks, then for 30 s mic windows searches
the system envelope over a wide lag range for the best Pearson correlation.
High correlation means the mic hears the same loudness pattern as system audio.

usage: bleed_env.py <system.wav> <mic.wav>
"""
import sys
import wave
import numpy as np
from scipy.signal import butter, sosfilt


def env(path, hop=0.02):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    x = sosfilt(butter(4, [300, 3400], btype="band", fs=sr, output="sos"), x)
    n = int(sr * hop)
    k = len(x) // n
    e = np.log10((x[: k * n].reshape(k, n) ** 2).mean(axis=1) + 1e-10)
    return e, hop


def main(sp, mp):
    es, hop = env(sp)
    em, _ = env(mp)
    W = int(30 / hop)
    rows = []
    for st in range(int(60 / hop), len(em) - W, int(60 / hop)):
        a = em[st : st + W]
        t = st * hop
        reach = int((0.03 * t + 5) / hop)
        best, bl = -1, 0
        for lag in range(-reach, reach + 1):
            j = st + lag
            if j < 0 or j + W > len(es):
                continue
            c = np.corrcoef(a, es[j : j + W])[0, 1]
            if c > best:
                best, bl = c, lag * hop
        rows.append((t, best, bl))
    r = np.array(rows)
    strong = r[r[:, 1] > 0.5]
    print(f"windows={len(r)}  env-corr median={np.median(r[:,1]):.2f}  p90={np.percentile(r[:,1],90):.2f}  windows>0.5={len(strong)}/{len(r)}")
    if len(strong) >= 3:
        k, b0 = np.polyfit(strong[:, 0], strong[:, 2], 1)
        print(f"lag fit: lag(s) = {b0:+.2f} + {k*100:.2f}% * t   (+ = system later than mic)")
        for t, c, lag in strong[:: max(1, len(strong) // 6)]:
            print(f"  t={t/60:5.1f}min corr={c:.2f} lag={lag:+.2f}s")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
