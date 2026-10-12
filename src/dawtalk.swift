// The DAW assistant's language: what a sentence about a project means.
//
// A sentence is read against the real state of the project and becomes one of four things:
// a fact to say, a short question when it is ambiguous, one operation, or a plan of several
// steps that is explained before it runs. Nothing here changes the project; that is daw.swift.

import Foundation

struct PlanStep { let what: String; let op: (DawState) -> DawOp? }

enum DawAsk {
    case say(String)
    case question(String)
    case op(DawOp, confirm: String?)
    case plan(explain: String, steps: [PlanStep])
}

enum TrackPick { case one(DawTrack), many([DawTrack]), none }

let fxKinds: [(words: [String], inName: [String], stock: String, called: String)] = [
    (["compressor", "compressors", "compression", "compress", "comp"], ["comp", "1176", "la-2a", "la2a"], "ReaComp", "compressor"),
    (["eq", "equalizer", "equaliser", "equalization", "eqs"], ["eq", "pultec"], "ReaEQ", "EQ"),
    (["reverb", "reverbs", "verb"], ["verb", "room", "hall", "plate"], "ReaVerbate", "reverb"),
    (["delay", "delays", "echo"], ["delay", "echo"], "ReaDelay", "delay"),
    (["limiter", "limiters"], ["limit"], "ReaLimit", "limiter"),
    (["gate", "noise gate"], ["gate"], "ReaGate", "gate"),
    (["tuner", "autotune", "auto tune", "pitch correction"], ["tune"], "ReaTune", "tuner"),
]

func stem(_ w: String) -> String { w.count > 3 && w.hasSuffix("s") ? String(w.dropLast()) : w }

extension Daw {
    // MARK: Finding what the sentence points at

    /// The track a phrase names. "This", "it" and silence mean the selected track, then the last one touched.
    func pick(_ words: [String], _ s: DawState, allowDefault: Bool = true) -> TrackPick {
        let stems = words.map(stem)
        if words.contains("master") || (words.contains("main") && words.contains("output")) { return .one(s.master) }
        for marker in ["track", "channel", "number"] {
            if let i = words.firstIndex(of: marker), i + 1 < words.count, let n = Int(words[i + 1]) ?? numberWords[words[i + 1]], let t = s.track(n), n >= 1 { return .one(t) }
        }
        let generic: Set<String> = ["track", "bus", "the", "a", "my", "of", "and"]
        var scored: [(DawTrack, Int, Bool)] = []
        for t in s.tracks {
            let tokens = Heard(t.name).words.map(stem).filter { !generic.contains($0) }
            guard !tokens.isEmpty else { continue }
            let hits = tokens.filter { stems.contains($0) }.count
            if hits > 0 { scored.append((t, hits, hits == tokens.count)) }
        }
        if !scored.isEmpty {
            // A track whose whole name was said wins; otherwise the most words in common.
            let whole = scored.filter { $0.2 }
            let pool = whole.isEmpty ? scored : whole
            let top = pool.map { $0.1 }.max()!
            let best = pool.filter { $0.1 == top }.map { $0.0 }
            return best.count == 1 ? .one(best[0]) : .many(best)
        }
        guard allowDefault else { return .none }
        if let t = s.tracks.first(where: { $0.selected }) { return .one(t) }
        if let l = lastTrack, let t = s.track(l) { return .one(t) }
        return .none
    }

    func which(_ many: [DawTrack]) -> DawAsk { .question("I found \(many.map { $0.name }.joined(separator: " and ")). Which one?") }

    /// The plug-in on a track that the sentence means.
    func pickFx(_ h: Heard, on t: DawTrack) -> Int? {
        for kind in fxKinds where kind.words.contains(where: { h.has($0) }) {
            if let i = t.fx.firstIndex(where: { n in kind.inName.contains { n.lowercased().contains($0) } }) { return i + 1 }
        }
        for (i, n) in t.fx.enumerated() {
            let tokens = Heard(n).words.filter { $0.count > 2 }
            if !tokens.isEmpty, tokens.allSatisfy({ h.words.contains($0) }) { return i + 1 }
        }
        if let l = lastFx, l.track == t.index, l.fx <= t.fx.count { return l.fx }
        return t.fx.count == 1 ? 1 : nil
    }

    /// The setting of a plug-in that the sentence means.
    func pickParam(_ h: Heard, _ list: [Param], allowLast: Bool = false) -> Param? {
        let named: [(say: [String], inName: String)] = [
            (["threshold"], "thresh"), (["ratio"], "ratio"), (["attack"], "attack"), (["release"], "release"), (["knee"], "knee"),
            (["wet", "wetter", "wetness"], "wet"), (["dry", "drier"], "dry"), (["room size", "size", "bigger", "smaller", "roomier"], "size"),
            (["dampening", "damping"], "damp"), (["width", "wider", "narrower"], "width"), (["low pass", "lowpass"], "lowpass"),
            (["high pass", "highpass", "hipass"], "hipass"), (["feedback"], "feedback"), (["ceiling"], "ceil"), (["mix"], "mix"), (["gain", "output"], "gain"),
        ]
        // Bands of an equaliser, by where they sit: "low mids" is the band nearest 350 hertz.
        let bands: [(say: [String], hz: Double)] = [
            (["low mids", "low mid", "lower mids", "mud", "boxiness"], 350), (["high mids", "high mid", "upper mids", "presence"], 3000),
            (["lows", "low end", "bass", "low shelf", "bottom"], 100), (["highs", "high end", "treble", "air", "high shelf", "top end", "brightness"], 10000),
            (["mids", "midrange", "middle"], 1000),
        ]
        for b in bands where b.say.contains(where: { h.has($0) }) {
            var best: (Param, Double)? = nil
            for p in list where p.name.lowercased().hasPrefix("gain") {
                let partner = p.name.replacingOccurrences(of: "Gain", with: "Freq")
                guard let f = list.first(where: { $0.name == partner }), let hz = Double(f.shown) else { continue }
                let far = abs(log(hz / b.hz))
                if best == nil || far < best!.1 { best = (p, far) }
            }
            if let found = best { return found.0 }
        }
        for n in named where n.say.contains(where: { h.has($0) }) {
            if let p = list.first(where: { $0.name.lowercased().contains(n.inName) }) { return p }
        }
        if allowLast, let l = lastParam { return list.first { $0.index == l } }
        return nil
    }

    // MARK: Reading a sentence

    func understand(_ h: Heard, _ s: DawState) -> DawAsk? {
        // Words after "to", "on" and so on point at the target; the rest describe the action.
        func target(_ after: String..., fallbackWhole: Bool = true, allowDefault: Bool = true) -> TrackPick {
            for m in after { if let rest = h.after(m) { let p = pick(rest.split(separator: " ").map(String.init), s, allowDefault: false); if case .none = p {} else { return p } } }
            return fallbackWhole ? pick(h.words, s, allowDefault: allowDefault) : (allowDefault ? pick([], s) : .none)
        }
        // For requests about a plug-in: the named track, else where the last plug-in was, else one that has such a plug-in.
        func fxTrack(_ after: String...) -> TrackPick {
            for m in after { if let rest = h.after(m) { let p = pick(rest.split(separator: " ").map(String.init), s, allowDefault: false); if case .none = p {} else { return p } } }
            if let kind = fxKinds.first(where: { k in k.words.contains { h.has($0) } }) {
                let named = pick(h.words.filter { w in !kind.words.contains(w) }, s, allowDefault: false)
                if case .one = named { return named }
                func hasIt(_ t: DawTrack) -> Bool { t.fx.contains { n in kind.inName.contains { n.lowercased().contains($0) } } }
                if let l = lastFx, let t = s.track(l.track), hasIt(t) { return .one(t) }
                if let l = lastTrack, let t = s.track(l), hasIt(t) { return .one(t) }   // the track just being talked about
                if let sel = s.tracks.first(where: { $0.selected }), hasIt(sel) { return .one(sel) }
                let owners = ([s.master] + s.tracks).filter(hasIt)
                if owners.count == 1 { return .one(owners[0]) }
                if owners.count > 1 { return .many(owners) }
            }
            if let l = lastFx, let t = s.track(l.track) { return .one(t) }
            return pick([], s)
        }
        let noTrack = DawAsk.question("Which track? The project has \(s.tracks.map { $0.name }.joined(separator: ", ")).")
        func withTrack(_ p: TrackPick, _ make: (DawTrack) -> DawAsk?) -> DawAsk? {
            switch p {
            case .one(let t): return make(t)
            case .many(let m): return which(m)
            case .none: return s.tracks.isEmpty ? .say("This project has no tracks yet. Say new track to make one.") : noTrack
            }
        }
        let amount = h.has("a little", "slightly", "a bit", "a touch", "a tad", "little") ? 0.03 : h.has("a lot", "much", "way", "loads") ? 0.12 : 0.06
        let up = h.has("raise", "increase", "more", "up", "higher", "boost", "louder", "longer", "bigger", "wetter", "wider", "brighter", "add")
        let down = h.has("lower", "decrease", "less", "down", "reduce", "cut", "quieter", "shorter", "smaller", "drier", "narrower", "darker", "soften")
        func number(after markers: String...) -> Double? {
            for m in markers {
                guard let rest = h.after(m) else { continue }
                let w = rest.split(separator: " ").map(String.init)
                var sign = 1.0
                for (i, x) in w.enumerated().prefix(4) {
                    if x == "minus" || x == "negative" { sign = -1; continue }
                    if let n = Double(x) ?? numberWords[x].map(Double.init) { _ = i; return sign * n }
                }
            }
            return nil
        }

        // What happened, and taking it back.
        if h.has("what did you change", "what did you do", "what just happened", "recent changes", "what have you changed", "read my changes", "what changed") {
            let recent = history.suffix(5).map { $0.what }
            return .say(recent.isEmpty ? "I have not changed anything in this project yet." : "Most recent last: " + recent.joined(separator: ". ") + ". Say undo to take back the last one.")
        }
        if h.has("undo") { return .op(.undo, confirm: nil) }
        if h.has("redo") { return .op(.redo, confirm: nil) }

        // Questions about the project. These only read.
        if h.has("how many tracks"), s.tracks.isEmpty { return .say("There are no tracks yet. Say new track to make one.") }
        if h.has("how many tracks") { return .say("\(s.tracks.count) track\(s.tracks.count == 1 ? "" : "s"): \(s.tracks.map { $0.name }.joined(separator: ", ")).") }
        if h.has("list the tracks", "list tracks", "list all tracks", "what tracks", "which tracks are there", "read the tracks", "all the tracks") && !h.has("muted", "soloed", "armed", "have", "with") {
            return .say(s.tracks.isEmpty ? "There are no tracks yet." : s.tracks.map { "\($0.index), \($0.name)" + ($0.mute ? ", muted" : "") + ($0.solo ? ", soloed" : "") + ($0.arm ? ", armed" : "") }.joined(separator: ". ") + ".")
        }
        for (word, test) in [("muted", { (t: DawTrack) in t.mute }), ("soloed", { $0.solo }), ("armed", { $0.arm })] as [(String, (DawTrack) -> Bool)] where h.has("which", "what", "any", "are any", "list") && h.has(word) {
            let hit = s.tracks.filter(test).map { $0.name }
            return .say(hit.isEmpty ? "No track is \(word)." : "\(hit.joined(separator: ", ")) \(hit.count == 1 ? "is" : "are") \(word).")
        }
        if h.has("which", "what tracks", "show me all", "show me the", "list all the", "where are the", "find all"), let kind = fxKinds.first(where: { k in k.words.contains { h.has($0) } }), !h.has("add", "put") {
            let hit = ([s.master] + s.tracks).filter { t in t.fx.contains { n in kind.inName.contains { n.lowercased().contains($0) } } }
            return .say(hit.isEmpty ? "No track has a \(kind.called)." : hit.map { t in "\(t.name) has " + t.fx.filter { n in kind.inName.contains { n.lowercased().contains($0) } }.joined(separator: " and ") }.joined(separator: ". ") + ".")
        }
        if h.has("what is selected", "whats selected", "where am i", "what track am i on", "which track am i on", "what am i on", "current track") {
            guard let t = s.tracks.first(where: { $0.selected }) else { return .say("No track is selected. \(s.transport.capitalizedFirst), at \(s.position.lowercased()).") }
            return .say(t.described(detailed: false) + " \(s.transport.capitalizedFirst), at \(s.position.lowercased()).")
        }
        if h.has("what can i do", "what can you do here", "what are my options", "what can i say") {
            return .say("In \(adapter.name) I can find and describe tracks, change volume, pan, mute, solo and record arm, rename, duplicate, move and delete tracks, add, remove and bypass plug-ins, read and change their settings and presets, make sends and buses, run the transport, and undo. Ask me what I changed at any time.")
        }
        if h.has("before exporting", "before i export", "ready to export", "check the project", "anything wrong", "troubleshoot", "why cant i hear", "why is it silent", "no sound") {
            var notes: [String] = []
            let muted = s.tracks.filter { $0.mute }.map { $0.name }, soloed = s.tracks.filter { $0.solo }.map { $0.name }, armed = s.tracks.filter { $0.arm }.map { $0.name }
            if !soloed.isEmpty { notes.append("\(soloed.joined(separator: ", ")) \(soloed.count == 1 ? "is" : "are") soloed, so nothing else will be heard") }
            if !muted.isEmpty { notes.append("\(muted.joined(separator: ", ")) \(muted.count == 1 ? "is" : "are") muted") }
            if s.master.mute { notes.append("the master is muted") }
            if s.master.volDB < -40 { notes.append("the master is turned almost all the way down") }
            if !armed.isEmpty { notes.append("\(armed.joined(separator: ", ")) \(armed.count == 1 ? "is" : "are") still armed for recording") }
            for t in [s.master] + s.tracks { for (n, on) in zip(t.fx, t.fxOn) where !on { notes.append("\(n) on \(t.name) is bypassed") } }
            let empty = s.tracks.filter { $0.items == 0 && $0.sends.isEmpty && !$0.fx.contains { $0.lowercased().contains("verb") || $0.lowercased().contains("delay") } }.map { $0.name }
            if !empty.isEmpty { notes.append("\(empty.joined(separator: ", ")) \(empty.count == 1 ? "has" : "have") nothing recorded") }
            return .say(notes.isEmpty ? "I checked mutes, solos, record arms, bypassed plug-ins and the master. Nothing looks wrong. I have not measured the sound itself." : "Here is what I can see: " + notes.joined(separator: "; ") + ". I have not measured the sound itself.")
        }
        if h.has("what plugins", "which plugins", "what plug ins", "what effects", "which effects", "plugins are on", "effects are on", "list the plugins", "list plugins", "whats on", "what is on") {
            return withTrack(target("on", "in")) { t in
                self.lastTrack = t.index
                return .say(t.fx.isEmpty ? "\(t.name) has no plug-ins." : "\(t.name) has \(zip(t.fx, t.fxOn).enumerated().map { "\($0.offset + 1), \($0.element.0)" + ($0.element.1 ? "" : ", bypassed") }.joined(separator: ". "))." + (t.sends.isEmpty ? "" : " It sends to \(t.sends.map { $0.to }.joined(separator: " and "))."))
            }
        }
        if h.has("settings", "parameters", "current settings", "what is the", "what are the", "read the", "tell me its", "how is the") && (fxKinds.contains { k in k.words.contains { h.has($0) } } || h.has("settings", "parameters", "its")) {
            return withTrack(fxTrack("on the", "on my", "on", "of the", "in the")) { t in
                guard let f = self.pickFx(h, on: t) else { return .say(t.fx.isEmpty ? "\(t.name) has no plug-ins." : "Which plug-in? \(t.name) has \(t.fx.joined(separator: ", ")).") }
                let list = self.params(t.index, f)
                self.lastTrack = t.index; self.lastFx = (t.index, f)
                if let p = self.pickParam(h, list) {
                    return .say("\(p.name) on \(t.fx[f - 1]) is \(p.shown).")
                }
                let main = list.filter { !["resvd", "signin", "audin", "bypass", "delta", "filter preview"].contains($0.name.lowercased()) }.prefix(6)
                return .say(main.isEmpty ? "\(t.fx[f - 1]) does not show its settings to \(self.adapter.name)." : "\(t.fx[f - 1]) on \(t.name): " + main.map { "\($0.name) \($0.shown)" }.joined(separator: ", ") + (list.count > 6 ? ". It has \(list.count) settings in all." : "."))
            }
        }
        if h.has("tell me about", "describe", "inspect", "status of", "how is", "read me") {
            let named = pick(h.words, s, allowDefault: h.has("track", "channel", "selected"))
            if case .none = named {} else { return withTrack(named) { t in self.lastTrack = t.index; return .say(t.described(detailed: true)) } }
        }

        // Autonomy.
        if h.has("guided mode", "assisted mode", "autonomous mode") { return nil }

        // Workflows: several steps, explained first.
        if (h.has("vocal", "vocals", "voice") && h.has("prepare", "clean up", "mix", "process", "chain", "set up", "ready")) && h.has("help", "prepare", "for mixing", "chain", "set up", "clean up") {
            return withTrack(pick(h.words, s)) { t in
                var steps: [PlanStep] = [], saying: [String] = [], has: [String] = []
                func present(_ kind: String) -> Bool { let k = fxKinds.first { $0.called == kind }!; return t.fx.contains { n in k.inName.contains { n.lowercased().contains($0) } } }
                if present("EQ") { has.append("an EQ") } else { saying.append("add an EQ, left flat for you to shape"); steps.append(PlanStep(what: "EQ") { _ in .fxAdd(track: t.index, fx: "ReaEQ") }) }
                if present("compressor") { has.append("a compressor") } else { saying.append("add a compressor after it, at its default setting"); steps.append(PlanStep(what: "compressor") { _ in .fxAdd(track: t.index, fx: "ReaComp") }) }
                let bus = s.tracks.first { $0.name.lowercased().contains("reverb") || $0.name.lowercased().contains("verb") }
                if t.sends.contains(where: { $0.to.lowercased().contains("verb") }) { has.append("a reverb send") }
                else {
                    if bus == nil {
                        saying.append("make a reverb bus")
                        steps.append(PlanStep(what: "reverb bus") { _ in .newTrack(instrument: false, name: "Reverb Bus", fx: "ReaVerbate") })
                    }
                    saying.append("send the vocal to the reverb bus, quietly, at minus 15 decibels")
                    steps.append(PlanStep(what: "send") { now in
                        guard let b = now.tracks.first(where: { $0.name.lowercased().contains("verb") }), let v = now.tracks.first(where: { $0.name == t.name }) else { return nil }
                        return .send(from: v.index, to: b.index, db: -15)
                    })
                }
                if steps.isEmpty { return .say("\(t.name) already has \(has.joined(separator: ", ")). I would not add more. Ask me for its settings if you want to adjust them.") }
                return .plan(explain: "For \(t.name)" + (has.isEmpty ? "" : ", which already has \(has.joined(separator: " and "))") + ", I would \(saying.joined(separator: ", then ")). These are starting points, not a finished vocal sound.", steps: steps)
            }
        }
        if h.has("master", "mastering") && h.has("help", "chain", "master my", "master the", "master this", "could you master", "can you master", "starting") && !h.has("volume", "mute", "what") {
            let limiter = s.master.fx.contains { $0.lowercased().contains("limit") }
            if limiter { return .say("The master already has \(s.master.fx.joined(separator: ", ")). I can read their settings or measure the level while it plays, but judging a master needs your ears.") }
            return .plan(explain: "I cannot master a song by myself, and nobody should claim to with one plug-in. What I can do is put a limiter last on the master so nothing clips, then read you the level while it plays." + (s.master.fx.isEmpty ? "" : " The master already has \(s.master.fx.joined(separator: ", ")).") + " Everything else needs your ears.",
                         steps: [PlanStep(what: "limiter") { _ in .fxAdd(track: 0, fx: "ReaLimit") }])
        }
        if h.has("reverb", "delay") && h.has("bus", "send", "a little", "some", "a bit of", "a touch of") && !h.has("remove", "bypass", "settings") {
            let kind = h.has("delay") && !h.has("reverb") ? "delay" : "reverb"
            let busName = kind == "reverb" ? "Reverb Bus" : "Delay Bus"
            let source = Heard(h.text.replacingOccurrences(of: "reverb", with: "").replacingOccurrences(of: "delay", with: "").replacingOccurrences(of: " bus", with: ""))
            return withTrack(pick(source.words, s)) { t in
                let bus = s.tracks.first { $0.name.lowercased().contains(kind == "reverb" ? "verb" : "delay") && $0.index != t.index }
                let level = h.has("a little", "a touch", "a bit", "slightly") ? -18.0 : -12.0
                if let b = bus { return .op(.send(from: t.index, to: b.index, db: level), confirm: nil) }
                return .plan(explain: "There is no \(kind) bus yet. I would make a track called \(busName) with a \(kind) on it, and send \(t.name) to it at \(spokenDB(level)).",
                             steps: [PlanStep(what: "bus") { _ in .newTrack(instrument: false, name: busName, fx: kind == "reverb" ? "ReaVerbate" : "ReaDelay") },
                                     PlanStep(what: "send") { now in
                                         guard let b = now.tracks.first(where: { $0.name == busName }), let v = now.tracks.first(where: { $0.name == t.name }) else { return nil }
                                         return .send(from: v.index, to: b.index, db: level)
                                     }])
            }
        }
        if h.has("send") && h.has("to"), let dest = h.after("to") {
            let sourceWords = h.text.components(separatedBy: " to ").first?.split(separator: " ").map(String.init) ?? []
            return withTrack(pick(sourceWords, s)) { from in
                self.withDest(dest, s) { to in .op(.send(from: from.index, to: to.index, db: -12), confirm: nil) }
            }
        }

        // Tracks: make, name, copy, move, remove.
        if h.has("new track", "add a track", "create a track", "another track", "make a track", "new instrument track", "new audio track", "new piano track", "add a piano track", "add an instrument track", "add an audio track", "create a new track") {
            let instrument = h.has("instrument", "piano", "synth", "keys", "midi", "keyboard")
            let name = (h.after("called", "named") ?? (h.has("piano") ? "piano" : "")).capitalized
            return .op(.newTrack(instrument: instrument, name: name, fx: instrument ? "ReaSynth" : ""), confirm: nil)
        }
        if h.has("duplicate", "copy of", "make a copy") {
            let name = (h.after("call it", "name it", "called", "named") ?? "").capitalized
            let words = h.text.components(separatedBy: " and ").first?.split(separator: " ").map(String.init) ?? h.words
            return withTrack(pick(words, s)) { t in .op(.duplicate(track: t.index, name: name), confirm: nil) }
        }
        if h.has("rename") || (h.has("call this track", "name this track", "call that track", "name that track")), let name = h.after("to", "as", "call this track", "name this track", "call that track", "name that track") {
            let words = h.text.components(separatedBy: " to ").first?.split(separator: " ").map(String.init) ?? h.words
            return withTrack(pick(words, s)) { t in .op(.rename(track: t.index, name: name.capitalized), confirm: nil) }
        }
        if h.has("delete", "remove", "get rid of") && h.has("track", "channel") && !fxKinds.contains(where: { k in k.words.contains { h.has($0) } }) {
            return withTrack(pick(h.words, s, allowDefault: h.has("this", "that", "it", "selected"))) { t in
                .op(.delete(track: t.index), confirm: "Delete \(t.name)" + (t.items > 0 ? ", which has \(t.items) recorded item\(t.items == 1 ? "" : "s")" : "") + (t.fx.isEmpty ? "" : " and \(t.fx.count) plug-in\(t.fx.count == 1 ? "" : "s")") + "? Say yes or no.")
            }
        }
        if h.has("move"), let rest = h.after("below", "under", "after") {
            let words = h.text.components(separatedBy: " below ").first?.components(separatedBy: " under ").first?.components(separatedBy: " after ").first?.split(separator: " ").map(String.init) ?? []
            return withTrack(pick(words, s, allowDefault: false)) { t in self.withDest(rest, s) { anchor in .op(.moveBelow(track: t.index, below: anchor.index), confirm: nil) } }
        }

        // Plug-ins: presets, removing, bypassing, adding, and their settings.
        if h.has("preset") {
            return withTrack(fxTrack("on the", "on my", "for the")) { t in
                guard let f = self.pickFx(h, on: t) else { return .say(t.fx.isEmpty ? "\(t.name) has no plug-ins to load a preset on." : "Which plug-in? \(t.name) has \(t.fx.joined(separator: ", ")).") }
                if h.has("next") { return .op(.preset(track: t.index, fx: f, choice: "next"), confirm: nil) }
                if h.has("previous", "last one", "go back") { return .op(.preset(track: t.index, fx: f, choice: "previous"), confirm: nil) }
                if h.has("what", "which", "current") {
                    let now = (self.adapter.send(["fx_preset", String(t.index), String(f)], timeout: 4) ?? "").components(separatedBy: "|")
                    return .say((now.first ?? "").isEmpty ? "\(t.fx[f - 1]) is not on a named preset. It has \(now.last ?? "0") to choose from." : "\(t.fx[f - 1]) is on the preset \(now[0]).")
                }
                guard let name = h.after("called", "named", "preset called", "to the", "to my", "load the", "load") else { return .question("Which preset? Say next preset to step through them.") }
                let clean = name.replacingOccurrences(of: " preset", with: "").replacingOccurrences(of: "preset ", with: "")
                return .op(.preset(track: t.index, fx: f, choice: clean), confirm: nil)
            }
        }
        if let kind = fxKinds.first(where: { k in k.words.contains { h.has($0) } }) {
            if h.has("remove", "delete", "take off", "get rid of") {
                return withTrack(fxTrack("from the", "from my", "from", "on the", "off the")) { t in
                    guard let f = self.pickFx(h, on: t) else { return .say("\(t.name) has no \(kind.called).") }
                    return .op(.fxRemove(track: t.index, fx: f), confirm: nil)
                }
            }
            if h.has("bypass", "disable", "turn off", "switch off", "enable", "turn on", "switch on", "unbypass") {
                return withTrack(fxTrack("on the", "on my", "of the")) { t in
                    guard let f = self.pickFx(h, on: t) else { return .say("\(t.name) has no \(kind.called).") }
                    return .op(.fxBypass(track: t.index, fx: f), confirm: nil)
                }
            }
            if h.has("add", "put", "insert", "give", "use", "needs", "open a", "new") && !up && !down || h.starts("add", "put", "insert") {
                return withTrack(target("to", "on", "onto", "for", fallbackWhole: false)) { t in .op(.fxAdd(track: t.index, fx: kind.stock), confirm: nil) }
            }
        }
        if (up || down || h.has("set", "make", "change", "turn")) && !h.has("volume", "pan", "tempo", "track up", "track down") {
            // A setting of a plug-in: on the named track, else wherever the last plug-in was.
            var t: DawTrack? = nil
            if case .one(let found) = fxTrack("on the", "on my", "of the") { t = found }
            let followUp = h.has("that", "it", "more", "less", "again", "bit", "little") && Date().timeIntervalSince(lastChange) < 60
            if let t = t, let f = pickFx(h, on: t) {
                let list = params(t.index, f)
                if let param = pickParam(h, list, allowLast: followUp) {
                    if let to = number(after: "to"), h.has("set", "to") { return .op(.paramTo(track: t.index, fx: f, param: param.index, value: to), confirm: nil) }
                    if let by = number(after: "by"), let now = Double(param.shown.replacingOccurrences(of: "+", with: "")) {
                        return .op(.paramTo(track: t.index, fx: f, param: param.index, value: now + (down ? -by : by)), confirm: nil)
                    }
                    // "A bit more" and "again" carry on in the direction of the last change.
                    let onlyMore = followUp && !down && !h.has("raise", "increase", "up", "higher", "boost", "louder", "longer", "bigger", "wetter", "wider", "brighter") && lastNudge != 0
                    if onlyMore { return .op(.paramNudge(track: t.index, fx: f, param: param.index, by: lastNudge < 0 ? -amount : amount), confirm: nil) }
                    if up || down { return .op(.paramNudge(track: t.index, fx: f, param: param.index, by: (down && !up) ? -amount : amount), confirm: nil) }
                }
            }
        }

        // The channel strip.
        let namesTrack: Bool = { if case .none = pick(h.words, s, allowDefault: false) { return h.has("track", "channel") }; return true }()
        if h.has("all the solo", "all solo", "unsolo everything", "unsolo all", "clear the solos", "every solo", "all the solos") { return .op(.allOff(key: "solo"), confirm: nil) }
        if h.has("unmute everything", "unmute all", "all the mute", "clear the mutes", "all the mutes") { return .op(.allOff(key: "mute"), confirm: nil) }
        if h.has("disarm everything", "disarm all", "unarm all") { return .op(.allOff(key: "arm"), confirm: nil) }
        for (key, onWords, offWords) in [("mute", ["mute"], ["unmute"]), ("solo", ["solo"], ["unsolo"]), ("arm", ["arm", "record enable"], ["disarm", "unarm"])] {
            if offWords.contains(where: { h.has($0) }) { return withTrack(pick(h.words, s)) { t in .op(.flag(track: t.index, key: key, on: false), confirm: nil) } }
            if onWords.contains(where: { h.has($0) }) && (key != "arm" || namesTrack || h.has("this", "it")) { return withTrack(pick(h.words, s)) { t in .op(.flag(track: t.index, key: key, on: !h.has("off", "stop", "dont")), confirm: nil) } }
        }
        if !h.has("band", "voice", "metronome") && (h.has("volume", "fader") || ((up || down || h.has("turn", "bring", "pull", "push")) && namesTrack && h.has("up", "down", "louder", "quieter", "turn", "bring", "pull", "push"))) {
            return withTrack(pick(h.words, s)) { t in
                if h.has("what", "read", "tell") { return .say("\(t.name) is at \(spokenDB(t.volDB)).") }
                if let to = number(after: "to", "at") { return .op(.volumeTo(track: t.index, db: to > 12 ? -to : to), confirm: nil) }
                let by = number(after: "by") ?? (amount == 0.03 ? 1.5 : amount == 0.12 ? 6 : 3)
                return .op(.volumeTo(track: t.index, db: max(-90, min(12, t.volDB + (down && !up ? -abs(by) : abs(by))))), confirm: nil)
            }
        }
        if h.has("pan", "panned", "panning") || h.has("to the left", "to the right", "centre it", "center it") {
            return withTrack(pick(h.words, s)) { t in
                if h.has("centre", "center", "middle") { return .op(.panTo(track: t.index, pan: 0), confirm: nil) }
                let n = Int(number(after: "left", "right", "pan", "to", "by") ?? 30)
                if h.has("left") { return .op(.panTo(track: t.index, pan: -abs(n)), confirm: nil) }
                if h.has("right") { return .op(.panTo(track: t.index, pan: abs(n)), confirm: nil) }
                return .say("\(t.name) is panned \(spokenPan(t.pan)).")
            }
        }

        // Finding and moving between tracks.
        if h.has("next track", "track down", "down a track") {
            let i = (s.tracks.first { $0.selected }?.index ?? 0) + 1
            return i <= s.tracks.count ? .op(.select(i), confirm: nil) : .say("That is the last track.")
        }
        if h.has("previous track", "track up", "up a track") {
            let i = (s.tracks.first { $0.selected }?.index ?? 2) - 1
            return i >= 1 ? .op(.select(i), confirm: nil) : .say("That is the first track.")
        }
        if h.has("find", "select", "go to", "jump to", "show me", "take me to", "where is", "open") {
            let named = pick(h.words, s, allowDefault: false)
            if case .none = named {
                if h.has("track", "channel") { return .question("I could not find that track. The project has \(s.tracks.map { $0.name }.joined(separator: ", ")).") }
            } else {
                return withTrack(named) { t in t.index == 0 ? .say(t.described(detailed: true)) : .op(.select(t.index), confirm: nil) }
            }
        }

        // Transport.
        if h.has("tempo", "bpm", "beats per minute") {
            if let n = h.number, n >= 20 { return .op(.tempo(Double(n)), confirm: nil) }
            return .say("The tempo is \(Int(s.tempo)).")
        }
        if h.has("stop recording") || (h.has("stop") && s.transport != "stopped") { return .op(.transport("stop"), confirm: nil) }
        if h.has("record", "recording") { return .op(.transport("record"), confirm: nil) }
        if h.has("playback", "play the project", "play it in reaper", "play reaper", "play the track", "play the tracks", "hit play", "press play", "play the session", "play from the start") { return .op(.transport("play"), confirm: nil) }
        if h.has("rewind", "go to the start", "go to the beginning", "back to the start", "back to the beginning") { return .op(.transport("start"), confirm: nil) }
        if h.has("how loud", "peak", "level right now", "is it clipping") {
            let db = Double(adapter.send(["peak", "master"], timeout: 3) ?? "") ?? -150
            if s.transport == "stopped" { return .say("Nothing is playing, so there is no level to read. Say play, then ask again.") }
            return .say("The master is peaking at \(spokenDB(db)) right now." + (db > -0.1 ? " That is at or over full scale, so it is clipping." : db > -3 ? " That is close to the top." : ""))
        }
        return nil
    }

    func withDest(_ phrase: String, _ s: DawState, _ make: (DawTrack) -> DawAsk?) -> DawAsk? {
        switch pick(phrase.split(separator: " ").map(String.init), s, allowDefault: false) {
        case .one(let t): return make(t)
        case .many(let m): return which(m)
        case .none: return .question("I could not find a track called \(phrase). The project has \(s.tracks.map { $0.name }.joined(separator: ", ")).")
        }
    }
}

// MARK: - A stand-in project for the self-test

/// Behaves like a small REAPER project in memory. With `deaf` set it accepts commands and
/// does nothing, which is how the test proves that unconfirmed changes are never announced.
final class FakeDaw: DawAdapter {
    let name = "REAPER"
    var s = DawState()
    var deaf = false
    var paramValues: [String: (String, Double)] = [:]
    init() {
        func t(_ i: Int, _ n: String, fx: [String] = []) -> DawTrack { var x = DawTrack(); x.index = i; x.name = n; x.fx = fx; x.fxOn = fx.map { _ in true }; return x }
        s.master = t(0, "Master")
        s.tracks = [t(1, "Lead Vocals", fx: ["ReaEQ"]), t(2, "Bass"), t(3, "Kick"), t(4, "Vocal Double")]
        s.tracks[0].selected = true
        s.tracks[1].mute = true; s.tracks[2].solo = true
    }
    func state() -> DawState? { s }
    private func at(_ i: String) -> Int? { Int(i).flatMap { n in n == 0 ? -1 : s.tracks.firstIndex { $0.index == n } } }
    private func renumber() { for i in s.tracks.indices { s.tracks[i].index = i + 1 } }
    private func edit(_ i: String, _ change: (inout DawTrack) -> Void) { if i == "0" { change(&s.master) } else if let k = at(i), k >= 0 { change(&s.tracks[k]) } }
    private func paramList(_ fx: String) -> [String] {
        let n = fx.lowercased()
        return n.contains("comp") ? ["Threshold", "Ratio", "Attack", "Release"] : n.contains("verb") ? ["Wet", "Dry", "Room size"]
            : n.contains("eq") ? ["Freq-Band 1", "Gain-Band 1", "Freq-Band 2", "Gain-Band 2", "Freq-Band 3", "Gain-Band 3"] : ["Gain"]
    }
    func send(_ p: [String], timeout: Double) -> String? {
        if deaf, !["fx_params", "fx_preset", "peak"].contains(p[0]) { return "ok" }
        switch p[0] {
        case "select": for i in s.tracks.indices { s.tracks[i].selected = String(s.tracks[i].index) == p[1] }
        case "fx_add":
            if p[2] == "Nonsense" { return "I could not find Nonsense" }
            edit(p[1]) { $0.fx.append(p[2]); $0.fxOn.append(true) }
        case "fx_remove": edit(p[1]) { let i = Int(p[2])! - 1; $0.fx.remove(at: i); $0.fxOn.remove(at: i) }
        case "fx_bypass": edit(p[1]) { $0.fxOn[Int(p[2])! - 1].toggle() }
        case "fx_params":
            let tr = p[1] == "0" ? s.master : s.tracks[at(p[1])!]
            let fx = tr.fx[Int(p[2])! - 1]
            return paramList(fx).enumerated().map { i, n in
                let key = "\(p[1])/\(p[2])/\(i + 1)"
                let v = paramValues[key] ?? (n.hasPrefix("Freq") ? (["100.0", "350.0", "3000.0"][i / 2], 0.2) : (n == "Threshold" ? "0.0" : n == "Ratio" ? "4.00" : "0.0", 0.5))
                return "\(i + 1)|\(n)|\(v.0)|\(v.1)"
            }.joined(separator: "\n")
        case "fx_param_set":
            let v = Double(p[4]) ?? 0
            paramValues["\(p[1])/\(p[2])/\(p[3])"] = (String(format: "%.1f", v * 48 - 24), v)
        case "fx_param_to":
            guard let v = Double(p[4]), v >= -60, v <= 24 else { return "out of range: it goes from -60 to 24" }
            paramValues["\(p[1])/\(p[2])/\(p[3])"] = (String(format: "%.1f", v), (v + 60) / 84)
        case "fx_preset": return p.count > 3 && !p[3].isEmpty ? (p[3] == "missing" ? "|3" : "\(p[3].capitalized)|3") : "|3"
        case "track_vol_set": edit(p[1]) { $0.volDB = Double(p[2]) ?? 0 }
        case "track_pan_set": edit(p[1]) { $0.pan = Int(p[2]) ?? 0 }
        case "track_set": edit(p[1]) { t in if p[2] == "mute" { t.mute = p[3] == "1" } else if p[2] == "solo" { t.solo = p[3] == "1" } else { t.arm = p[3] == "1" } }
        case "all_off": for i in s.tracks.indices { if p[1] == "mute" { s.tracks[i].mute = false } else if p[1] == "solo" { s.tracks[i].solo = false } else { s.tracks[i].arm = false } }
        case "track_rename": edit(p[1]) { $0.name = p[2] }
        case "track_duplicate":
            if let k = at(p[1]), k >= 0 { var c = s.tracks[k]; c.selected = false; if p.count > 2, !p[2].isEmpty { c.name = p[2] }; s.tracks.insert(c, at: k + 1); renumber() }
        case "track_new":
            var t = DawTrack(); t.name = p.count > 2 && !p[2].isEmpty ? p[2] : "Track \(s.tracks.count + 1)"
            if p.count > 3, !p[3].isEmpty { t.fx = [p[3]]; t.fxOn = [true] }
            s.tracks.append(t); renumber()
        case "track_delete": if let k = at(p[1]), k >= 0 { s.tracks.remove(at: k); renumber() }
        case "track_move":
            if let k = at(p[1]), k >= 0 {
                let moving = s.tracks.remove(at: k)
                let anchor = s.tracks.firstIndex { String($0.index) == p[2] } ?? s.tracks.count - 1
                s.tracks.insert(moving, at: anchor + 1); renumber()
            }
        case "send_create": if let d = at(p[2]), d >= 0 { let to = s.tracks[d].name; edit(p[1]) { $0.sends.append((to, Double(p[3]) ?? -12)) } }
        case "tempo": if p.count > 2 { s.tempo = Double(p[2]) ?? s.tempo }
        case "play": s.transport = s.transport == "playing" ? "stopped" : "playing"
        case "stop": s.transport = "stopped"
        case "record": s.transport = "recording"
        case "undo": return "Undid: the last change"
        case "peak": return "-6.0"
        default: break
        }
        return "ok"
    }
}

func dawSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let fake = FakeDaw()
    let real = engine.daw.adapter
    engine.daw.adapter = fake
    engine.dawForced = true
    engine.dawMode = "assisted"
    defer { engine.daw.adapter = real; engine.dawForced = false; engine.pendingConfirm = nil; engine.pendingSentence = nil }
    var wrong: [String] = []
    // Each sentence, and words that must appear in what is said back.
    let talk: [(String, [String])] = [
        ("\(Me.name), find my bass track", ["Bass, track 2", "Volume 0 decibels"]),
        ("what is selected", ["Bass, track 2"]),
        ("tell me what plugins are on the lead vocals", ["Lead Vocals has 1, ReaEQ"]),
        ("add a compressor to the lead vocals", ["ReaComp is now on Lead Vocals", "2 plug-ins"]),
        ("lower the threshold a little", ["Threshold on ReaComp is now", "It was"]),
        ("set the threshold to minus 18", ["Threshold on ReaComp is now -18.0"]),
        ("what are the compressor settings", ["ReaComp on Lead Vocals", "Threshold -18.0", "Ratio"]),
        ("set the lead vocals volume to minus 6 decibels", ["Lead Vocals is at minus 6 decibels", "It was 0 decibels"]),
        ("which tracks are muted", ["Bass is muted"]),
        ("unmute the bass", ["Bass is unmuted"]),
        ("turn off all the solo buttons", ["Solo is off on every track", "Kick"]),
        ("duplicate the kick and name it kick sample", ["Kick is duplicated", "called Kick Sample"]),
        ("move the bass below the kick", ["Bass is now track", "just below Kick"]),
        ("which tracks have compression", ["Lead Vocals has ReaComp"]),
        ("rename track 2 to drums", ["is now called Drums"]),
        ("pan the vocal double left 30", ["Vocal Double is panned 30 percent left"]),
        ("lower the low mids on the lead vocals eq", ["Gain-Band 2 on ReaEQ is now"]),
        ("load the preset called clean vocal", ["is now on the preset Clean Vocal"]),
        ("what did you change", ["Most recent last", "preset Clean Vocal"]),
        ("add a flanger made of cheese to the bass", []),
        ("how many tracks", ["5 tracks"]),
        ("is anything wrong before exporting", ["Here is what I can see"]),
        ("set the tempo to 96", ["Tempo is 96. It was 120"]),
        ("undo that", ["Undid"]),
    ]
    for (said, wants) in talk {
        engine.daw.lastSaid = ""
        _ = engine.hear(said)
        for w in wants where !engine.daw.lastSaid.contains(w) { wrong.append("\"\(said)\" gave \"\(engine.daw.lastSaid)\", missing \"\(w)\"") }
    }
    check("DAW assistant: \(talk.count) requests are carried out and reported from the real project state", wrong.isEmpty, wrong.isEmpty ? "all correct" : wrong.joined(separator: " || "))

    // Ambiguity: two tracks have "vocal" in their names, so it must ask, and the answer must finish the job.
    _ = engine.hear("mute the vocal")
    let asked = engine.daw.lastSaid.contains("Which one") && !fake.s.tracks.contains { $0.name.contains("Vocal") && $0.mute }
    _ = engine.hear("the lead one")
    check("DAW assistant: an ambiguous request gets a question, and the answer completes it", asked && fake.s.tracks.first { $0.name == "Lead Vocals" }?.mute == true, engine.daw.lastSaid)

    // Deleting asks first, and "no" really cancels.
    let count = fake.s.tracks.count
    _ = engine.hear("delete the kick sample track")
    let confirmAsked = engine.daw.lastSaid.contains("Delete Kick Sample") && fake.s.tracks.count == count
    _ = engine.hear("no")
    let kept = fake.s.tracks.count == count
    _ = engine.hear("delete the kick sample track"); _ = engine.hear("yes")
    check("DAW assistant: deleting asks first, no cancels, yes deletes", confirmAsked && kept && fake.s.tracks.count == count - 1, engine.daw.lastSaid)

    // A plan is explained, waits for a yes, then runs step by step.
    _ = engine.hear("help me prepare my lead vocal for mixing")
    let explained = engine.daw.lastSaid.contains("Shall I go ahead") && engine.daw.lastSaid.contains("reverb bus") && !engine.daw.lastSaid.contains("add an EQ")
    _ = engine.hear("yes")
    let lead = fake.s.tracks.first { $0.name == "Lead Vocals" }
    check("DAW assistant: a vocal chain is planned around what is already there, then built after a yes",
          explained && fake.s.tracks.contains { $0.name == "Reverb Bus" } && lead?.sends.first?.to == "Reverb Bus" && lead?.fx.filter { $0 == "ReaEQ" }.count == 1, engine.daw.lastSaid)
    _ = engine.hear("help me prepare my lead vocal for mixing")
    check("DAW assistant: asked again, it adds nothing more", engine.daw.lastSaid.contains("already has"), engine.daw.lastSaid)

    // The important one: if the DAW does not actually change, nothing is claimed.
    fake.deaf = true
    engine.daw.lastSaid = ""
    _ = engine.hear("add an eq to the bass")
    let honest1 = !engine.daw.lastSaid.contains("is now on") && engine.daw.lastSaid.contains("not there")
    _ = engine.hear("set the kick volume to minus 10")
    let honest2 = engine.daw.lastSaid.contains("cannot confirm")
    fake.deaf = false
    check("DAW assistant: when the DAW does not change, it says so and claims nothing", honest1 && honest2, engine.daw.lastSaid)
    engine.goHomeQuietly()
}
