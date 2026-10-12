// The AI, kept running: one Claude session that stays open for as long as the app does.
//
// Starting the AI afresh for every sentence cost about seven seconds each time. A session
// that stays open answers in a second or two, and it remembers the conversation, so
// "make that a bit quieter" or "no, the other one" make sense. It may answer in words, or
// name something the app can do, which is then done.

import Foundation

final class AISession {
    static let shared = AISession()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let lock = NSLock()
    private var waiting: DispatchSemaphore?
    private var answer = ""
    private var turns = 0
    private(set) var signedOut = false
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true && !signedOut }

    static var persona: String { """
    You are \(Me.name), \(You.name)'s personal assistant on their Mac, with a gift for music. \(Profile.current.about.isEmpty ? "" : "About them: " + Profile.current.about + ".") \
    Everything you write is spoken aloud to them, so talk the way a person talks: short, warm, natural, with contractions, a little dry \
    humour when it fits, and no stiffness. Never sound like a manual or a call centre. Never list options unless they ask. Never mention \
    being an AI, a model or a program. No markdown, symbols, lists or emoji. One or two short sentences is nearly always right. \
    Use their name now and then. Name notes and chords in words, like E flat or F minor. If you don't know, say so plainly.

    You can also do things, not just talk. When \(You.name) wants something on this list, however they put it, do not describe it: reply with \
    exactly one line that starts with DO: followed by the command, filling the blanks from what they said. \
    Commands: new composition | play it back with the band | what did I just play | keep that | save that as <name> | \
    play me something <sad, happy, calm, epic, dreamy or hopeful> | make it a lullaby | make it a video game | make it epic | \
    play my album | jam with me | teach me <song from the library> | play <song from the library> | song menu | jazz lesson <number> | \
    ear training | metronome at <number> | metronome off | timer for <number> minutes | slower | faster | band louder | band quieter | \
    voice louder | voice quieter (these two mean your own speaking voice, not a singer) | next voice | stop | home | again | next | go back | say the notes | right hand only | left hand only | \
    both hands again | large captions | tell me a joke | surprise me | stop listening | \
    open <app name> | quit <app name> | search google for <words> | open youtube | \
    play <song, artist, album or playlist> on spotify | pause spotify | next song on spotify | what song is this on spotify | tell me about this song | restart the song | skip ahead <number> seconds | shuffle on | shuffle off | \
    play more by this artist | play this album | what album is this | \
    play <anything> on youtube | in <app name>, <what to do, in the words of that app's own menu command, for example: in Logic Pro, new audio track> | click <button name> | \
    read the window | what buttons are there | where am I | what is in the <name> menu | type <text> | read the clipboard | talk slower | talk faster | \
    <one command> and then <another command> | start with my Mac | do not start with my Mac | go to the background | show the window | open the visualizer | close the visualizer | visualize <song> | full screen | exit full screen | \
    new tab | close the tab | next tab | reload the page | scroll down | scroll up | zoom in | zoom out | remind me in <number> minutes to <thing> | \
    logic control | reaper control | play through the piano | flip a coin | roll a dice | what is in my <downloads, documents, desktop or onedrive> | open my <downloads, documents, desktop or onedrive> folder | \
    open the latest file in downloads | find the file called <name> | what is the weather tomorrow | what is the weather in <city> | \
    new project | save the project | start recording | stop recording | play the project | go to the start | undo | redo | \
    press <keys> in <app>  (for example: press command shift n in Logic Pro) | \
    click menu <menu> then <item> in <app>  (for example: click menu File then Save As in Logic Pro) | \
    and when REAPER is open: find the <track> track | list the tracks | tell me about the <track> | mute the <track> | unmute the <track> | \
    solo the <track> | set the <track> volume to <number> decibels | pan the <track> <left or right> <number> | \
    add a <compressor, eq, reverb, delay or limiter> to the <track> | remove the <plugin> from the <track> | what plugins are on the <track> | \
    what are the <plugin> settings | lower the threshold a little | set the <setting> to <number> | load the next preset | \
    duplicate the <track> and name it <name> | rename <track> to <name> | new audio track called <name> | new piano track called <name> | \
    add a little reverb to the <track> | help me prepare my <track> for mixing | set the tempo to <number> | what did you change. \
    Each message from \(You.name) begins with a line in square brackets saying what is going on right now; use it, but never read it out. \
    Any app that is open can be worked through its menus and buttons with the "in <app name>," command, so never say you cannot do something \
    inside an app: turn what they want into the menu command that does it. \
    If they ask for a song or an artist that is not in their library and does not say where, use the spotify command. \
    You can search the web. For anything current, or any fact you are not sure of (news, sports scores, who or what or when, opening hours, \
    prices, how to do something), search, then answer in one to three short spoken sentences with the actual answer. No links, no list of sources, \
    and never tell them to go and look it up themselves. \
    If they want something that is not on the list and you cannot do it, say so in a friendly sentence and, if there is something close, \
    offer that. Ask a question only when you truly cannot act without the answer.
    """ }

    var library = ""                  // the song list, told to the AI once when the session starts

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard process?.isRunning != true, !signedOut, let path = AI.path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-p", "--model", "haiku", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--system-prompt", AISession.persona + "\nSongs in their library: " + library + ".", "--allowedTools", "WebSearch,WebFetch", "--disallowedTools", "Bash,Edit,Write,Read,Agent,NotebookEdit,Glob,Grep"]
        let dir = NSTemporaryDirectory() + "talking-piano-ai"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        // A clean environment, so the session signs in as the player and not as whatever launched the app.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !["ANTHROPIC_BASE_URL", "AI_AGENT", "BAGGAGE"].contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.feed(data)
        }
        p.terminationHandler = { [weak self] _ in self?.lock.lock(); self?.waiting?.signal(); self?.lock.unlock() }
        do { try p.run(); process = p; input = inPipe.fileHandleForWriting; turns = 0; buffer = Data() } catch { process = nil }
    }

    func shutDown() { try? input?.close(); process?.terminate() }

    private func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["type"] as? String == "result" else { continue }
            answer = (obj["result"] as? String) ?? ""
            if (obj["is_error"] as? Bool) == true || answer.contains("authenticate") || answer.contains("401") { signedOut = answer.contains("authenticate") || answer.contains("401"); answer = "" }
            waiting?.signal()
        }
    }

    /// One turn of the conversation. Returns nil if the AI could not answer.
    func ask(_ question: String, state: String) -> String? {
        start()
        lock.lock()
        guard let input = input, process?.isRunning == true else { lock.unlock(); return nil }
        let sem = DispatchSemaphore(value: 0)
        waiting = sem
        answer = ""
        turns += 1
        let stale = turns > 40
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "[\(state)]\n\(question)"]]]]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { lock.unlock(); return nil }
        data.append(10)
        lock.unlock()
        do { try input.write(contentsOf: data) } catch { return nil }
        let timedOut = sem.wait(timeout: .now() + 75) == .timedOut
        lock.lock()
        let got = answer
        waiting = nil
        lock.unlock()
        // A long conversation is started afresh now and then, so it stays quick.
        if stale || timedOut { shutDown(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.start() } }
        let clean = got.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "—", with: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

extension Engine {
    /// What is going on, in a line, for the AI.
    func aiState() -> String {
        var bits: [String] = []
        if let l = lesson, mode == .teach, l.units.indices.contains(unitIdx) {
            let u = l.units[unitIdx]
            bits.append("in a lesson on \(l.song.name), part \(u.to + 1) of \(l.bounds.count), \(["right hand", "left hand", "both hands"][u.hand])")
        } else {
            bits.append(mode == .compose ? "in composition mode" : mode == .jazz ? "in the jazz course" : mode == .menu ? "in the song menu" : "nothing in particular going on")
        }
        if !Opt.fast {
            if Reaper.running { bits.append("REAPER is open") }
            if runTool("/usr/bin/pgrep", ["-xq", "Logic Pro"], timeout: 2).ok { bits.append("Logic Pro is open") }
            if !Reaper.running { bits.append("REAPER is not open, so there are no tracks to change") }
            if let front = frontApp() { bits.append("the app in front is \(front)") }
        }
        if !lastSummary.isEmpty { bits.append("their latest piece: \(lastSummary.prefix(160))") }
        if !mem.pieces.isEmpty { bits.append("\(mem.pieces.count) pieces saved") }
        let f = DateFormatter(); f.dateFormat = "EEEE h:mm a"
        bits.append(f.string(from: Date()))
        return bits.joined(separator: ". ")
    }

    func frontApp() -> String? {
        // Asked of the system's own list of running apps, which answers in a few thousandths of a second.
        let id = runTool("/usr/bin/lsappinfo", ["front"], timeout: 2).out
        let r = runTool("/usr/bin/lsappinfo", ["info", "-only", "name", id], timeout: 2)
        guard r.ok, let q = r.out.range(of: "=\"") else { return nil }
        let name = r.out[q.upperBound...].replacingOccurrences(of: "\"", with: "")
        return name.isEmpty ? nil : name
    }

    // MARK: Driving any app: keys and menus

    /// "press command shift n in Logic Pro", "click menu File then New in Logic Pro". Returns what was done, or nil.
    func macHear(_ h: Heard) -> String? {
        let needs = "I need one permission for that. Open System Settings, Privacy and Security, Accessibility, and switch on Nova."
        func target() -> String? {
            guard let name = h.after("in") else { return frontApp() }
            let asked = Heard(name)
            return appNamed(asked)?.name ?? name.capitalized
        }
        if h.starts("press", "hit", "type the shortcut"), let keysPart = h.after("press", "hit", "shortcut") {
            let keysText = keysPart.components(separatedBy: " in ")[0]
            var mods: [String] = [], key: String? = nil, code: Int? = nil
            let named: [String: Int] = ["return": 36, "enter": 36, "space": 49, "spacebar": 49, "tab": 48, "escape": 53, "delete": 51, "backspace": 51,
                                        "up": 126, "down": 125, "left": 123, "right": 124, "home": 115, "end": 119]
            for w in keysText.split(separator: " ").map(String.init) {
                switch w {
                case "command", "cmd": mods.append("command")
                case "shift": mods.append("shift")
                case "option", "alt": mods.append("option")
                case "control", "ctrl": mods.append("control")
                case "and", "plus", "key", "arrow", "the", "then": continue
                default: if let c = named[w] { code = c } else if w.count == 1 { key = w } else if let n = numberWords[w], n < 10 { key = String(n) }
                }
            }
            guard key != nil || code != nil, let app = target() else { return nil }
            run { g in
                if Opt.fast { self.say("Pressed.", g); return }
                let using = mods.isEmpty ? "" : " using {" + mods.map { $0 + " down" }.joined(separator: ", ") + "}"
                let press = code.map { "key code \($0)" } ?? "keystroke \(LogicControl.quote(key ?? ""))"
                let r = LogicControl.osa(LogicControl.front(app) + "tell application \"System Events\" to \(press)\(using)")
                self.say(r.ok ? pick(["Done.", "Pressed.", "There you go."]) : (LogicControl.denied(r.out) ? needs : "That didn't go through. Is \(app) open?"), g)
            }
            return "press \(mods.joined(separator: "+"))\(mods.isEmpty ? "" : "+")\(key ?? String(code ?? 0)) in \(app)"
        }
        if h.has("click menu", "choose menu", "from the menu", "in the menu", "menu item"), let rest = h.after("click menu", "choose menu", "menu") {
            let body = rest.components(separatedBy: " in ")[0]
            let path = body.components(separatedBy: " then ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard path.count >= 2, let app = target() else { return nil }
            run { g in
                if Opt.fast { self.say("Done.", g); return }
                // Menu names are matched without regard to capitals, and "Save As" also finds "Save As…".
                var script = LogicControl.front(app) + "tell application \"System Events\" to tell process \(LogicControl.quote(app))\n"
                script += "set theMenu to menu 1 of (first menu bar item of menu bar 1 whose name is \(LogicControl.quote(path[0].capitalized)))\n"
                for (i, name) in path.dropFirst().enumerated() {
                    let lastOne = i == path.count - 2
                    script += "set theItem to (first menu item of theMenu whose name starts with \(LogicControl.quote(name.capitalized)))\n"
                    script += lastOne ? "click theItem\n" : "set theMenu to menu 1 of theItem\n"
                }
                script += "end tell"
                let r = LogicControl.osa(script)
                self.say(r.ok ? pick(["Done.", "There."]) : (LogicControl.denied(r.out) ? needs : "I couldn't find that in \(app)'s menus."), g)
            }
            return "menu \(path.joined(separator: " > ")) in \(app)"
        }
        // A new track in Logic, through its Track menu. (In REAPER this is handled with the rest of the project.)
        if h.has("track"), h.has("new", "add", "create", "make", "another"), !h.has("menu", "volume", "mute", "solo", "rename", "delete", "remove"),
           h.has("logic") || (!Opt.fast && !Reaper.running && runTool("/usr/bin/pgrep", ["-xq", "Logic Pro"], timeout: 2).ok) {
            let audio = h.has("audio", "vocal", "vocals", "voice", "mic", "microphone", "guitar", "recording")
            let item = audio ? "New Audio Track" : "New Software Instrument Track"
            run { g in
                if Opt.fast { self.say(item + ".", g); return }
                guard runTool("/usr/bin/pgrep", ["-xq", "Logic Pro"], timeout: 2).ok else { self.say("Logic isn't open. Say open Logic first.", g); return }
                let script = LogicControl.front("Logic Pro") + """
                tell application "System Events" to tell process "Logic Pro"
                    if (count of windows) is 0 then return "no project"
                    set theItem to (first menu item of menu 1 of menu bar item "Track" of menu bar 1 whose name is \(LogicControl.quote(item)))
                    if not (enabled of theItem) then return "not available"
                    click theItem
                    return "ok"
                end tell
                """
                let r = runTool("/usr/bin/osascript", ["-e", script], timeout: 15)
                let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if r.ok && out == "ok" { self.say(audio ? "A new audio track is in your Logic project." : "A new software instrument track is in your Logic project, ready to play.", g) }
                else if out == "no project" { self.say("Logic has no project open. Say new project in Logic first.", g) }
                else if out == "not available" { self.say("Logic won't let me add a track right now. A dialog may be open.", g) }
                else {
                    self.noteMistake("a studio action failed", "new track in Logic: \(out.prefix(120))")
                    self.say(LogicControl.denied(out) ? needs : "I couldn't find that in Logic's Track menu.", g)
                }
            }
            return "logic track \(audio ? "audio" : "instrument")"
        }
        // A new project, in whichever music program is open.
        if h.has("new project", "new session", "new song file", "blank project", "empty project", "fresh project") {
            run { g in
                if Opt.fast { self.say("A new project.", g); return }
                let front = self.frontApp() ?? ""
                let logicOpen = runTool("/usr/bin/pgrep", ["-xq", "Logic Pro"], timeout: 2).ok
                if Reaper.running, front == "REAPER" || !logicOpen {
                    _ = Reaper.send("action", "40023")
                    self.say("A new project in REAPER. If the old one had changes, REAPER is asking whether to save them.", g)
                } else if logicOpen {
                    let r = LogicControl.logicNewProject()
                    let f = r.out.components(separatedBy: "|")
                    if !r.ok || f.first != "ok" {
                        self.noteMistake("a studio action failed", "new project in Logic: \(r.out.prefix(120))")
                        self.say(LogicControl.denied(r.out) ? needs : "I couldn't reach Logic's File menu, so no new project was started.", g)
                    } else {
                        // Only say what Logic is really showing.
                        func part(_ i: Int) -> String { f.count > i ? f[i].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
                        let first = Int(part(1)) ?? 0, nowCount = Int(part(2)) ?? 0
                        let name = part(4).components(separatedBy: " - ")[0]
                        let asking = part(5)
                        if !asking.isEmpty {
                            self.say(asking == "a dialog" ? "Logic is asking something before it carries on, probably about the project that's already open. I've left that for you to answer."
                                     : "Logic is asking something before it carries on. It says: \(String(asking.prefix(120))) I've left that for you to answer.", g)
                        } else if part(3) == "1" {
                            self.say(name.isEmpty ? "A new project is open in Logic, with a track ready to play." : "A new project is open in Logic, called \(name), with a track ready to play.", g)
                        } else if nowCount > first {
                            self.say("A new project is open in Logic.", g)
                        } else {
                            self.noteMistake("a studio action failed", "new project in Logic: menu clicked, nothing changed (\(r.out.prefix(80)))")
                            self.say("I chose New in Logic's File menu, but I can't see a new project. Logic may be waiting on another window.", g)
                        }
                    }
                } else {
                    self.say("Open Logic or REAPER first, and I'll start a project.", g)
                }
            }
            return "new project"
        }
        return nil
    }
}
