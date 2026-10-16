// Goon mode: everything turned up.
//
// "Activate goon mode": the window goes full screen into the visualiser, a neon frame and a
// glitching title come up, the band plays a fast, heavy original piece so the screen fills with
// light, and the assistant switches to its most playful manner until goon mode is ended.
// "End goon mode" puts everything back as it was. Each sound is introduced by voice first.

import Foundation

var goonOn = false
private var goonStyleBefore: String?

extension Engine {
    func goonHear(_ h: Heard) -> String? {
        // The recogniser often writes "goon" as "lagoon" ("end goon mode" came out as "and lagoon").
        let named = h.has("goon mode", "goon", "goons mode", "gun mode", "goons", "lagoon", "lagoon mode", "the goon", "gune")
        guard named, h.words.count <= 8 else { return nil }
        let off = h.has("deactivate", "exit", "end", "stop", "turn off", "leave", "quit", "disable", "off", "cancel", "kill", "close", "no more") || (goonOn && h.starts("and"))
        if off { return goonMode(false) }
        if h.has("status", "are you in", "is goon mode") { run { g in self.say(goonOn ? "Goon mode is live." : "Goon mode is off. Say activate goon mode.", g) }; return "goon status" }
        return goonMode(true)
    }

    @discardableResult
    func goonMode(_ on: Bool) -> String {
        if on == goonOn {
            run { g in self.say(on ? "Already in goon mode. Say end goon mode to come back down." : "Goon mode is already off.", g) }
            return on ? "goon already" : "goon off already"
        }
        goonOn = on
        if on {
            goonStyleBefore = Profile.current.style
            Profile.current.style = Style.playful.rawValue        // only while it lasts: not saved
            ui("goon 1")
            ui("window visual 1")
            ui("window full 1")
            ui("flash good")
            let mood = Mood(name: "goon", minor: true, chords: [(0, true), (10, false), (8, false), (7, false), (0, true), (8, false), (3, false), (7, false)], seconds: 1.25, busy: 0.95,
                            words: [])
            let piece = invent(mood)
            let ev = events(piece.notes + bandFull(piece.notes, analyse(piece.notes)))
            ui("now Goon mode: \(piece.key)")
            run { g in
                self.say(pick(["Goon mode. Activated. Lights up, band in, here we go.", "Goon mode engaged. Hold on to something.", "Goon mode online. Turning everything up."]), g)
                guard !Opt.fast else { return }
                self.play(ev, g)
                guard self.alive(g) else { return }
                self.say(pick(["Goon mode is live. Ask me anything, or say end goon mode to come back down.", "That's goon mode. I'm staying like this until you say end goon mode."]), g)
            }
            return "goon on"
        }
        if let s = goonStyleBefore { Profile.current.style = s }
        goonStyleBefore = nil
        ui("goon 0")
        ui("window full 0")
        ui("window visual 0")
        ui("now ")
        run { g in self.say(pick(["Goon mode off. Back to normal.", "And we're back. Goon mode off."]), g) }
        return "goon off"
    }
}

func goonSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let style = Profile.current.style
    let a = engine.hear("activate goon mode")
    let wasOn = goonOn, playful = Style.current == .playful
    let wake = engine.wakeOptions(hour: 12, first: false, again: false, longGap: false)
    let b = engine.hear("deactivate goon mode")
    engine.lastSpoken = ""; engine.lastSpokenAt = now() - 30
    let c = engine.hear("goon mode off")
    let d = engine.hear("open safari")
    check("goon mode: it switches on and off by voice, is playful while on, and puts the manner back",
          a == "goon on" && wasOn && playful && wake.contains { $0.lowercased().contains("goon") || $0.contains("move") } && b == "goon off" && !goonOn && c == "goon off already" && Profile.current.style == style && d != "goon on",
          "\(a) \(wasOn) \(playful) \(b) \(c) \(d) \(wake)")
}

/// Cases from a real session's log, where overheard talk or a misheard word turned into a random action.
func realLogSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let good = [("make me a sad song", "play me something sad"), ("audition the voices please", "audition the voices"), ("put on some smooth jazz", "play smooth jazz on youtube")]
    let bad = [("do you wanna play emoji", "play me something sad"), ("if you want its not loading", "open the visualizer"), ("I auditions", "open the visualizer"), ("input a random", "new composition")]
    let g = good.map { Engine.related($0.0, $0.1) }, b = bad.map { Engine.related($0.0, $0.1) }
    check("guesses: the AI's reading is only acted on when it shares a real word with what was said", !g.contains(false) && !b.contains(true), "\(g) \(b)")
    // After it asks something, talk in the room without its name is not handed to the AI.
    engine.goHomeQuietly(); engine.lastSpoken = "Want another one?"; engine.lastSpokenAt = now() - 1
    let ears = Ears()
    ears.expectAnswer()
    let overheard = ears.partial("do you wanna play emoji", final: true, engine: engine)
    engine.goHomeQuietly(); engine.lastSpoken = ""; engine.lastSpokenAt = now() - 30
    let named = Ears()
    _ = named.partial("Jarvis", final: true, engine: engine)
    usleep(300_000)
    engine.lastSpoken = "Yes, sir?"; engine.lastSpokenAt = now() - 30
    let after = named.partial("Jarvis new composition", final: true, engine: engine)
    let composed = engine.mode == .compose
    check("ears: after it asks a question, overheard talk is let go, while a request after its name still works", overheard == "ignored" && after == "acted" && composed, "\(overheard) \(after) \(composed)")
    engine.goHomeQuietly()
    // "End goon mode", as the recogniser wrote it.
    _ = engine.goonMode(true)
    engine.lastSpoken = ""; engine.lastSpokenAt = now() - 30
    let off = engine.hear("and lagoon")
    check("goon mode: \"and lagoon\" (how \"end goon mode\" was heard) ends it", off == "goon off" && !goonOn, off)
    if goonOn { _ = engine.goonMode(false) }
    engine.goHomeQuietly()
}
