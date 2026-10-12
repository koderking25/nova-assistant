# Runs the sherpa-onnx keyword spotter over a test set as a microphone would feed it (0.1 s at a time)
# and reports misses, false activations and delay, separately.
import sys, json, time, wave, os, resource
import numpy as np, sherpa_onnx, sentencepiece as spm
M = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
setdir, name, score, thresh = sys.argv[1], sys.argv[2].upper(), float(sys.argv[3]), float(sys.argv[4])
sp = spm.SentencePieceProcessor(model_file=f"{M}/bpe.model")
kw = "kw.txt"
with open(kw, "w") as f:
    for phrase in [name, "HEY " + name]:
        f.write(" ".join(sp.encode(phrase, out_type=str)) + f" :{score} #{thresh} @{phrase.replace(' ', '_')}\n")
t0 = time.time()
spotter = sherpa_onnx.KeywordSpotter(tokens=f"{M}/tokens.txt", encoder=f"{M}/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx", decoder=f"{M}/decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                                     joiner=f"{M}/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx", num_threads=1, keywords_file=kw, provider="cpu")
load = time.time() - t0
meta = json.load(open(f"{setdir}/meta.json"))
res = {}; audio = 0.0; work = 0.0
for m in meta:
    with wave.open(f"{setdir}/{m['file']}") as w: x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768
    x = np.concatenate([x, np.zeros(8000, dtype=np.float32)])
    s = spotter.create_stream(); hits = []
    t1 = time.time()
    for i in range(0, len(x), 1600):
        s.accept_waveform(16000, x[i:i + 1600])
        while spotter.is_ready(s):
            spotter.decode_stream(s)
            r = spotter.get_result(s)
            if r:
                hits.append((i + 1600) / 16000); spotter.reset_stream(s)
    work += time.time() - t1; audio += len(x) / 16000
    k = (m["kind"], m["condition"]); d = res.setdefault(k, {"n": 0, "hit": 0, "count": 0, "secs": 0.0, "delays": [], "missed": []})
    d["n"] += 1; d["secs"] += m["seconds"]; d["count"] += len(hits)
    if hits:
        d["hit"] += 1
        if m["kind"] == "pos" and m["text"].strip("?").lower() == name.lower(): d["delays"].append(hits[0] - m["end"])
    elif m["kind"] == "pos": d["missed"].append(m["voice"] + ":" + m["text"])
    if hits and m["kind"] != "pos": d["missed"].append(m["voice"] + ":" + m["text"][:28])
print(f"score {score} threshold {thresh} | model loaded in {load:.2f} s | {work / audio * 100:.1f}% of one core | memory {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6:.0f} MB")
for cond in ["clean", "quiet", "noise", "babble", "echo"]:
    p, sm, tk = res[("pos", cond)], res[("sim", cond)], res[("talk", cond)]
    dl = sorted(p["delays"])
    print(f"  {cond:6} heard the name {p['hit']:3}/{p['n']} | woke on a sound-alike {sm['hit']:3}/{sm['n']} | woke during talk {tk['count']} times in {tk['secs'] / 60:.1f} min" + (f" | delay after the word: median {dl[len(dl) // 2]:.2f} s, worst {dl[-1]:.2f} s" if dl else ""))
tot_p = sum(res[("pos", c)]["hit"] for c in ["clean", "quiet", "noise", "babble", "echo"]); n_p = sum(res[("pos", c)]["n"] for c in ["clean", "quiet", "noise", "babble", "echo"])
fa = sum(res[(k, c)]["count"] for k in ["sim", "talk"] for c in ["clean", "quiet", "noise", "babble", "echo"]); hrs = sum(res[(k, c)]["secs"] for k in ["sim", "talk"] for c in ["clean", "quiet", "noise", "babble", "echo"]) / 3600
print(f"  TOTAL  heard {tot_p}/{n_p} ({tot_p / n_p * 100:.0f}%) | false wake-ups {fa} in {hrs * 60:.0f} min ({fa / hrs:.1f} per hour)")
if "--detail" in sys.argv:
    from collections import Counter
    print("  false wake-ups on:", Counter(x.split(":")[1] for k in ["sim", "talk"] for c in ["clean", "quiet", "noise", "babble", "echo"] for x in res[(k, c)]["missed"]).most_common(12))
    print("  missed:", Counter(x.split(":")[1] for c in ["clean", "quiet", "noise", "babble", "echo"] for x in res[("pos", c)]["missed"]).most_common(8))
