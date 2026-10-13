# Runs the training notebook's own cells on a Linux machine with tiny amounts of data, to prove that
# every stage works before anyone spends hours on Colab. Used by .github/workflows/train-smoke.yml.
# The only changes from the real notebook: the 17 GB feature file is replaced by the small validation
# file, the music set is skipped, and cell 7 (the download button, which only exists on Colab) is left out.
import json, os, re, subprocess, sys
nb = json.load(open(os.path.join(os.path.dirname(__file__), "nova_wake_word.ipynb")))
# The surroundings Colab gives a notebook, to prove the cells cope with them.
os.environ["MPLBACKEND"] = "module://matplotlib_inline.backend_inline"
os.environ["PYTHONPATH"] = "/env/python"
os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
cells = ["".join(c["source"]) for c in nb["cells"] if c["cell_type"] == "code"]

def run(src, label):
    print(f"\n===== {label} =====", flush=True)
    src = re.sub(r"\\\n\s*", " ", src)                      # join continued shell lines
    out = []
    for line in src.split("\n"):
        if line.lstrip().startswith("!"):
            indent = line[:len(line) - len(line.lstrip())]
            out.append(f"{indent}__sh({line.lstrip()[1:]!r})")
        else:
            out.append(line)
    def sh(cmd):
        sys.stdout.flush()
        subprocess.call(cmd, shell=True, executable="/bin/bash")
    exec(compile("\n".join(out), label, "exec"), {"__sh": sh, "__name__": "__main__"})

run(cells[0], "cell 1: tools")
two = cells[1]
big = "!cd /content && wget -q --show-progress -nc https://huggingface.co/datasets/davidscripka/openwakeword_features/resolve/main/openwakeword_features_ACAV100M_2000_hrs_16bit.npy"
assert big in two, "cell 2 has changed: update ci_smoke.py"
second = "!wget -q -nc -O /content/audioset/10.parquet https://huggingface.co/datasets/agkphysics/AudioSet/resolve/main/data/bal_train/10.parquet"
assert second in two, "cell 2 has changed: update ci_smoke.py"
two = two.replace(big, "").replace(second, "").replace("big > 17 and", "True and")
run(two, "cell 2: data (reduced)")
subprocess.call("cp /content/validation_set_features.npy /content/openwakeword_features_ACAV100M_2000_hrs_16bit.npy", shell=True)
assert len(os.listdir("/content/audioset_16k")) > 100 and len(os.listdir("/content/mit_rirs")) > 100, "the reduced downloads did not arrive"
run(cells[2], "cell 3: settings")
run(cells[3], "cell 4: trial run")
ok = os.path.exists("/content/models_trial_run/trial_run.onnx")
print("\nSMOKE TEST " + ("PASSED: a model was produced" if ok else "FAILED: no model was produced"))
sys.exit(0 if ok else 1)
