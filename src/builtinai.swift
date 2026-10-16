// A brain of its own, for any Mac.
//
// Macs without Apple Intelligence (older ones, Intel ones, or with it switched off) still get a
// language model that runs entirely on the Mac: Qwen 2.5, 1.5 billion parameters, run by
// llama.cpp. Both are open source (Apache 2.0 and MIT). They are fetched once, about 1.1 GB,
// checked against fixed checksums, and kept in Nova's own folder. After that nothing is sent
// anywhere: there is no account, no key and no internet needed to answer.
//
// The model runs in a small helper program (llama-server) that only listens on this Mac
// (127.0.0.1), kept running in the background so answers start quickly.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum BuiltInAI {
    static let folder = baseDir.appendingPathComponent("brain")
    static let build = "b11262"
    #if arch(arm64)
    static let archive = (url: "https://github.com/ggml-org/llama.cpp/releases/download/b11262/llama-b11262-bin-macos-arm64.tar.gz",
                          sha: "29c8887969de8014cde399efb572ecca7883010726f6292ffa3d784165fafd2d")
    #else
    static let archive = (url: "https://github.com/ggml-org/llama.cpp/releases/download/b11262/llama-b11262-bin-macos-x64.tar.gz",
                          sha: "01bdac9e66ee6e480e69c0d51e085190371ad0f57b0a6c4c89bd9d227a401c85")
    #endif
    static let model = (url: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
                        sha: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e", bytes: 1_117_320_736)
    static var server: URL { folder.appendingPathComponent("llama-\(build)/llama-server") }
    static var modelFile: URL { folder.appendingPathComponent("qwen2.5-1.5b-instruct-q4_k_m.gguf") }
    static var declineFile: URL { baseDir.appendingPathComponent("brain-declined.txt") }

    static var installed: Bool {
        FileManager.default.isExecutableFile(atPath: server.path) && ((try? modelFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) == model.bytes
    }
    static var declined: Bool { FileManager.default.fileExists(atPath: declineFile.path) }
    static var installing = false
    static var progress = ""                     // "40 percent", while fetching

    private static let lock = NSLock()
    private static var process: Process?
    private static var port = 0
    private static var made = ""                 // the instructions the conversation was started with
    private static var history: [[String: String]] = []

    // MARK: Fetching it

    /// Returns nil when done, or a sentence saying what went wrong.
    static func install(step: @escaping (String) -> Void) -> String? {
        let fm = FileManager.default
        lock.lock()
        if installing { lock.unlock(); return "I'm already fetching it." }
        installing = true
        lock.unlock()
        defer { lock.lock(); installing = false; progress = ""; lock.unlock() }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        if !installed && free < 2_500_000_000 { return "There isn't enough free space. My built-in brain needs about two and a half gigabytes free while it installs." }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func sha(_ f: URL) -> String { runTool("/usr/bin/shasum", ["-a", "256", f.path], timeout: 120).out.split(separator: " ").first.map(String.init) ?? "" }
        func fetch(_ url: String, to file: URL, minutes: Double, watch total: Int? = nil) -> Bool {
            let part = file.appendingPathExtension("part")
            // For testing the installer without the internet: NOVA_MIRROR names a folder holding the same files.
            let url = ProcessInfo.processInfo.environment["NOVA_MIRROR"].map { "file://" + $0 + "/" + (url.components(separatedBy: "/").last ?? "") } ?? url
            var done = false
            if let total = total {
                DispatchQueue.global(qos: .utility).async {
                    var said = 0
                    while !done {
                        let have = (try? part.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        let pc = min(99, have * 100 / max(1, total))
                        lock.lock(); progress = "\(pc) percent"; lock.unlock()
                        ui("now Fetching my built-in brain: \(pc) percent")
                        if pc >= said + 25, pc < 99 { said = pc / 25 * 25; if said > 0 { step("\(said) percent of my brain is here.") } }
                        sleep(2)
                    }
                }
            }
            let r = runTool("/usr/bin/curl", ["-fsSL", "--retry", "3", "-C", "-", "-m", "\(Int(minutes * 60))", "-o", part.path, url], timeout: minutes * 60 + 30)
            done = true
            guard r.ok, fm.fileExists(atPath: part.path) else { return false }
            try? fm.removeItem(at: file)
            return (try? fm.moveItem(at: part, to: file)) != nil
        }
        // The program that runs the model: about 11 MB.
        if !fm.isExecutableFile(atPath: server.path) {
            let tar = folder.appendingPathComponent("llama.tar.gz")
            guard fetch(archive.url, to: tar, minutes: 10) else { return "I couldn't download part of my brain. Check the internet connection and ask me again." }
            guard sha(tar) == archive.sha else { try? fm.removeItem(at: tar); return "A download came back damaged, so I threw it away. Ask me again to retry." }
            guard runTool("/usr/bin/tar", ["-xzf", tar.path, "-C", folder.path], timeout: 120).ok, fm.isExecutableFile(atPath: server.path) else { return "I couldn't unpack part of my brain. Ask me again to retry." }
            try? fm.removeItem(at: tar)
        }
        // The model itself: about 1.1 GB.
        if !installed {
            step("The download is about one gigabyte. I'll keep working while it comes in.")
            guard fetch(model.url, to: modelFile, minutes: 120, watch: model.bytes) else { return "The download stopped part way. Ask me again and I'll carry on from where it stopped." }
            guard sha(modelFile) == model.sha else { try? fm.removeItem(at: modelFile); return "The download came back damaged, so I threw it away. Ask me again to retry." }
        }
        try? fm.removeItem(at: declineFile)
        return start() ? nil : "Everything downloaded, but my brain wouldn't start. Quit Nova and open it again."
    }

    // MARK: Running it

    static var running: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true && port > 0 }

    /// Starts the helper if it is not running. Waits until the model is loaded. True if it is ready.
    @discardableResult
    static func start() -> Bool {
        guard installed, !Opt.fast else { return false }
        lock.lock()
        if process?.isRunning == true, port > 0 { lock.unlock(); return true }
        // Any left behind by a Nova that did not get to close it.
        _ = runTool("/usr/bin/pkill", ["-f", server.path], timeout: 3)
        let p = Process()
        let chosen = Int.random(in: 47000...48999)
        // Run under a small watchdog: when Nova goes away, for any reason, the helper goes with it,
        // so a gigabyte of memory is never left in use by something nobody can see.
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        #if arch(arm64)
        let gpu = ["-ngl", "99"]
        #else
        let gpu = ["-ngl", "0"]
        #endif
        let threads = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
        let serverArgs = ["-m", modelFile.path, "--host", "127.0.0.1", "--port", "\(chosen)", "-c", "4096", "-np", "1", "-t", "\(threads)", "--no-webui"] + gpu
        let watch = "\"$0\" \"$@\" & c=$!; trap 'kill $c 2>/dev/null; exit 0' TERM INT; while kill -0 \(getpid()) 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 2; done; kill $c 2>/dev/null"
        p.arguments = ["-c", watch, server.path] + serverArgs
        p.currentDirectoryURL = server.deletingLastPathComponent()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .userInitiated
        do { try p.run() } catch { lock.unlock(); logLine("built-in brain: could not start: \(error)"); return false }
        process = p
        port = chosen
        lock.unlock()
        // Loading takes a second or two from a fast disk.
        for _ in 0..<120 {
            if !p.isRunning { break }
            if get("/health")?.contains("ok") == true { logLine("built-in brain: ready on port \(chosen)"); return true }
            usleep(250_000)
        }
        logLine("built-in brain: did not become ready")
        stop()
        return false
    }

    static func stop() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
        process = nil
        port = 0
    }

    private static func get(_ path: String) -> String? {
        lock.lock(); let p = port; lock.unlock()
        guard p > 0, let url = URL(string: "http://127.0.0.1:\(p)\(path)") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 2
        return send(req, wait: 3).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func send(_ req: URLRequest, wait: Double) -> Data? {
        let done = DispatchSemaphore(value: 0)
        var out: Data?
        let task = URLSession.shared.dataTask(with: req) { d, r, _ in
            if (r as? HTTPURLResponse)?.statusCode == 200 { out = d }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + wait) == .timedOut { task.cancel(); return nil }
        return out
    }

    /// One turn of the conversation. Nil if it could not answer.
    static func ask(_ prompt: String, instructions: String, maxWords: Int = 160) -> String? {
        guard start() else { return nil }
        lock.lock()
        // A short memory of the conversation, started afresh when the instructions change.
        if made != instructions || history.count > 8 { history = []; made = instructions }
        let messages = [["role": "system", "content": instructions]] + history + [["role": "user", "content": prompt]]
        let p = port
        lock.unlock()
        guard let url = URL(string: "http://127.0.0.1:\(p)/v1/chat/completions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = ["messages": messages, "temperature": 0.3, "top_p": 0.9, "max_tokens": maxWords, "cache_prompt": true, "stream": false]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let d = send(req, wait: 60), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choice = (o["choices"] as? [[String: Any]])?.first, let msg = choice["message"] as? [String: Any],
              let text = (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        lock.lock()
        history += [["role": "user", "content": prompt], ["role": "assistant", "content": text]]
        lock.unlock()
        return text
    }
}

extension Engine {
    /// "Install your brain", or offered when a question comes and there is nothing to answer it with.
    func installBrain(announce: Bool = true) {
        guard !Opt.fast else { run { g in self.say("Installing.", g) }; return }
        guard !BuiltInAI.installing else { run { g in self.say("It's on its way: \(BuiltInAI.progress.isEmpty ? "starting" : BuiltInAI.progress).", g) }; return }
        if announce { run { g in self.say(self.styled(classic: ["Fetching my brain. It's about a gigabyte, once only, and it runs entirely on this Mac. Carry on, I'll say when it's ready."],
                                                         warm: ["I'm fetching my own brain now. It's about a gigabyte, just this once, and after that it works with no internet at all. I'll tell you when it's ready."],
                                                         playful: ["Brain transplant in progress. About a gigabyte, once only, and then I think for myself, offline. I'll shout when it's done."],
                                                         brief: ["Fetching my brain. About a gigabyte. I'll say when it's ready."]), g) } }
        DispatchQueue.global(qos: .utility).async {
            let problem = BuiltInAI.install { step in if announce { self.announce(step) } }
            ui("now ")
            if let p = problem { self.noteMistake("the built-in brain did not install", p); if announce { self.announce(p) }; return }
            self.announce(self.styled(classic: ["My brain is in. Ask me anything."], warm: ["My brain is ready. Ask me anything you like."],
                                      playful: ["It's alive. Brain online. Ask me anything."], brief: ["Brain ready."]))
        }
    }

    /// After the welcome, and at each start: a Mac with no other language model gets the built-in one,
    /// unless the person said no to it. A download that was cut off carries on.
    func fetchBrainIfWanted(announce: Bool) {
        guard !Opt.fast, !Opt.textMode, !BuiltInAI.installed, !BuiltInAI.installing, !BuiltInAI.declined, !LocalAI.apple else { return }
        let partial = FileManager.default.fileExists(atPath: BuiltInAI.modelFile.appendingPathExtension("part").path)
        guard announce || partial else { return }      // never a surprise gigabyte: only when asked for in the welcome, or to finish one begun
        // After the natural voice, when that is coming too: one download at a time is faster for both.
        DispatchQueue.global(qos: .utility).async {
            while VoiceInstaller.running { sleep(3) }
            self.installBrain(announce: announce)
        }
    }

    /// Voice: install, remove, or ask about the built-in brain.
    func brainHear(_ h: Heard) -> String? {
        let about = h.has("brain", "built in ai", "builtin ai", "offline ai", "local ai", "ai model", "own ai")
        guard about else { return nil }
        if h.has("how is", "hows", "going", "status", "progress", "how far", "ready yet", "done yet") {
            let s = BuiltInAI.installing ? "It's coming in: \(BuiltInAI.progress.isEmpty ? "just starting" : BuiltInAI.progress)." : BuiltInAI.installed ? "My brain is installed\(BuiltInAI.running ? " and awake" : "")." : "I don't have my built-in brain yet. Say install your brain."
            run { g in self.say(s, g) }; return "brain status"
        }
        if h.has("install", "download", "get", "fetch", "add", "set up", "setup", "give yourself", "turn on", "enable") && !h.has("uninstall", "remove", "delete") {
            if BuiltInAI.installed { run { g in self.say("My brain is already here.", g) }; return "brain have" }
            installBrain(); return "brain install"
        }
        return nil
    }
}

func builtInAISelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let a = engine.brainHear(Heard("install your brain"))
    let b = engine.brainHear(Heard("how is the brain download going"))
    let c = engine.brainHear(Heard("open safari"))
    check("built-in brain: it can be installed and asked about by voice, and other requests are left alone", (a == "brain install" || a == "brain have") && b == "brain status" && c == nil, "\(a ?? "nil") \(b ?? "nil") \(c ?? "nil")")
}
