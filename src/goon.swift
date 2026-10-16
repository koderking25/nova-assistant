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
        let named = h.has("goon mode", "goon", "goons mode", "gun mode")
        guard named, h.words.count <= 8 else { return nil }
        let off = h.has("deactivate", "exit", "end", "stop", "turn off", "leave", "quit", "disable", "off", "cancel", "kill", "close", "no more")
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
