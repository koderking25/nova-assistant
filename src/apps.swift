// Hands in any app: doing what is asked inside whatever program is open.
//
// macOS lets an assistive tool read an app's menus, buttons and text, and press them. That is
// used here so a request such as "start an audio track in Logic" is carried out by finding
// the menu command that means it ("New Audio Track") and choosing it. Nothing is guessed in
// silence: a command is only chosen when its words are all in the request; a near miss is
// offered and waits for a yes; anything that closes, deletes or quits asks first; and after
// a command, any dialog the app puts up is read out with its buttons.

import ApplicationServices
import Foundation

struct MenuEntry {
    let path: [String]              // ["Track", "New Audio Track"]
    let element: AXUIElement?       // nil in the self-test
    var title: String { path.last ?? "" }
}

struct ScreenItem { let role: String; let name: String; let element: AXUIElement? }

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    static func text(_ e: AXUIElement, _ name: String) -> String { (value(e, name) as? String) ?? "" }
    static func flag(_ e: AXUIElement, _ name: String) -> Bool { (value(e, name) as? Bool) ?? false }
    static func children(_ e: AXUIElement) -> [AXUIElement] { (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func pid(of app: String) -> pid_t? {
        var r = runTool("/usr/bin/pgrep", ["-x", app], timeout: 2)
        if !r.ok || r.out.isEmpty { r = runTool("/usr/bin/pgrep", ["-f", "/\(app).app/Contents/MacOS/"], timeout: 2) }
        return r.out.components(separatedBy: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let a = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(a, 1.5)
        return a
    }

    /// Every command in the app's menus, three levels deep.
    static func menus(_ pid: pid_t) -> [MenuEntry] {
        guard let bar = element(app(pid), kAXMenuBarAttribute) else { return [] }
        var out: [MenuEntry] = []
        func walk(_ menu: AXUIElement, _ path: [String], _ depth: Int) {
            for item in children(menu) {
                let title = text(item, kAXTitleAttribute)
                guard !title.isEmpty, out.count < 2500 else { continue }
                if depth < 3, let sub = children(item).first, !children(sub).isEmpty { walk(sub, path + [title], depth + 1) }
                else { out.append(MenuEntry(path: path + [title], element: item)) }
            }
        }
        for top in children(bar).dropFirst() {                    // the first is the Apple menu
            let title = text(top, kAXTitleAttribute)
            if let menu = children(top).first, !title.isEmpty { walk(menu, [title], 1) }
        }
        return out
    }

    static let pressable: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXLink", "AXDisclosureTriangle", "AXTab", "AXCell", "AXMenuItem"]

    /// What is in a window: its buttons and other controls, and its text.
    static func contents(of root: AXUIElement) -> (controls: [ScreenItem], texts: [String]) {
        var controls: [ScreenItem] = [], texts: [String] = []
        var seen = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard seen < 700, depth < 12 else { return }
            seen += 1
            let role = text(e, kAXRoleAttribute)
            if pressable.contains(role) {
                var name = text(e, kAXTitleAttribute)
                if name.isEmpty { name = text(e, kAXDescriptionAttribute) }
                if name.isEmpty, role == "AXCell" { return walkChildren(e, depth) }
                if !name.isEmpty, name.count < 60 { controls.append(ScreenItem(role: role, name: name, element: e)) }
            } else if role == "AXStaticText" {
                let v = text(e, kAXValueAttribute)
                if !v.isEmpty, v.count < 300 { texts.append(v) }
            } else if role == "AXSecureTextField" {
                texts.append("a password box")
            }
            walkChildren(e, depth)
        }
        func walkChildren(_ e: AXUIElement, _ depth: Int) { for c in children(e) { walk(c, depth + 1) } }
        walk(root, 0)
        return (controls, texts)
    }

    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let a = app(pid)
        return element(a, kAXFocusedWindowAttribute) ?? element(a, kAXMainWindowAttribute) ?? (value(a, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    /// A sheet or dialog that is waiting for an answer, if there is one.
    static func dialog(_ pid: pid_t) -> AXUIElement? {
        guard let w = focusedWindow(pid) else { return nil }
        if let sheet = children(w).first(where: { text($0, kAXRoleAttribute) == "AXSheet" }) { return sheet }
        let sub = text(w, kAXSubroleAttribute)
        return sub == "AXDialog" || sub == "AXSystemDialog" ? w : nil
    }

    static func press(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }
}

/// Words boiled down for matching: "Tracks…" and "track" are the same word, "start" means "new".
func commandWords(_ s: String) -> [String] {
    let same: [String: String] = ["start": "new", "create": "new", "add": "new", "make": "new", "begin": "new", "another": "new", "remove": "delete", "erase": "delete", "display": "show",
                                  "view": "show", "shut": "close", "bring": "show", "reveal": "show", "instrument": "instrument", "copy": "copy", "settings": "settings", "preferences": "settings",
                                  "prefs": "settings", "options": "settings", "tabs": "tab", "windows": "window", "incognito": "incognito", "private": "private", "vocals": "audio", "vocal": "audio",
                                  "mic": "audio", "piano": "instrument", "synth": "instrument", "keyboard": "instrument", "open": "show", "launch": "show", "hide": "hide", "redo": "redo"]
    var out: [String] = []
    for raw in s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) where !raw.isEmpty {
        var w = same[raw] ?? raw
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss"), same[w] == nil { w = String(w.dropLast()) }
        out.append(same[w] ?? w)
    }
    return out
}

let commandNoise: Set<String> = ["the", "a", "an", "in", "on", "of", "to", "my", "this", "that", "please", "me", "can", "you", "i", "want", "it", "for", "with", "menu", "item", "click", "choose",
                                 "select", "option", "go", "do", "app", "now", "up", "and", "then", "there", "here", "just", "some", "command", "pick", "use", "hit", "run", "is", "s", "would", "like",
                                 "could", "need", "lets", "let", "us", "program", "inside", "from", "at", "current", "one"]

/// The menu command a request means. `sure` is false for a near miss that should be offered, not done.
func matchCommand(_ request: String, in entries: [MenuEntry], ignoring appWords: [String], strict: Bool) -> (entry: MenuEntry, sure: Bool)? {
    let noise = commandNoise.union(appWords)
    let wanted = Set(commandWords(request).filter { !noise.contains($0) })
    guard !wanted.isEmpty else { return nil }
    var best: (MenuEntry, Double, Bool)? = nil
    for e in entries {
        // The app's own name is left out on both sides, so "new window" finds "New Finder Window".
        var title = Set(commandWords(e.title).filter { !["the", "a", "an", "of", "to"].contains($0) })
        if !title.subtracting(appWords).isEmpty { title.subtract(appWords) }
        guard !title.isEmpty else { continue }
        let parents = Set(e.path.dropLast().flatMap { commandWords($0) })
        let hits = title.intersection(wanted)
        guard !hits.isEmpty else { continue }
        // "Show" must never be answered with a command that hides, nor the other way round.
        if (wanted.contains("show") && title.contains("hide")) || (wanted.contains("hide") && title.contains("show")) { continue }
        let precision = Double(hits.count) / Double(title.count)
        let coverage = Double(wanted.intersection(title.union(parents)).count) / Double(wanted.count)
        let exact = precision == 1 && coverage >= (strict ? 0.99 : 0.6)
        // A near miss: most of the command's words (counting the menu it sits in) were said.
        let wide = title.union(e.path.count >= 2 ? Set(commandWords(e.path[e.path.count - 2])) : [])
        let near = !exact && Double(wide.intersection(wanted).count) / Double(wide.count) >= 0.5 && coverage >= 0.99 && wanted.count >= 2
        guard exact || near else { continue }
        let score = (exact ? 10 : 0) + coverage * 2 + precision + Double(hits.count) * 0.3 - Double(e.path.count) * 0.05
        if best == nil || score > best!.1 { best = (e, score, exact) }
    }
    return best.map { ($0.0, $0.2) }
}

let riskyCommandWords: Set<String> = ["delete", "close", "quit", "revert", "empty", "discard", "reset", "format", "sign", "log", "restart", "shut", "clear", "uninstall", "trash", "erase", "replace",
                                      "overwrite", "send", "post", "publish", "buy", "purchase", "pay", "submit", "order"]

func spokenList(_ items: [String], limit: Int = 8) -> String {
    var seen = Set<String>()
    let unique = items.filter { seen.insert($0.lowercased()).inserted }
    let shown = unique.prefix(limit)
    return shown.joined(separator: ", ") + (unique.count > limit ? ", and \(unique.count - limit) more" : "")
}

extension Engine {
    /// Said when the Mac has not yet allowed Nova to work in other apps. Asking for it also makes
    /// macOS show its own window with a button that goes straight to the right setting.
    static var noAccess: String {
        if !Opt.fast { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        return "The Mac hasn't let me work in other apps yet. A window should be asking now: choose Open System Settings, then switch on Nova under Accessibility."
    }

    /// The app a request is about: one that is named and running, or else the one in front.
    func targetApp(_ h: Heard) -> (name: String, named: Bool)? {
        if Opt.fast { return pretendApp.map { ($0, h.has($0.lowercased()) || h.has(Heard($0).words.first ?? "")) } }
        if let named = appNamed(h), named.name != "Nova", AX.pid(of: named.name) != nil { return (named.name, true) }
        if let front = frontApp(), front != "Nova" { lastFrontApp = front; return (front, false) }
        return lastFrontApp.map { ($0, false) }
    }

    func menuEntries(_ app: String) -> [MenuEntry] {
        if Opt.fast { return pretendMenus }
        guard let pid = AX.pid(of: app) else { return [] }
        return AX.menus(pid)
    }

    /// After something was pressed: if the app has put up a dialog, say what it says and what can be pressed.
    func dialogReport(_ app: String) -> String {
        guard !Opt.fast, let pid = AX.pid(of: app), let d = AX.dialog(pid) else { return "" }
        let c = AX.contents(of: d)
        let buttons = c.controls.filter { $0.role == "AXButton" }.map { $0.name }
        let said = c.texts.filter { $0.count > 2 }.prefix(3).joined(separator: ". ")
        if buttons.isEmpty && said.isEmpty { return "" }
        return " \(app) is now asking: \(said.isEmpty ? "something" : String(said.prefix(160))). " + (buttons.isEmpty ? "" : "The buttons are \(spokenList(buttons, limit: 5)). Say click, and the one you want.")
    }

    func chooseMenu(_ entry: MenuEntry, in app: String) {
        let path = entry.path.joined(separator: ", ")
        run { g in
            if Opt.fast { self.say("Done: \(entry.title).", g); return }
            guard AX.trusted else { self.say(Engine.noAccess, g); return }
            guard let el = entry.element else { return }
            if !AX.flag(el, kAXEnabledAttribute) {
                self.say("\(entry.title) is greyed out in \(app) right now, so it can't be chosen.", g); return
            }
            _ = LogicControl.osa(LogicControl.front(app))
            guard AX.press(el) else {
                self.noteMistake("an app action failed", "\(app): \(path)")
                self.say("I found \(entry.title) in \(app), but it wouldn't respond.", g); return
            }
            usleep(700_000)
            self.say(pick(["Done: \(entry.title), in \(app).", "\(entry.title), in \(app). Done."]) + self.dialogReport(app), g)
        }
    }

    /// Carrying out a spoken command through the menus of an app. `explicit` when the app was named.
    func menuHear(_ h: Heard, app: String, explicit: Bool) -> String? {
        if !Opt.fast, !AX.trusted { return nil }
        let entries = menuEntries(app)
        guard !entries.isEmpty else { return nil }
        let appWords = commandWords(app) + ["logic", "pro", "chrome", "google", "reaper"]
        guard let m = matchCommand(h.text, in: entries, ignoring: appWords, strict: !explicit) else {
            // Asked to show something whose only command is "Hide…": it is showing already. And the reverse.
            let said = h.text.replacingOccurrences(of: "open ", with: "show ")
            for (from, to, state) in [("show", "hide", "already showing"), ("hide", "show", "already hidden")] where (" " + said + " ").contains(" \(from) ") {
                let flipped = (" " + said + " ").replacingOccurrences(of: " \(from) ", with: " \(to) ")
                if let other = matchCommand(flipped, in: entries, ignoring: appWords, strict: true), other.sure {
                    let thing = other.entry.title.replacingOccurrences(of: "Hide ", with: "").replacingOccurrences(of: "Show ", with: "")
                    run { g in self.say("\(thing) is \(state) in \(app).", g) }
                    return "menu state \(app): \(other.entry.title)"
                }
            }
            return nil
        }
        let risky = !Set(commandWords(m.entry.title)).isDisjoint(with: riskyCommandWords)
        let path = m.entry.path.joined(separator: ", ")
        if m.sure && !risky { chooseMenu(m.entry, in: app); return "menu \(app): \(m.entry.path.joined(separator: " > "))" }
        // A near miss, or something that cannot easily be taken back: say what it is and wait for a yes.
        pendingConfirm = { [unowned self] in self.chooseMenu(m.entry, in: app) }
        pendingUntil = now() + 20
        run { g in self.say(m.sure ? "That's \(path), in \(app). Shall I go ahead?" : "The closest thing in \(app) is \(path). Shall I choose it?", g) }
        return "menu? \(app): \(m.entry.path.joined(separator: " > "))"
    }

    /// Requests about whatever app is open: its menus, its buttons, what is on screen.
    func axHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        let inReaper = Reaper.running || pretendReaper        // there, "where am I" asks for the place in the song
        let whereAmI = (!inReaper && h.has("where am i")) || h.has("what app is this", "what app am i in", "which app is this", "which app am i in", "what window is this", "what is in front", "whats in front", "what am i looking at")
        let readWindow = h.has("read the window", "read the screen", "read this window", "whats on the screen", "what is on the screen", "whats on my screen", "what is on my screen", "describe the window",
                               "describe the screen", "read the dialog", "what does it say", "what does the dialog say", "whats it asking", "what is it asking", "read that to me", "read it to me", "what does the window say")
        let listButtons = h.has("what buttons", "which buttons", "what can i click", "what can i press", "list the buttons", "read the buttons", "what are the buttons", "what are my options here")
        let listMenus = h.has("what menus", "which menus", "list the menus", "read the menus", "what can i do here", "what can i do in")
        let inMenu = h.after("whats in the", "what is in the", "read the", "read me the", "list the", "whats under", "what is under")
        let clicking = h.starts("click", "tap", "push", "press the", "press", "choose", "select", "tick", "untick", "check the", "uncheck")
        let typing = h.starts("type", "dictate", "write this", "type this", "enter the text")
        let selection = h.has("read the selection", "read the selected text", "read what i selected", "read what is selected", "read whats selected", "read the highlighted", "what did i select", "read my selection")
        let clipboard = h.has("clipboard", "what i copied", "what did i copy", "read what i copied")
        let menuList = inMenu != nil && h.has("menu")
        guard whereAmI || readWindow || listButtons || listMenus || menuList || clicking || typing || selection || clipboard else { return nil }
        if clipboard {
            run { g in
                let text = Opt.fast ? "" : runTool("/usr/bin/pbpaste", [], timeout: 3).out.trimmingCharacters(in: .whitespacesAndNewlines)
                self.say(text.isEmpty ? "The clipboard has no text on it." : "The clipboard says: \(String(text.prefix(500)))\(text.count > 500 ? ". And it goes on." : "")", g)
            }
            return "clipboard"
        }
        guard let target = targetApp(h) else {
            if whereAmI { reply("Just me, \(Me.name). No other app is in front."); return "where" }
            // Asked to read or press something, but there is no other app to do it in.
            if !Opt.fast, readWindow || listButtons || listMenus || menuList || selection || (typing && !h.has("hello")) || (clicking && !h.has("track", "metronome", "on", "off") && h.words.count >= 2) {
                reply("No other app is open in front of me. Open one, or say which app you mean."); return "no app in front"
            }
            return nil
        }
        let app = target.name
        if Opt.fast {
            return whereAmI ? "where" : readWindow ? "read window" : listButtons ? "buttons" : listMenus ? "menus" : menuList ? "menu list" : typing ? "type" : selection ? "selection" : clicking ? "click" : nil
        }
        guard AX.trusted else { reply(Engine.noAccess); return "no access" }
        guard let pid = AX.pid(of: app) else { return nil }
        if whereAmI {
            let w = AX.focusedWindow(pid)
            let title = w.map { AX.text($0, kAXTitleAttribute) } ?? ""
            var text = "You're in \(app)" + (title.isEmpty ? "." : ", in the window called \(title).")
            if let f = AX.element(AX.app(pid), kAXFocusedUIElementAttribute) {
                let role = AX.text(f, kAXRoleDescriptionAttribute), name = AX.text(f, kAXTitleAttribute).isEmpty ? AX.text(f, kAXDescriptionAttribute) : AX.text(f, kAXTitleAttribute)
                if !role.isEmpty, role != "window" { text += " The focus is on \(name.isEmpty ? "a" : name + ", a") \(role)." }
            }
            reply(text + (AX.dialog(pid) != nil ? dialogReport(app) : "")); return "where"
        }
        if readWindow || listButtons {
            guard let w = AX.dialog(pid) ?? AX.focusedWindow(pid) else { reply("\(app) has no window open."); return "read window" }
            let c = AX.contents(of: w)
            let buttons = c.controls.map { $0.name }
            if listButtons { reply(buttons.isEmpty ? "I can't find any buttons in this \(app) window." : "In \(app) you can press: \(spokenList(buttons, limit: 12)). Say click, and its name."); return "buttons" }
            let title = AX.text(w, kAXTitleAttribute)
            var text = AX.dialog(pid) != nil ? "\(app) is showing a dialog." : "\(app)\(title.isEmpty ? "" : ", \(title)")."
            let words = c.texts.filter { $0.count > 2 }
            if !words.isEmpty { text += " It says: \(String(words.prefix(6).joined(separator: ". ").prefix(420)))." }
            if !buttons.isEmpty { text += " Buttons: \(spokenList(buttons, limit: 8))." }
            if words.isEmpty && buttons.isEmpty { text += " I can't read anything inside it. Some apps don't describe their windows." }
            reply(text); return "read window"
        }
        if listMenus {
            let tops = AX.children(AX.element(AX.app(pid), kAXMenuBarAttribute) ?? AX.app(pid)).dropFirst().map { AX.text($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
            reply("\(app) has these menus: \(spokenList(Array(tops), limit: 14)). Ask what's in any of them, or just tell me what you want done."); return "menus"
        }
        if menuList, let asked = inMenu {
            let name = commandWords(asked).filter { $0 != "menu" && !commandNoise.contains($0) }
            let entries = menuEntries(app).filter { e in !name.isEmpty && Set(name).isSubset(of: Set(e.path.dropLast().flatMap { commandWords($0) })) }
            guard !entries.isEmpty else { reply("I can't find that menu in \(app)."); return "menu list" }
            let usable = entries.filter { $0.element.map { AX.flag($0, kAXEnabledAttribute) } ?? true }.map { $0.title }
            reply("In \(entries[0].path.dropLast().joined(separator: ", ")): \(spokenList(usable, limit: 14)). Tell me which one you want."); return "menu list"
        }
        if selection {
            let f = AX.element(AX.app(pid), kAXFocusedUIElementAttribute)
            let text = f.map { AX.text($0, kAXSelectedTextAttribute) } ?? ""
            reply(text.isEmpty ? "Nothing is selected in \(app), or it won't tell me what is." : "Selected: \(String(text.prefix(600)))"); return "selection"
        }
        if typing, let words = h.after("type this", "type", "dictate", "write this", "enter the text") {
            // What was said, as it was said: the recogniser's own capitals and punctuation are gone by now, so plain text.
            if let f = AX.element(AX.app(pid), kAXFocusedUIElementAttribute), AX.text(f, kAXRoleAttribute) == "AXSecureTextField" {
                reply("That's a password box. I don't type into those. Please type it yourself."); return "type refused"
            }
            run { g in
                let r = LogicControl.osa(LogicControl.front(app) + "tell application \"System Events\" to keystroke \(LogicControl.quote(words))")
                self.say(r.ok ? "Typed, in \(app)." : (LogicControl.denied(r.out) ? Engine.noAccess : "I couldn't type into \(app)."), g)
            }
            return "type"
        }
        if clicking {
            let wanted = Set(commandWords(h.text).filter { !commandNoise.contains($0) && !["tap", "push", "press", "button", "tick", "untick", "check", "uncheck", "box", "checkbox", "tab", "link"].contains($0) }).subtracting(commandWords(app))
            guard !wanted.isEmpty else { return nil }
            let root = AX.dialog(pid) ?? AX.focusedWindow(pid)
            let controls = root.map { AX.contents(of: $0).controls } ?? []
            var best: (ScreenItem, Double)? = nil
            for c in controls {
                let name = Set(commandWords(c.name))
                guard !name.isEmpty, name.isSubset(of: wanted) || wanted.isSubset(of: name) else { continue }
                let score = Double(name.intersection(wanted).count) / Double(name.union(wanted).count) + (c.role == "AXButton" ? 0.1 : 0)
                if best == nil || score > best!.1 { best = (c, score) }
            }
            guard let hit = best?.0, let el = hit.element else {
                // Not a button in the window: it may be a command in the menus.
                if let done = menuHear(h, app: app, explicit: true) { return done }
                let names = controls.map { $0.name }
                reply(names.isEmpty ? "I can't find anything to click in \(app)'s window." : "I can't find that in \(app). I can see: \(spokenList(names, limit: 8))."); return "click none"
            }
            let risky = !Set(commandWords(hit.name)).isDisjoint(with: riskyCommandWords)
            let go = { [unowned self] in
                self.run { g in
                    _ = LogicControl.osa(LogicControl.front(app))
                    guard AX.press(el) else { self.say("\(hit.name) wouldn't respond.", g); return }
                    usleep(700_000)
                    self.say("Pressed \(hit.name), in \(app)." + self.dialogReport(app), g)
                }
            }
            if risky {
                pendingConfirm = go; pendingUntil = now() + 20
                reply("Press \(hit.name), in \(app)? Say yes or no."); return "click? \(hit.name)"
            }
            go(); return "click \(hit.name)"
        }
        return nil
    }

    /// "Do this, then that": each part is carried out in turn, waiting for the one before to finish.
    func sequenceHear(_ raw: String) -> String? {
        let lower = " " + raw.lowercased() + " "
        guard let r = [" and then ", " then ", ", then ", " after that "].compactMap({ lower.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let first = String(lower[..<r.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        var second = String(lower[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        guard first.split(separator: " ").count >= 2, second.split(separator: " ").count >= 1 else { return nil }
        // "…in Logic, then start recording": the second part is about the same app.
        if let app = appNamed(Heard(first)), appNamed(Heard(second)) == nil, !Heard(second).has("spotify", "youtube") { second += " in \(app.name)" }
        if Opt.fast {
            sequencing = true; defer { sequencing = false }
            let a = hear(first), b = hear(second)
            return "then: \(a) | \(b)"
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.lock.lock(); self.sequencing = true; _ = self.hear(first); self.sequencing = false; self.lock.unlock()
            // Wait until the first has been done and reported, then give it a breath.
            let began = now()
            usleep(1_200_000)
            while now() - began < 25, self.lastSpokenAt > now() || now() - self.lastSpokenAt < 0.5 || (self.lastSpokenAt < began && now() - began < 6) { usleep(100_000) }
            self.lock.lock(); self.sequencing = true; _ = self.hear(second); self.sequencing = false; self.lock.unlock()
        }
        return "then"
    }
}

func appsSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let logic: [[String]] = [["File", "New"], ["File", "New from Template…"], ["File", "Save"], ["File", "Save As…"], ["File", "Close Project"], ["File", "Bounce", "Project or Section…"],
                             ["Track", "New Tracks…"], ["Track", "New Audio Track"], ["Track", "New Software Instrument Track"], ["Track", "Delete Track"], ["Track", "Rename Track"],
                             ["Window", "Open Mixer"], ["Window", "Open Piano Roll"], ["Edit", "Undo"], ["Edit", "Select All"], ["View", "Show Library"], ["Mix", "Show Automation"]]
    let entries = logic.map { MenuEntry(path: $0, element: nil) }
    func m(_ s: String, strict: Bool = false) -> String {
        matchCommand(Heard(s).text, in: entries, ignoring: ["logic", "pro"], strict: strict).map { ($0.sure ? "" : "?") + $0.entry.path.joined(separator: " > ") } ?? "none"
    }
    let got = [m("start an audio track in logic"), m("add a software instrument track"), m("open the mixer in logic pro"), m("show the piano roll"), m("bounce the project"),
               m("delete the track in logic"), m("show me the library"), m("what's the capital of France", strict: true), m("play me something sad", strict: true), m("new tracks"), m("save as")]
    check("apps: a spoken request finds the right menu command, a near miss is only offered, and ordinary talk finds nothing",
          got == ["Track > New Audio Track", "Track > New Software Instrument Track", "Window > Open Mixer", "Window > Open Piano Roll", "?File > Bounce > Project or Section…",
                  "Track > Delete Track", "View > Show Library", "none", "none", "Track > New Tracks…", "File > Save As…"], got.joined(separator: " | "))
    engine.goHomeQuietly()
    engine.pretendApp = "Logic Pro"; engine.pretendMenus = entries
    let a = engine.hear("open the mixer in logic")
    let b = engine.hear("delete the track in logic")
    let c = engine.hear("yes")
    let d = engine.hear("in logic, show the library and then open the piano roll")
    let e = engine.hear("what buttons are there")
    let f = engine.hear("where am I")
    let g2 = engine.hear("click create")
    engine.pretendApp = nil; engine.pretendMenus = []
    check("apps: commands are carried out in the named app, deleting asks first, two steps run in order, and the window can be read and clicked",
          a == "menu Logic Pro: Window > Open Mixer" && b == "menu? Logic Pro: Track > Delete Track" && c == "confirmed" && d == "then: menu Logic Pro: View > Show Library | menu Logic Pro: Window > Open Piano Roll"
          && e == "buttons" && f == "where" && g2 == "click", "\(a) / \(b) / \(c) / \(d) / \(e) / \(f) / \(g2)")
    engine.goHomeQuietly()
}
