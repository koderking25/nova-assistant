# Builds the test recordings: the name said many ways, words that sound like it, and ordinary
# talk, each in five conditions. Everything is made by the Mac's own voices, so it is repeatable.
import os, subprocess, wave, sys, json
import numpy as np
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(7)
voices = ["Alex", "Daniel", "Karen", "Moira", "Fred", "Kathy", "Ralph", "Reed", "Eddy", "Flo", "Junior", "Grandma"]
name = sys.argv[2] if len(sys.argv) > 2 else "Nova"
positives = [name, f"Hey {name}", f"{name}, what's the weather", f"{name} stop", f"so anyway. {name}, play some music", f"Okay {name}, what time is it", f"{name}, open Safari", f"{name}?"]
# Words that sound like the name. For another name, give its own list as the third argument, separated by "|".
similar = sys.argv[3].split("|") if len(sys.argv) > 3 else ["No", "No.", "Now", "Know", "Nope", "No way", "Noah", "Novel", "November", "Nobody", "Over", "Innovate", "Nevada", "Mocha", "Lava", "No, not now", "I know that", "Not over there", "No, I don't think so", "Now I know"]
talk = ["I don't know what time the movie starts, but no, I can't go now. Maybe over the weekend. Nobody told me about the new plan.",
        "We were over at the store and there was no bread left. Now we have to go back tomorrow, you know how it is in November.",
        "The novel she is reading is about a navy officer who moves to Nevada. No one knows why he left, not even his mother.",
        "Can you turn the volume down a little? No, lower. That's better. Now pass me the remote, I know it's over there somewhere.",
        "He said no at first, then he said maybe, and now he says he never knew about it. I've no idea what is going on any more.",
        "Innovation is not about knowing everything. It is about noticing what nobody else has noticed, and then doing it over and over."]
def say(voice, text, path, rate=None):
    # Some voices occasionally never finish; each gets ten seconds, and a silent clip stands in if one fails.
    cmd = ["say", "-v", voice, "-o", path, "--data-format=LEI16@16000"] + (["-r", str(rate)] if rate else []) + [text]
    if os.path.exists(path): os.remove(path)
    try: subprocess.run(cmd, check=False, timeout=10)
    except subprocess.TimeoutExpired: pass
    if not os.path.exists(path):
        with wave.open(path, "wb") as w: w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(b"\0\0" * 8000)
def read(path):
    with wave.open(path) as w: return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768
def write(path, x):
    x = np.clip(x, -1, 1)
    with wave.open(path, "wb") as w: w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes((x * 32767).astype("<i2").tobytes())
def pink(n):
    f = np.fft.rfft(rng.standard_normal(n)); f[1:] /= np.sqrt(np.arange(1, len(f))); x = np.fft.irfft(f, n); return x / (np.abs(x).max() + 1e-9)
def rms(x): return float(np.sqrt(np.mean(x ** 2)) + 1e-9)
def mix(x, noise, snr): 
    noise = np.resize(noise, len(x)); return x + noise * (rms(x[np.abs(x) > 0.01]) if np.any(np.abs(x) > 0.01) else rms(x)) / rms(noise) / (10 ** (snr / 20))
ir = rng.standard_normal(int(0.35 * 16000)) * np.exp(-np.linspace(0, 7, int(0.35 * 16000))); ir[0] = 1; ir /= np.abs(ir).sum() ** 0.5
tmp = os.path.join(out, "_raw.wav")
babble = []
for i, t in enumerate(talk):
    say(voices[(i * 5 + 3) % len(voices)], t, tmp); babble.append(read(tmp))
babble = np.concatenate(babble)
meta = []
def emit(kind, voice, text, x, extra=""):
    pad = np.zeros(8000, dtype=np.float32)
    x = np.concatenate([pad[:4000], x, pad])              # a little silence before, half a second after
    spoken_end = (len(x) - 8000) / 16000
    for cond, y in [("clean", x), ("quiet", x * 0.1), ("noise", mix(x, pink(len(x)), 10)), ("babble", mix(x, babble[rng.integers(0, len(babble) - len(x) - 1):], 8)), ("echo", np.convolve(x, ir)[:len(x)])]:
        fn = f"{kind}-{len(meta):04d}.wav"; write(os.path.join(out, fn), y)
        meta.append({"file": fn, "kind": kind, "voice": voice, "text": text, "condition": cond, "end": spoken_end, "seconds": len(y) / 16000, "extra": extra})
for v in voices:
    for p in positives: say(v, p, tmp); emit("pos", v, p, read(tmp))
    for r in (150, 240): say(v, name, tmp, r); emit("pos", v, name, read(tmp), f"rate {r}")
    for s in similar: say(v, s, tmp); emit("sim", v, s, read(tmp))
for i, t in enumerate(talk):
    for v in voices[i % 2::2]: say(v, t, tmp); emit("talk", v, t, read(tmp))
os.remove(tmp)
json.dump(meta, open(os.path.join(out, "meta.json"), "w"))
from collections import Counter
c = Counter(m["kind"] for m in meta)
print(dict(c), "talk minutes: %.1f" % (sum(m["seconds"] for m in meta if m["kind"] == "talk") / 60), "similar minutes: %.1f" % (sum(m["seconds"] for m in meta if m["kind"] == "sim") / 60))
