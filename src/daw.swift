// The DAW assistant: plain requests turned into checked operations on a real project.
//
// Three rules shape this file.
//  1. The assistant never acts on words alone. A sentence becomes one of a fixed set of
//     operations (DawOp); anything outside that set is refused, not improvised.
//  2. Nothing is announced as done until it has been seen to be done. Every operation reads
//     the project before and after, and the spoken result is built from what is really there.
//  3. The DAW is behind an adapter. REAPER's is complete because REAPER lets a script read
//     and change everything; other DAWs say honestly what they can and cannot do.

import Foundation

struct DawTrack {
    var index = 0                 // 0 is the master
    var name = ""
    var volDB = 0.0
    var pan = 0                   // -100 left to 100 right
    var mute = false, solo = false, arm = false, selected = false
    var fx: [String] = []
    var fxOn: [Bool] = []
    var sends: [(to: String, db: Double)] = []
    var items = 0
}

struct DawState {
    var master = DawTrack()
    var tracks: [DawTrack] = []
    var transport = "stopped"
    var position = ""
    var tempo = 120.0
}

protocol DawAdapter {
    var name: String { get }
    func state() -> DawState?
    func send(_ parts: [String], timeout: Double) -> String?
}

struct ReaperAdapter: DawAdapter {
    let name = "REAPER"
    func send(_ parts: [String], timeout: Double) -> String? { Reaper.sendList(parts, timeout: timeout) }
    func state() -> DawState? {
        guard let raw = Reaper.sendList(["snapshot"]) else { return nil }
        return DawState.parse(raw)
    }
}

extension DawState {
    static func parse(_ raw: String) -> DawState? {
        var s = DawState()
        var sawMaster = false
        for line in raw.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if f[0] == "P", f.count >= 4 { s.transport = f[1]; s.position = f[2]; s.tempo = Double(f[3]) ?? 120; continue }
            guard f.count >= 12, let idx = Int(f[0]) else { continue }
            var t = DawTrack()
            t.index = idx; t.name = f[1]; t.volDB = Double(f[2]) ?? 0; t.pan = Int(f[3]) ?? 0
            t.mute = f[4] == "1"; t.solo = f[5] == "1"; t.arm = f[6] == "1"; t.selected = f[7] == "1"
            t.fx = f[8].isEmpty ? [] : f[8].components(separatedBy: ";")
            t.fxOn = f[9].isEmpty ? [] : f[9].components(separatedBy: ";").map { $0 == "1" }
            t.sends = f[10].isEmpty ? [] : f[10].components(separatedBy: ";").map { part in
                let bits = part.components(separatedBy: "@")
                return (bits[0], Double(bits.count > 1 ? bits[1] : "0") ?? 0)
            }
            t.items = Int(f[11]) ?? 0
            if idx == 0 { s.master = t; s.master.name = "Master"; sawMaster = true } else { s.tracks.append(t) }
        }
        return sawMaster ? s : nil
    }
    func track(_ i: Int) -> DawTrack? { i == 0 ? master : tracks.first { $0.index == i } }
}

func spokenDB(_ db: Double) -> String {
    if db <= -120 { return "silent" }
    let r = (db * 10).rounded() / 10
    if abs(r) < 0.05 { return "0 decibels" }
    let n = r == r.rounded() ? String(Int(abs(r))) : String(abs(r))
    return "\(r < 0 ? "minus" : "plus") \(n) decibels"
}

func spokenPan(_ pan: Int) -> String { pan == 0 ? "centre" : "\(abs(pan)) percent \(pan < 0 ? "left" : "right")" }

extension DawTrack {
    /// What a sighted person would read off the channel strip.
    func described(detailed: Bool) -> String {
        var parts = [index == 0 ? "Master" : "\(name), track \(index)", "Volume \(spokenDB(volDB))", "Panned \(spokenPan(pan))"]
        parts.append(fx.isEmpty ? "No plug-ins" : "\(fx.count) plug-in\(fx.count == 1 ? "" : "s")" + (detailed || fx.count <= 3 ? ": " + zip(fx, fxOn).map { $0 + ($1 ? "" : ", bypassed") }.joined(separator: ", ") : ""))
        var flags: [String] = []
        if mute { flags.append("muted") }
        if solo { flags.append("soloed") }
        if arm { flags.append("armed for recording") }
        parts.append(flags.isEmpty ? "Not muted, not soloed" : flags.joined(separator: ", ").capitalizedFirst)
        if detailed || !sends.isEmpty {
            parts.append(sends.isEmpty ? "No sends" : "Sends to " + sends.map { "\($0.to) at \(spokenDB($0.db))" }.joined(separator: " and "))
        }
        if detailed { parts.append(items == 0 ? "Nothing recorded on it" : "\(items) item\(items == 1 ? "" : "s") on it") }
        return parts.joined(separator: ". ") + "."
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Everything the assistant is allowed to do to a project. Nothing else can be executed.
enum DawOp {
    case select(Int)
    case fxAdd(track: Int, fx: String)
    case fxRemove(track: Int, fx: Int)
    case fxBypass(track: Int, fx: Int)
    case paramNudge(track: Int, fx: Int, param: Int, by: Double)     // by a share of the control's travel
    case paramTo(track: Int, fx: Int, param: Int, value: Double)     // to the number the plug-in shows
    case preset(track: Int, fx: Int, choice: String)
    case volumeTo(track: Int, db: Double)
    case panTo(track: Int, pan: Int)
    case flag(track: Int, key: String, on: Bool)                     // mute, solo, arm
    case allOff(key: String)
    case rename(track: Int, name: String)
    case duplicate(track: Int, name: String)
    case newTrack(instrument: Bool, name: String, fx: String)
    case delete(track: Int)
    case moveBelow(track: Int, below: Int)
    case send(from: Int, to: Int, db: Double)
    case transport(String)                                           // play, stop, record, start
    case tempo(Double)
    case undo, redo

    var destructive: Bool { if case .delete = self { return true }; return false }
}

struct DawResult { var ok: Bool; var said: String }

final class Daw {
    var adapter: DawAdapter = ReaperAdapter()
    var history: [(at: Date, what: String)] = []
    var lastTrack: Int? = nil                // what "it" and "that track" mean
    var lastFx: (track: Int, fx: Int)? = nil
    var lastParam: Int? = nil
    var lastSaid = ""
    var lastNudge = 0.0                  // the direction of the last small change, for "a bit more"
    var lastChange = Date.distantPast    // when the project was last changed through the assistant
    static let logURL = baseDir.appendingPathComponent("daw-history.txt")

    struct Param { var index: Int; var name: String; var shown: String; var norm: Double }

    func params(_ track: Int, _ fx: Int) -> [Param] {
        (adapter.send(["fx_params", String(track), String(fx)], timeout: 4) ?? "").split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let i = Int(f[0]) else { return nil }
            return Param(index: i, name: f[1], shown: f[2], norm: Double(f[3]) ?? 0)
        }
    }

    private func note(_ what: String) {
        lastChange = Date()
        history.append((Date(), what))
        if history.count > 200 { history.removeFirst(50) }
        if Opt.fast { return }   // the self-test's stand-in project is not real history
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(what)\n"
        if let h = try? FileHandle(forWritingTo: Daw.logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: Daw.logURL, atomically: true, encoding: .utf8) }
    }

    /// Carries out one operation: check it makes sense, do it, look again, and report only what is true.
    func perform(_ op: DawOp) -> DawResult {
        guard let before = adapter.state() else { return DawResult(ok: false, said: "\(adapter.name) is not answering, so I have not changed anything.") }
        func name(_ t: Int) -> String { before.track(t)?.name ?? "track \(t)" }
        func missing(_ t: Int) -> DawResult? { before.track(t) == nil ? DawResult(ok: false, said: "There is no track \(t). The project has \(before.tracks.count).") : nil }
        func hasFx(_ t: Int, _ f: Int) -> DawResult? {
            if let m = missing(t) { return m }
            return f >= 1 && f <= (before.track(t)?.fx.count ?? 0) ? nil : DawResult(ok: false, said: "\(name(t)) has no plug-in number \(f).")
        }
        func ask(_ parts: [String], timeout: Double = 4) -> String { adapter.send(parts, timeout: timeout) ?? "" }
        func after() -> DawState? { adapter.state() }
        func unconfirmed(_ what: String) -> DawResult { DawResult(ok: false, said: "I asked \(adapter.name) to \(what), but I cannot confirm that it happened.") }
        func done(_ said: String, log: String) -> DawResult { note(log); return DawResult(ok: true, said: said) }

        switch op {
        case .select(let t):
            if let m = missing(t) { return m }
            _ = ask(["select", String(t)])
            guard let s = after(), let tr = s.track(t), tr.selected else { return unconfirmed("select \(name(t))") }
            lastTrack = t
            return DawResult(ok: true, said: tr.described(detailed: false))

        case .fxAdd(let t, let fx):
            if let m = missing(t) { return m }
            let reply = ask(["fx_add", String(t), fx], timeout: 15)
            guard let s = after(), let tr = s.track(t), tr.fx.count == (before.track(t)?.fx.count ?? 0) + 1, let added = tr.fx.last else {
                return DawResult(ok: false, said: reply.contains("could not find") ? "I could not find a plug-in called \(fx)." : "I tried to add \(fx) to \(name(t)), but it is not there.")
            }
            lastTrack = t; lastFx = (t, tr.fx.count); lastParam = nil
            return done("\(added) is now on \(tr.name), which has \(tr.fx.count) plug-in\(tr.fx.count == 1 ? "" : "s").", log: "added \(added) to \(tr.name)")

        case .fxRemove(let t, let f):
            if let m = hasFx(t, f) { return m }
            let gone = before.track(t)!.fx[f - 1]
            _ = ask(["fx_remove", String(t), String(f)])
            guard let s = after(), s.track(t)?.fx.count == before.track(t)!.fx.count - 1 else { return unconfirmed("remove \(gone)") }
            lastFx = nil
            return done("\(gone) is removed from \(name(t)). Say undo to bring it back.", log: "removed \(gone) from \(name(t))")

        case .fxBypass(let t, let f):
            if let m = hasFx(t, f) { return m }
            _ = ask(["fx_bypass", String(t), String(f)])
            guard let s = after(), let tr = s.track(t), tr.fxOn[f - 1] != before.track(t)!.fxOn[f - 1] else { return unconfirmed("bypass that plug-in") }
            lastFx = (t, f)
            return done("\(tr.fx[f - 1]) on \(tr.name) is \(tr.fxOn[f - 1] ? "on" : "bypassed").", log: "\(tr.fxOn[f - 1] ? "switched on" : "bypassed") \(tr.fx[f - 1]) on \(tr.name)")

        case .paramNudge(let t, let f, let p, let by):
            if let m = hasFx(t, f) { return m }
            let was = params(t, f)
            guard let old = was.first(where: { $0.index == p }) else { return DawResult(ok: false, said: "That plug-in has no such setting.") }
            _ = ask(["fx_param_set", String(t), String(f), String(p), String(max(0, min(1, old.norm + by)))])
            guard let now = params(t, f).first(where: { $0.index == p }), now.norm != old.norm else {
                return DawResult(ok: false, said: "\(old.name) is already as \(by > 0 ? "high" : "low") as it goes, at \(old.shown).")
            }
            lastFx = (t, f); lastParam = p; lastTrack = t; lastNudge = by
            return done("\(now.name) on \(before.track(t)!.fx[f - 1]) is now \(now.shown). It was \(old.shown).", log: "\(now.name) on \(name(t)) from \(old.shown) to \(now.shown)")

        case .paramTo(let t, let f, let p, let value):
            if let m = hasFx(t, f) { return m }
            guard let old = params(t, f).first(where: { $0.index == p }) else { return DawResult(ok: false, said: "That plug-in has no such setting.") }
            let reply = ask(["fx_param_to", String(t), String(f), String(p), String(value)])
            if reply != "ok" { return DawResult(ok: false, said: reply.hasPrefix("out of range") ? "\(old.name) cannot go there. \(String(reply.dropFirst(14)).capitalizedFirst)." : reply + ".") }
            guard let now = params(t, f).first(where: { $0.index == p }) else { return unconfirmed("change \(old.name)") }
            lastFx = (t, f); lastParam = p; lastTrack = t
            return done("\(now.name) on \(before.track(t)!.fx[f - 1]) is now \(now.shown). It was \(old.shown).", log: "\(now.name) on \(name(t)) from \(old.shown) to \(now.shown)")

        case .preset(let t, let f, let choice):
            if let m = hasFx(t, f) { return m }
            let was = ask(["fx_preset", String(t), String(f)]).components(separatedBy: "|")
            guard (Int(was.last ?? "0") ?? 0) > 0 else { return DawResult(ok: false, said: "\(before.track(t)!.fx[f - 1]) has no presets that \(adapter.name) can see.") }
            let now = ask(["fx_preset", String(t), String(f), choice]).components(separatedBy: "|")
            guard let chosen = now.first, !chosen.isEmpty, chosen != was.first || choice == chosen else {
                return DawResult(ok: false, said: "I could not find a preset called \(choice) on \(before.track(t)!.fx[f - 1]).")
            }
            lastFx = (t, f)
            return done("\(before.track(t)!.fx[f - 1]) is now on the preset \(chosen). Say undo to go back.", log: "preset \(chosen) on \(before.track(t)!.fx[f - 1]), \(name(t))")

        case .volumeTo(let t, let db):
            if let m = missing(t) { return m }
            guard db >= -90, db <= 12 else { return DawResult(ok: false, said: "Volume has to be between minus 90 and plus 12 decibels.") }
            _ = ask(["track_vol_set", String(t), String(db)])
            guard let s = after(), let tr = s.track(t), abs(tr.volDB - db) < 0.2 else { return unconfirmed("set the volume of \(name(t))") }
            lastTrack = t
            return done("\(tr.name) is at \(spokenDB(tr.volDB)). It was \(spokenDB(before.track(t)!.volDB)).", log: "volume of \(tr.name) from \(spokenDB(before.track(t)!.volDB)) to \(spokenDB(tr.volDB))")

        case .panTo(let t, let pan):
            if let m = missing(t) { return m }
            _ = ask(["track_pan_set", String(t), String(max(-100, min(100, pan)))])
            guard let s = after(), let tr = s.track(t), abs(tr.pan - max(-100, min(100, pan))) <= 1 else { return unconfirmed("pan \(name(t))") }
            lastTrack = t
            return done("\(tr.name) is panned \(spokenPan(tr.pan)).", log: "pan of \(tr.name) to \(spokenPan(tr.pan))")

        case .flag(let t, let key, let on):
            if let m = missing(t) { return m }
            _ = ask(["track_set", String(t), key, on ? "1" : "0"])
            guard let s = after(), let tr = s.track(t), (key == "mute" ? tr.mute : key == "solo" ? tr.solo : tr.arm) == on else { return unconfirmed("\(key) \(name(t))") }
            lastTrack = t
            let word = key == "mute" ? (on ? "muted" : "unmuted") : key == "solo" ? (on ? "soloed" : "no longer soloed") : (on ? "armed for recording" : "no longer armed")
            return done("\(tr.name) is \(word).", log: "\(tr.name) \(word)")

        case .allOff(let key):
            _ = ask(["all_off", key])
            guard let s = after(), !s.tracks.contains(where: { key == "mute" ? $0.mute : key == "solo" ? $0.solo : $0.arm }) else { return unconfirmed("clear every \(key)") }
            let were = before.tracks.filter { key == "mute" ? $0.mute : key == "solo" ? $0.solo : $0.arm }.map { $0.name }
            return done(were.isEmpty ? "No track had \(key) on." : "\(key.capitalizedFirst) is off on every track. It was on for \(were.joined(separator: ", ")).", log: "all \(key) off")

        case .rename(let t, let newName):
            if let m = missing(t) { return m }
            guard !newName.isEmpty else { return DawResult(ok: false, said: "What should I call it?") }
            _ = ask(["track_rename", String(t), newName])
            guard let s = after(), s.track(t)?.name == newName else { return unconfirmed("rename \(name(t))") }
            lastTrack = t
            return done("Track \(t) is now called \(newName). It was \(name(t)).", log: "renamed \(name(t)) to \(newName)")

        case .duplicate(let t, let newName):
            if let m = missing(t) { return m }
            _ = ask(["track_duplicate", String(t), newName])
            guard let s = after(), s.tracks.count == before.tracks.count + 1, let copy = s.track(t + 1) else { return unconfirmed("duplicate \(name(t))") }
            lastTrack = t + 1
            return done("\(name(t)) is duplicated. The copy is track \(copy.index), called \(copy.name), with the same \(copy.fx.count) plug-in\(copy.fx.count == 1 ? "" : "s").", log: "duplicated \(name(t)) as \(copy.name)")

        case .newTrack(let instrument, let trackName, let fx):
            _ = ask(["track_new", instrument ? "instrument" : "audio", trackName, fx], timeout: 15)
            guard let s = after(), s.tracks.count == before.tracks.count + 1, let made = s.tracks.last else { return unconfirmed("make a new track") }
            lastTrack = made.index
            if !fx.isEmpty, made.fx.isEmpty {
                note("new track \(made.name), without \(fx)")
                return DawResult(ok: false, said: "I made track \(made.index), \(made.name), but \(fx) did not load on it.")
            }
            return done("New \(instrument ? "instrument" : "audio") track, number \(made.index)\(made.name.hasPrefix("Track ") ? "" : ", called \(made.name)")\(made.fx.isEmpty ? "" : ", with \(made.fx.joined(separator: " and "))"). It is armed and selected.", log: "new track \(made.name)")

        case .delete(let t):
            if let m = missing(t) { return m }
            guard t != 0 else { return DawResult(ok: false, said: "The master track cannot be deleted.") }
            _ = ask(["track_delete", String(t)])
            guard let s = after(), s.tracks.count == before.tracks.count - 1 else { return unconfirmed("delete \(name(t))") }
            lastTrack = nil; lastFx = nil
            return done("\(name(t)) is deleted. Say undo to bring it back.", log: "deleted \(name(t))")

        case .moveBelow(let t, let below):
            if let m = missing(t) ?? missing(below) { return m }
            let moving = name(t), anchor = name(below)
            _ = ask(["track_move", String(t), String(below)])
            guard let s = after(), let a = s.tracks.first(where: { $0.name == anchor }), let m = s.tracks.first(where: { $0.name == moving }), m.index == a.index + 1 else {
                return unconfirmed("move \(moving)")
            }
            lastTrack = m.index
            return done("\(moving) is now track \(m.index), just below \(anchor).", log: "moved \(moving) below \(anchor)")

        case .send(let from, let to, let db):
            if let m = missing(from) ?? missing(to) { return m }
            guard from != to else { return DawResult(ok: false, said: "A track cannot send to itself.") }
            if before.track(from)!.sends.contains(where: { $0.to == name(to) }) { return DawResult(ok: true, said: "\(name(from)) already sends to \(name(to)).") }
            _ = ask(["send_create", String(from), String(to), String(db)])
            guard let s = after(), let made = s.track(from)?.sends.first(where: { $0.to == name(to) }) else { return unconfirmed("create that send") }
            lastTrack = from
            return done("\(name(from)) now sends to \(name(to)) at \(spokenDB(made.db)).", log: "send from \(name(from)) to \(name(to))")

        case .transport(let what):
            let reply = ask([what])
            guard let s = after() else { return unconfirmed(what) }
            if what == "record", s.transport != "recording", before.transport != "recording" { return DawResult(ok: false, said: reply.isEmpty ? "Recording did not start." : reply + ".") }
            return DawResult(ok: true, said: what == "start" ? "At the start." : "\(s.transport.capitalizedFirst). \(s.position).")

        case .tempo(let bpm):
            guard bpm >= 20, bpm <= 400 else { return DawResult(ok: false, said: "Tempo has to be between 20 and 400.") }
            _ = ask(["tempo", "set", String(bpm)])
            guard let s = after(), abs(s.tempo - bpm) < 0.5 else { return unconfirmed("set the tempo") }
            return done("Tempo is \(Int(s.tempo)). It was \(Int(before.tempo)).", log: "tempo from \(Int(before.tempo)) to \(Int(s.tempo))")

        case .undo, .redo:
            let isUndo: Bool = { if case .undo = op { return true }; return false }()
            let reply = ask([isUndo ? "undo" : "redo"])
            if reply.hasPrefix("Nothing") { return DawResult(ok: false, said: reply + ".") }
            note(reply)
            return DawResult(ok: true, said: reply + ".")
        }
    }
}
