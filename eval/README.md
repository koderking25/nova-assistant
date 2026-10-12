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
