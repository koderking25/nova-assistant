// The natural voice: an optional download.
//
// Nova speaks with the Mac's own voice out of the box. The natural voices (Kokoro, an open
// speech model that runs on this Mac) need about 600 MB of files, so they are fetched only
// when asked for: a small Python, the kokoro-onnx package, and the model itself. Everything
// goes into Nova's own folder, and "remove the natural voice" takes it all away again.

import Foundation

enum VoiceInstaller {
    static var running = false
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
    static func install(progress: (String) -> Void) -> String? {
        let fm = FileManager.default
        let dir = Kokoro.folder
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        if free < 1_500_000_000 { return "There isn't enough free space. The natural voice needs about one and a half gigabytes while it installs." }
        try? fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        placeHelper()
        guard fm.fileExists(atPath: baseDir.appendingPathComponent("kokoro_server.py").path) else { return "A file that should be inside the app is missing. Downloading Nova again should fix it." }
        func curl(_ url: String, to file: URL, minutes: Double) -> Bool {
            let part = file.appendingPathExtension("part")
            let r = runTool("/usr/bin/curl", ["-fsSL", "--retry", "3", "-C", "-", "-m", "\(Int(minutes * 60))", "-o", part.path, url], timeout: minutes * 60 + 30)
            guard r.ok, fm.fileExists(atPath: part.path) else { return false }
            try? fm.removeItem(at: file)
            return (try? fm.moveItem(at: part, to: file)) != nil
        }
        // 1. A small tool that sets up Python without touching the system's own.
        let uv = dir.appendingPathComponent("bin/uv")
        if !fm.isExecutableFile(atPath: uv.path) {
            progress("Step one of three: a small setup tool.")
            let tar = dir.appendingPathComponent("uv.tar.gz")
            guard curl(uvURL, to: tar, minutes: 5) else { return "I couldn't download the setup tool. Check the internet connection and ask me again." }
            guard runTool("/usr/bin/tar", ["-xzf", tar.path, "-C", dir.appendingPathComponent("bin").path, "--strip-components", "1"], timeout: 60).ok, fm.isExecutableFile(atPath: uv.path) else { return "The setup tool wouldn't unpack." }
            try? fm.removeItem(at: tar)
        }
        // 2. Python and the speech package, kept inside Nova's folder.
        let python = dir.appendingPathComponent(".venv/bin/python")
        let env = ["UV_PYTHON_INSTALL_DIR=\(dir.appendingPathComponent("python").path)", "UV_CACHE_DIR=\(dir.appendingPathComponent("uv-cache").path)"]
        if !fm.isExecutableFile(atPath: python.path) {
            progress("Step two of three: the speech engine. This takes a minute or two.")
            let made = runTool("/usr/bin/env", env + [uv.path, "venv", "--python", "3.12", dir.appendingPathComponent(".venv").path], timeout: 600)
            guard made.ok, fm.isExecutableFile(atPath: python.path) else { return "Python wouldn't set up: \(made.out.suffix(120))" }
        }
        let have = runTool(python.path, ["-I", "-c", "import kokoro_onnx, onnxruntime, numpy"], timeout: 60)
        if !have.ok {
            let got = runTool("/usr/bin/env", env + [uv.path, "pip", "install", "--python", python.path, "kokoro-onnx>=0.4,<1"], timeout: 1200)
            guard got.ok else { return "The speech engine wouldn't install: \(got.out.suffix(120))" }
        }
        try? fm.removeItem(at: dir.appendingPathComponent("uv-cache"))
        // 3. The voices themselves.
        let voicesFile = dir.appendingPathComponent("voices-v1.0.bin"), modelFile = dir.appendingPathComponent("kokoro-v1.0.onnx")
        if !fm.fileExists(atPath: voicesFile.path) {
            guard curl(voices, to: voicesFile, minutes: 10) else { return "I couldn't download the voices. Ask me again and I'll carry on from where it stopped." }
        }
        if !fm.fileExists(atPath: modelFile.path) {
            progress("Step three of three: the voice itself. It's 325 megabytes, so this is the long one.")
            guard curl(model, to: modelFile, minutes: 45) else { return "The download stopped part way. Ask me again and I'll carry on from where it stopped." }
        }
        let size = ((try? fm.attributesOfItem(atPath: modelFile.path))?[.size] as? Int) ?? 0
        guard size > 300_000_000 else { try? fm.removeItem(at: modelFile); return "The voice file came down incomplete. Ask me again to retry." }
        return nil
    }
}

extension Engine {
    func voiceInstallHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        let natural = h.has("natural voice", "natural voices", "better voice", "human voice", "nicer voice", "realistic voice", "real voice", "kokoro", "good voice", "new voice pack", "voice pack", "premium voice")
        guard natural else { return nil }
        if h.has("remove", "uninstall", "delete", "get rid of") {
            guard Kokoro.installed || FileManager.default.fileExists(atPath: Kokoro.folder.path) else { reply("The natural voice isn't installed."); return "voice remove" }
            pendingConfirm = { [unowned self] in
                Kokoro.shared.shutDown()
                if !Opt.fast { try? FileManager.default.removeItem(at: Kokoro.folder) }
                self.run { g in self.say("The natural voice is removed. I'm back to the Mac's own voice after the next restart.", g) }
            }
            pendingUntil = now() + 20
            reply("Remove the natural voice and free about 600 megabytes? Say yes or no."); return "voice remove?"
        }
        if h.has("install", "download", "get", "add", "set up", "turn on", "i want", "give me", "use", "switch to", "can i have") {
            if Kokoro.installed { reply("The natural voice is already installed. Say next voice to hear the others, or audition the voices."); return "voice have" }
            if VoiceInstaller.running { reply("It's already downloading. I'll tell you the moment it's ready."); return "voice busy" }
            pendingConfirm = { [unowned self] in self.installVoice() }
            pendingUntil = now() + 25
            reply("The natural voice is a free download of about 400 megabytes, and uses about 600 on your disk. It runs entirely on this Mac. Shall I get it? Say yes or no.")
            return "voice install?"
        }
        reply(Kokoro.installed ? "Yes, the natural voice is installed. I'm speaking as \(Kokoro.shared.enabled ? Kokoro.shared.name : "the Mac's own voice") now." : "Not yet. Say, install the natural voice, and I'll download it. It's free.")
        return "voice status"
    }

    func installVoice() {
        if Opt.fast { run { g in self.say("Installing.", g) }; return }
        VoiceInstaller.running = true
        run { g in self.say("Starting now. Carry on with whatever you like. I'll tell you when each step is done.", g) }
        DispatchQueue.global(qos: .utility).async {
            let problem = VoiceInstaller.install { step in
                ui("now Installing the natural voice")
                while self.lastSpokenAt > now() { usleep(200_000) }
                self.speaker.say(step)
            }
            VoiceInstaller.running = false
            while self.lastSpokenAt > now() { usleep(200_000) }
            if let p = problem {
                self.noteMistake("the natural voice did not install", p)
                self.speaker.say(p)
                return
            }
            Kokoro.shared.start()
            guard Kokoro.shared.available() else { self.speaker.say("Everything downloaded, but the voice wouldn't start. Quit Nova and open it again, and it should be there."); return }
            ui("voice " + Kokoro.shared.name + " (Kokoro)")
            self.run { g in self.say("And this is my natural voice. Much better, isn't it? Say next voice to try the others, or audition the voices to hear them all.", g) }
        }
    }
}
