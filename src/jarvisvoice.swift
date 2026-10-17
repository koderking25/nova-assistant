// The Jarvis voice: Kyutai's Pocket TTS, run on the Mac's graphics chip with Apple's MLX, in a
// British voice with a "hologram" finish (bright, a faint doubled shimmer, a small clean room).
//
// It is an optional download of about 600 MB, for Macs with Apple silicon. A small Python helper
// (jarvis_voice_server.py, in its own environment under jarvis-voice/) keeps the model loaded;
// Nova sends it one sentence at a time and plays the sound file it writes.
//
// Credits: Pocket TTS by Kyutai (CC BY 4.0). The voice is VCTK speaker p226 (CC BY 4.0, Centre
// for Speech Technology Research, University of Edinburgh), from Kyutai's tts-voices.

import Foundation

final class JarvisVoice {
    static let shared = JarvisVoice()
    static let id = "jarvis"
    static let folder = baseDir.appendingPathComponent("jarvis-voice")
    static var python: URL { folder.appendingPathComponent("env/bin/python") }
    static var helper: URL { folder.appendingPathComponent("jarvis_voice_server.py") }
    static var appleSilicon: Bool {
        var info = utsname(); uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        // Under Rosetta uname says x86_64, so ask the system directly too.
        var arm: Int32 = 0; var size = MemoryLayout<Int32>.size
        return machine == "arm64" || (sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1)
    }
    static var installed: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python.path) && fm.fileExists(atPath: folder.appendingPathComponent("voice.wav").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("hf/hub/models--mlx-community--pocket-tts-8bit").path)
    }

    enum State { case off, starting, ready, failed }
    private(set) var state = State.off
    private var process: Process?
    private var input: FileHandle?
    private let lock = NSLock()
    private var replies: [String: (DispatchSemaphore, String)] = [:]
    private var buffer = Data()
    private var counter = 0

    /// The helper travels inside the app; it is copied next to the voice whenever it has changed.
    static func placeHelper() {
        let beside = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("jarvis_voice_server.py")
        guard FileManager.default.fileExists(atPath: folder.path), let code = FileManager.default.contents(atPath: beside.path) else { return }
        if FileManager.default.contents(atPath: helper.path) != code { FileManager.default.createFile(atPath: helper.path, contents: code) }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard state == .off || state == .failed, JarvisVoice.installed else { return }
        JarvisVoice.placeHelper()
        guard FileManager.default.fileExists(atPath: JarvisVoice.helper.path) else { state = .failed; return }
        state = .starting
        let p = Process()
        p.executableURL = JarvisVoice.python
        p.arguments = ["-I", JarvisVoice.helper.path, JarvisVoice.folder.path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = JarvisVoice.folder.appendingPathComponent("hf").path
        env["HF_HUB_OFFLINE"] = "1"                       // everything it needs is already here: never reach out
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
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
        p.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.state = .failed
            for (_, r) in self.replies { r.0.signal() }
            self.lock.unlock()
            logLine("Jarvis voice helper stopped")
        }
        do { try p.run(); process = p; input = inPipe.fileHandleForWriting } catch { state = .failed }
    }

    func shutDown() { try? input?.close(); process?.terminate() }

    /// Waits for the voice to finish loading (a few seconds at most). True when it can speak.
    func waitReady(_ seconds: Double = 15) -> Bool {
        if state == .off || state == .failed { start() }
        let until = now() + seconds
        while state == .starting, now() < until { usleep(50_000) }
        return state == .ready
    }

    private func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            let parts = line.components(separatedBy: "\t")
            if parts[0] == "ready" { state = .ready; logLine("Jarvis voice ready") }
            else if parts[0] == "failed" { state = .failed; logLine("Jarvis voice could not start: \(parts.dropFirst().joined(separator: " "))") }
            else if let waiting = replies[parts[0]] { replies[parts[0]] = (waiting.0, parts.dropFirst().joined(separator: "\t")); waiting.0.signal() }
        }
    }

    /// One sentence to a sound file. True when it worked.
    func write(_ text: String, to url: URL) -> Bool {
        guard waitReady() else { return false }
        lock.lock()
        guard let input = input else { lock.unlock(); return false }
        counter += 1
        let id = String(counter)
        let sem = DispatchSemaphore(value: 0)
        replies[id] = (sem, "")
        let clean = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        lock.unlock()
        do { try input.write(contentsOf: Data("\(id)\tjarvis\t1\t\(url.path)\t\(clean)\n".utf8)) } catch { return false }
        let timedOut = sem.wait(timeout: .now() + 25) == .timedOut
        lock.lock()
        let answer = replies.removeValue(forKey: id)?.1 ?? ""
        lock.unlock()
        return !timedOut && answer.hasPrefix("ok") && FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Installing

    static var running = false
    static let mlxAudio = "mlx-audio==0.5.9"
    static let voiceURL = "https://huggingface.co/kyutai/tts-voices/resolve/main/vctk/p226_023_enhanced.wav"

    /// Fetches and sets up everything, about 600 MB. Returns nil when it worked, or a sentence saying what went wrong.
    static func install(progress: @escaping (String) -> Void) -> String? {
        guard appleSilicon else { return "The Jarvis voice needs a Mac with Apple silicon, an M1 or newer. This Mac keeps its current voice." }
        let fm = FileManager.default
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        if free < 2_500_000_000 { return "There isn't enough free space. The Jarvis voice needs about two and a half gigabytes free while it installs, and keeps about 600 megabytes." }
        let dir = folder
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["UV_CACHE_DIR"] = dir.appendingPathComponent("uv-cache").path
        env["UV_PYTHON_INSTALL_DIR"] = dir.appendingPathComponent("python").path
        env["HF_HOME"] = dir.appendingPathComponent("hf").path
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        func sh(_ tool: String, _ args: [String], timeout: Double) -> (ok: Bool, out: String) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args; p.environment = env
            p.currentDirectoryURL = dir
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return (false, "\(error)") }
            let until = Date().addingTimeInterval(timeout)
            while p.isRunning, Date() < until { usleep(200_000) }
            if p.isRunning { p.terminate(); return (false, "took too long") }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (p.terminationStatus == 0, out)
        }
        progress("Step one of four: the installer.")
        let uv = dir.appendingPathComponent("uv")
        if !fm.isExecutableFile(atPath: uv.path) {
            let tar = dir.appendingPathComponent("uv.tar.gz")
            guard sh("/usr/bin/curl", ["-sfL", "--retry", "3", "-o", tar.path, VoiceInstaller.uvURL], timeout: 300).ok,
                  sh("/usr/bin/tar", ["-xzf", tar.path, "--strip-components", "1", "-C", dir.path], timeout: 60).ok else {
                return "I couldn't download the installer. Check the internet connection and ask me again."
            }
            try? fm.removeItem(at: tar)
        }
        progress("Step two of four: the speech engine. This is the big one.")
        if !fm.isExecutableFile(atPath: python.path) {
            guard sh(uv.path, ["venv", "-q", "--python", "3.12", dir.appendingPathComponent("env").path], timeout: 900).ok else {
                return "I couldn't set up the speech engine. Ask me again to carry on from where it stopped."
            }
        }
        let pip = sh(uv.path, ["pip", "install", "-q", "--python", python.path, mlxAudio, "sentencepiece", "requests"], timeout: 1800)
        guard pip.ok else { return "The speech engine didn't finish downloading. Ask me again to carry on from where it stopped." }
        progress("Step three of four: the voice model.")
        let model = sh(python.path, ["-I", "-c", "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/pocket-tts-8bit')"], timeout: 1800)
        guard model.ok else { return "The voice model didn't finish downloading. Ask me again to carry on from where it stopped." }
        progress("Step four of four: the voice itself.")
        let voice = dir.appendingPathComponent("voice.wav")
        guard sh("/usr/bin/curl", ["-sfL", "--retry", "3", "-o", voice.path, voiceURL], timeout: 300).ok, (try? Data(contentsOf: voice))?.count ?? 0 > 100_000 else {
            return "I couldn't download the voice sample. Ask me again to carry on."
        }
        // The downloads' working copies are not needed any more.
        try? fm.removeItem(at: dir.appendingPathComponent("uv-cache"))
        placeHelper()
        return installed ? nil : "Everything downloaded, but something is missing. Ask me to install the Jarvis voice again."
    }
}

extension Engine {
    func jarvisVoiceHear(_ h: Heard) -> String? {
        // The wake word is Jarvis too, so "Jarvis, voice louder" must not land here: an action word is needed.
        guard h.has("jarvis voice", "hologram voice", "futuristic voice", "ai voice", "pocket voice", "robot voice", "iron man voice"),
              h.has("install", "download", "get", "use", "switch", "change", "remove", "uninstall", "delete", "turn on", "give me", "want", "try", "put on", "go back to"),
              !h.has("louder", "quieter", "slower", "faster", "softer", "speak up") else { return nil }
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        if h.has("remove", "uninstall", "delete", "get rid of") {
            guard FileManager.default.fileExists(atPath: JarvisVoice.folder.path) else { reply("The Jarvis voice isn't installed."); return "jarvis voice remove" }
            pendingConfirm = { [unowned self] in
                JarvisVoice.shared.shutDown()
                if Kokoro.shared.voice == JarvisVoice.id { _ = Kokoro.shared.nextVoice() }
                if !Opt.fast { try? FileManager.default.removeItem(at: JarvisVoice.folder) }
                self.run { g in self.say("The Jarvis voice is removed, and its space is free again.", g) }
            }
            pendingUntil = now() + 20
            reply("Remove the Jarvis voice and free about 600 megabytes? Say yes or no."); return "jarvis voice remove?"
        }
        if JarvisVoice.installed {
            if Kokoro.shared.voice == JarvisVoice.id && Kokoro.shared.enabled { reply("This is the Jarvis voice."); return "jarvis voice have" }
            _ = Kokoro.shared.choose("Jarvis")
            run { g in self.say("Switched. This is the Jarvis voice.", g) }
            return "jarvis voice on"
        }
        if !JarvisVoice.appleSilicon { reply("The Jarvis voice needs a Mac with Apple silicon, an M1 or newer, so I'll keep this voice."); return "jarvis voice no" }
        if JarvisVoice.running { reply("It's already downloading. I'll tell you the moment it's ready."); return "jarvis voice busy" }
        pendingConfirm = { [unowned self] in self.installJarvisVoice() }
        pendingUntil = now() + 25
        reply("The Jarvis voice is a free download of about 600 megabytes, and it runs on this Mac. Shall I get it? Say yes or no.")
        return "jarvis voice install?"
    }

    func installJarvisVoice() {
        if Opt.fast { run { g in self.say("Installing.", g) }; return }
        JarvisVoice.running = true
        announce("Starting now. Carry on with whatever you like. I'll tell you when each step is done.")
        DispatchQueue.global(qos: .utility).async {
            let problem = JarvisVoice.install { step in
                ui("now Fetching the Jarvis voice")
                while self.lastSpokenAt > now() { usleep(200_000) }
                self.announce(step)
            }
            JarvisVoice.running = false
            ui("now ")
            while self.lastSpokenAt > now() { usleep(200_000) }
            if let p = problem { self.noteMistake("the Jarvis voice did not install", p); self.announce(p); return }
            Kokoro.shared.refreshVoices()
            guard Kokoro.shared.choose("Jarvis") != nil else { self.announce("Everything downloaded, but the voice wouldn't start. Quit Nova and open it again."); return }
            ui("voice Jarvis")
            self.run { g in self.say("Systems online. This is my new voice. Say next voice if you'd like the old one back.", g) }
        }
    }
}

func jarvisVoiceSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let asks = ["install the jarvis voice", "use the jarvis voice", "switch to the futuristic voice", "remove the jarvis voice"]
    let not = ["jarvis voice louder", "jarvis voice quieter", "jarvis voice slower"]
    let got = asks.map { engine.jarvisVoiceHear(Heard($0)) }
    let wrong = not.compactMap { engine.jarvisVoiceHear(Heard($0)) }
    engine.pendingConfirm = nil
    check("Jarvis voice: install, use and remove are understood, and \"Jarvis, voice louder\" is left alone",
          !got.contains(nil) && wrong.isEmpty, "\(got) \(wrong)")
}
