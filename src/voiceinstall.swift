// The natural voice: an optional download.
//
// Nova speaks with the Mac's own voice out of the box. The natural voices (Kokoro, an open
// speech model that runs on this Mac) are about 370 MB, so they are fetched when the welcome's
// switch is left on or when asked for: the sherpa-onnx speech library and the model. Everything
// goes into Nova's own folder, and "remove the natural voice" takes it all away again.

import Foundation

enum VoiceInstaller {
    static var running = false
    static var cancelled = false
    /// The person asked for the Mac's own voice, so the natural one is not fetched by itself.
    static let declineFile = baseDir.appendingPathComponent("voice-declined.txt")
    static var declined: Bool { FileManager.default.fileExists(atPath: declineFile.path) }
    static let model = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
    static let voices = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"
    static var uvURL: String {
        var info = utsname(); uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        return "https://github.com/astral-sh/uv/releases/latest/download/uv-\(machine == "arm64" ? "aarch64" : "x86_64")-apple-darwin.tar.gz"
    }

    /// The helper script travels inside the app; the voice code looks for it in the data folder.
    static func placeHelper() {
        let beside = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("kokoro_server.py")
        let target = baseDir.appendingPathComponent("kokoro_server.py")
        guard let code = FileManager.default.contents(atPath: beside.path) else { return }
        if FileManager.default.contents(atPath: target.path) != code { FileManager.default.createFile(atPath: target.path, contents: code) }
    }

    /// Fetches and sets up everything. Returns nil when it worked, or a sentence saying what went wrong.
    static func install(progress: @escaping (String) -> Void) -> String? {
        let fm = FileManager.default
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        if free < 1_000_000_000 { return "There isn't enough free space. The natural voice needs about one gigabyte free while it installs." }
        // The voice is made inside Nova (sherpa-onnx): two checked downloads and nothing to set up.
        return SherpaVoice.install(progress: progress, cancelled: { cancelled })
    }
}

extension Engine {
    func voiceInstallHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        let natural = h.has("natural voice", "natural voices", "better voice", "human voice", "nicer voice", "realistic voice", "real voice", "kokoro", "good voice", "new voice pack", "voice pack", "premium voice")
        guard natural else { return nil }
        if h.has("cancel", "stop", "dont download", "do not download", "dont install") {
            VoiceInstaller.cancelled = true
            if !Opt.fast {
                try? "declined".write(to: VoiceInstaller.declineFile, atomically: true, encoding: .utf8)
                _ = runTool("/usr/bin/pkill", ["-f", Kokoro.folder.path], timeout: 5)
            }
            reply("Stopped. I'll keep the Mac's own voice. If you change your mind, say install the natural voice."); return "voice cancel"
        }
        if h.has("remove", "uninstall", "delete", "get rid of") {
            guard Kokoro.installed || FileManager.default.fileExists(atPath: Kokoro.folder.path) else { reply("The natural voice isn't installed."); return "voice remove" }
            pendingConfirm = { [unowned self] in
                Kokoro.shared.shutDown()
                if !Opt.fast { try? FileManager.default.removeItem(at: Kokoro.folder); try? "declined".write(to: VoiceInstaller.declineFile, atomically: true, encoding: .utf8) }
                self.run { g in self.say("The natural voice is removed. I'm back to the Mac's own voice after the next restart.", g) }
            }
            pendingUntil = now() + 20
            reply("Remove the natural voice and free about 400 megabytes? Say yes or no."); return "voice remove?"
        }
        if h.has("install", "download", "get", "add", "set up", "turn on", "i want", "give me", "use", "switch to", "can i have") {
            if Kokoro.installed { reply("The natural voice is already installed. Say next voice to hear the others, or audition the voices."); return "voice have" }
            if VoiceInstaller.running { reply("It's already downloading. I'll tell you the moment it's ready."); return "voice busy" }
            pendingConfirm = { [unowned self] in try? FileManager.default.removeItem(at: VoiceInstaller.declineFile); self.installVoice() }
            pendingUntil = now() + 25
            reply("The natural voice is a free download of about 370 megabytes. It runs entirely on this Mac. Shall I get it? Say yes or no.")
            return "voice install?"
        }
        reply(Kokoro.installed ? "Yes, the natural voice is installed. I'm speaking as \(Kokoro.shared.enabled ? Kokoro.shared.name : "the Mac's own voice") now." : "Not yet. Say, install the natural voice, and I'll download it. It's free.")
        return "voice status"
    }

    /// Called when the welcome is finished, and at every start after that: if the natural voice
    /// is not there yet and the person has not chosen the Mac's voice, it is fetched in the background.
    func fetchVoiceIfWanted(announce: Bool) {
        guard !Opt.fast, !Opt.textMode, !SherpaVoice.installed, !VoiceInstaller.running, !VoiceInstaller.declined else { return }
        // Someone with the older, Python-run voice gets the built-in one quietly: same voices, quicker to start, nothing to break.
        if Kokoro.python { installVoice(quiet: true, opening: nil, upgrade: true); return }
        installVoice(quiet: true, opening: announce ? "I'm fetching my natural voice in the background. It's a one time download, and I'll switch to it the moment it's ready." : nil)
    }

    func installVoice(quiet: Bool = false, opening: String? = "Starting now. Carry on with whatever you like. I'll tell you when each step is done.", upgrade: Bool = false) {
        if Opt.fast { run { g in self.say("Installing.", g) }; return }
        VoiceInstaller.running = true
        VoiceInstaller.cancelled = false
        if let line = opening { DispatchQueue.global().async { while self.lastSpokenAt > now() { usleep(200_000) }; self.announce(line) } }
        DispatchQueue.global(qos: .utility).async {
            let problem = VoiceInstaller.install { step in
                ui("now Fetching the natural voice")
                if quiet { return }
                while self.lastSpokenAt > now() { usleep(200_000) }
                self.announce(step)
            }
            if VoiceInstaller.cancelled { VoiceInstaller.running = false; return }
            VoiceInstaller.running = false
            ui("now ")
            while self.lastSpokenAt > now() { usleep(200_000) }
            if let p = problem {
                self.noteMistake("the natural voice did not install", p)
                // When it was fetching by itself, a failure is not announced: it simply tries again next time.
                if !quiet { self.announce(p) }
                return
            }
            if upgrade {
                // The old helper's files go to the Trash, where they can still be got back. The new voice takes over at the next start.
                if SherpaVoice.load(british: Kokoro.shared.voice.hasPrefix("b")) {
                    for name in [".venv", "python", "bin", "kokoro-v1.0.onnx", "voices-v1.0.bin", "uv-cache"] {
                        let u = Kokoro.folder.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
                    }
                    logLine("natural voice: moved to the built-in engine; the old Python files are in the Trash")
                }
                return
            }
            Kokoro.shared.start()
            guard Kokoro.shared.available() else { self.announce("Everything downloaded, but the voice wouldn't start. Quit Nova and open it again, and it should be there."); return }
            ui("voice " + Kokoro.shared.name + " (Kokoro)")
            self.run { g in self.say("And this is my natural voice. Much better, isn't it? Say next voice to try the others, or audition the voices to hear them all.", g) }
        }
    }
}
