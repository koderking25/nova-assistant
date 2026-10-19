// More that can be asked for: the visualiser and the window, the browser's tabs, and the
// buttons that until now could only be pressed.

import Foundation

extension Engine {
    /// A MIDI file whose name matches the words: one of the Nova Songs songs, or one of the player's own pieces.
    func midiFileNamed(_ h: Heard) -> URL? {
        let skip: Set<String> = ["visualize", "visualise", "visualizer", "visualiser", "visuals", "in", "the", "show", "me", "play", "mode", "open", "with", "on", "of", "my", "piece", "song", "file",
                                 "midi", "a", "and", "light", "to", "it", "for", "please", "can", "you", "as", "start", "put", "up", "watch", "see", "called", "named"]
        let want = h.words.filter { !skip.contains($0) && $0.count > 1 }
        guard !want.isEmpty else { return nil }
        var best: (URL, Double)? = nil
        for dir in [NSHomeDirectory() + "/Music/Nova Songs", baseDir.appendingPathComponent("ideas").path] {
            guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk where ["mid", "midi"].contains(url.pathExtension.lowercased()) {
                let name = Set(Heard(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")).words)
                let hits = want.filter { name.contains($0) }.count
                guard hits == want.count || (hits >= 2 && Double(hits) / Double(want.count) >= 0.6) else { continue }
                let score = Double(hits) / Double(want.count) + Double(hits) / Double(max(1, name.count)) * 0.5
                if best == nil || score > best!.1 { best = (url, score) }
            }
        }
        return best?.0
    }

    func windowHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        // The visualiser: playing shown as rising light, filling the window.
        if h.has("visualizer", "visualiser", "visualize", "visualise", "visuals", "light show", "falling notes", "visualization", "visualisation") {
            if h.has("close", "exit", "leave", "off", "hide", "stop", "quit", "out of", "back to normal") {
                ui("window visual 0"); reply("Visualiser closed."); return "visual off"
            }
            if !Opt.fast, let file = midiFileNamed(h) {
                ui("window visual 1")
                playFile(file.path)
                return "visual play \(file.deletingPathExtension().lastPathComponent)"
            }
            ui("window visual 1")
            reply(pick(["The visualiser is open. Play something, and your notes rise as light.", "Visualiser on. Everything you play shows as rising light."]) + " Say close the visualiser to come back.")
            return "visual on"
        }
        // How fast it talks.
        let slower = h.has("talk slower", "speak slower", "speak more slowly", "talk more slowly", "slow your voice", "talk too fast", "talking too fast", "speak too fast", "slower voice", "slow down your voice", "too fast for me")
        let faster = h.has("talk faster", "speak faster", "speak more quickly", "talk more quickly", "talk too slow", "talking too slow", "talk too slowly", "faster voice", "speed up your voice")
        if slower || faster || h.has("normal voice speed", "normal talking speed", "talk at normal speed", "normal speaking speed") {
            // Up to twice as fast: people who use a screen reader often listen at speed.
            let quick = h.has("much faster", "a lot faster", "way faster", "fastest", "as fast as you can")
            Kokoro.rate = slower ? max(0.6, Kokoro.rate - 0.12) : faster ? min(2.0, Kokoro.rate + (quick ? 0.4 : 0.15)) : 1
            if !Opt.fast { try? String(format: "%.2f", Kokoro.rate).write(to: Kokoro.rateFile, atomically: true, encoding: .utf8) }
            let edge = Kokoro.rate <= 0.6 ? " That's as slow as I go." : Kokoro.rate >= 2.0 ? " That's as fast as I go." : ""
            reply((slower ? "I'll talk more slowly." : faster ? "I'll talk faster." : "Back to my normal pace.") + edge)
            return slower ? "voice slower" : faster ? "voice faster" : "voice pace"
        }
        if h.has("slowly") && h.has("repeat that", "say that again", "say it again", "repeat", "again") && !lastSpoken.isEmpty {
            let again = lastSpoken, usual = Kokoro.rate
            run { g in Kokoro.rate = usual * 0.78; self.say(again, g); Kokoro.rate = usual }
            return "repeat slowly"
        }
        // Running out of sight, like Siri: start with the Mac, hide the window, bring it back.
        if h.has("start with my mac", "start with the mac", "start when i log in", "start at login", "start automatically", "open at login", "launch at startup", "start at startup", "start on startup",
                 "start by yourself", "always run in the background", "run in the background all the time", "always be running", "start when my mac starts", "start when the mac starts", "open automatically") {
            let off = h.has("dont", "do not", "stop", "never", "no longer", "not")
            if Opt.fast { reply(off ? "Okay." : "Done."); return off ? "login off" : "login on" }
            ui("window login \(off ? 0 : 1)")
            return off ? "login off" : "login on"
        }
        if h.has("hide the window", "hide yourself", "hide", "go to the background", "go into the background", "run in the background", "close the window", "close your window", "minimize", "minimise", "get out of the way", "go away") && h.words.count <= 6 && !h.has("track", "plugin", "tab") {
            ui("window show 0"); reply(pick(["I'll be in the background. Just say my name.", "Out of the way. Say \(Me.name) when you need me."])); return "window hide"
        }
        if h.has("show the window", "open the window", "open your window", "show yourself", "show your window", "come back", "open the dashboard", "show the dashboard", "open jarvis", "bring the window back", "show me the window") {
            ui("window show 1"); reply("Here I am."); return "window show"
        }
        if h.has("full screen", "fullscreen", "fill the screen", "fill the whole screen", "make the window bigger", "maximize", "maximise") {
            let off = h.has("exit", "leave", "off", "close", "stop", "out of", "no")
            ui("window full \(off ? 0 : 1)"); reply(off ? "Back to a normal window." : "Full screen."); return off ? "full off" : "full on"
        }
        if h.has("normal window", "smaller window", "make the window smaller") { ui("window full 0"); reply("Back to a normal window."); return "full off" }
        // Buttons that had no words.
        if h.has("logic control", "logic menu", "logic menus", "control logic") { openLogic(); return "logic" }
        if h.has("reaper control", "reaper menu", "control reaper") { openReaper(); return "reaper" }
        if h.has("through the piano", "piano speakers", "pianos speakers", "pianos own sound") { stdinKey("p"); return "to piano" }
        // The browser: tabs, scrolling, zoom.
        let keys: [(say: [String], key: String?, code: Int?, mods: [String], done: String)] = [
            (["new tab", "open a tab", "another tab"], "t", nil, ["command"], "A new tab"),
            (["reopen the tab", "reopen tab", "bring that tab back", "reopen that tab"], "t", nil, ["command", "shift"], "Reopened the last tab"),
            (["close the tab", "close this tab", "close tab", "close that tab"], "w", nil, ["command"], "Closed the tab"),
            (["next tab"], nil, 48, ["control"], "Next tab"),
            (["previous tab", "last tab"], nil, 48, ["control", "shift"], "Previous tab"),
            (["reload", "refresh", "reload the page", "refresh the page"], "r", nil, ["command"], "Reloaded"),
            (["scroll down", "page down"], nil, 49, [], "Scrolled down"),
            (["scroll up", "page up"], nil, 49, ["shift"], "Scrolled up"),
            (["top of the page", "scroll to the top", "back to the top"], nil, 126, ["command"], "At the top"),
            (["bottom of the page", "scroll to the bottom"], nil, 125, ["command"], "At the bottom"),
            (["zoom in", "make the page bigger", "bigger text on the page"], "=", nil, ["command"], "Zoomed in"),
            (["zoom out", "make the page smaller"], "-", nil, ["command"], "Zoomed out"),
            (["back a page", "previous page", "go back a page"], "[", nil, ["command"], "Back a page"),
        ]
        guard !h.has("track", "plugin", "lesson", "song"), let k = keys.first(where: { e in e.say.contains { h.has($0) } }) else { return nil }
        run { g in
            if Opt.fast { self.say(k.done + ".", g); return }
            let browsers = ["Google Chrome", "Safari", "Arc", "Microsoft Edge", "Firefox", "Brave Browser"]
            let front = self.frontApp() ?? ""
            let app = browsers.contains(front) ? front : browsers.first { runTool("/usr/bin/pgrep", ["-xq", $0], timeout: 2).ok }
            guard let target = app else { self.say("No browser is open. Say open Google first.", g); return }
            let using = k.mods.isEmpty ? "" : " using {" + k.mods.map { $0 + " down" }.joined(separator: ", ") + "}"
            let press = k.code.map { "key code \($0)" } ?? "keystroke \(LogicControl.quote(k.key ?? ""))"
            let r = LogicControl.osa(LogicControl.front(target) + "tell application \"System Events\" to \(press)\(using)")
            self.say(r.ok ? "\(k.done), in \(target == "Google Chrome" ? "Chrome" : target)." : (LogicControl.denied(r.out) ? LogicControl.needPermission : "I couldn't reach \(target)."), g)
        }
        return "browser \(k.done.lowercased())"
    }
}

func moreSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    engine.goHomeQuietly()
    let v = ["open visualizer mode", "show me the visualiser", "close the visualizer", "full screen", "exit full screen"].map { engine.hear($0) }
    check("window: the visualiser and full screen can be asked for by voice", v == ["visual on", "visual on", "visual off", "full on", "full off"], v.joined(separator: " / "))
    let b = ["new tab", "close the tab", "scroll down", "zoom in", "reload the page", "next"].map { engine.hear($0) }
    check("browser: tabs, scrolling and zoom are understood, and a plain next is still the lesson's", b == ["browser a new tab", "browser closed the tab", "browser scrolled down", "browser zoomed in", "browser reloaded", "next"], b.joined(separator: " / "))
    let w = ["start with my Mac", "don't start with my mac", "go to the background", "show the window", "can you run in the background all the time"].map { engine.hear($0) }
    check("background: starting with the Mac, hiding and coming back are understood", w == ["login on", "login off", "window hide", "window show", "login on"], w.joined(separator: " / "))
    let pace = Kokoro.rate
    let sp = ["talk slower", "you're talking too fast", "talk faster", "talk at normal speed"].map { engine.hear($0) }
    Kokoro.rate = pace
    check("voice: its talking speed can be changed by asking", sp == ["voice slower", "voice slower", "voice faster", "voice pace"], sp.joined(separator: " / "))
    let c = ["flip a coin", "roll a dice", "what's 15 percent of 80", "spell rhythm", "remind me in ten minutes to stretch", "logic control"].map { engine.hear($0) }
    check("small things: a coin, a dice, percentages, spelling, reminders, and Logic control by name", c == ["chat", "chat", "chat", "chat", "timer", "logic"], c.joined(separator: " / "))
    engine.goHomeQuietly()
}
