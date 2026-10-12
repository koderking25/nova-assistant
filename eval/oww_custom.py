# Scores custom openWakeWord models (for example hey_nova.onnx and nova.onnx) on a test set made by gen.py.
# Usage: python oww_custom.py <set folder> <threshold> <model.onnx> [<model.onnx> ...]
# The recordings are SYNTHETIC (the Mac's own voices). This says nothing certain about real voices.
import sys, json, time, wave, os, resource
import numpy as np
from openwakeword.model import Model
setdir, thresh, paths = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
C = ["clean", "quiet", "noise", "babble", "echo"]
meta = json.load(open(f"{setdir}/meta.json"))
for path in paths:
    key = os.path.splitext(os.path.basename(path))[0]
    needs_hey = key.startswith("hey")
    t0 = time.time(); model = Model(wakeword_models=[path], inference_framework="onnx"); load = time.time() - t0
    res = {}; audio = work = 0.0
    for m in meta:
        with wave.open(f"{setdir}/{m['file']}") as w: x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
        x = np.concatenate([x, np.zeros(16000, dtype="<i2")])
        model.reset(); hits = []; cool = 0
        t1 = time.time()
        for i in range(0, len(x) - 1280, 1280):
            p = list(model.predict(x[i:i + 1280]).values())[0]
            if cool > 0: cool -= 1
            elif p >= thresh: hits.append((i + 1280) / 16000); cool = 12
        work += time.time() - t1; audio += len(x) / 16000
        # For a "hey ..." model only the recordings that say "Hey" are fair positives.
        kind = m["kind"]
        if kind == "pos" and needs_hey and "Hey" not in m["text"]: kind = "name-without-hey"
        d = res.setdefault((kind, m["condition"]), {"n": 0, "hit": 0, "count": 0, "secs": 0.0, "delays": []})
        d["n"] += 1; d["secs"] += m["seconds"]; d["count"] += len(hits)
        if hits:
            d["hit"] += 1
            if kind == "pos": d["delays"].append(hits[0] - m["end"])
    print(f"{key} | threshold {thresh} | loaded in {load:.2f} s | {work / audio * 100:.1f}% of one core | memory {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6:.0f} MB  [synthetic recordings]")
    for c in C:
        p, s, t = res[("pos", c)], res[("sim", c)], res[("talk", c)]
        dl = sorted(p["delays"])
        print(f"  {c:6} heard {p['hit']:3}/{p['n']} | woke on a sound-alike {s['hit']:3}/{s['n']} | woke during talk {t['count']} times in {t['secs'] / 60:.1f} min" + (f" | delay median {dl[len(dl) // 2]:.2f} s worst {dl[-1]:.2f} s" if dl else ""))
    hp = sum(res[("pos", c)]["hit"] for c in C); np_ = sum(res[("pos", c)]["n"] for c in C)
    fa = sum(res[(k, c)]["count"] for k in ["sim", "talk"] for c in C); hrs = sum(res[(k, c)]["secs"] for k in ["sim", "talk"] for c in C) / 3600
    print(f"  TOTAL  heard {hp}/{np_} ({hp / max(1, np_) * 100:.0f}%) | false wake-ups {fa} in {hrs * 60:.0f} min ({fa / hrs:.1f} per hour)")
