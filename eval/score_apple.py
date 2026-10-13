# Scores what Apple's recogniser wrote for a test set, using Nova's own wake rules (nova-engine --wake-score).
import subprocess, collections, os, re, sys, glob
S = os.path.dirname(os.path.abspath(__file__)); E = sys.argv[1]
env = dict(os.environ, NOVA_HOME=S + "/scorehome")
C = ["clean", "quiet", "noise", "babble", "echo"]
for name in sys.argv[2:]:
    path = S + "/apple-" + name + ".txt"
    if not os.path.exists(path): continue
    groups = collections.defaultdict(list)
    for line in open(path):
        if line.startswith("plain |"): groups[line.split("|")[1].strip()].append(line.rstrip("\n"))
    res = {}
    for k, lines in groups.items():
        f = S + "/grp.txt"; open(f, "w").write("\n".join(lines) + "\n")
        out = subprocess.run([E, "--wake-score", f, name], capture_output=True, text=True, env=env).stdout.strip().split("\n")[-1]
        m = re.search(r"answered (\d+) of (\d+)", out); res[k] = (int(m.group(1)), int(m.group(2)))
    tp = sum(res["pos/" + c][0] for c in C); tn = sum(res["pos/" + c][1] for c in C)
    fs = sum(res["sim/" + c][0] for c in C); ns = sum(res["sim/" + c][1] for c in C)
    ft = sum(res["talk/" + c][0] for c in C); nt = sum(res["talk/" + c][1] for c in C)
    bare = collections.Counter(l.split(" -> ")[1] for k, ls in groups.items() if k.startswith("pos") for l in ls if l.split("|")[3].split(" -> ")[0].strip().strip("?") == name)
    nb = sum(bare.values()); ok = sum(v for t, v in bare.items() if name.lower() in t.lower())
    woke = collections.Counter(l.split("|")[3].split(" -> ")[0].strip()[:22] for k, ls in groups.items() if not k.startswith("pos") for l in ls if name.lower() in l.split(" -> ")[1].lower())
    print(f"{name:10} heard {tp}/{tn} ({tp / tn * 100:.0f}%) | by condition " + " ".join(f"{c} {res['pos/' + c][0]}" for c in C) + f" (each of {res['pos/clean'][1]})")
    print(f"{'':10} bare name written correctly {ok}/{nb} | woke on its sound-alikes {fs}/{ns} | woke during ordinary talk {ft}/{nt}")
    print(f"{'':10} sound-alikes that woke it: {woke.most_common(5)} | bare name misheard as: {[(t, v) for t, v in bare.most_common(6) if name.lower() not in t.lower()][:4]}")
