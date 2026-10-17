// Everyday things a voice assistant on a Mac should just do.
//
//  - The Mac's own volume: "set the volume to 40", "volume up", "mute", "what's the volume".
//    (Nova's own voice is "talk louder" or "speak up".)
//  - Dark mode on or off, a screenshot to the desktop, locking the screen.
//  - Dictation: "start dictation", and everything said is typed into the app in front until "stop dictation".
//  - Piano off: "ignore the piano" and no key on the piano does anything until "piano on".

import Foundation

var pianoIgnored = FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("piano-off.txt").path)

extension Engine {
    func setPianoIgnored(_ off: Bool, say: Bool = true) {
        lock.lock(); pianoIgnored = off; lock.unlock()
        let f = baseDir.appendingPathComponent("piano-off.txt")
        if !Opt.fast { if off { try? "off".write(to: f, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: f) } }
        if off { midi.allOff() }
        ui("piano \(off ? 0 : 1)")
        if say { run { g in self.say(off ? "Piano off. I'll ignore every key until you say piano on." : "Piano on. I'm listening to your keys again.", g) } }
    }

    /// The Mac's output volume, 0 to 100, or nil if it could not be read.
    func macVolume() -> Int? {
        if Opt.fast { return 50 }
        return Int(runTool("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"], timeout: 4).out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func setMacVolume(_ v: Int) -> Bool {
        if Opt.fast { return true }
        return runTool("/usr/bin/osascript", ["-e", "set volume output volume \(max(0, min(100, v))) without output muted"], timeout: 4).ok
    }

    func usefulHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }

        // Piano off and on. ("Mute the piano track" is a DAW request, and "play piano on YouTube" is music.)
        let pianoWords = !h.has("track", "channel", "youtube", "spotify", "play", "song", "music")
        if pianoWords, h.has("ignore the piano", "piano off", "turn off the piano", "turn the piano off", "stop listening to the piano", "disable the piano", "no piano", "keys off") { setPianoIgnored(true); return "piano off" }
        if pianoWords, h.has("piano on", "turn on the piano", "turn the piano on", "listen to the piano", "enable the piano", "keys on", "use the piano again") { setPianoIgnored(false); return "piano on" }

        // Dictation.
        if h.has("start dictation", "start dictating", "dictation mode", "type what i say", "type everything i say", "take dictation", "dictate for me", "start typing for me") {
            lock.lock(); dictating = true; lock.unlock()
            ui("dictation 1")
            reply("Dictation on. Everything you say goes into \(frontApp() ?? "the app in front"). Say stop dictation when you're done."); return "dictation on"
        }
        if h.has("stop dictation", "stop dictating", "end dictation", "dictation off", "stop typing") {
            lock.lock(); dictating = false; lock.unlock()
            ui("dictation 0")
            reply("Dictation off."); return "dictation off"
        }

        // Dark mode.
        if h.has("dark mode", "light mode", "night mode") {
            let wantDark: Bool? = h.has("light mode") || h.has("off", "disable", "turn off") && h.has("dark mode") ? false : h.has("on", "enable", "turn on", "switch to", "use", "go") || h.starts("dark mode") ? true : nil
            let script = wantDark.map { "tell application \"System Events\" to tell appearance preferences to set dark mode to \($0)" } ?? "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
            run { g in
                let r = Opt.fast ? (ok: true, out: "") : runTool("/usr/bin/osascript", ["-e", script], timeout: 8)
                self.say(r.ok ? (wantDark == false ? "Light mode." : wantDark == true ? "Dark mode." : "Switched.") : LogicControl.denied(r.out) ? "I need permission to control System Events for that. macOS should have just asked: choose OK, then ask me again." : "I couldn't change that.", g)
            }
            return "dark mode"
        }

        // A screenshot of the whole screen, saved on the desktop.
        if h.has("screenshot", "screen shot", "capture the screen", "capture my screen", "picture of the screen", "picture of my screen") {
            run { g in
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let path = NSHomeDirectory() + "/Desktop/Screenshot " + f.string(from: Date()) + ".png"
                let r = Opt.fast ? (ok: true, out: "") : runTool("/usr/sbin/screencapture", ["-x", path], timeout: 10)
                let ok = Opt.fast || (r.ok && FileManager.default.fileExists(atPath: path))
                self.say(ok ? "Screenshot saved to your desktop." : "I couldn't take it. Nova needs Screen Recording, in System Settings, Privacy and Security.", g)
            }
            return "screenshot"
        }

        // Locking: the screen sleeps, and the password is asked for when it wakes.
        if h.has("lock the screen", "lock my screen", "lock the computer", "lock my computer", "lock my mac", "lock the mac", "lock screen") {
            run { g in self.say("Locking.", g); if !Opt.fast { _ = runTool("/usr/bin/pmset", ["displaysleepnow"], timeout: 4) } }
            return "lock"
        }
        return nil
    }

    /// The Mac's own volume. Asked after Spotify and the DAW have had their chance, so "turn it up" while
    /// a song plays, or "set the bass to minus 6 decibels", still go where they belong.
    func macVolumeHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        // The Mac's volume. Nova's own voice and the band have their own words, so leave those alone.
        let aboutVoice = h.words.count > 8 || h.has("decibels", "db", "track", "channel", "vocals", "drums", "guitar", "synth", "master", "spotify", "song", "metronome", "piano", "bass", "your voice", "voice louder", "voice quieter", "talk louder", "talk quieter", "speak up", "speak louder", "speak softer", "cant hear you", "too quiet", "band")
        if !aboutVoice {
            if ["unmute", "unmute it", "unmute the sound", "unmute the mac", "unmute my mac", "unmute the computer", "sound back on", "turn the sound on", "turn the sound back on", "sound on"].contains(h.text) {
                _ = runTool("/usr/bin/osascript", ["-e", "set volume without output muted"], timeout: 4); reply("Sound on."); return "unmute"
            }
            if ["mute", "mute it", "mute the sound", "mute the mac", "mute my mac", "mute the computer", "mute the volume", "sound off", "turn the sound off", "turn off the sound"].contains(h.text) {
                run { g in self.say("Muting.", g); if !Opt.fast { _ = runTool("/usr/bin/osascript", ["-e", "set volume with output muted"], timeout: 4) } }; return "mute"
            }
            if h.has("volume", "louder", "quieter", "turn it up", "turn it down", "turn up", "turn down") && !h.has("track", "spotify", "metronome") {
                if h.has("what is the volume", "whats the volume", "how loud", "volume level", "current volume") {
                    reply(macVolume().map { "The volume is at \($0) percent." } ?? "I couldn't read the volume."); return "volume?"
                }
                if let n = h.number, h.has("volume", "to", "at"), (0...100).contains(n) {
                    reply(setMacVolume(n) ? "Volume \(n)." : "I couldn't change the volume."); return "volume \(n)"
                }
                let up = h.has("up", "louder", "raise", "increase", "higher")
                let down = h.has("down", "quieter", "lower", "decrease", "softer")
                if up != down {
                    let step = h.has("a lot", "much", "way") ? 25 : h.has("a little", "a bit", "slightly", "tiny") ? 6 : 12
                    let now = macVolume() ?? 50
                    let to = max(0, min(100, now + (up ? step : -step)))
                    if setMacVolume(to) { reply(to >= 100 ? "That's as loud as it goes." : to <= 0 ? "Volume all the way down." : (up ? "Louder. " : "Quieter. ") + "\(to) percent."); return up ? "volume up" : "volume down" }
                    reply("I couldn't change the volume."); return "volume failed"
                }
            }
        }

        return nil
    }

    /// While dictating, each finished sentence is typed into the app in front. Returns true if it was taken.
    func dictate(_ text: String) -> Bool {
        lock.lock(); let on = dictating; lock.unlock()
        guard on else { return false }
        let h = Heard(text)
        if h.has("stop dictation", "stop dictating", "end dictation", "dictation off", "stop typing") { _ = usefulHear(h); return true }
        let clean = text.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return true }
        if Opt.fast { return true }
        let out = clean.prefix(1).uppercased() + clean.dropFirst() + (clean.last.map { ".?!,".contains($0) } == true ? " " : ". ")
        _ = LogicControl.osa("tell application \"System Events\" to keystroke \(LogicControl.quote(out))")
        return true
    }
}

func usefulSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let cases: [(String, String?)] = [("set the volume to 40", "volume 40"), ("turn the volume up", "volume up"), ("make it quieter", "volume down"), ("mute", "mute"),
                                      ("speak up", nil), ("band louder", nil), ("turn on dark mode", "dark mode"), ("take a screenshot", "screenshot"), ("lock my screen", "lock"),
                                      ("whats the volume", "volume?"), ("open safari", nil), ("mute the piano track", nil), ("unmute the bass", nil), ("set the lead vocals volume to minus 6 decibels", nil), ("play piano on youtube", nil), ("start dictation", "dictation on"), ("stop dictation", "dictation off")]
    let got = cases.map { engine.usefulHear(Heard($0.0)) ?? engine.macVolumeHear(Heard($0.0)) }
    let bad = zip(cases, got).filter { $0.0.1 != $0.1 }.map { "\($0.0.0) -> \($0.1 ?? "nil")" }
    check("everyday: volume, dark mode, screenshot, lock and dictation are understood, and the voice and band keep their own words", bad.isEmpty, bad.joined(separator: "; "))
    let saved = pianoIgnored
    engine.setPianoIgnored(true, say: false)
    let before = engine.mode
    engine.rawNote(keyCompose, 100); engine.rawNote(keyCompose, 0)
    let ignored = engine.mode == before
    engine.setPianoIgnored(saved, say: false)
    check("piano off: no key does anything until it is switched back on", ignored, "\(engine.mode)")
}

/// From a real session: "make me a pop song", then a "Did you mean, play me something epic?", then "Jarvis", "yes".
func didYouMeanSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    engine.goHomeQuietly(); engine.lastSpoken = ""; engine.lastSpokenAt = now() - 30
    let a = engine.loosely(Heard("make me a pop song")), b = engine.loosely(Heard("make me a sad song")), c = engine.loosely(Heard("play something chill"))
    var ran = false
    engine.pendingConfirm = { ran = true }
    engine.pendingUntil = now() + 15
    _ = engine.hear("\(Me.name)")                  // the name on its own first
    let kept = engine.pendingConfirm != nil
    let d = engine.hear("yes")
    engine.pendingConfirm = nil
    engine.lastSpoken = ""; engine.lastSpokenAt = now() - 30      // its own "Yes, sir?" is long finished
    let e = engine.hear("yes")                     // and with nothing asked
    check("asking: pop and chill are moods, the name alone keeps a question open, and a lone yes never goes to the AI",
          a == "play me something happy" && b == "play me something sad" && c == "play me something calm" && kept && d == "confirmed" && ran && e == "lone answer",
          "\(a ?? "nil") \(b ?? "nil") \(c ?? "nil") \(kept) \(d) \(ran) \(e)")
    engine.goHomeQuietly()
}
