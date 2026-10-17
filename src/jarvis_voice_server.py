"""The Jarvis voice: Kyutai's Pocket TTS on Apple's MLX, with a hologram finish.

Nova starts this once and keeps it running. It reads one request per line,
    id <tab> voice <tab> speed <tab> output path <tab> text
writes a 16-bit stereo WAV to the path, and answers "id <tab> ok" (or "fail").
At start it prints "ready <tab> jarvis" once the model and the voice are loaded.

The voice is VCTK speaker p226 (CC BY 4.0, Centre for Speech Technology Research,
University of Edinburgh), via Kyutai's tts-voices. Pocket TTS is by Kyutai (CC BY 4.0).
"""
import os, sys, wave
import numpy as np

FOLDER = sys.argv[1]


def out(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


try:
    import mlx.core as mx
    from scipy.signal import butter, sosfilt, lfilter
    from mlx_audio.tts.utils import load_model

    # Keep the graphics memory this holds on to small: this Mac has little to spare.
    mx.set_cache_limit(64 * 1024 * 1024)
    # From the folder itself (it may be inside the app, where nothing can be written), never the network.
    import glob
    snap = sorted(glob.glob(os.path.join(FOLDER, "hf/hub/models--mlx-community--pocket-tts-8bit/snapshots/*")))
    model = load_model(snap[-1] if snap else "mlx-community/pocket-tts-8bit")
    SR = model.sample_rate
    with wave.open(os.path.join(FOLDER, "voice.wav")) as w:
        raw = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
        if w.getnchannels() == 2:
            raw = raw.reshape(-1, 2).mean(1)
        ref_rate = w.getframerate()
    if ref_rate != SR:
        n = int(len(raw) * SR / ref_rate)
        raw = np.interp(np.linspace(0, len(raw) - 1, n), np.arange(len(raw)), raw).astype(np.float32)
    # The voice is learned once; every sentence starts from this state.
    prompt = model._encode_audio(mx.array(raw)[None, None, :])
    mx.eval(prompt)

    def fresh_state():
        # Each sentence starts from the voice alone: the model's memory of the last sentence is not carried over.
        st = model.init_state()
        model._run_flow_lm_and_increment_step(model_state=st, audio_conditioning=prompt)
        model._slice_flow_cache(st, prompt.shape[1])
        return st
except Exception as e:  # noqa: BLE001
    out("failed\t" + str(e).replace("\n", " ")[:300])
    sys.exit(1)


# ---- The hologram finish (voice 1, C): bright and airy, a faint doubled shimmer, a small clean room.

def peak(x, f, gain_db, q):
    A = 10 ** (gain_db / 40); w0 = 2 * np.pi * f / SR; al = np.sin(w0) / (2 * q)
    b = np.array([1 + al * A, -2 * np.cos(w0), 1 - al * A]); a = np.array([1 + al / A, -2 * np.cos(w0), 1 - al / A])
    return lfilter(b / a[0], a / a[0], x)


def shelf(x, f, gain_db):
    return x + (10 ** (gain_db / 20) - 1) * sosfilt(butter(2, f, "highpass", fs=SR, output="sos"), x)


def compress(x, thr_db=-20, ratio=3, att=0.003, rel=0.08):
    blk = SR // 1000; n = len(x) // blk * blk
    if n == 0:
        return x
    e = np.abs(x[:n]).reshape(-1, blk).max(1)
    env = np.empty_like(e); v = 0.0; ga = np.exp(-1 / (att * 1000)); gr = np.exp(-1 / (rel * 1000))
    for i, s in enumerate(e):
        v = ga * v + (1 - ga) * s if s > v else gr * v + (1 - gr) * s
        env[i] = v
    thr = 10 ** (thr_db / 20); env = np.maximum(env, 1e-9)
    g = np.where(env < thr, 1.0, (thr * (env / thr) ** (1 / ratio)) / env)
    g = np.concatenate([np.repeat(g, blk), np.full(len(x) - n, g[-1])])
    return x * g * 1.6


def vdelay(x, base_ms, depth_ms, rate):
    n = np.arange(len(x)); d = (base_ms + depth_ms * np.sin(2 * np.pi * rate * n / SR)) * SR / 1000
    idx = n - d; fl = np.floor(idx); i0 = np.clip(fl.astype(int), 0, len(x) - 1); i1 = np.clip(i0 + 1, 0, len(x) - 1)
    fr = idx - fl; y = x[i0] * (1 - fr) + x[i1] * fr; y[idx < 0] = 0
    return y


ROOM_BAND = butter(1, [300, 7000], "bandpass", fs=SR, output="sos")
TOP_BAND = butter(2, [2500, 9000], "bandpass", fs=SR, output="sos")
LOW_CUT = butter(2, 150, "highpass", fs=SR, output="sos")


def room(x, size, mix):
    y = np.zeros_like(x)
    for d, g in [(23, .5), (31, .45), (41, .4), (53, .35), (67, .3), (83, .25), (101, .2), (127, .15)]:
        k = int(d * SR / 1000 * (0.6 + size))
        if k < len(x):
            y[k:] += x[:-k] * g
    return x + mix * sosfilt(ROOM_BAND, y)


def hologram(x):
    x = sosfilt(LOW_CUT, x)
    x = peak(x, 250, -3, 0.8)
    x = peak(x, 3000, 7, 0.8)
    x = shelf(shelf(x, 4500, 9), 8000, 8)
    x = compress(x)
    h = np.abs(x) - np.abs(x).mean()
    x = x + 0.35 * sosfilt(TOP_BAND, h)
    tail = np.zeros(int(SR * 0.12), np.float32)        # room for the echo to finish
    x = np.concatenate([x, tail])
    l = room(x + 0.45 * vdelay(x, 9, 3, 0.25), 0.45, 0.14)
    r = room(x + 0.45 * vdelay(x, 14, 3, 0.31), 0.50, 0.14)
    st = np.stack([l, r], 1)
    return st / max(1e-6, np.abs(st).max()) * 0.89


def speak(text, path):
    pieces = [np.array(c).reshape(-1) for c in model.generate_audio_stream(model_state=fresh_state(), text_to_generate=text)]
    if not pieces:
        return False
    a = hologram(np.concatenate(pieces).astype(np.float64))
    tmp = path + ".part"
    with wave.open(tmp, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((a * 32767).astype(np.int16).tobytes())
    os.replace(tmp, path)
    mx.clear_cache()
    return True


import tempfile
speak("Ready.", os.path.join(tempfile.gettempdir(), "nova-jarvis-warm.wav"))     # the first sentence is slow; get it out of the way
out("ready\tjarvis")
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 5:
        continue
    rid, _voice, _speed, path, text = parts[0], parts[1], parts[2], parts[3], "\t".join(parts[4:])
    try:
        out(rid + ("\tok" if speak(text, path) else "\tfail"))
    except Exception as e:  # noqa: BLE001
        out(rid + "\tfail " + str(e).replace("\n", " ")[:200])
