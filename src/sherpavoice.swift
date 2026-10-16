// The natural voice, made inside Nova itself.
//
// The same Kokoro voices as before (George and the rest), run by sherpa-onnx, a small open
// source speech library (Apache 2.0) that Nova loads directly. There is no Python and no helper
// program: two downloads, checked against fixed checksums, and nothing to set up. Each sentence
// becomes sound in this process, so there is nothing that can be left half started.

import Foundation
import Darwin

enum SherpaVoice {
    static let folder = Kokoro.folder.appendingPathComponent("sherpa")
    static let library = folder.appendingPathComponent("SherpaOnnxC")
    static let modelDir = folder.appendingPathComponent("kokoro-multi-lang-v1_0")
    static let libraryDownload = (url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.5-macos-shared-onnxruntime-static.xcframework.zip",
                                  sha: "886ba51951b278acbb72a95436b9b9da757e0d6be7cf4fcc85e23709da48fd90")
    static let modelDownload = (url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2",
                                sha: "c5f7e2d2caf082bc1d20fb70334a61d99d20b484500aad32e7cf84c128ea3298", bytes: 349_000_000)

    /// The model's speakers, in the order of its voices file.
    static let speakers = ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
                           "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa",
                           "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis"]

    static var installed: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: library.path) && ["model.onnx", "voices.bin", "tokens.txt", "espeak-ng-data"].allSatisfy { fm.fileExists(atPath: modelDir.appendingPathComponent($0).path) }
    }

    private typealias Create = @convention(c) (UnsafePointer<SherpaOnnxOfflineTtsConfig>?) -> OpaquePointer?
    private typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    private typealias Generate = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, Float) -> UnsafePointer<SherpaOnnxGeneratedAudio>?
    private typealias Free = @convention(c) (UnsafePointer<SherpaOnnxGeneratedAudio>?) -> Void

    private static let lock = NSLock()
    private static var handle: UnsafeMutableRawPointer?
    private static var tts: OpaquePointer?
    private static var british: Bool?
    private static var create: Create?, destroy: Destroy?, generate: Generate?, free: Free?

    /// Loads the library and the model for this accent. True if it can speak.
    static func load(british wantBritish: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tts != nil, british == wantBritish { return true }
        guard installed else { return false }
        if handle == nil {
            guard let h = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else { logLine("natural voice: library would not load: \(String(cString: dlerror()))"); return false }
            handle = h
            create = dlsym(h, "SherpaOnnxCreateOfflineTts").map { unsafeBitCast($0, to: Create.self) }
            destroy = dlsym(h, "SherpaOnnxDestroyOfflineTts").map { unsafeBitCast($0, to: Destroy.self) }
            generate = dlsym(h, "SherpaOnnxOfflineTtsGenerate").map { unsafeBitCast($0, to: Generate.self) }
            free = dlsym(h, "SherpaOnnxDestroyOfflineTtsGeneratedAudio").map { unsafeBitCast($0, to: Free.self) }
        }
        guard let create = create else { return false }
        if let old = tts { destroy?(old); tts = nil }
        let d = modelDir.path
        // The pronunciation data (espeak-ng) fails on paths longer than about 160 characters, which
        // a long user name can reach. So it is given a short link in /tmp that points to the real folder.
        var data = d + "/espeak-ng-data"
        var hash: UInt64 = 1469598103934665603
        for b in data.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let link = "/tmp/nova-speech-" + String(hash % 1_000_000_007, radix: 36)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != data {
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: data)
        }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == data { data = link }
        // British voices: espeak-ng's "en" (which is British English) with the British word list. "en-gb" is not a name it accepts here.
        let lexicon = d + (wantBritish ? "/lexicon-gb-en.txt" : "/lexicon-us-en.txt")
        let strings = [d + "/model.onnx", d + "/voices.bin", d + "/tokens.txt", data,
                       FileManager.default.fileExists(atPath: lexicon) ? lexicon : "", wantBritish ? "en" : "en-us", "cpu"].map { strdup($0) }
        defer { strings.forEach { Darwin.free($0) } }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = UnsafePointer(strings[0])
        config.model.kokoro.voices = UnsafePointer(strings[1])
        config.model.kokoro.tokens = UnsafePointer(strings[2])
        config.model.kokoro.data_dir = UnsafePointer(strings[3])
        config.model.kokoro.lexicon = UnsafePointer(strings[4])
        config.model.kokoro.lang = UnsafePointer(strings[5])
        config.model.kokoro.length_scale = 1.0
        config.model.provider = UnsafePointer(strings[6])
        config.model.num_threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))
        config.max_num_sentences = 1
        let started = now()
        tts = create(&config)
        british = wantBritish
        if tts == nil { logLine("natural voice: the model would not load"); return false }
        logLine(String(format: "natural voice: loaded in %.1f s", now() - started))
        return true
    }

    /// One sentence to a WAV file, trimmed and evened out the way the old helper did. True when written.
    static func write(_ text: String, voice: String, speed: Double, to url: URL) -> Bool {
        guard load(british: voice.hasPrefix("b")) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let tts = tts, let generate = generate else { return false }
        let sid = Int32(speakers.firstIndex(of: voice) ?? speakers.firstIndex(of: "bm_george")!)
        guard let audio = text.withCString({ generate(tts, $0, sid, Float(speed)) }) else { return false }
        defer { free?(audio) }
        let a = audio.pointee
        guard a.n > 0, let p = a.samples else { return false }
        var s = Array(UnsafeBufferPointer(start: p, count: Int(a.n)))
        let rate = Int(a.sample_rate)
        // Cut the dead air at each end and bring every sentence to the same strength.
        let peak = s.map { abs($0) }.max() ?? 0
        if peak > 0 {
            let floor = peak * 0.006
            let first = s.firstIndex { abs($0) > floor } ?? 0, last = s.lastIndex { abs($0) > floor } ?? (s.count - 1)
            let from = max(0, first - rate / 20), to = min(s.count, last + rate * 22 / 100)
            s = Array(s[from..<to]).map { $0 * (0.9 / peak) }
            let fadeIn = min(s.count / 2, rate * 8 / 1000), fadeOut = min(s.count / 2, rate * 6 / 100)
            for i in 0..<fadeIn { s[i] *= Float(i) / Float(fadeIn) }
            for i in 0..<fadeOut { s[s.count - 1 - i] *= Float(i) / Float(fadeOut) }
        }
        var pcm = Data(capacity: s.count * 2)
        for v in s { var x = Int16(max(-1, min(1, v)) * 32767).littleEndian; withUnsafeBytes(of: &x) { pcm.append(contentsOf: $0) } }
        var wav = Data("RIFF".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        u32(36 + pcm.count); wav.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        wav.append(Data("data".utf8)); u32(pcm.count); wav.append(pcm)
        return (try? wav.write(to: url, options: .atomic)) != nil
    }

    /// Fetches the library and the voice. Nil when done, or a sentence saying what went wrong.
    static func install(progress: @escaping (String) -> Void, cancelled: () -> Bool) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func sha(_ f: URL) -> String { runTool("/usr/bin/shasum", ["-a", "256", f.path], timeout: 120).out.split(separator: " ").first.map(String.init) ?? "" }
        func fetch(_ url: String, to file: URL, minutes: Double, total: Int? = nil) -> Bool {
            let part = file.appendingPathExtension("part")
            // For testing the installer without the internet: NOVA_MIRROR names a folder holding the same files.
            let url = ProcessInfo.processInfo.environment["NOVA_MIRROR"].map { "file://" + $0 + "/" + (url.components(separatedBy: "/").last ?? "") } ?? url
            var done = false
            if let total = total {
                DispatchQueue.global(qos: .utility).async {
                    while !done {
                        let have = (try? part.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        ui("now Fetching the natural voice: \(min(99, have * 100 / max(1, total))) percent")
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
        if !fm.fileExists(atPath: library.path) {
            let zip = folder.appendingPathComponent("engine.zip")
            guard fetch(libraryDownload.url, to: zip, minutes: 10) else { return "I couldn't download the voice engine. Check the internet connection and ask me again." }
            guard sha(zip) == libraryDownload.sha else { try? fm.removeItem(at: zip); return "A download came back damaged, so I threw it away. Ask me again to retry." }
            let unpacked = folder.appendingPathComponent("engine")
            try? fm.removeItem(at: unpacked)
            guard runTool("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 120).ok else { return "The voice engine wouldn't unpack. Ask me again to retry." }
            let inside = unpacked.appendingPathComponent("sherpa-onnx.xcframework/macos-arm64_x86_64/SherpaOnnxC.framework/Versions/A/SherpaOnnxC")
            guard (try? fm.copyItem(at: inside, to: library)) != nil else { return "The voice engine wouldn't unpack. Ask me again to retry." }
            try? fm.removeItem(at: unpacked); try? fm.removeItem(at: zip)
        }
        if cancelled() { return "Cancelled." }
        if !installed {
            progress("The voice itself is about 350 megabytes. I'll keep talking in this one until it's here.")
            let tar = folder.appendingPathComponent("voice.tar.bz2")
            guard fetch(modelDownload.url, to: tar, minutes: 60, total: modelDownload.bytes) else { return "The download stopped part way. Ask me again and I'll carry on from where it stopped." }
            guard sha(tar) == modelDownload.sha else { try? fm.removeItem(at: tar); return "The download came back damaged, so I threw it away. Ask me again to retry." }
            try? fm.removeItem(at: modelDir)
            guard runTool("/usr/bin/tar", ["-xjf", tar.path, "-C", folder.path], timeout: 600).ok, installed else { return "The voice wouldn't unpack. Ask me again to retry." }
            try? fm.removeItem(at: tar)
        }
        return nil
    }
}
