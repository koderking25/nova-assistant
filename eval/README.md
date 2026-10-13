# Wake-word evaluation

A repeatable test of how well a detector hears the assistant's name, and how often it wakes
when it should not. It needs no microphone: the recordings are made by the Mac's own voices.
That is also its limit. **No real voice or real microphone has been tested with this.**

## The test set (`gen.py`)

`python gen.py <folder> <Name>` makes 1,980 recordings:

- **The name** said eight ways by twelve voices, plus slow and fast (120 per condition).
- **Sound-alikes**: twenty words and phrases such as "No", "Now", "Know", "Novel", "Nevada", "Innovate" (240 per condition).
- **Ordinary talk**: six paragraphs full of "no", "now" and "know" (36 per condition).

Each is produced in five conditions: clean, quiet (20 dB down), pink noise (10 dB below the voice),
another voice talking underneath (8 dB below), and a small-room echo.

## What was compared (12 October 2026, Apple M1, macOS 27)

| Detector | Heard the name | False wake-ups in 59 min | CPU (one core) | Memory |
|---|---|---|---|---|
| Nova 1.2.2: Apple's recogniser, taught the name, plus text rules | 391 of 600 (65%) | 15 | not measured | not measured |
| sherpa-onnx keyword spotter, English 3.3M model, no training (`kws.py`) | 247 of 600 (41%) | 21 | 1.3% | 100 MB |
| openWakeWord, its own trained "hey jarvis" model, on a "Jarvis" set (`oww.py`) | 56 of 60 (93%) | 1 | 2.1% | 230 MB |

The third row is not a like-for-like comparison. There is no trained "Nova" model, so it shows only
what a purpose-trained detector reaches for its own phrase. Its false wake-ups were measured against
words chosen to sound like "Nova", not like "Jarvis".

By condition, Nova 1.2.2 heard the name 103/120 clean, 96 quiet, 82 in noise, 80 with echo, 30 over
another voice. A bare "Nova" was written as "Nova" 130 times, "No" 71 times and nothing 18 times.
Its false wake-ups came from "Innovate" and "Lava".

## Running it

    uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python sherpa-onnx sentencepiece numpy openwakeword
    python gen.py set-nova Nova
    python kws.py set-nova Nova 1.0 0.25 --detail        # needs the sherpa-onnx gigaspeech KWS model unpacked beside it
    python oww.py set-jarvis 0.5                         # after: python gen.py set-jarvis Jarvis

For Apple's recogniser: `open -n Nova.app --args --wake-dir <set folder> <out.txt> Nova`, then score
each condition with `nova-engine --wake-score <file> Nova`.

## Training a custom model (experimental)

`train/nova_wake_word.ipynb` is a Google Colab notebook, adapted from openWakeWord's own, that trains
"hey nova" and "nova". It needs a Linux machine with a GPU and about 20 GB of public datasets, which is
why it is not run on a Mac. It uses only synthetic speech: no personal recordings.

Open it at
https://colab.research.google.com/github/koderking25/nova-assistant/blob/main/eval/train/nova_wake_word.ipynb

Score the result on the test set with:

    python oww_custom.py set-nova 0.5 models/hey_nova.onnx models/nova.onnx

Nothing here is used by the app. The app's wake-word system is unchanged.

## Choosing a wake word (13 October 2026)

All of this is with synthetic voices and Apple's on-device recogniser. No real microphone.

**Quick test** (12 voices x 6 phrasings = 72 per name; how often the recogniser wrote the name). About 90 names were tried.
Best: Maxwell 71, Julian 71, Benjamin 70, Jarvis 70, Sebastian 69, Apollo 69, Galaxy 68, Harmony 67, Amelia 66, Meridian 66,
Watson 66, Gabriel 65, Phoenix 65. Worst: Atticus 29, Zenith 29, Atlas 29, Orion 30, Juno 32, Maestro 33, Edison 35, Kepler 36,
Vega 36, Lumina 38, Cadence 38, Sonata 39, Figaro 39, Nova 40.

**Harder test** for six finalists (`gen.py <folder> <Name> "<sound-alikes>"`, then `--wake-dir`, then `score_apple.py`): 600 recordings
of the name in five conditions, 600 of ten words chosen to sound like it, 180 of ordinary talk; name taught to the recogniser,
scored with Nova 1.2.2's rules.

| Name | Heard (of 600) | In noise (of 120) | Over another voice (of 120) | Woke on its sound-alikes (of 600) | Woke in ordinary talk (of 180) |
|---|---|---|---|---|---|
| Sebastian | 511 (85%) | 109 | 81 | 51 ("Bastion", "Sebastopol") | 0 |
| Jarvis (with its extra sound-alike rules) | 538 (90%) | 112 | 80 | 224 ("Service", "Travis", "Nervous", "Harvest") | 0 |
| Julian | 507 (84%) | 112 | 56 | 285 ("Julia", "Julie", "Jillian") | 0 |
| Maxwell | 506 (84%) | 90 | 80 | 96 ("Max will", "Makes well") | 0 |
| Meridian | 476 (79%) | 101 | 48 | 19 | 0 |
| Harmony | 425 (71%) | 96 | 52 | 83 ("Hominy"; heard as "How many") | 0 |
| Apollo | 403 (67%) | 73 | 36 | 117 ("A polo", "Hello") | 0 |
| Nova (its own sound-alike list) | 391 (65%) | 82 | 30 | 15 of 1,200 | 1 |

Guidance from wake-word makers agrees with what was measured: at least six distinct sounds, three or more syllables, and a word
that is rare in conversation ([Picovoice](https://picovoice.ai/docs/tips/choosing-a-wake-word/)).

**Brand-style names, quick test (13 October, of 72):** Veronica 72, Genesis 71, Roxanne 70, Kassandra 70, Alexis 66, Arcadia 65,
Zodiac 62, Lennox 60, Pixel 60, Valencia 60, Avalon 56, Solara 54, Geneva 53, Quantum 53, Matrix 52, Felix 50, Vortex 49,
Indigo 49, Sapphire 49, Sienna 49, Calista 49, Seraphina 49, Dexter 48, Nexus 47, Ophelia 47, Olympia 45, Helix 37, Moxie 37,
Vesper 35, Odyssey 31. Words with an "x" did not do well with Apple's recogniser, whatever is said about "Alexa".
