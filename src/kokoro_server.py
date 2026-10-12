# Kokoro voice server for Talking Piano.
# Keeps the Kokoro speech model loaded and turns each line it is given into a sound file.
#
# Started by the tool as:  voice/.venv/bin/python -I kokoro_server.py <folder with the model>
# Each input line:   <id> TAB <voice> TAB <speed> TAB <output path> TAB <text>
# Each reply line:   <id> TAB ok TAB <seconds of sound>      or      <id> TAB error TAB <why>
# The first line printed is "ready" followed by the voices on offer.
import struct
import sys

def main():
    folder = sys.argv[1]
    try:
        import numpy as np
        from kokoro_onnx import Kokoro
        # The speech rules (espeak-ng) are told where their data is by naming the folder that holds
        # a folder called "espeak-ng-data". Given the long path inside the Python packages, they
        # fail on some Macs (a path over about 160 characters is cut short), and then nothing can be
        # spoken. So a short folder is made in /tmp with a link to the data, and that is named instead.
        espeak = None
        try:
            import os, tempfile, hashlib
            import espeakng_loader
            from kokoro_onnx.config import EspeakConfig
            data = espeakng_loader.get_data_path()
            home = os.path.join("/tmp" if os.path.isdir("/tmp") else tempfile.gettempdir(), "nova-espeak-" + hashlib.md5(data.encode()).hexdigest()[:10])
            link = os.path.join(home, "espeak-ng-data")
            if os.path.islink(home) or os.path.isfile(home):
                os.remove(home)
            os.makedirs(home, exist_ok=True)
            if os.path.islink(link) and os.readlink(link) != data:
                os.remove(link)
            if not os.path.exists(link):
                os.symlink(data, link)
            if os.path.exists(os.path.join(link, "phontab")):
                espeak = EspeakConfig(lib_path=espeakng_loader.get_library_path(), data_path=home)
        except Exception:
            espeak = None
        try:
            # Four threads, one per fast core of the Mac. Left to itself the engine spreads
            # over the slow cores as well, which was measured to take about twice as long.
            import onnxruntime as ort
            options = ort.SessionOptions()
            options.intra_op_num_threads = 4
            session = ort.InferenceSession(folder + "/kokoro-v1.0.onnx", sess_options=options, providers=["CPUExecutionProvider"])
            kokoro = Kokoro.from_session(session, folder + "/voices-v1.0.bin", espeak_config=espeak)
        except Exception:
            kokoro = Kokoro(folder + "/kokoro-v1.0.onnx", folder + "/voices-v1.0.bin", espeak_config=espeak)
        voices = sorted(kokoro.get_voices())
    except Exception as e:  # the tool falls back to the Mac's own voice
        print("failed\t" + str(e).replace("\n", " "), flush=True)
        return
    print("ready\t" + " ".join(voices), flush=True)
    for line in sys.stdin:
        parts = line.rstrip("\n").split("\t", 4)
        if len(parts) < 5:
            continue
        ident, voice, speed, path, text = parts
        try:
            lang = "en-gb" if voice.startswith("b") else "en-us"
            samples, rate = kokoro.create(text, voice=voice, speed=float(speed), lang=lang)
            samples = np.asarray(samples, dtype=np.float32)
            peak = float(np.max(np.abs(samples))) if len(samples) else 0.0
            if peak > 0:
                # Cut the dead air at each end, so sentences follow each other like speech, and
                # bring every sentence to the same strength so none comes out faint.
                # Soft openings such as "y", "s" and "h" are far quieter than the vowel after
                # them, so the cut is made well below their level and with room to spare.
                loud = np.nonzero(np.abs(samples) > peak * 0.006)[0]
                start = max(0, int(loud[0]) - int(rate * 0.05))
                end = min(len(samples), int(loud[-1]) + int(rate * 0.22))
                samples = samples[start:end] * (0.9 / peak)
                fade_in = min(len(samples) // 2, int(rate * 0.008))
                fade_out = min(len(samples) // 2, int(rate * 0.06))
                if fade_in > 0:
                    samples[:fade_in] *= np.linspace(0.0, 1.0, fade_in, dtype=np.float32)
                if fade_out > 0:
                    samples[-fade_out:] *= np.linspace(1.0, 0.0, fade_out, dtype=np.float32)
            pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()
            with open(path, "wb") as f:
                f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " +
                        struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm)
            print(f"{ident}\tok\t{len(samples) / rate:.3f}", flush=True)
        except Exception as e:
            print(f"{ident}\terror\t" + str(e).replace("\n", " "), flush=True)

main()
