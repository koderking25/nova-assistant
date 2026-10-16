// The Kokoro voice: a small neural speech model that runs on this Mac and sounds far more
// human than the built-in voices. A helper (kokoro_server.py, in its own Python environment
// under voice/) keeps the model loaded; this file sends it sentences, plays what comes back,
// and tells the window which word is being spoken. If anything about it fails, the tool
// carries on with the Mac's own voice.

import Foundation
import AVFoundation

final class Kokoro {
    static let shared = Kokoro()
    static let folder = baseDir.appendingPathComponent("voice")
    static let choiceFile = baseDir.appendingPathComponent("voice-kokoro.txt")
    // A short list worth choosing from: British and American, male and female.
    static let favourites: [(id: String, name: String)] = [
        ("bm_george", "George"), ("bm_fable", "Fable"), ("bm_lewis", "Lewis"), ("bm_daniel", "Daniel"),
        ("am_michael", "Michael"), ("am_fenrir", "Fenrir"), ("bf_emma", "Emma"), ("af_heart", "Heart"), ("af_bella", "Bella"),
    ]

    enum State { case off, starting, ready, failed }
    private(set) var state = State.off
    private(set) var voices: [String] = []
    var voice = "bm_george"
    var enabled = true                     // false when the player picked the Mac's voice instead
    var name: String { Kokoro.favourites.first { $0.id == voice }?.name ?? voice }

    private var process: Process?
    private var input: FileHandle?
    private let lock = NSLock()
    private var replies: [String: (DispatchSemaphore, String)] = [:]
    private var buffer = Data()
    private var counter = 0
    private var gen = 0                    // goes up whenever speech is cut off
    private var player: AVAudioPlayer?
    var firstSoundAt = 0.0                 // when the last thing spoken began to sound, for measuring delay

    static var installed: Bool { SherpaVoice.installed || python }
    /// The older way, kept working for anyone who installed it: a Python helper.
    static var python: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("kokoro-v1.0.onnx").path) &&
            fm.isExecutableFile(atPath: folder.appendingPathComponent(".venv/bin/python").path)
    }

    func start() {
        guard state == .off, Kokoro.installed else { return }
        if let saved = try? String(contentsOf: Kokoro.choiceFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            if saved == "mac" { enabled = false } else { voice = saved }
        }
        state = .starting
        tidy()
        try? FileManager.default.createDirectory(at: Kokoro.folder.appendingPathComponent("cache"), withIntermediateDirectories: true)
        // Made inside Nova: no helper to start, only the model to load (a second or two).
        if SherpaVoice.installed {
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = SherpaVoice.load(british: self.voice.hasPrefix("b"))
                self.lock.lock()
                self.voices = ok ? SherpaVoice.speakers : []
                if ok, !self.voices.contains(self.voice) { self.voice = "bm_george" }
                self.state = ok ? .ready : .failed
                self.lock.unlock()
                logLine(ok ? "natural voice ready (built in)" : "natural voice could not start (built in)")
                if ok { self.warmPlayer() }
            }
            return
        }
        let p = Process()
        p.executableURL = Kokoro.folder.appendingPathComponent(".venv/bin/python")
        p.arguments = ["-I", baseDir.appendingPathComponent("kokoro_server.py").path, Kokoro.folder.path]
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
        }
        do { try p.run(); process = p; input = inPipe.fileHandleForWriting } catch { state = .failed }
        try? FileManager.default.createDirectory(at: Kokoro.folder.appendingPathComponent("cache"), withIntermediateDirectories: true)
    }

    /// Clears out sound files left behind by speech that was cut off, and keeps the store of
    /// ready-made phrases from growing without limit (the oldest go first, past 40 megabytes).
    private func tidy() {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory()
        for name in (try? fm.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix("tp-kokoro-") || name.hasPrefix("talking-piano-") && name.hasSuffix(".wav") {
            try? fm.removeItem(atPath: tmp + name)
        }
        let cache = Kokoro.folder.appendingPathComponent("cache")
        let files = ((try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey])) ?? []).compactMap { u -> (URL, Date, Int)? in
            guard let v = try? u.resourceValues(forKeys: [.contentAccessDateKey, .fileSizeKey]) else { return nil }
            return (u, v.contentAccessDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var total = 0
        for f in files { total += f.2; if total > 40_000_000 { try? fm.removeItem(at: f.0) } }
        // The listening log is for finding faults, not for keeping: start it afresh when it gets long.
        let log = baseDir.appendingPathComponent("voice-log.txt").path
        if let size = (try? fm.attributesOfItem(atPath: log))?[.size] as? Int, size > 300_000 { try? "".write(toFile: log, atomically: true, encoding: .utf8) }
    }

    func shutDown() { try? input?.close(); process?.terminate() }

    private func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            let parts = line.components(separatedBy: "\t")
            if parts[0] == "ready" {
                voices = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
                if !voices.contains(voice) { voice = voices.first { $0 == "bm_george" } ?? voices.first ?? voice }
                state = .ready
                logLine("Kokoro voice ready, \(voices.count) voices")
                DispatchQueue.global().async { self.warmPlayer() }
            } else if parts[0] == "failed" {
                state = .failed
                logLine("Kokoro could not start: \(parts.dropFirst().joined(separator: " "))")
            } else if let waiting = replies[parts[0]] {
                replies[parts[0]] = (waiting.0, parts.dropFirst().joined(separator: "\t"))
                waiting.0.signal()
            }
        }
    }

    /// How fast it talks, as a multiple of its usual pace. Set by "talk slower" and "talk faster", and remembered.
    static let rateFile = baseDir.appendingPathComponent("voice-speed.txt")
    static var rate: Double = {
        let saved = (try? String(contentsOf: rateFile, encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return max(0.6, min(1.5, saved ?? 1))
    }()
    private var lastRetry = 0.0
    private var speakingNow = 0            // sentences being spoken, so background preparation can stand aside

    /// True when Kokoro should be given the sentence. It does not wait: while the voice is still
    /// loading, anything already kept as sound plays at once and the rest follows when it is ready.
    func usable() -> Bool {
        guard enabled else { return false }
        if state == .failed, now() - lastRetry > 60 { lastRetry = now(); state = .off; start(); return false }
        return state == .ready || state == .starting
    }

    /// True when Kokoro should speak. Waits a few seconds for it right after launch.
    func available() -> Bool {
        guard enabled else { return false }
        // If the voice helper has died, start it again (at most once a minute) so one failure
        // does not leave the old voice in place for the rest of the session.
        if state == .failed, now() - lastRetry > 60 { lastRetry = now(); state = .off; start(); return false }
        var waited = 0
        while state == .starting, waited < 60 { usleep(100_000); waited += 1 }
        return state == .ready
    }

    // One sentence to a sound file. Short, common phrases are kept so they play at once next time.
    private func synth(_ text: String, as other: String? = nil) -> URL? {
        let voice = other ?? self.voice
        // A touch brisker than the model's default, which drags. Very short phrases are the
        // exception: rushed, they sound clipped, so they are given their natural pace.
        let speed = String(format: "%.2f", (text.count <= 16 ? 0.98 : 1.06) * Kokoro.rate)
        let text = Kokoro.spoken(text)
        var hash: UInt64 = 1469598103934665603
        for b in ("v3" + voice + speed + text).utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let keep = text.count <= 60
        let url = keep ? Kokoro.folder.appendingPathComponent("cache/\(String(hash, radix: 16)).wav")
                       : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tp-kokoro-\(getpid())-\(String(hash, radix: 16)).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var waited = 0
        while state == .starting, waited < 100 { usleep(100_000); waited += 1 }      // just after launch, the voice is still loading
        if SherpaVoice.installed {
            guard state == .ready else { return nil }
            return SherpaVoice.write(text, voice: voice, speed: Double(speed) ?? 1, to: url) ? url : nil
        }
        lock.lock()
        guard state == .ready, let input = input else { lock.unlock(); return nil }
        counter += 1
        let id = String(counter)
        let sem = DispatchSemaphore(value: 0)
        replies[id] = (sem, "")
        let clean = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        let line = "\(id)\t\(voice)\t\(speed)\t\(url.path)\t\(clean)\n"
        lock.unlock()
        do { try input.write(contentsOf: Data(line.utf8)) } catch { return nil }
        let timedOut = sem.wait(timeout: .now() + 25) == .timedOut
        lock.lock()
        let answer = replies.removeValue(forKey: id)?.1 ?? ""
        lock.unlock()
        return !timedOut && answer.hasPrefix("ok") ? url : nil
    }

    // Splits a paragraph into sentences, so the first one can start while the rest are prepared.
    static func sentences(_ text: String) -> [(text: String, at: Int)] {
        var out: [(String, Int)] = []
        let chars = Array(text)
        var start = 0
        var i = 0
        while i < chars.count {
            let end = ".?!".contains(chars[i]) && (i + 1 == chars.count || chars[i + 1] == " ")
            if end || i == chars.count - 1 {
                let piece = String(chars[start...i]).trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty {
                    // Very short pieces ride along with the one before, so the voice does not sound chopped.
                    if let last = out.last, last.0.count + piece.count < 28 { out[out.count - 1] = (last.0 + " " + piece, last.1) }
                    else { out.append((piece, start + (String(chars[start...i]).count - String(chars[start...i]).drop { $0 == " " }.count))) }
                }
                start = i + 1
            }
            i += 1
        }
        // The opening piece is kept short, cut at the first comma if need be, because the time
        // before the voice starts grows with the length of what has to be prepared first.
        if let first = out.first, first.0.count > 30 {
            let c = Array(first.0)
            if let cut = c.indices.first(where: { $0 >= 12 && $0 <= 60 && c[$0] == "," && $0 + 1 < c.count && c[$0 + 1] == " " }) {
                let head = String(c[0...cut]), tail = String(c[(cut + 2)...])
                out.replaceSubrange(0...0, with: [(head, first.1), (tail, first.1 + cut + 2)])
            } else {
                // No comma: break before a joining word, where a speaker would naturally draw breath.
                let text = first.0
                var best: Int? = nil
                for word in [" and ", " but ", " then ", " so ", " which ", " because "] {
                    if let r = text.range(of: word) {
                        let at = text.distance(from: text.startIndex, to: r.lowerBound)
                        if at >= 12, at <= 50, best == nil || at < best! { best = at }
                    }
                }
                if best == nil {
                    // Failing that, between the subject and what is said about it: "Lead Vocals | is at minus 6 decibels".
                    for word in [" is now ", " is at ", " is ", " are ", " has ", " was ", " now sends ", " will "] {
                        if let r = text.range(of: word) {
                            let at = text.distance(from: text.startIndex, to: r.lowerBound)
                            if at >= 4, at <= 40, best == nil || at < best! { best = at }
                        }
                    }
                }
                if let at = best {
                    out.replaceSubrange(0...0, with: [(String(c[0..<at]), first.1), (String(c[(at + 1)...]), first.1 + at + 1)])
                }
            }
        }
        return out
    }

    /// Makes the sound for phrases that are said all the time, ahead of need, so they start at once.
    func prewarm(_ phrases: [String]) {
        DispatchQueue.global(qos: .utility).async {
            guard self.available() else { return }
            for phrase in phrases {
                for piece in Kokoro.sentences(phrase) where piece.text.count <= 60 {
                    guard self.state == .ready, self.enabled else { return }
                    while self.speakingNow > 0 { usleep(200_000) }       // never make a sentence being spoken wait behind this
                    _ = self.synth(piece.text)
                }
            }
        }
    }

    // Written the way it should be said: the model reads symbols and musical shorthand badly.
    static func spoken(_ text: String) -> String {
        var t = " " + text + " "
        // Names and shorthand the model reads badly.
        for (a, b) in [(" dB", " decibels"), ("8-bit", "eight bit"), ("REAPER", "Reaper"), ("MIDI", "middy"), ("Fur Elise", "Fur Eleeza"), ("Clair de Lune", "Clair de Loon"),
                       ("Debussy", "Deb you see"), ("Chopin", "Show pan"), (" // ", ", "), ("#", " sharp"), ("ReaEQ", "Rea E Q"), ("ReaComp", "Rea Comp"), ("ReaVerbate", "Rea Verbate"),
                       ("ReaDelay", "Rea Delay"), ("ReaLimit", "Rea Limit"), ("ReaSynth", "Rea Synth"), ("ReaGate", "Rea Gate"), ("ReaTune", "Rea Tune"), (" EQ", " E Q"),
                       (" vs ", " versus "), (" e.g. ", " for example "), (" & ", " and ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        // People do not say "I cannot" and "it is" out loud. The caption keeps the written form.
        for (a, b) in [("I cannot ", "I can't "), ("I could not ", "I couldn't "), ("I did not ", "I didn't "), ("I do not ", "I don't "), ("I will ", "I'll "), ("I have ", "I've "),
                       ("I am ", "I'm "), ("I would ", "I'd "), (" it is ", " it's "), ("It is ", "It's "), (" that is ", " that's "), ("That is ", "That's "), (" there is ", " there's "),
                       ("There is ", "There's "), (" does not ", " doesn't "), (" do not ", " don't "), (" did not ", " didn't "), (" is not ", " isn't "), (" was not ", " wasn't "),
                       (" cannot ", " can't "), (" could not ", " couldn't "), (" will not ", " won't "), (" has not ", " hasn't "), (" have not ", " haven't "), (" you are ", " you're "),
                       ("You are ", "You're "), (" you have ", " you've "), ("You have ", "You've "), (" you will ", " you'll "), (" they are ", " they're "), (" what is ", " what's "),
                       (" here is ", " here's "), ("Here is ", "Here's "), (" let us ", " let's ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Speaks the text and returns when it has finished or been cut off. False if Kokoro could not speak it.
    func say(_ text: String, meter: VoiceMeter?, as other: String? = nil, onStart: (() -> Void)? = nil) -> Bool {
        lock.lock(); gen += 1; let mine = gen; speakingNow += 1; lock.unlock()
        defer { lock.lock(); speakingNow -= 1; lock.unlock() }
        let parts = Kokoro.sentences(text)
        guard !parts.isEmpty else { return true }
        var ready: [Int: URL?] = [:]
        let readyLock = NSLock()
        func prepare(_ i: Int) {
            guard i < parts.count else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let url = self.synth(parts[i].text, as: other)
                // Stored as "tried, and here is the result": a plain nil would look like "not ready yet",
                // and a sentence that failed to synthesise would then be waited for without end.
                readyLock.lock(); ready[i] = .some(url); readyLock.unlock()
            }
        }
        prepare(0)
        for i in parts.indices {
            // Wait for this sentence, while the next one is already being made.
            var url: URL?? = nil
            while url == nil {
                lock.lock(); let alive = mine == gen; lock.unlock()
                if !alive { return true }
                readyLock.lock(); url = ready[i]; readyLock.unlock()
                if url == nil { usleep(15_000) }
            }
            prepare(i + 1)
            guard let got = url, let file = got, let data = try? Data(contentsOf: file), data.count > 44 else {
                if i == 0 { return false }   // nothing said yet: let the Mac's voice take the whole thing
                continue                     // skip a piece that could not be made, and carry on
            }
            if uiOn, let meter = meter { meter.measure(wav: data) }
            // The sound goes out through an audio engine that is already running, which starts
            // noticeably sooner than opening a new player for every sentence.
            var length = playNow(data)
            let onNode = length != nil
            let base = playBase
            var p: AVAudioPlayer? = nil
            if length == nil {
                guard let made = try? AVAudioPlayer(data: data) else { return i > 0 }
                made.volume = min(1, Opt.voiceVolume * 1.5)
                lock.lock(); player = made; lock.unlock()
                made.play()
                p = made
                length = made.duration
            }
            let began = now(), duration = length ?? 0
            if i == 0 { onStart?(); ui("start"); firstSoundAt = began }
            // Tell the window which word is being spoken and for how long. Time is shared out by
            // the length of each word, with extra after a comma or a full stop where the voice pauses.
            let words = Kokoro.wordRanges(parts[i].text, offset: parts[i].at)
            let chars = Array(parts[i].text.utf16)
            let weights: [Double] = words.map { w in
                let end = w.0 - parts[i].at + w.1 - 1
                let lastChar = end >= 0 && end < chars.count ? chars[end] : 0
                let pause: Double = [46, 33, 63].contains(lastChar) ? 7 : [44, 59, 58].contains(lastChar) ? 4 : 0
                return Double(w.1) + 1.5 + pause
            }
            let totalWeight = max(1, weights.reduce(0, +))
            let spoken = max(0.05, duration - 0.27)       // the sound has a little silence at each end
            var starts: [Double] = []
            var acc = 0.05
            for w in weights { starts.append(acc); acc += spoken * w / totalWeight }
            var next = 0
            while true {
                lock.lock(); let alive = mine == gen; lock.unlock()
                if !alive { p?.stop(); if p == nil { node.stop() }; return true }
                // Words are timed by how much sound has really come out, not by the clock. Right
                // after launch the sound takes a moment to start, and the caption used to run ahead.
                let wall = now() - began
                let elapsed = onNode ? min(wall, max(0, (playerSeconds() ?? (base + wall)) - base - outputDelay)) : wall
                if elapsed >= duration || wall > duration + 1.2 { break }
                while next < words.count, starts[next] <= elapsed {
                    // Third number: how long this word takes to say, in thousandths of a second, without its pause.
                    let share = spoken * (Double(words[next].1) + 1.5) / totalWeight
                    ui("word \(words[next].0) \(words[next].1) \(Int(share * 1000))")
                    next += 1
                }
                usleep(12_000)
            }
            if !file.path.contains("/cache/") { try? FileManager.default.removeItem(at: file) }
        }
        return true
    }

    static func wordRanges(_ text: String, offset: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start: Int? = nil
        for (i, ch) in text.utf16.enumerated() {
            if ch == 32 { if let s = start { out.append((offset + s, i - s)); start = nil } } else if start == nil { start = i }
        }
        if let s = start { out.append((offset + s, text.utf16.count - s)) }
        return out
    }

    /// Turns the voice well down, or back up. Used while someone seems to be talking over it,
    /// so the microphone can hear them and not mostly itself.
    private var ducked = false
    func duck(_ down: Bool) {
        lock.lock()
        let change = ducked != down
        ducked = down
        let ready = engineReady
        lock.unlock()
        guard change, ready else { return }
        DispatchQueue.main.async { self.node.volume = min(1, Opt.voiceVolume * 1.5) * (down ? 0.18 : 1) }
    }

    func stop() {
        lock.lock()
        gen += 1
        player?.stop()
        if engineReady { node.stop() }
        lock.unlock()
    }

    // MARK: A player that is always ready

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var engineReady = false
    private var engineFormat: AVAudioFormat?
    private var observer: NSObjectProtocol?

    private func startEngine(rate: Double) -> Bool {
        if engineReady, engineFormat?.sampleRate == rate, engine.isRunning { return true }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return false }
        if !engineReady {
            engine.attach(node)
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                // Headphones plugged in or the output changed: start again on the new output.
                self?.lock.lock(); self?.engineFormat = nil; self?.lock.unlock()
            }
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return false }
        engineFormat = format
        engineReady = true
        return true
    }

    private var playBase = 0.0             // where the player's own clock stood when the current sentence began
    private var outputDelay = 0.0

    /// How many seconds of sound the player has put out since it was started.
    private func playerSeconds() -> Double? {
        guard engineReady, engine.isRunning, let render = node.lastRenderTime, render.isSampleTimeValid, let t = node.playerTime(forNodeTime: render), t.sampleRate > 0 else { return nil }
        return Double(t.sampleTime) / t.sampleRate
    }

    /// Plays a finished recording (16-bit, one channel) at once. Returns its length, or nil if this route cannot be used.
    private func playNow(_ data: Data) -> Double? {
        let rate = Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) })
        let count = (data.count - 44) / 2
        lock.lock(); defer { lock.unlock() }
        guard rate > 0, count > 0, startEngine(rate: rate), let format = engineFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let out = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count { out[0][i] = Float(raw.loadUnaligned(fromByteOffset: 44 + i * 2, as: Int16.self)) / 32768 }
        }
        node.volume = min(1, Opt.voiceVolume * 1.5) * (ducked ? 0.18 : 1)
        let running = node.isPlaying
        playBase = running ? (playerSeconds() ?? 0) : 0
        outputDelay = min(0.3, engine.outputNode.presentationLatency)
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !running { node.play() }
        return Double(count) / rate
    }

    /// Gets the player running before the first sentence needs it.
    func warmPlayer() { lock.lock(); _ = startEngine(rate: 24000); lock.unlock() }

    /// The launcher's own announcements ("Updating. One moment.") are recordings, because the
    /// voice is not running at that point. They are re-made whenever the chosen voice changes.
    func makeSystemClips() {
        DispatchQueue.global(qos: .utility).async {
            guard self.available() else { return }
            let marker = Kokoro.folder.appendingPathComponent("sys-voice.txt")
            let tag = self.voice + " v3"
            if (try? String(contentsOf: marker, encoding: .utf8)) == tag { return }
            for (name, text) in [("updating", "Updating. One moment."), ("update-failed", "The update didn't build, so this is the last working version."), ("stopped", "I stopped unexpectedly. Starting again.")] {
                guard let made = self.synth(text) else { return }
                let target = Kokoro.folder.appendingPathComponent("sys-\(name).wav")
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: made, to: target)
            }
            try? tag.write(to: marker, atomically: true, encoding: .utf8)
        }
    }

    /// Chooses a voice by name, such as "Emma". Returns the name if it exists.
    func choose(_ wanted: String) -> String? {
        guard state == .ready, let v = Kokoro.favourites.first(where: { $0.name.lowercased() == wanted.lowercased() && voices.contains($0.id) }) else { return nil }
        voice = v.id
        enabled = true
        try? voice.write(to: Kokoro.choiceFile, atomically: true, encoding: .utf8)
        makeSystemClips()
        return v.name
    }

    /// The next voice in the short list; after the last comes the Mac's own voice.
    func nextVoice() -> String? {
        guard state == .ready else { return nil }
        let list = Kokoro.favourites.filter { voices.contains($0.id) }
        if !enabled { enabled = true; voice = list.first?.id ?? voice }
        else if let i = list.firstIndex(where: { $0.id == voice }), i + 1 < list.count { voice = list[i + 1].id }
        else { enabled = false }
        try? (enabled ? voice : "mac").write(to: Kokoro.choiceFile, atomically: true, encoding: .utf8)
        if enabled { makeSystemClips() }
        return enabled ? name : nil
    }
}
