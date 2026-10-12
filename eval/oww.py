# Runs openWakeWord's ready-made "hey jarvis" model over a test set, 80 ms at a time, as a microphone would feed it.
import sys, json, time, wave, resource
import numpy as np
from openwakeword.model import Model
setdir, thresh = sys.argv[1], float(sys.argv[2])
t0 = time.time(); model = Model(wakeword_models=["hey_jarvis"], inference_framework="onnx"); load = time.time() - t0
meta = json.load(open(f"{setdir}/meta.json"))
res = {}; audio = work = 0.0
for m in meta:
    with wave.open(f"{setdir}/{m['file']}") as w: x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
    x = np.concatenate([x, np.zeros(16000, dtype="<i2")])
    model.reset(); hits = []; cool = 0
    t1 = time.time()
    for i in range(0, len(x) - 1280, 1280):
        p = model.predict(x[i:i + 1280])["hey_jarvis"]
        if cool > 0: cool -= 1
        elif p >= thresh: hits.append((i + 1280) / 16000); cool = 12
    work += time.time() - t1; audio += len(x) / 16000
    kind = "hey" if m["kind"] == "pos" and "Hey" in m["text"] else "name" if m["kind"] == "pos" else m["kind"]
    d = res.setdefault((kind, m["condition"]), {"n": 0, "hit": 0, "count": 0, "secs": 0.0, "delays": []})
    d["n"] += 1; d["secs"] += m["seconds"]; d["count"] += len(hits)
    if hits:
        d["hit"] += 1
        if kind == "hey": d["delays"].append(hits[0] - m["end"])
C = ["clean", "quiet", "noise", "babble", "echo"]
print(f"threshold {thresh} | loaded in {load:.2f} s | {work / audio * 100:.1f}% of one core | memory {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6:.0f} MB")
for c in C:
    h, n, s, t = res[("hey", c)], res[("name", c)], res[("sim", c)], res[("talk", c)]
    dl = sorted(h["delays"])
    print(f"  {c:6} 'Hey Jarvis' heard {h['hit']:2}/{h['n']} | 'Jarvis' without hey {n['hit']:3}/{n['n']} | woke on other words {s['hit']}/{s['n']} | during talk {t['count']} in {t['secs'] / 60:.1f} min" + (f" | delay median {dl[len(dl) // 2]:.2f} s worst {dl[-1]:.2f} s" if dl else ""))
hh = sum(res[("hey", c)]["hit"] for c in C); hn = sum(res[("hey", c)]["n"] for c in C)
fa = sum(res[(k, c)]["count"] for k in ["sim", "talk"] for c in C); hrs = sum(res[(k, c)]["secs"] for k in ["sim", "talk"] for c in C) / 3600
print(f"  TOTAL 'Hey Jarvis' heard {hh}/{hn} ({hh / hn * 100:.0f}%) | false wake-ups {fa} in {hrs * 60:.0f} min ({fa / hrs:.1f} per hour)")
