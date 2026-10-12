// Help: spoken help for the current mode, the list printed in the Terminal window,
// and a large-print page of every command.

import Foundation

func keyLabel(_ key: Int) -> String { "\(sharpNames[key % 12].replacingOccurrences(of: " sharp", with: "#"))\(key / 12 - 1)" }

// What each of the eight buttons does, in a lesson and in composition mode.
let buttonRows: [(lesson: String, compose: String)] = [
    ("Start the lesson, or hear the part again. Hold it for the song menu", "Play it back as a band. Twice quickly: type a name for it"),
    ("Say the notes of the part", "Say what you wrote"),
    ("Skip ahead (past the end: next song)", "Play the next variation"),
    ("Go back (before the start: previous song)", "Save it as a MIDI file"),
    ("Talk mode on or off", "Learn: a new composing idea, played for you"),
    ("Pause, and carry on", "Stop the sound"),
    ("New composition, from anywhere", "New composition. Twice quickly: leave composition mode"),
    ("Help: says these buttons aloud", "Help: says these buttons aloud"),
]

let computerRows: [(String, String)] = [
    ("Space", "Start the lesson, or hear the part again"),
    ("N", "Say the notes"),
    ("Right arrow", "Skip ahead"),
    ("Left arrow", "Go back"),
    ("T", "Talk mode on or off"),
    ("Return", "Pause, and carry on"),
    ("C", "New composition. Twice quickly: leave composition mode"),
    ("H", "Spoken help"),
    ("Slash", "Open the large-print list of commands"),
    ("0 (zero)", "Home: leave any mode"),
    ("A", "Ask the AI anything, by typing"),
    ("G", "Logic control"),
    ("R", "REAPER control"),
    ("M", "Song menu"),
    ("J", "Jazz course, at the lesson you are on"),
    ("L", "List the songs"),
    ("1 to 9", "Pick one of the first nine songs"),
    ("Minus, Equals", "Slower or faster demo"),
    ("Left and right square bracket", "Band quieter or louder"),
    ("V", "Change the voice"),
    ("Comma, Full stop", "Voice quieter or louder"),
    ("S", "Keep what you just played (same as the lowest piano key)"),
    ("P", "Also play demos through the piano's own speakers"),
    ("Shift and K", "Set the top key again"),
    ("Q", "Quit"),
]

extension Engine {
    var buttonKeys: [Int] { [keyHear, keyNotes, keyNext, keyBack, keyTalk, keyPause, keyCompose, keyHelp] }

    // Short, and only about the mode the player is in.
    func helpText() -> String {
        let count = "Counting white keys down from the top. "
        switch mode {
        case .compose:
            return "Composition mode. Just play, then use the buttons. " + count + "One, play it back as a band. One twice quickly, name the piece by typing. Two, say what you wrote. Two twice quickly, ask the AI what it thinks. Three, next variation. Four, save. Five, learn a new composing idea. Six, stop the sound. Seven, start a new composition. Eight, this help. The second lowest white key on the piano is home: it leaves this mode."
        case .teach:
            return "Lesson. " + count + "One, hear the part again. Two, say the notes. Three, skip ahead. Four, go back. Five, talk mode. Six, pause. Seven, new composition. Eight, this help."
        case .talk:
            return "Talk mode. Middle C, D, E, F and G each say a sentence. " + count + "One starts a lesson. Five leaves talk mode. Seven is composition mode. Eight, this help."
        case .reaper:
            return "REAPER control. " + count + "Three and four step through the list. One chooses the item you heard. Two goes back a level. Start at Transport, Tracks, or New track. The second lowest white key is home."
        case .logic:
            return "Logic control. " + count + "Three and four step through the commands. One does the command you heard. Two goes back a level. The last item in the list opens every menu in Logic. The second lowest white key is home."
        case .jazz:
            return "Jazz mode. " + count + "One, play with the band again. Two, hear the lesson's idea again. Three, next lesson. Four, previous lesson. Six, stop the band. Seven, new composition. Eight, this help."
        case .menu:
            return "Song menu. Five octaves, starting two octaves below middle C. The lowest is easy and each octave up is harder. Press a key to hear a song, and press it again to learn it. The octave below the easy songs is the jazz course. " + count + "One starts the song you just heard. Two counts the songs. Three and four step through the songs one at a time. Eight, this help."
        case .idle:
            return "Home. Keys three and four step through everything I can do, and key one opens it. " + count + "The very lowest key of the piano keeps what you just played, and the white key next to it is home, which leaves any mode. One starts a lesson. Hold it down for the song menu. Five is talk mode. Seven is composition mode. Eight is this help, and it changes to match what you are doing."
        }
    }

    func sheetText() -> String {
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        var lines = ["TALKING PIANO", "", "PIANO BUTTONS  (the eight highest white keys, counted down from the top)", ""]
        lines.append("  " + pad("Key", 9) + pad("In a lesson", 70) + "In composition mode")
        for (i, row) in buttonRows.enumerated() {
            lines.append("  " + pad("\(i + 1)  \(keyLabel(buttonKeys[i]))", 9) + pad(row.lesson, 70) + row.compose)
        }
        if keyHome >= 0 { lines += ["", "  Second lowest white key (\(keyLabel(keyHome))): home. Leaves any mode and goes back to the start."] }
        if keyKeep >= 0 { lines += ["", "  Lowest key of the piano (\(keyLabel(keyKeep))): keep what you just played. No need to press record first."] }
        lines += ["", "COMPUTER KEYS  (this window must be in front)", ""]
        for row in computerRows { lines.append("  " + pad(row.0, 32) + row.1) }
        lines += ["", "SONGS", ""]
        lines.append("  Hold the top key (or press M) for the song menu, then press a song's key twice.")
        lines += ["", "  JAZZ COURSE"]
        for (i, l) in jazzLessons.enumerated() { lines.append("    " + pad(keyLabel(jazzMenuKeys[i]), 6) + "Lesson \(i + 1): \(l.title)") }
        for level in 1...5 where songs.contains(where: { $0.level == level }) {
            lines += ["", "  " + levelNames[level - 1].uppercased()]
            for (i, s) in songs.enumerated() where s.level == level {
                lines.append("    " + pad(menuKey(forSong: i).map { keyLabel($0) } ?? "", 6) + s.name)
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    func writeSheetHTML() -> URL {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        var h = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Nova commands</title>
        <style>
        body{background:#0d1117;color:#f0f3f6;font:22px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:32px;max-width:1100px}
        h1{font-size:40px;margin:0 0 8px}h2{font-size:28px;margin:40px 0 12px;color:#7ee0c3}
        p{color:#c9d1d9;margin:0 0 16px}
        table{border-collapse:collapse;width:100%}
        th,td{text-align:left;padding:12px 16px;border-bottom:1px solid #30363d;vertical-align:top}
        th{color:#7ee0c3;font-size:18px}
        td:first-child{font-weight:700;white-space:nowrap;color:#ffd866}
        </style></head><body>
        <h1>Nova commands</h1>
        <p>Press the eighth white key from the top of the piano at any time to hear the buttons for what you are doing.</p>
        <h2>Piano buttons</h2>
        <p>The eight highest white keys, counted down from the top key.</p>
        <table><tr><th scope="col">Key</th><th scope="col">In a lesson</th><th scope="col">In composition mode</th></tr>
        """
        for (i, row) in buttonRows.enumerated() {
            h += "<tr><td>\(i + 1). \(esc(keyLabel(buttonKeys[i])))</td><td>\(esc(row.lesson))</td><td>\(esc(row.compose))</td></tr>\n"
        }
        h += "</table><h2>Home</h2><p>The second lowest white key of the piano leaves whatever mode you are in and goes back to the start. An unsaved composition is saved first.</p>"
        h += "<h2>Keep that</h2><p>The very lowest key of the piano keeps what you just played, from any mode. Everything is always being recorded, so there is no need to press record first.</p>"
        h += "<h2>Talk mode</h2><p>Middle C, D, E, F and G each make the instrument say a sentence.</p>"
        h += "<h2>Computer keys</h2><p>The Terminal window must be in front.</p><table><tr><th scope=\"col\">Key</th><th scope=\"col\">What it does</th></tr>\n"
        for row in computerRows { h += "<tr><td>\(esc(row.0))</td><td>\(esc(row.1))</td></tr>\n" }
        h += "</table><h2>Songs</h2><p>Hold the top key for the song menu. Each song has its own key. Press it once to hear the song, and again to learn it. Low octaves are easy and high octaves are hard.</p>"
        h += "<table><tr><th scope=\"col\">Key</th><th scope=\"col\">Song</th><th scope=\"col\">Level</th></tr>\n"
        for (i, s) in songs.enumerated() {
            h += "<tr><td>\(esc(menuKey(forSong: i).map { keyLabel($0) } ?? ""))</td><td>\(esc(s.name))</td><td>\(levelNames[s.level - 1])</td></tr>\n"
        }
        h += "</table></body></html>\n"
        let url = baseDir.appendingPathComponent("commands.html")
        try? h.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func openSheet() {
        let url = writeSheetHTML()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.path]
        try? p.run()
        run { g in self.say("Opened the list of commands.", g) }
    }

    // Plays the other hand's notes that belong to the step just played, at the player's own pace.
    func accompanyStep(_ i: Int) {
        guard !Opt.fast, !accompany.isEmpty, let l = lesson, curSteps.indices.contains(i) else { return }
        let from = curSteps[i].beat
        let to = i + 1 < curSteps.count ? curSteps[i + 1].beat : .infinity
        let nominal = 60 / l.song.bpm / tempo
        var secPerBeat = nominal
        if i > 0, stepTimes.count >= 2 {
            let beats = curSteps[i].beat - curSteps[i - 1].beat
            let secs = stepTimes[stepTimes.count - 1] - stepTimes[stepTimes.count - 2]
            if beats > 0.01 { secPerBeat = max(nominal * 0.5, min(nominal * 2.5, secs / beats)) }
        }
        let g = accGen
        for n in accompany where n.beat >= from - 0.02 && n.beat < to - 0.02 {
            let delay = max(0, (n.beat - from) * secPerBeat)
            let dur = max(0.12, min(n.dur, 4) * secPerBeat * 0.95)
            let p = UInt8(max(0, min(127, n.pitch)))
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) {
                guard self.accGen == g else { return }
                self.midi.send([0x90, p, 62])
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + dur) { self.midi.send([0x80, p, 0]) }
            }
        }
    }
}
