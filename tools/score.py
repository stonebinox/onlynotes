#!/usr/bin/env python3
"""Score a diarized transcript against its WAV. Prints numbers only (no text/names/titles)."""
import argparse, json, os, re, sys, wave
from collections import defaultdict

DEFAULT_NOTES = "~/Library/Application Support/OnlyNotes/notes.json"


def wav_duration(path):
    with wave.open(path, "rb") as w:
        return w.getnframes() / float(w.getframerate())


def pct(vals, p):
    s = sorted(vals)
    if not s:
        return 0.0
    k = (len(s) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def norm_words(text):
    return re.sub(r"[^\w\s]", "", (text or "").lower()).split()


def load_segments(args):
    if args.segments:
        with open(os.path.expanduser(args.segments)) as f:
            return json.load(f)
    notes_path = os.path.expanduser(args.notes)
    with open(notes_path) as f:
        notes = json.load(f)
    if isinstance(notes, dict):  # current format: {"notes": [...], "schemaVersion": n}
        notes = notes.get("notes", [])
    base = os.path.basename(args.wav)
    for n in notes:
        ma = n.get("meetingAttachment") or {}
        p = ma.get("audioFilePath")
        if p and os.path.basename(p) == base:
            return ma.get("segments") or []
    sys.exit(f"ERROR: no note in {notes_path} has meetingAttachment.audioFilePath with basename {base}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    ap.add_argument("--notes", default=DEFAULT_NOTES)
    ap.add_argument("--segments")
    args = ap.parse_args()

    segs = load_segments(args)
    if not segs:
        sys.exit("ERROR: no segments")
    wav_dur = wav_duration(args.wav)
    mic = args.wav[:-4] + "_mic.wav" if args.wav.endswith(".wav") else None
    print(f"segments: {len(segs)}  wav_duration: {wav_dur:.1f}s", end="")
    if mic and os.path.exists(mic):
        print(f"  mic_duration: {wav_duration(mic):.1f}s", end="")
    print()

    for s in segs:
        s["_w"] = norm_words(s.get("text"))
        s["_d"] = s["endTime"] - s["startTime"]

    # 1. per-speaker
    print("\n== 1. Speakers ==")
    tags = sorted({s["speakerTag"] for s in segs})
    print(f"speaker tags: {len(tags)}")
    for t in tags:
        ss = [s for s in segs if s["speakerTag"] == t]
        print(f"  tag {t}: segments={len(ss)} talk={sum(s['_d'] for s in ss):.1f}s "
              f"words={sum(len(s['_w']) for s in ss)}")

    # 2. cross-speaker n-gram duplication
    print("\n== 2. Cross-speaker duplicates ==")
    for n in (4, 6, 8):
        owners = defaultdict(set)  # ngram -> tags
        occ = []                   # (tag, ngram) per occurrence
        for s in segs:
            w = s["_w"]
            for i in range(len(w) - n + 1):
                g = tuple(w[i:i + n])
                owners[g].add(s["speakerTag"])
                occ.append((s["speakerTag"], g))
        dup = sum(1 for t, g in occ if len(owners[g] - {t}) > 0)
        pairs = defaultdict(int)
        for g, ts in owners.items():
            for a in ts:
                for b in ts:
                    if a != b:
                        pairs[(a, b)] += 1
        print(f"  n={n}: occurrences={len(occ)} duplicated={dup} ({100.0 * dup / len(occ) if occ else 0:.1f}%)")
        for (a, b), c in sorted(pairs.items()):
            print(f"    pair {a}->{b}: shared distinct={c}")

    # 3. segment length
    print("\n== 3. Segment length ==")
    d = [s["_d"] for s in segs]
    wc = [len(s["_w"]) for s in segs]
    print(f"  dur s: max={max(d):.1f} median={pct(d, 50):.1f} p90={pct(d, 90):.1f} "
          f"p99={pct(d, 99):.1f} count>60s={sum(1 for x in d if x > 60)}")
    print(f"  words: max={max(wc)} median={pct(wc, 50):.1f}")

    # 4. coverage
    print("\n== 4. Coverage ==")
    iv = sorted((s["startTime"], s["endTime"]) for s in segs if s["endTime"] > s["startTime"])
    union, cs, ce = 0.0, None, None
    for a, b in iv:
        if ce is None or a > ce:
            if ce is not None:
                union += ce - cs
            cs, ce = a, b
        else:
            ce = max(ce, b)
    if ce is not None:
        union += ce - cs
    tend = max(s["endTime"] for s in segs)
    print(f"  union={union:.1f}s wav={wav_dur:.1f}s transcript_end={tend:.1f}s ratio={union / wav_dur:.3f}")
    if tend < wav_dur - max(5.0, 0.05 * wav_dur):
        print(f"  WARNING: transcript ends {wav_dur - tend:.1f}s before WAV end")

    # 5. ordering anomalies
    print("\n== 5. Anomalies ==")
    bad_neg = sum(1 for s in segs if s["endTime"] < s["startTime"])
    last_end, same_overlap = {}, 0
    for s in segs:  # in transcript order
        t = s["speakerTag"]
        if t in last_end and s["startTime"] < last_end[t]:
            same_overlap += 1
        last_end[t] = max(last_end.get(t, float("-inf")), s["endTime"])
    print(f"  end<start: {bad_neg}  same-tag overlap with previous: {same_overlap}  "
          f"total flagged (union, approx): {bad_neg + same_overlap}")


if __name__ == "__main__":
    main()
