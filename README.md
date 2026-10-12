# Nova

A free, open source voice assistant for the Mac. Say its name and it opens apps and works
inside them, plays music, answers questions, keeps notes and lists, and teaches piano. It is
built to be fully usable without looking at the screen.

- **Download:** `site/Nova.zip` (macOS 13 or later, Apple silicon and Intel).
- **Website:** `site/index.html`.
- **Licence:** MIT.

## What it does

- Wake word of your choice (Nova, Aria, Luna, Atlas, Orion, or your own), changeable by asking.
- Works in other apps through their own menus and buttons: "in Logic, new audio track", "click Create", "read the window".
- Music: Spotify and YouTube by voice, and "tell me about this song".
- Works with REAPER (a script bridge, every change verified) and Logic Pro (menus). More DAWs to come.
- Notes, lists, alarms, reminders, focus sessions, a daily briefing, weather, conversions.
- With a MIDI keyboard: lessons by ear, a band that plays your ideas back, a jazz course, ear training.
- Captions for everything said, large text, high contrast, one handed lessons, VoiceOver labels.
- Optional natural voices (Kokoro), downloaded on request and run on the Mac.

## Privacy

Speech recognition is done on the Mac by macOS (Nova refuses to listen if on-device recognition
is not available). Nothing is acted on unless it follows the wake word, and what is overheard is
neither shown nor saved. There is no account, server or telemetry. Network requests: the weather
(wttr.in, city name only), song and video look-ups (the words asked for), and, if you ask for it,
the natural voice download.

## Build

You need the Xcode command line tools (`xcode-select --install`).

    ./build.sh

This makes `dist/Nova.app` and `site/Nova.zip`.

## Layout

- `src/*.swift` the engine: listening rules, understanding, music, app control.
- `src/ui/NovaUI.swift` the window, the welcome screens, the menu bar icon and floating panel.
- `src/kokoro_server.py` the helper for the optional natural voices.
- `src/reaper/` the script that REAPER loads.
- `site/` the website.

## Check without making a sound

    NOVA_HOME=/tmp/nova-test dist/Nova.app/Contents/Resources/nova-engine --selftest
    NOVA_HOME=/tmp/nova-test dist/Nova.app/Contents/Resources/nova-engine --route "what can you do" "set an alarm for 7"

`NOVA_HOME` points the app at a throwaway data folder. Normally data lives in
`~/Library/Application Support/Nova`.

## Known limits

- The app is not yet notarised by Apple, so macOS asks for confirmation the first time it is opened.
- English only.
- Logic Pro control relies on Logic's English menu names.
- Spotify needs the Spotify desktop app. Finding a song uses an ordinary web search, which can occasionally fail; Nova then opens the search in Spotify instead.
- Open questions and web answers use Claude Code if it is installed and signed in. Without it, Nova says when it does not understand.

## Thanks

The natural voices are [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) (Apache 2.0), run through
[kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) (MIT). Instrument sounds are the ones built into macOS.
Spotify, YouTube, Logic Pro, REAPER and Claude belong to their owners; Nova is independent of them.
