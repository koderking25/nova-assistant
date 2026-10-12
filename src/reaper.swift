// REAPER control: a spoken menu, driven from the piano, that can run and read back
// almost anything in REAPER. It talks to a small script inside REAPER
// (reaper/talking_piano_bridge.lua, loaded when REAPER starts) through two files.

import Foundation

enum Reaper {
    static let resources = NSHomeDirectory() + "/Library/Application Support/REAPER"
    static let dir = resources + "/Scripts/TalkingPiano"
    static var counter = Int(Date().timeIntervalSince1970) % 100000
    static let lock = NSLock()

    static var installed: Bool { FileManager.default.fileExists(atPath: "/Applications/REAPER.app") }
    static var running: Bool { runTool("/usr/bin/pgrep", ["-xq", "REAPER"], timeout: 3).ok }

    // Puts the bridge script where REAPER loads it at startup. Returns false if REAPER
    // already has a startup script of its own that does not load the bridge.
    static func installBridge() -> Bool {
        let scripts = resources + "/Scripts"
        let source = baseDir.appendingPathComponent("reaper/talking_piano_bridge.lua").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: resources), let code = fm.contents(atPath: source) else { return false }
        try? fm.createDirectory(atPath: scripts, withIntermediateDirectories: true)
        if fm.contents(atPath: scripts + "/talking_piano_bridge.lua") != code { fm.createFile(atPath: scripts + "/talking_piano_bridge.lua", contents: code) }
        let startup = scripts + "/__startup.lua"
        let line = "dofile(reaper.GetResourcePath() .. \"/Scripts/talking_piano_bridge.lua\")\n"
        if let existing = try? String(contentsOfFile: startup, encoding: .utf8) {
            if existing.contains("talking_piano_bridge") { return true }
            return (try? (existing + "\n" + line).write(toFile: startup, atomically: true, encoding: .utf8)) != nil
        }
        return (try? ("-- Runs when REAPER starts. Added by Nova; delete this file to remove the bridge.\n" + line).write(toFile: startup, atomically: true, encoding: .utf8)) != nil
    }

    // Sends one command and waits for the sentence that comes back.
    static func send(_ parts: String..., timeout: Double = 3) -> String? { sendList(parts, timeout: timeout) }

    static func sendList(_ parts: [String], timeout: Double = 3) -> String? {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let id = String(counter)
        let fm = FileManager.default
        let cmd = dir + "/cmd.txt", reply = dir + "/reply.txt"
        try? fm.removeItem(atPath: reply)
        let clean = parts.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        guard (try? ([id] + clean).joined(separator: "\t").write(toFile: cmd + ".tmp", atomically: false, encoding: .utf8)) != nil else { return nil }
        try? fm.removeItem(atPath: cmd)
        guard (try? fm.moveItem(atPath: cmd + ".tmp", toPath: cmd)) != nil else { return nil }
        let end = now() + timeout
        while now() < end {
            if let text = try? String(contentsOfFile: reply, encoding: .utf8), text.hasPrefix(id + "\t") {
                return String(text.dropFirst(id.count + 1))
            }
            usleep(30_000)
        }
        try? fm.removeItem(atPath: cmd)
        return nil
    }

    static func lines(_ parts: String...) -> [String] {
        let r: String?
        switch parts.count {
        case 1: r = send(parts[0])
        case 2: r = send(parts[0], parts[1])
        default: r = send(parts[0], parts[1], parts[2])
        }
        return (r ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // "VST3i: Kontakt 8 (Native Instruments) (64 out)" is spoken as "Kontakt 8, VST3".
    static func spoken(_ fx: String) -> String {
        var name = fx, kind = ""
        if let r = fx.range(of: ": ") { kind = String(fx[..<r.lowerBound]).replacingOccurrences(of: "i", with: ""); name = String(fx[r.upperBound...]) }
        while let open = name.lastIndex(of: "("), name.hasSuffix(")") { name = String(name[..<open]).trimmingCharacters(in: .whitespaces) }
        return kind.isEmpty ? name : "\(name), \(kind)"
    }
}

// One level of the spoken menu. Items are rebuilt after each action, so labels that show
// a state, such as "armed", are always current.
final class RScreen {
    let title: String
    let build: () -> [RItem]
    var items: [RItem] = []
    var idx = 0
    init(_ title: String, _ build: @escaping () -> [RItem]) { self.title = title; self.build = build }
}

struct RItem {
    let label: String
    let go: () -> ROut
}

enum ROut {
    case say(String)                          // speak the result and stay here
    case push(RScreen)                        // go one level deeper
    case back(String)                         // speak, then go up one level
    case type(String, (String) -> ROut)       // ask for typed text, then carry on
}

let stockEffects = ["ReaEQ", "ReaComp", "ReaVerbate", "ReaDelay", "ReaLimit", "ReaGate", "ReaTune", "ReaPitch"]

extension Engine {
    func cmd(_ label: String, _ parts: String...) -> RItem {
        RItem(label: label) {
            let r: String?
            switch parts.count {
            case 1: r = Reaper.send(parts[0])
            case 2: r = Reaper.send(parts[0], parts[1])
            case 3: r = Reaper.send(parts[0], parts[1], parts[2])
            default: r = Reaper.send(parts[0], parts[1], parts[2], parts[3])
            }
            return .say(r ?? "REAPER did not answer.")
        }
    }

    // MARK: Screens

    func reaperRoot() -> RScreen {
        RScreen("REAPER control") { [unowned self] in
            [
                RItem(label: "Transport") { .push(self.transportScreen()) },
                RItem(label: "Tracks") { .push(self.tracksScreen()) },
                RItem(label: "New track") { .push(self.newTrackScreen()) },
                RItem(label: "Markers") { .push(RScreen("Markers") { [self.cmd("Add a marker here", "marker_add"), self.cmd("Next marker", "marker_next"), self.cmd("Previous marker", "marker_prev")] }) },
                RItem(label: "Project") { .push(RScreen("Project") { [self.cmd("About this project", "info"), self.cmd("Save", "save"), self.cmd("Undo", "undo"), self.cmd("Redo", "redo")] }) },
                RItem(label: "Find any action by typing") {
                    .type("Type a few words of what you want, such as normalize items") { text in
                        let found = Reaper.lines("action_search", text)
                        if found.isEmpty { return .say("Nothing in REAPER matches \(text).") }
                        return .push(RScreen("\(found.count) actions for \(text)") {
                            found.map { line in
                                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                                return RItem(label: parts.count > 1 ? parts[1] : line) { .say((Reaper.send("action", parts[0]) ?? "No answer") + ".") }
                            }
                        })
                    }
                },
            ]
        }
    }

    func transportScreen() -> RScreen {
        RScreen("Transport") { [unowned self] in
            [
                self.cmd("Play or stop", "play"), self.cmd("Record, or stop recording", "record"), self.cmd("Stop", "stop"),
                self.cmd("Go to the start", "start"), self.cmd("Where am I", "position"),
                self.cmd("Metronome on or off", "metronome"), self.cmd("Repeat on or off", "repeat"),
                self.cmd("Tempo up five", "tempo", "5"), self.cmd("Tempo down five", "tempo", "-5"),
                RItem(label: "Set the tempo by typing") { .type("Type the tempo in beats per minute") { t in .say(Reaper.send("tempo", "set", t) ?? "No answer") } },
                self.cmd("Undo", "undo"), self.cmd("Redo", "redo"),
            ]
        }
    }

    func tracksScreen() -> RScreen {
        RScreen("Tracks") { [unowned self] in
            let tracks = Reaper.lines("tracks")
            if tracks.isEmpty { return [RItem(label: "No tracks yet. Go back and choose New track.") { .say("There are no tracks yet.") }] }
            return tracks.enumerated().map { i, line in
                RItem(label: line) { _ = Reaper.send("track_select", String(i + 1)); return .push(self.trackScreen(i + 1)) }
            }
        }
    }

    func trackScreen(_ n: Int) -> RScreen {
        let t = String(n)
        let label = (Reaper.lines("tracks").dropFirst(n - 1).first ?? "Track \(n)").components(separatedBy: ", ").prefix(2).joined(separator: ", ")
        return RScreen(label) { [unowned self] in
            [
                self.cmd("Arm or disarm for recording", "track_arm", t), self.cmd("Mute or unmute", "track_mute", t), self.cmd("Solo or unsolo", "track_solo", t),
                self.cmd("Louder", "track_vol", t, "2"), self.cmd("Quieter", "track_vol", t, "-2"),
                self.cmd("Pan left", "track_pan", t, "-0.1"), self.cmd("Pan right", "track_pan", t, "0.1"),
                RItem(label: "Effects on this track") { .push(self.effectsScreen(n)) },
                RItem(label: "Add an effect") { .push(self.addEffectScreen(n)) },
                RItem(label: "Rename by typing") { .type("Type the new name") { name in .say(Reaper.send("track_rename", t, name) ?? "No answer") } },
                RItem(label: "Delete this track") { .back(Reaper.send("track_delete", t) ?? "No answer") },
            ]
        }
    }

    func effectsScreen(_ n: Int) -> RScreen {
        let t = String(n)
        return RScreen("Effects on track \(n)") { [unowned self] in
            let fx = Reaper.lines("fx_list", t)
            if fx.isEmpty { return [RItem(label: "No effects on this track yet") { .say("None yet. Go back and choose Add an effect.") }] }
            return fx.enumerated().map { i, name in
                RItem(label: name) {
                    .push(RScreen(name) {
                        [self.cmd("Bypass, or switch back on", "fx_bypass", t, String(i + 1)),
                         RItem(label: "Remove") { .back(Reaper.send("fx_remove", t, String(i + 1)) ?? "No answer") }]
                    })
                }
            }
        }
    }

    func addEffectScreen(_ n: Int) -> RScreen {
        let t = String(n)
        func results(_ found: [String], _ title: String) -> ROut {
            if found.isEmpty { return .say("No plug-in matches that.") }
            return .push(RScreen(title) { found.map { name in RItem(label: Reaper.spoken(name)) { .back(Reaper.send("fx_add", t, name) ?? "No answer") } } })
        }
        return RScreen("Add an effect to track \(n)") {
            stockEffects.map { name in RItem(label: name) { .back(Reaper.send("fx_add", t, name) ?? "No answer") } } +
            [RItem(label: "Search all your plug-ins by typing") { .type("Type part of the plug-in's name") { text in results(Reaper.lines("fx_search", text), "Plug-ins matching \(text)") } }]
        }
    }

    func newTrackScreen() -> RScreen {
        RScreen("New track") {
            let instruments = Reaper.lines("fx_search", "", "instrument")
            return [RItem(label: "Audio track") { .back(Reaper.send("track_new", "audio") ?? "No answer") },
                    RItem(label: "Instrument track with ReaSynth") { .back(Reaper.send("track_new", "instrument", "ReaSynth", "ReaSynth") ?? "No answer") }]
                + instruments.map { name in
                    RItem(label: "Instrument track with " + Reaper.spoken(name)) {
                        .back(Reaper.send("track_new", "instrument", Reaper.spoken(name).components(separatedBy: ",")[0], name, timeout: 20) ?? "REAPER is still loading it.")
                    }
                }
        }
    }

    // MARK: Driving the menu

    func openReaper() {
        autosaveTake()
        mode = .reaper
        waiting = false
        reaperStack = []
        run { g in
            if Opt.fast { self.lock.lock(); self.reaperStack = [self.reaperRoot()]; self.reaperStack[0].items = self.reaperStack[0].build(); self.lock.unlock(); return }
            guard Reaper.installed else { self.say("I cannot find REAPER in the Applications folder.", g); return }
            let fresh = !FileManager.default.fileExists(atPath: Reaper.resources + "/Scripts/talking_piano_bridge.lua")
            guard Reaper.installBridge() else { self.say("I could not set up the link to REAPER.", g); return }
            if !Reaper.running {
                self.say("Opening REAPER.", g)
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-g", "-a", "REAPER"])
            } else if fresh {
                self.say("The link to REAPER is installed. Quit REAPER and open it again, then come back here.", g)
                return
            }
            var answer: String? = nil
            for _ in 0..<40 where answer == nil && self.alive(g) { answer = Reaper.send("ping", timeout: 1) }
            guard self.alive(g) else { return }
            guard answer != nil else {
                self.say("REAPER is not answering. If it was already open before today, quit it and open it again so it loads the link.", g)
                return
            }
            let info = Reaper.send("info") ?? ""
            self.lock.lock()
            let root = self.reaperRoot()
            root.items = root.build()
            self.reaperStack = [root]
            self.lock.unlock()
            self.say("REAPER control. \(info)" + self.intro("reaper", " The third and fourth keys step through the list. The top key chooses. The second key goes back.") + " " + root.items[0].label + ".", g)
        }
    }

    // Returns true when the key was handled here.
    func reaperCommand(_ key: Int) -> Bool {
        guard mode == .reaper else { return false }
        guard let screen = reaperStack.last, !screen.items.isEmpty else { return [keyHear, keyNotes, keyNext, keyBack].contains(key) }
        switch key {
        case keyNext, keyBack:
            screen.idx = (screen.idx + (key == keyNext ? 1 : screen.items.count - 1)) % screen.items.count
            let label = screen.items[screen.idx].label
            let edge = screen.idx == 0 && screen.items.count > 2 ? "Top of the list. " : ""
            run { g in self.say(edge + label + ".", g) }
        case keyNotes:
            if reaperStack.count > 1 {
                reaperStack.removeLast()
                let up = reaperStack[reaperStack.count - 1]
                run { g in
                    let items = up.build()
                    self.lock.lock(); up.items = items; up.idx = min(up.idx, max(0, items.count - 1)); self.lock.unlock()
                    self.say("Back to \(up.title). " + (items.isEmpty ? "" : items[up.idx].label + "."), g)
                }
            } else {
                let title = screen.title, label = screen.items[screen.idx].label
                run { g in self.say("\(title). \(label). The second lowest white key goes home.", g) }
            }
        case keyHear:
            let item = screen.items[screen.idx]
            run { g in self.handle(item.go(), from: screen, g) }
        default: return false
        }
        return true
    }

    func handle(_ out: ROut, from screen: RScreen, _ g: Int) {
        switch out {
        case .say(let text):
            let items = screen.build()
            lock.lock(); if !items.isEmpty { screen.items = items; screen.idx = min(screen.idx, items.count - 1) }; lock.unlock()
            say(text.hasSuffix(".") ? text : text + ".", g)
        case .back(let text):
            lock.lock()
            if reaperStack.count > 1, reaperStack.last === screen { reaperStack.removeLast() }
            let up = reaperStack.last
            lock.unlock()
            let items = up?.build() ?? []
            lock.lock(); if let up = up, !items.isEmpty { up.items = items; up.idx = min(up.idx, items.count - 1) }; lock.unlock()
            say((text.hasSuffix(".") ? text : text + ".") + (up.map { " Back in \($0.title)." } ?? ""), g)
        case .push(let next):
            let items = next.build()
            guard !items.isEmpty else { say("Nothing there.", g); return }
            lock.lock(); next.items = items; next.idx = 0; reaperStack.append(next); lock.unlock()
            say("\(next.title). \(items.count) item\(items.count == 1 ? "" : "s"). \(items[0].label).", g)
        case .type(let prompt, let then):
            lock.lock()
            typing = "reaper"; naming = true; nameBytes = []
            typedThen = { text in then(text) }
            typedScreen = screen
            lock.unlock()
            if !Opt.fast {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Terminal"])
                print("\n\(prompt), then press Return (Escape cancels): ", terminator: "")
            }
            say(prompt + ", then press Return.", g)
        }
    }

    func finishReaperTyping(_ text: String) {
        guard let then = typedThen, let screen = typedScreen else { return }
        typedThen = nil
        guard !text.isEmpty else { run { g in self.say("Nothing typed.", g) }; return }
        run { g in self.handle(then(text), from: screen, g) }
    }
}

// Runs against a real REAPER if one is open with the bridge loaded; otherwise checks the menu only.
func reaperSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    check("REAPER: plug-in names are tidied for speech", Reaper.spoken("VST3i: Kontakt 8 (Native Instruments) (64 out)") == "Kontakt 8, VST3" && Reaper.spoken("VST: ReaEQ (Cockos)") == "ReaEQ, VST", Reaper.spoken("AUi: PianoOne (Yichi Wang)"))
    engine.openReaper()
    let rootOK = engine.mode == .reaper && engine.reaperStack.count == 1 && engine.reaperStack[0].items.count == 6
    engine.command(keyHear)
    let inTransport = engine.reaperStack.count == 2 && engine.reaperStack[1].title == "Transport"
    engine.command(keyNext)
    engine.command(keyNotes)
    check("REAPER: the menu opens, goes a level down and comes back", rootOK && inTransport && engine.reaperStack.count == 1, engine.reaperStack[0].items.map { $0.label }.joined(separator: ", "))
    engine.goHome()
}
