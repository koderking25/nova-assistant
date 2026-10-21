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
    /// Where a downloaded copy goes. Newer apps carry the voice inside themselves instead (see `folder`).
    static let downloaded = baseDir.appendingPathComponent("jarvis-voice")
    /// Inside the app: Nova.app/Contents/Resources/jarvis-voice, with its own Python.
    static var builtIn: URL? {
        var places: [String] = []
        if let r = ProcessInfo.processInfo.environment["NOVA_APP_RESOURCES"], !r.isEmpty { places.append(r) }
        places.append("/Applications/Nova.app/Contents/Resources")
        return places.map { URL(fileURLWithPath: $0).appendingPathComponent("jarvis-voice") }
            .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("python/bin/python3").path) }
    }
    static var folder: URL { complete(downloaded) ? downloaded : builtIn ?? downloaded }
    static var python: URL {
        let venv = folder.appendingPathComponent("env/bin/python")
        return FileManager.default.isExecutableFile(atPath: venv.path) ? venv : folder.appendingPathComponent("python/bin/python3")
    }
    /// The helper script comes with the engine; a copy beside the voice is the fallback.
    static var helper: URL {
        let name = "jarvis_voice_server.py"
        var places = [URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(name)]
        // The app's starter copies a fixed list of files into the Library; older starters leave this one behind,
        // so the copy inside the app itself is looked for too.
        if let r = ProcessInfo.processInfo.environment["NOVA_APP_RESOURCES"], !r.isEmpty { places.append(URL(fileURLWithPath: r).appendingPathComponent("payload/" + name)) }
        places.append(URL(fileURLWithPath: "/Applications/Nova.app/Contents/Resources/payload/" + name))
        places.append(downloaded.appendingPathComponent(name))
        return places.first { FileManager.default.fileExists(atPath: $0.path) } ?? places[0]
    }
    private static func complete(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return (fm.isExecutableFile(atPath: dir.appendingPathComponent("env/bin/python").path) || fm.isExecutableFile(atPath: dir.appendingPathComponent("python/bin/python3").path))
            && fm.fileExists(atPath: dir.appendingPathComponent("voice.wav").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("hf/hub/models--mlx-community--pocket-tts-8bit").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("hf/hub/models--kyutai--pocket-tts-without-voice-cloning").path)
    }
    static var appleSilicon: Bool {
        var info = utsname(); uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        // Under Rosetta uname says x86_64, so ask the system directly too.
        var arm: Int32 = 0; var size = MemoryLayout<Int32>.size
        return machine == "arm64" || (sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1)
    }
    static var installed: Bool { appleSilicon && complete(folder) }

    /// How it sounds: which sample it copies, how lively it is, and how strong the hologram finish is.
    struct Style: Codable, Equatable {
        var sample = ""            // empty: the voice that comes with it
        var temp = 1.0
        var finish = "light"
        static let file = baseDir.appendingPathComponent("jarvis-voice-style.json")
        static var current: Style {
            get { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Style.self, from: $0) } ?? Style() }
            set { if !Opt.fast, let d = try? JSONEncoder().encode(newValue) { try? d.write(to: file) } }
        }
        var tag: String { "\(sample.isEmpty ? "p226" : URL(fileURLWithPath: sample).lastPathComponent)-\(temp)-\(finish)" }
    }

    /// Changes how it sounds; the helper starts again with the new style.
    func restyle(_ change: (inout Style) -> Void) {
        var s = Style.current; change(&s); Style.current = s
        if Opt.fast { return }                    // checks never start the real voice
        shutDown()
        DispatchQueue.global().async { _ = self.waitReady(30) }
    }

    enum State { case off, starting, ready, failed }
    private var failedAt = -100.0
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
        let target = downloaded.appendingPathComponent("jarvis_voice_server.py")
        guard FileManager.default.fileExists(atPath: downloaded.path), let code = FileManager.default.contents(atPath: beside.path) else { return }
        if FileManager.default.contents(atPath: target.path) != code { FileManager.default.createFile(atPath: target.path, contents: code) }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard state == .off || state == .failed, JarvisVoice.installed else { return }
        JarvisVoice.placeHelper()
        guard FileManager.default.fileExists(atPath: JarvisVoice.helper.path) else { state = .failed; return }
        state = .starting
        let p = Process()
        p.executableURL = JarvisVoice.python
        p.arguments = ["-I", "-B", JarvisVoice.helper.path, JarvisVoice.folder.path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = JarvisVoice.folder.appendingPathComponent("hf").path
        env["PYTHONDONTWRITEBYTECODE"] = "1"              // the copy inside the app is never written to
        env["HF_HUB_OFFLINE"] = "1"                       // everything it needs is already here: never reach out
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        let style = Style.current
        env["NOVA_VOICE_TEMP"] = String(style.temp)
        env["NOVA_VOICE_FINISH"] = style.finish
        env["NOVA_VOICE_SAMPLE"] = style.sample
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
        p.terminationHandler = { [weak self] ended in
            guard let self = self else { return }
            self.lock.lock()
            // A helper that was shut down on purpose (and perhaps already replaced) changes nothing.
            guard ended === self.process else { self.lock.unlock(); return }
            self.process = nil; self.input = nil
            self.state = .failed
            self.failedAt = now()
            for (_, r) in self.replies { r.0.signal() }
            self.lock.unlock()
            logLine("Jarvis voice helper stopped")
        }
        do { try p.run(); process = p; input = inPipe.fileHandleForWriting } catch { state = .failed }
    }

    /// Stops the helper now. The next sentence starts a fresh one, rather than going to the one that is ending.
    func shutDown() {
        lock.lock()
        let p = process, i = input, waiting = replies
        process = nil; input = nil; replies = [:]
        if state != .off { state = .off }
        buffer = Data()
        lock.unlock()
        waiting.values.forEach { $0.0.signal() }
        try? i?.close(); p?.terminate()
    }

    /// Waits for the voice to finish loading (a few seconds at most). True when it can speak.
    func waitReady(_ seconds: Double = 15) -> Bool {
        lock.lock(); let st = state, lastFail = failedAt; lock.unlock()
        // A helper that just failed is not restarted for every sentence: the Mac's voice fills in for half a minute.
        if st == .failed, now() - lastFail < 30 { return false }
        if st == .off || st == .failed { start() }
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
            else if parts[0] == "failed" { state = .failed; failedAt = now(); logLine("Jarvis voice could not start: \(parts.dropFirst().joined(separator: " "))") }
            else if let waiting = replies[parts[0]] { replies[parts[0]] = (waiting.0, parts.dropFirst().joined(separator: "\t")); waiting.0.signal() }
        }
    }

    /// One sentence to a sound file. True when it worked.
    func write(_ text: String, to url: URL, speed: Double = 1) -> Bool {
        guard waitReady() else { return false }
        lock.lock()
        guard let input = input else { lock.unlock(); return false }
        counter += 1
        let id = String(counter)
        let sem = DispatchSemaphore(value: 0)
        replies[id] = (sem, "")
        let clean = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        lock.unlock()
        do { try input.write(contentsOf: Data("\(id)\tjarvis\t\(String(format: "%.2f", speed))\t\(url.path)\t\(clean)\n".utf8)) } catch { return false }
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
        let dir = downloaded
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
        if !fm.isExecutableFile(atPath: dir.appendingPathComponent("env/bin/python").path) {
            guard sh(uv.path, ["venv", "-q", "--python", "3.12", dir.appendingPathComponent("env").path], timeout: 900).ok else {
                return "I couldn't set up the speech engine. Ask me again to carry on from where it stopped."
            }
        }
        let pip = sh(uv.path, ["pip", "install", "-q", "--python", dir.appendingPathComponent("env/bin/python").path, mlxAudio, "sentencepiece", "requests"], timeout: 1800)
        guard pip.ok else { return "The speech engine didn't finish downloading. Ask me again to carry on from where it stopped." }
        progress("Step three of four: the voice model.")
        let model = sh(dir.appendingPathComponent("env/bin/python").path, ["-I", "-B", "-c", "from mlx_audio.tts.utils import load_model; load_model('mlx-community/pocket-tts-8bit')"], timeout: 1800)
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
    /// "Be livelier", "calmer", "more robotic", "more natural": how the Jarvis voice delivers.
    func jarvisStyleHear(_ h: Heard) -> String? {
        guard Kokoro.shared.voice == JarvisVoice.id, Kokoro.shared.enabled else { return nil }
        // About the voice, not the music: "play something with more energy" is a request for music.
        guard h.has("voice", "sound", "talk", "speak", "yourself", "you", "your"), !h.has("play", "song", "music", "piece", "band", "track", "melody", "chord", "drums") else { return nil }
        let lively = h.has("livelier", "more lively", "more alive", "more expressive", "more energy", "more emotion", "less flat", "less dead", "less boring", "more excited", "more animated")
        let calm = h.has("calmer", "more calm", "less lively", "less expressive", "more relaxed", "more steady", "less excited", "tone it down")
        let robotic = h.has("more robotic", "more robot", "stronger effect", "more hologram", "more futuristic", "more ai", "more like a computer", "more digital")
        let natural = h.has("more natural", "less robotic", "more human", "lighter effect", "less hologram", "less effect", "less digital")
        guard lively || calm || robotic || natural else { return nil }
        let s = JarvisVoice.Style.current
        if lively && s.temp >= 1.3 || calm && s.temp <= 0.6 { run { g in self.say(lively ? "That's as lively as I get." : "That's as calm as I get.", g) }; return "voice style edge" }
        JarvisVoice.shared.restyle { st in
            if lively { st.temp = min(1.3, st.temp + 0.15) }
            if calm { st.temp = max(0.6, st.temp - 0.15) }
            if robotic { st.finish = "full" }
            if natural { st.finish = "light" }
        }
        run { g in self.say(lively ? "How's this? A bit more life in it." : calm ? "Calmer. Like this." : robotic ? "Hologram at full strength." : "A more natural sound. Like this.", g) }
        return "voice style"
    }

    func jarvisVoiceHear(_ h: Heard) -> String? {
        // The wake word is Jarvis too, so "Jarvis, voice louder" must not land here: an action word is needed.
        guard h.has("jarvis voice", "hologram voice", "futuristic voice", "ai voice", "pocket voice", "robot voice", "iron man voice"),
              h.has("install", "download", "get", "use", "switch", "change", "remove", "uninstall", "delete", "turn on", "give me", "want", "try", "put on", "go back to"),
              !h.has("louder", "quieter", "slower", "faster", "softer", "speak up") else { return nil }
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        if h.has("remove", "uninstall", "delete", "get rid of") {
            if JarvisVoice.builtIn != nil && !FileManager.default.fileExists(atPath: JarvisVoice.downloaded.path) { reply("The Jarvis voice is built into the app, so there's nothing to remove. Say next voice to use another one."); return "jarvis voice built in" }
            guard FileManager.default.fileExists(atPath: JarvisVoice.downloaded.path) else { reply("The Jarvis voice isn't installed."); return "jarvis voice remove" }
            pendingConfirm = { [unowned self] in
                JarvisVoice.shared.shutDown()
                if Kokoro.shared.voice == JarvisVoice.id { _ = Kokoro.shared.nextVoice() }
                if !Opt.fast { try? FileManager.default.removeItem(at: JarvisVoice.downloaded) }
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

func jarvisStyleSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let savedVoice = Kokoro.shared.voice, savedOn = Kokoro.shared.enabled
    Kokoro.shared.voice = JarvisVoice.id; Kokoro.shared.enabled = true
    let yes = ["can you sound more lively", "make your voice more natural", "talk calmer", "make your voice more robotic"].map { engine.jarvisStyleHear(Heard($0)) }
    let no = ["play something with more energy", "make the band more exciting", "play a calmer song", "make it more epic"].map { engine.jarvisStyleHear(Heard($0)) }
    Kokoro.shared.voice = savedVoice; Kokoro.shared.enabled = savedOn
    check("voice style: lively, calm, robotic and natural change the voice, and the same words about music are left for the music",
          yes.allSatisfy { $0 != nil } && no.allSatisfy { $0 == nil }, "\(yes) \(no)")
}
