// What makes the tool feel less like a machine: a spoken home menu, an AI that can be
// asked anything and that comments on compositions, remarks on free playing, and a mode
// that drives Logic Pro from the piano.

import Foundation

// MARK: - Running helper programs

func runTool(_ path: String, _ args: [String], input: String? = nil, timeout: Double = 20, cwd: String? = nil) -> (ok: Bool, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = out
    p.standardInput = inp
    do { try p.run() } catch { return (false, "could not start") }
    if let s = input { inp.fileHandleForWriting.write(Data(s.utf8)) }
    try? inp.fileHandleForWriting.close()
    let deadline = DispatchTime.now() + timeout
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
    if done.wait(timeout: deadline) == .timedOut { p.terminate(); return (false, "timed out") }
    p.waitUntilExit()
    return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - AI

// Uses the Claude command-line tool that is already on this Mac, signed in with the
// player's own Claude account. Nothing is sent anywhere unless a question is asked.
enum AI {
    static let paths = ["/opt/homebrew/bin/claude", NSHomeDirectory() + "/.local/bin/claude", "/usr/local/bin/claude"]
    // (NOVA_AI=local makes it behave as on a Mac without Claude Code, for checking the built-in model.)
    static var path: String? {
        let env = ProcessInfo.processInfo.environment
        if env["NOVA_AI"] == "local" { return nil }
        if let test = env["NOVA_AI_PATH"], FileManager.default.isExecutableFile(atPath: test) { return test }     // a stand-in, for tests
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var persona: String { """
    You are \(Me.name), the voice of a music assistant for \(You.name). \(Profile.current.about.isEmpty ? "" : "About them: " + Profile.current.about + ".") Your words are spoken aloud. Answer in plain sentences with no lists, symbols, markdown or emoji. Keep to \
    two or three short sentences unless asked for more. Be warm, direct and specific, like a good teacher who is also a \
    friend. Name notes and chords in words, such as E flat or F minor. If you are unsure, say so.

    You can also make the app act. If \(You.name) is asking for something on this list, however they word it, do not explain: reply with \
    one line only, starting with DO: and then the command, with the blank filled in from what they said. \
    Commands: new composition | play it back with the band | what did I just play | keep that | save that as <name> | \
    play me something <sad, happy, calm, epic, dreamy or hopeful> | make it a lullaby | make it a video game | make it epic | \
    play my album | jam with me | teach me <song from the library> | play <song from the library> | song menu | jazz lesson <number> | \
    ear training | metronome at <number> | metronome off | timer for <number> minutes | slower | faster | band louder | band quieter | \
    voice louder | voice quieter | next voice | open <app name> | search google for <words> | stop | home | again | next | go back | \
    say the notes | right hand only | left hand only | both hands again | large captions | tell me a joke | surprise me | \
    and, when REAPER is open: find the <track> track | list the tracks | mute the <track> | unmute the <track> | \
    set the <track> volume to <number> decibels | add a <compressor, eq, reverb, delay or limiter> to the <track> | \
    what plugins are on the <track> | lower the threshold a little | duplicate the <track> and name it <name> | undo | start recording. \
    If what they want is not on the list, answer in one or two short sentences. Ask a question only when you cannot act without the answer.
    """ }

    // Returns the answer, or a sentence explaining what the player needs to do.
    static func ask(_ question: String, context: String) -> String {
        if path == nil || AISession.shared.signedOut, let local = LocalAI.ask(question, instructions: persona + "\n\nWhat you know right now:\n" + context) {
            return local.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
        }
        guard let path = path else { return "The AI is not signed in yet." }
        let dir = NSTemporaryDirectory() + "talking-piano-ai"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let r = runTool(path, ["-p", "--model", "haiku", "--system-prompt", persona + "\n\nWhat you know right now:\n" + context,
                               "--disallowedTools", "Bash,Edit,Write,Read,WebFetch,WebSearch,Agent"],
                        input: question, timeout: 60, cwd: dir)
        if r.out.contains("authenticate") || r.out.contains("401") || r.out.contains("/login") {
            return "The AI is not signed in yet. Open a Terminal window, type claude, press Return, and sign in with your Claude account. After that I can answer."
        }
        if !r.ok || r.out.isEmpty { return "I could not reach the AI just now." }
        return r.out.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
    }
}

// MARK: - Logic Pro control

enum LogicControl {
    static func osa(_ script: String) -> (ok: Bool, out: String) { runTool("/usr/bin/osascript", ["-e", script], timeout: 12) }
    static func denied(_ out: String) -> Bool { out.contains("assistive") || out.contains("-1719") || out.contains("-25211") || out.contains("not allowed") || out.contains("-1743") }
    static let needPermission = "I need one permission for that. Open System Settings, Privacy and Security, Accessibility, and switch on Nova."
    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    /// AppleScript that brings an app forward and waits until it really is in front. A key
    /// pressed too soon lands in whatever was in front before, which only makes a beep.
    static func front(_ app: String) -> String {
        """
        tell application \(quote(app)) to activate
        tell application "System Events"
            repeat 40 times
                if frontmost of process \(quote(app)) then exit repeat
                delay 0.05
            end repeat
        end tell
        delay 0.15

        """
    }

    /// Starts a new project in Logic through its File menu. Logic then asks what kind of track
    /// to begin with; its own suggestion is accepted, so a project is really open at the end.
    /// Returns: "ok|<windows at first>|<windows now>|<1 if Create was pressed>|<front window>|<anything still asking>".
    static let newProjectScript = """
        tell application "System Events" to tell process "Logic Pro"
            set countAtFirst to count of windows
            click (first menu item of menu 1 of menu bar item "File" of menu bar 1 whose name starts with "New")
            set pressedCreate to "0"
            repeat 30 times
                delay 0.2
                repeat with w in windows
                    try
                        if exists button "Create" of group 1 of sheet 1 of w then
                            click button "Create" of group 1 of sheet 1 of w
                            set pressedCreate to "1"
                            exit repeat
                        end if
                    end try
                end repeat
                if pressedCreate is "1" then exit repeat
            end repeat
            delay 1.2
            set countNow to count of windows
            set frontName to ""
            try
                set frontName to name of window 1 as text
            end try
            set stillAsking to ""
            repeat with w in windows
                try
                    if (count of sheets of w) > 0 then
                        repeat with t in (static texts of group 1 of sheet 1 of w)
                            try
                                set stillAsking to stillAsking & (name of t as text) & ". "
                            end try
                        end repeat
                        if stillAsking is "" then set stillAsking to "a dialog"
                    end if
                end try
            end repeat
            return "ok|" & countAtFirst & "|" & countNow & "|" & pressedCreate & "|" & frontName & "|" & stillAsking
        end tell
        """

    static func logicNewProject() -> (ok: Bool, out: String) {
        runTool("/usr/bin/osascript", ["-e", front("Logic Pro") + newProjectScript], timeout: 25)
    }

    // Presses a key in Logic. `mods` is a list such as ["command", "option"].
    static func key(_ key: String, code: Int? = nil, mods: [String] = []) -> (ok: Bool, out: String) {
        let using = mods.isEmpty ? "" : " using {" + mods.map { $0 + " down" }.joined(separator: ", ") + "}"
        let press = code.map { "key code \($0)" } ?? "keystroke \(quote(key))"
        return osa(front("Logic Pro") + "tell application \"System Events\" to \(press)\(using)")
    }

    // The AppleScript reference for the menu at a path such as ["Track", "Other"].
    static func menuRef(_ path: [String]) -> String {
        var ref = "menu 1 of menu bar item \(quote(path[0])) of menu bar 1"
        for name in path.dropFirst() { ref = "menu 1 of menu item \(quote(name)) of " + ref }
        return ref
    }

    static func list(_ path: [String]) -> (ok: Bool, out: String) {
        let items = path.isEmpty ? "menu bar items of menu bar 1" : "menu items of \(menuRef(path))"
        return osa("""
        tell application "System Events" to tell process "Logic Pro"
            set out to ""
            repeat with i in (\(items))
                set n to name of i
                if n is not missing value then set out to out & n & linefeed
            end repeat
            return out
        end tell
        """)
    }

    static func hasSubmenu(_ path: [String], _ item: String) -> Bool {
        osa("tell application \"System Events\" to tell process \"Logic Pro\" to return exists menu 1 of menu item \(quote(item)) of \(menuRef(path))").out == "true"
    }

    static func click(_ path: [String], _ item: String) -> (ok: Bool, out: String) {
        osa("tell application \"Logic Pro\" to activate\ntell application \"System Events\" to tell process \"Logic Pro\" to click menu item \(quote(item)) of \(menuRef(path))")
    }
}

// The quick list in Logic mode. Each uses Logic's standard key command.
let logicQuick: [(name: String, key: String, code: Int?, mods: [String])] = [
    ("Play or stop", " ", 49, []),
    ("Record", "r", nil, []),
    ("Go to the beginning", "", 36, []),
    ("Undo", "z", nil, ["command"]),
    ("Next track", "", 125, []),
    ("Previous track", "", 126, []),
    ("New software instrument track", "s", nil, ["command", "option"]),
    ("New audio track", "a", nil, ["command", "option"]),
    ("Mute this track", "m", nil, []),
    ("Solo this track", "s", nil, []),
    ("Metronome on or off", "k", nil, []),
    ("Cycle on or off", "c", nil, []),
    ("Open or close the mixer", "x", nil, []),
    ("Open or close the library, to choose a sound", "y", nil, []),
    ("Save", "s", nil, ["command"]),
]

extension Engine {
    // MARK: Home menu

    var homeItems: [String] {
        let song = songs.indices.contains(songIdx) ? songs[songIdx].name : "a song"
        return ["Lesson: \(song)", "Song menu", "Jazz course", "Composition", "Ask me anything", "REAPER control", "Logic control", "Talk mode"]
    }

    // At home, the third and fourth keys step through everything the tool can do, and
    // the top key opens the one just named. Returns true when the key was handled.
    func homeCommand(_ key: Int) -> Bool {
        guard mode == .idle else { return false }
        if earTarget != nil, key == keyHear { playEar(); return true }   // in the ear game, the top key plays the note again
        switch key {
        case keyNext, keyBack:
            homeIdx = (homeIdx + (key == keyNext ? 1 : homeItems.count - 1)) % homeItems.count
            let name = homeItems[homeIdx]
            run { g in self.say(name + ".", g) }
        case keyNotes:
            let list = homeItems.joined(separator: ". ")
            run { g in self.say("From home you can open: " + list + ". Step through them with the third and fourth keys, and open one with the top key.", g) }
        case keyHear:
            let pickIdx = homeIdx
            homeIdx = 0
            switch pickIdx {
            case 1: openMenu()
            case 2: startJazz(mem.jazzLesson ?? 0)
            case 3: command(keyCompose)
            case 4: startAsk()
            case 5: openReaper()
            case 6: openLogic()
            case 7: command(keyTalk)
            default: chooseSong(songIdx)
            }
        default: return false
        }
        return true
    }

    // MARK: Asking the AI

    // A plain description of what is going on, so the AI can answer about it.
    func aiContext() -> String {
        var lines = ["Modes: lessons (songs taught a few notes at a time), jazz course (nine lessons), composition (band playback, describe, variations, save), Logic control, talk mode."]
        lines.append("Piano buttons, counting white keys down from the top key: 1 start or hear again, 2 say the notes or describe, 3 next, 4 back, 5 talk mode (learn an idea in composition mode), 6 pause or stop, 7 new composition, 8 help. The lowest key keeps what was just played. The white key next to it is home. At home, keys 3 and 4 step through the modes and key 1 opens one. Holding key 1 opens the song menu.")
        if let l = lesson, mode == .teach, l.units.indices.contains(unitIdx) {
            let u = l.units[unitIdx]
            lines.append("Right now: a lesson on \(l.song.name), part \(u.to + 1) of \(l.bounds.count), \(["right hand", "left hand", "both hands"][u.hand]). The notes of this part: \(l.describe(curSteps))")
        } else {
            lines.append("Right now: \(mode == .compose ? "composition mode" : mode == .jazz ? "jazz mode" : mode == .logic ? "Logic control" : mode == .reaper ? "REAPER control" : "at home").")
        }
        if let j = jazzIdx ?? mem.jazzLesson, jazzLessons.indices.contains(j) { lines.append("Jazz course: on lesson \(j + 1), \(jazzLessons[j].title).") }
        if !lastSummary.isEmpty { lines.append("His most recent composition: \(lastSummary)") }
        if !mem.pieces.isEmpty { lines.append("He has saved \(mem.pieces.count) pieces. Recent keys: \(mem.pieces.suffix(4).map { $0.key }.joined(separator: ", ")).") }
        lines.append("Songs in the library include: \(songs.filter { $0.level >= 2 }.prefix(14).map { $0.name }.joined(separator: "; ")).")
        return lines.joined(separator: "\n")
    }

    func startAsk() {
        typing = "ask"
        naming = true
        nameBytes = []
        if !Opt.fast {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Terminal"])
            print("\nType to \(Me.name), then press Return (Escape cancels): ", terminator: "")
        }
        run { g in self.say("Type a command or a question, then press Return.", g) }
    }

    func finishAsk(_ question: String) {
        guard !question.isEmpty else { run { g in self.say("No question.", g); self.resumeAfterHelp(g) }; return }
        let session = AISession.shared
        let oneShot = aiContext() + (talk.isEmpty ? "" : "\nThe conversation so far:\n" + talk.suffix(6).joined(separator: "\n"))
        run { g in
            // The session that stays open answers in a second or two. A short word first only when it is slow.
            // If the answer takes more than a moment, a soft note says "I heard you, I'm thinking".
            var thinking = true
            ui("think 1")
            defer { ui("think 0") }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) { if thinking, Engine.effects, self.alive(g) { self.chime([79, 84], vel: 34, hold: 0.25) } }
            var answer = ""
            var said = 0                     // how much of the arriving answer has already been spoken
            var streamed = ""                // everything that arrived, as it arrived
            if !Opt.fast {
                // The answer is spoken a sentence at a time while the rest is still being written.
                let feed = AnswerStream()
                let state = self.aiState()
                DispatchQueue.global(qos: .userInitiated).async {
                    let got = session.ask(question, state: state, onText: { feed.text($0) }, onTool: { feed.tool($0) })
                    feed.finish(got)
                }
                var filled = false
                let started = now()
                while true {
                    let step = feed.next(timeout: 0.12)
                    guard self.alive(g) else { return }
                    streamed = step.text
                    if let tool = step.tool {
                        ui("status " + Engine.toolStatus(tool))
                        if !filled, said == 0 { filled = true; thinking = false; self.say(Engine.filler(for: tool), g) }
                    }
                    let body = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A command is done, not read out: wait for all of it.
                    if body.hasPrefix("DO") || (said == 0 && body.contains("DO:")) { if step.done { answer = step.final ?? body; break }; continue }
                    if step.done { answer = step.final ?? body; break }
                    guard body.count >= 4 else { continue }     // too short yet to know it isn't a command
                    while let end = Engine.sentenceEnd(in: streamed, from: said) {
                        let piece = AISession.tidy(String(streamed.utf16Slice(said, end)))
                        said = end
                        if !piece.isEmpty { thinking = false; ui("status "); self.say(piece, g) }
                        guard self.alive(g) else { return }
                    }
                    if !filled, said == 0, now() - started > 4.5 {
                        filled = true; thinking = false
                        self.say(pick(["Let me look that up.", "Give me a moment, I'm checking.", "Looking into it."]), g)
                    }
                }
                ui("status ")
            }
            thinking = false
            guard self.alive(g) else { return }
            if answer.isEmpty, !Opt.fast {
                if !self.warnedNoAI { self.say(pick(["Let me think.", "One moment.", "Thinking."]), g) }
                answer = AI.ask(question, context: oneShot)
                guard self.alive(g) else { return }
            }
            if answer.hasPrefix("The AI is not signed in") {
                // Say how to sign in once; after that, just admit the sentence was not understood.
                answer = self.warnedNoAI ? pick(["Sorry, I didn't catch what you wanted there.", "I'm not sure what you meant. Say it another way?"])
                    : BuiltInAI.installing ? "My brain is still downloading, \(BuiltInAI.progress.isEmpty ? "just starting" : BuiltInAI.progress). Until it's here I can only follow requests I know."
                    : "I can't answer that yet, because my brain isn't installed. Say install your brain: it's a one time download of about a gigabyte, and then I can answer anything, with no internet needed."
                self.warnedNoAI = true
            }
            // The AI may name one of the things the app can do. Then it is done, not talked about.
            if let r = answer.range(of: "DO:") {
                let wanted = answer[r.upperBound...].components(separatedBy: "\n")[0].trimmingCharacters(in: CharacterSet(charactersIn: " .\"'`*"))
                // A guess that shares no real word with what was said is asked about, not done: overheard
                // talk and misheard words must never turn into a random action.
                if !wanted.isEmpty, !Engine.related(question, wanted), !Opt.fast {
                    // A guess that shares no word with what was said is usually wrong ("pop song" is not "epic"),
                    // and asking about it only gets in the way. Say so plainly instead, with the nearest thing that does exist.
                    self.noteMistake("the AI guessed something unrelated, so I said I wasn't sure", "\"\(question)\" as \"\(wanted)\"")
                    let near = self.closest(Heard(question))
                    self.say(near.map { "I'm not sure I can do that. The closest I have is: \($0.ask)." } ?? pick(["I'm not sure how to do that one yet.", "I didn't quite follow that one. Could you put it another way?"]), g)
                    return
                }
                self.lock.lock()
                self.aiRouting = true
                let done = wanted.isEmpty ? "ask" : self.hear(wanted)
                self.aiRouting = false
                self.lock.unlock()
                if done != "ask" {
                    // Remember what this way of saying it meant, so next time there is no wait.
                    // (Not from two or three words: those are usually a sentence that was cut short.)
                    if question.split(separator: " ").count >= 4 { self.lock.lock(); self.learn(question, means: wanted); self.lock.unlock() }
                    self.noteMistake("the AI explained", "\"\(question)\" meant \"\(wanted)\"")
                    self.talk += ["\(You.name): \(question)", "You did: \(wanted)"]
                    return
                }
                self.noteMistake("the AI named something the app could not do", "\"\(question)\" as \"\(wanted)\"")
                answer = pick(["I know what you're after, but I can't do that one yet.", "That's beyond me for now, sorry."])
            }
            self.talk += ["\(You.name): \(question)", "You: \(answer)"]
            if self.talk.count > 12 { self.talk.removeFirst(self.talk.count - 12) }
            print(answer + "\n")
            // A question back to him can be answered without saying the name again.
            if answer.hasSuffix("?") { self.ears.expectAnswer() }
            // Whatever was not already spoken while it arrived.
            let rest = said > 0 ? AISession.tidy(String(streamed.utf16Slice(said, streamed.utf16.count))) : answer
            if !rest.isEmpty { self.say(rest, g) }
            if answer.hasSuffix("?") { self.ears.expectAnswer() }
            self.resumeAfterHelp(g)
        }
    }

    // A second opinion on a composition, from the AI, after the plain facts.
    func aiThoughts(_ summary: String) {
        let context = aiContext()
        run { g in
            self.say(pick(["Let me think about it.", "Give me a moment with it."]), g)
            let answer = AI.ask("Here is what I just played: \(summary) Tell me what stands out musically about it, in the feeling it creates, and give me one concrete idea for where to take it next. Three sentences at most.", context: context)
            guard self.alive(g) else { return }
            self.say(answer, g)
        }
    }

    // MARK: Remarks on free playing

    // At home, after a good stretch of playing and a pause, one short remark. Rarely.
    func armRemark() {
        if Opt.fast { return }
        remarkToken += 1
        let token = remarkToken
        DispatchQueue.global().asyncAfter(deadline: .now() + 4.5) {
            self.lock.lock(); defer { self.lock.unlock() }
            guard token == self.remarkToken, self.mode == .idle, !self.paused, now() - self.lastRemark > 120 else { return }
            let stretch = self.lastStretch()
            guard stretch.count >= 24 else { return }
            self.lastRemark = now()
            let a = analyse(stretch)
            let colour = insights(a, earlier: []).first { $0.contains("borrowed") || $0.contains("Dorian") || $0.contains("loop") }
            let opener = pick(["That was in \(a.keyName).", "\(a.keyName). I liked that.", "I was listening. \(a.keyName)."])
            let offer = pick([" The lowest key keeps it.", " Press the lowest key if you want to keep it.", " The seventh key turns it into a composition."])
            self.run { g in self.say(opener + (colour.map { " " + $0 } ?? "") + offer, g) }
        }
    }

    // MARK: Logic control

    func openLogic() {
        autosaveTake()
        mode = .logic
        waiting = false
        logicPath = nil
        logicIdx = 0
        logicItems = logicQuick.map { $0.name } + ["All of Logic's menus"]
        run { g in
            self.say("Logic control." + self.intro("logic", " The third and fourth keys step through commands. The top key does the one you heard. The second key goes back a level. The last item opens every menu in Logic. Start with: ") + " " + self.logicItems[0] + ".", g)
        }
    }

    // Returns true when the key was handled here.
    func logicCommand(_ key: Int) -> Bool {
        guard mode == .logic, !logicItems.isEmpty else { return false }
        switch key {
        case keyNext, keyBack:
            logicIdx = (logicIdx + (key == keyNext ? 1 : logicItems.count - 1)) % logicItems.count
            let name = logicItems[logicIdx]
            run { g in self.say(name + ".", g) }
        case keyNotes:
            // Up one level, or back to the quick list.
            if var path = logicPath, !path.isEmpty {
                path.removeLast()
                loadLogicMenu(path, entering: nil)
            } else {
                openLogic()
            }
        case keyHear:
            let name = logicItems[logicIdx]
            if let path = logicPath {
                let menuPath = path
                run { g in
                    if !path.isEmpty, !LogicControl.hasSubmenu(menuPath, name) {
                        let r = LogicControl.click(menuPath, name)
                        self.say(r.ok ? "Done: \(name)." : (LogicControl.denied(r.out) ? LogicControl.needPermission : "Logic would not do that right now. It may be greyed out."), g)
                    } else {
                        self.lock.lock(); self.loadLogicMenu(menuPath + [name], entering: name); self.lock.unlock()
                    }
                }
            } else if logicIdx == logicQuick.count {
                loadLogicMenu([], entering: "All menus")
            } else {
                let q = logicQuick[logicIdx]
                run { g in
                    let r = Opt.fast ? (ok: true, out: "") : LogicControl.key(q.key, code: q.code, mods: q.mods)
                    self.say(r.ok ? q.name + "." : (LogicControl.denied(r.out) ? LogicControl.needPermission : "That did not work. Is Logic open?"), g)
                }
            }
        default: return false
        }
        return true
    }

    func loadLogicMenu(_ path: [String], entering: String?) {
        let r = Opt.fast ? (ok: true, out: "File\nEdit\nTrack") : LogicControl.list(path)
        let names = r.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty && $0 != "Apple" }
        guard r.ok, !names.isEmpty else {
            let why = LogicControl.denied(r.out) ? LogicControl.needPermission : "I could not read Logic's menus. Is Logic open?"
            run { g in self.say(why, g) }
            return
        }
        logicPath = path
        logicItems = names
        logicIdx = 0
        let head = entering.map { "\($0). \(names.count) items. " } ?? "Back. "
        run { g in self.say(head + names[0] + ".", g) }
    }
}

func aliveSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    engine.goHome()
    engine.command(keyNext)
    let stepped = engine.homeIdx == 1
    engine.command(keyHear)
    check("home menu: step to an item and open it from the piano", stepped && engine.mode == .menu, engine.homeItems.joined(separator: ", "))
    engine.goHome()
    for _ in 0..<6 { engine.command(keyNext) }
    engine.command(keyHear)
    let inLogic = engine.mode == .logic && engine.logicItems.count == logicQuick.count + 1
    engine.command(keyBack)
    engine.command(keyHear)
    check("Logic control: quick commands, then into the menus", inLogic && engine.logicPath != nil && engine.logicItems == ["File", "Edit", "Track"], LogicControl.menuRef(["Track", "Other"]))
    engine.command(keyNotes)
    check("Logic control: the second key goes back to the quick list", engine.logicPath == nil && engine.mode == .logic, "")
    engine.goHome()
    check("AI: knows the context it will be asked about", engine.aiContext().contains("home") && AI.persona.contains("spoken aloud"), AI.path ?? "claude tool not found")
}


/// An AI answer as it arrives: the text so far, any search it started, and whether it is finished.
final class AnswerStream {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var body = "", tools: [String] = [], finished = false, last: String?
    func text(_ t: String) { lock.lock(); body = t; lock.unlock(); signal.signal() }
    func tool(_ name: String) { lock.lock(); tools.append(name); lock.unlock(); signal.signal() }
    func finish(_ final: String?) { lock.lock(); finished = true; last = final; lock.unlock(); signal.signal() }
    func next(timeout: Double) -> (text: String, tool: String?, done: Bool, final: String?) {
        _ = signal.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        let t = tools.isEmpty ? nil : tools.removeFirst()
        return (body, t, finished, last)
    }
}

extension String {
    /// The text between two UTF-16 offsets.
    func utf16Slice(_ from: Int, _ to: Int) -> Substring {
        let u = utf16
        let a = u.index(u.startIndex, offsetBy: min(from, u.count)), b = u.index(u.startIndex, offsetBy: min(max(from, to), u.count))
        return self[(String.Index(a, within: self) ?? startIndex)..<(String.Index(b, within: self) ?? endIndex)]
    }
}

extension Engine {
    /// Where the next whole sentence ends (a UTF-16 offset), if one has arrived after `from`.
    static func sentenceEnd(in text: String, from: Int) -> Int? {
        let u = Array(text.utf16)
        var i = from
        while i < u.count - 1 {
            let c = u[i], n = u[i + 1]
            // . ! ? followed by a space or new line ends a sentence; so does a new line on its own.
            let stop = (c == 46 || c == 33 || c == 63) && (n == 32 || n == 10)
            if (stop && i + 1 - from >= 12) || (c == 10 && i - from >= 12) {
                // Not "Mr." or "Dr." or "e.g." (a short word before the full stop).
                var j = i - 1; while j > from, u[j] != 32 { j -= 1 }
                let word = String(utf16CodeUnits: Array(u[(j + 1)..<i]), count: i - j - 1).lowercased()
                if c == 46, ["mr", "mrs", "ms", "dr", "st", "vs", "e.g", "i.e", "etc", "no"].contains(word) { i += 1; continue }
                return i + 1
            }
            i += 1
        }
        return nil
    }
    /// What it says the moment a search starts, so a few seconds of work never sound like silence.
    static func filler(for tool: String) -> String {
        switch tool {
        case "WebSearch": return pick(["Searching.", "Looking that up.", "Checking now."])
        case "WebFetch": return pick(["Reading the page.", "Opening it up."])
        default: return pick(["Working on it.", "One moment."])
        }
    }
    static func toolStatus(_ tool: String) -> String {
        switch tool {
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Reading a page"
        default: return "Working"
        }
    }
}
