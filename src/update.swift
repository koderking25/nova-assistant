// Keeping itself up to date.
//
// Nova asks its website now and then whether there is a newer version. If there is, it says so
// and shows it on screen, and waits for a yes. On a yes it downloads the new "payload" (the
// window, the engine and their helper files), checks the download against the fingerprint the
// website published, swaps it into Nova's folder in the Library, and starts again. The small
// program in the Applications folder is not touched, so no permission has to be granted twice.

import Foundation

struct UpdateInfo { let version: String; let notes: String; let url: String; let sha256: String }

enum Updater {
    // (NOVA_FEED points it at a test copy of the website's update file, for checking updates before they are published.)
    static let testFeed = ProcessInfo.processInfo.environment["NOVA_FEED"]
    static let feed = testFeed ?? "https://saynova.app/version.json"
    static var offered: UpdateInfo? = nil
    static var busy = false
    static let skipFile = baseDir.appendingPathComponent("update-skipped.txt")
    static let doneFile = baseDir.appendingPathComponent("updated-to.txt")

    /// Where the running window and engine live.
    static var payload: URL {
        if let p = ProcessInfo.processInfo.environment["NOVA_PAYLOAD"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    }

    static func numbers(_ v: String) -> [Int] { let n = v.split(separator: ".").map { Int($0) ?? 0 }; return n + Array(repeating: 0, count: max(0, 3 - n.count)) }
    static func newer(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        for i in 0..<3 where x[i] != y[i] { return x[i] > y[i] }
        return false
    }

    /// Asks the website what the latest version is. Nil if it cannot be reached, or there is nothing newer.
    static func check() -> UpdateInfo? {
        let r = runTool("/usr/bin/curl", ["-fsSL", "-m", "10", feed], timeout: 12)
        guard r.ok, let o = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
              let v = o["version"] as? String, let url = o["url"] as? String, let sum = o["sha256"] as? String,
              url.hasPrefix("https://") || testFeed != nil, newer(v, than: novaVersion) else { return nil }
        return UpdateInfo(version: v, notes: (o["notes"] as? String) ?? "", url: url, sha256: sum.lowercased())
    }

    /// Downloads, checks and swaps in the new payload. Returns nil when it worked, or what went wrong.
    static func install(_ info: UpdateInfo) -> String? {
        let fm = FileManager.default
        let current = payload
        // Only a payload living in Nova's own folder can be replaced. (One run straight from inside the app cannot.)
        guard current.lastPathComponent == "app", fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            return "I can't update myself from where I'm running. Downloading the new version from the website will do it."
        }
        let parent = current.deletingLastPathComponent()
        let zip = parent.appendingPathComponent("update.zip"), fresh = parent.appendingPathComponent("app.new"), old = parent.appendingPathComponent("app.old")
        try? fm.removeItem(at: zip); try? fm.removeItem(at: fresh); try? fm.removeItem(at: old)
        guard runTool("/usr/bin/curl", ["-fsSL", "--retry", "2", "-m", "300", "-o", zip.path, info.url], timeout: 320).ok else { return "The download didn't finish. I'll try again later." }
        let sum = runTool("/usr/bin/shasum", ["-a", "256", zip.path], timeout: 30).out.split(separator: " ").first.map(String.init) ?? ""
        guard sum.lowercased() == info.sha256 else { try? fm.removeItem(at: zip); return "The download didn't match what the website published, so I've thrown it away and changed nothing." }
        guard runTool("/usr/bin/ditto", ["-x", "-k", zip.path, fresh.path], timeout: 60).ok else { return "The update wouldn't unpack." }
        try? fm.removeItem(at: zip)
        // The files may be at the top of the archive or inside one folder.
        var from = fresh
        if !fm.fileExists(atPath: from.appendingPathComponent("libNovaUI.dylib").path), let inner = (try? fm.contentsOfDirectory(at: fresh, includingPropertiesForKeys: nil))?.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("libNovaUI.dylib").path) }) { from = inner }
        for needed in ["libNovaUI.dylib", "nova-engine", "version.txt"] where !fm.fileExists(atPath: from.appendingPathComponent(needed).path) {
            try? fm.removeItem(at: fresh); return "The update was missing a file, so I've left everything as it was."
        }
        let got = ((try? String(contentsOf: from.appendingPathComponent("version.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard got == info.version else { try? fm.removeItem(at: fresh); return "The update wasn't the version it said it was, so I've left everything as it was." }
        _ = runTool("/bin/chmod", ["755", from.appendingPathComponent("nova-engine").path], timeout: 5)
        do {
            try fm.moveItem(at: current, to: old)
            do { try fm.moveItem(at: from, to: current) } catch { try? fm.moveItem(at: old, to: current); throw error }
        } catch { return "I couldn't put the new version in place, so nothing has changed." }
        try? fm.removeItem(at: fresh); try? fm.removeItem(at: old)
        try? info.version.write(to: doneFile, atomically: true, encoding: .utf8)
        return nil
    }
}

extension Engine {
    /// Looks for a newer version. Quietly when it is the routine look; with an answer when asked.
    func checkForUpdates(asked: Bool) {
        if Opt.fast || Opt.textMode || Updater.busy { return }
        DispatchQueue.global(qos: .utility).async {
            guard let info = Updater.check() else {
                if asked { self.run { g in self.say("You're up to date. This is version \(novaVersion).", g) } }
                return
            }
            // "No" to this version within the last day is respected, unless they are asking now.
            if !asked, let s = try? String(contentsOf: Updater.skipFile, encoding: .utf8) {
                let f = s.split(separator: " ")
                if f.count == 2, String(f[0]) == info.version, let t = Double(f[1]), Date().timeIntervalSince1970 - t < 86400 { return }
            }
            // Not in the middle of a lesson or a piece: it waits for a quiet moment.
            var waited = 0
            while !asked, waited < 180, self.mode != .idle || self.lastSpokenAt > now() || now() - self.lastSpokenAt < 4 { usleep(5_000_000); waited += 1 }
            self.offerUpdate(info)
        }
    }

    func offerUpdate(_ info: UpdateInfo) {
        Updater.offered = info
        ui("update \(info.version)|\(info.notes)")
        ui("flash good")
        lock.lock()
        pendingConfirm = { [unowned self] in self.acceptUpdate() }
        pendingUntil = now() + 45
        lock.unlock()
        run { g in self.say("There's a new version of Nova, \(info.version). \(info.notes.isEmpty ? "" : info.notes + " ")Do you want me to update now? It takes a few seconds. Say yes or no.", g) }
    }

    func acceptUpdate() {
        guard let info = Updater.offered, !Updater.busy else { return }
        Updater.busy = true
        pendingConfirm = nil
        run { g in
            self.say("Updating now. I'll be back in a few seconds.", g)
            let problem = Updater.install(info)
            Updater.busy = false
            if let p = problem {
                self.noteMistake("an update did not install", p)
                ui("update ")
                self.say(p, g)
                return
            }
            Updater.offered = nil
            ui("update ")
            ui("relaunch")
        }
    }

    func declineUpdate() {
        guard let info = Updater.offered else { return }
        Updater.offered = nil
        pendingConfirm = nil
        ui("update ")
        if !Opt.fast { try? "\(info.version) \(Date().timeIntervalSince1970)".write(to: Updater.skipFile, atomically: true, encoding: .utf8) }
        run { g in self.say("Okay. I'll ask again tomorrow. You can also say, update now, whenever you like.", g) }
    }

    func updateHear(_ h: Heard) -> String? {
        if h.has("what version", "which version", "version are you", "version number") {
            run { g in self.say("This is Nova version \(novaVersion).", g) }; return "version"
        }
        guard h.has("update", "updates", "upgrade", "new version", "latest version") else { return nil }
        if h.has("track", "plugin", "project", "list", "spotify") { return nil }
        if Updater.offered != nil, h.has("later", "not now", "tomorrow", "skip") { declineUpdate(); return "update later" }
        if Updater.offered != nil, h.has("now", "yes", "install", "do it", "go ahead", "update yourself", "update") { if !Opt.fast { acceptUpdate() }; return "update now" }
        if Opt.fast { run { g in self.say("Checking.", g) }; return "update check" }
        run { g in self.say("Let me check.", g) }
        checkForUpdates(asked: true)
        return "update check"
    }

    /// Run at start: says so if it has just been updated, then looks for updates now and twice a day.
    func startUpdates() {
        if Opt.fast || Opt.textMode { return }
        if let v = try? String(contentsOf: Updater.doneFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: Updater.doneFile)
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { while self.lastSpokenAt > now() { usleep(300_000) }; self.announce("I've updated myself. This is version \(v.trimmingCharacters(in: .whitespacesAndNewlines)).") }
        }
        func loop(after seconds: Double) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                if Profile.current.done { self.checkForUpdates(asked: false) }
                loop(after: 12 * 3600)
            }
        }
        loop(after: 25)
    }
}

func updateSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    check("updates: version numbers are compared as numbers", Updater.newer("1.10.0", than: "1.9.9") && Updater.newer("2.0", than: "1.99.99") && !Updater.newer("1.2.0", than: "1.2.0") && !Updater.newer("1.2", than: "1.2.1"), "")
    Updater.offered = UpdateInfo(version: "9.9.9", notes: "", url: "https://example.invalid/x.zip", sha256: "")
    let a = engine.hear("update later")
    Updater.offered = nil
    let b = [engine.hear("check for updates"), engine.hear("what version are you"), engine.hear("update the reverb plugin")]
    check("updates: asking to check, to wait and for the version are understood, and a plugin update is not mistaken for one", a == "update later" && b[0] == "update check" && b[1] == "version" && b[2] != "update check", "\(a) \(b)")
    engine.goHomeQuietly()
}
