// The band: built-in instruments (bass, strings, cello, drums) played by the Mac itself,
// plus the code that works out chords and writes the band's parts.

import Foundation
import AVFoundation

// Plays the band parts with the General MIDI sounds that ship with macOS, so the band has
// real bass, strings and drums without any setup in Logic. Nothing is downloaded.
final class Sounds {
    static let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    // MIDI channel, General MIDI program, drum kit, volume, whether it sits in the big hall
    // (the sustained instruments) or the smaller room, and where it sits from left (-1) to right (1).
    // Volumes were set by measuring each part's level against the piano on the player's own pieces.
    static let parts: [(ch: UInt8, program: UInt8, drums: Bool, volume: Float, hall: Bool, pan: Float)] = [
        (0, 0, false, 0.8, false, 0),      // piano, used only when Logic is not running
        (1, 32, false, 0.30, false, 0),    // acoustic bass
        (2, 48, false, 0.62, true, -0.35), // string ensemble
        (3, 42, false, 0.74, true, 0.35),  // cello
        (6, 48, false, 0.42, true, -0.15), // high strings, which join as the piece grows
        (7, 60, false, 0.40, true, 0.2),   // French horn, answering in the gaps of the melody
        (8, 89, false, 0.34, true, 0),     // warm pad under the strings, for body and a soft edge
        (5, 4, false, 0.5, false, 0.1),    // electric piano, the jazz band's chords
        (10, 80, false, 0.3, false, 0),    // square wave, for the video game version of a piece
        (11, 47, false, 0.7, true, 0),     // timpani, for the film score version
        (4, 10, false, 0.55, false, 0),    // music box, for the lesson's soft bells and hints
        (9, 0, true, 0.6, false, 0),       // drum kit
    ]
    var engine = AVAudioEngine()
    var samplers: [UInt8: AVAudioUnitSampler] = [:]
    private(set) var ready = false
    private var observer: NSObjectProtocol?
    private let swapLock = NSLock()
    private let fixQueue = DispatchQueue(label: "band.sound.fix")
    private var lastFix = 0.0
    private(set) var restarts = 0

    static func build(on engine: AVAudioEngine) throws -> [UInt8: AVAudioUnitSampler] {
        var out: [UInt8: AVAudioUnitSampler] = [:]
        // Everything goes through a little hall reverb, which puts the instruments in one
        // room and softens the edges of the built-in sounds.
        let room = AVAudioMixerNode(), reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 24
        engine.attach(room); engine.attach(reverb)
        engine.connect(room, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        // The sustained instruments share a larger hall and a filter that takes the hard
        // edge off the built-in string sound, so they sit behind the piano instead of on it.
        let hall = AVAudioMixerNode(), soften = AVAudioUnitEQ(numberOfBands: 2), bigReverb = AVAudioUnitReverb()
        soften.bands[0].filterType = .highShelf
        soften.bands[0].frequency = 3200
        soften.bands[0].gain = -7
        soften.bands[0].bypass = false
        soften.bands[1].filterType = .highPass
        soften.bands[1].frequency = 110
        soften.bands[1].bypass = false
        bigReverb.loadFactoryPreset(.largeHall)
        bigReverb.wetDryMix = 40
        engine.attach(hall); engine.attach(soften); engine.attach(bigReverb)
        engine.connect(hall, to: soften, format: nil)
        engine.connect(soften, to: bigReverb, format: nil)
        engine.connect(bigReverb, to: engine.mainMixerNode, format: nil)
        for p in parts {
            let s = AVAudioUnitSampler()
            engine.attach(s)
            // The classic band is heard as it first was: each instrument straight out, clear and
            // close, with no hall around it and at the volumes of that first version.
            if bandClassic, let early = classicVolumes[p.ch] {
                engine.connect(s, to: engine.mainMixerNode, format: nil)
                try s.loadSoundBankInstrument(at: bank, program: p.program,
                                              bankMSB: UInt8(p.drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
                                              bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                s.volume = early
                s.overallGain = p.ch == 0 ? Sounds.classicPianoDB : Sounds.gainDB + Sounds.classicBandDB
                out[p.ch] = s
                continue
            }
            engine.connect(s, to: p.hall ? hall : room, format: nil)
            s.pan = p.pan
            try s.loadSoundBankInstrument(at: bank, program: p.program,
                                          bankMSB: UInt8(p.drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
                                          bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            s.volume = p.volume
            // The piano is the star: it always sits well above the band, whatever the band level.
            s.overallGain = p.ch == 0 ? Sounds.pianoGainDB : Sounds.gainDB
            out[p.ch] = s
        }
        return out
    }

    func start() {
        guard FileManager.default.fileExists(atPath: Sounds.bank.path) else { return }
        do {
            samplers = try Sounds.build(on: engine)
            try engine.start()
            ready = true
        } catch {
            ready = false
        }
        watch()
    }

    // When the sound output changes under it, the instruments are built again from scratch.
    // That happens with headphones, and also whenever REAPER, Logic or another music program
    // opens after this one and takes over the audio interface. Simply pressing "start" again
    // was not enough then: the band stayed silent for the rest of the session.
    private func watch() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.revive("the sound output changed")
        }
    }

    func revive(_ why: String, wait: Bool = false) {
        let work = {
            if now() - self.lastFix < 1.0 { return }             // several notices arrive together
            let fresh = AVAudioEngine()
            guard let made = try? Sounds.build(on: fresh), (try? fresh.start()) != nil else {
                logLine("band sound could not restart after: \(why)")
                self.lastFix = now()
                return
            }
            self.swapLock.lock()
            let old = self.engine
            self.engine = fresh
            self.samplers = made
            self.ready = true
            self.restarts += 1
            self.swapLock.unlock()
            self.watch()
            old.stop()
            self.lastFix = now()
            if why != "a test" { logLine("band sound restarted: \(why)") }
        }
        if wait { fixQueue.sync(execute: work) } else { fixQueue.async(execute: work) }
    }

    // How loud the whole band is against the piano in Logic or REAPER, in decibels. Every
    // instrument gets the same boost, so the balance inside the band stays as it was tuned.
    // The setting is remembered in band-level.txt.
    static let gainFile = baseDir.appendingPathComponent("band-level.txt")
    static var gainDB: Float = {
        let saved = (try? String(contentsOf: gainFile, encoding: .utf8)).flatMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return max(-12, min(12, saved ?? 0))
    }()
    static let pianoGainDB: Float = 9
    // The first version's volumes for piano, bass, strings, cello and drums.
    static let classicVolumes: [UInt8: Float] = [0: 0.8, 1: 0.7, 2: 0.5, 3: 0.65, 9: 0.6]
    static let classicPianoDB: Float = 8        // measured on his pieces: the piano sits about 4 decibels above the whole band
    static let classicBandDB: Float = -2       // so the remembered band level of +2 is exactly the first version's loudness

    var level: Float {
        get { Sounds.gainDB }
        set {
            Sounds.gainDB = max(-12, min(12, newValue))
            // Changed on the main thread only: changing an instrument's settings from two threads at
            // once was the cause of the one crash this tool has had.
            let gain = Sounds.gainDB
            let list = samplers.filter { $0.key != 0 }.map { (s: $0.value, gain: bandClassic && Sounds.classicVolumes[$0.key] != nil ? gain + Sounds.classicBandDB : gain) }
            if Thread.isMainThread { for x in list { x.s.overallGain = x.gain } } else { DispatchQueue.main.async { for x in list { x.s.overallGain = x.gain } } }
            if !Opt.fast { try? String(Int(Sounds.gainDB)).write(to: Sounds.gainFile, atomically: true, encoding: .utf8) }   // tests never change settings
        }
    }

    func send(_ bytes: [UInt8]) {
        swapLock.lock()
        let found = samplers[bytes[0] & 0x0F], running = engine.isRunning
        swapLock.unlock()
        guard ready, bytes.count == 3, let s = found else { return }
        if !running {
            // Stopped without a notice: try the simple start, and failing that build it again.
            if (try? engine.start()) == nil { revive("it had stopped") }
        }
        if bytes[0] & 0xF0 == 0xB0 { s.sendController(bytes[1], withValue: bytes[2], onChannel: 0) }
        else if bytes[0] & 0xF0 == 0x90, bytes[2] > 0 { s.startNote(bytes[1], withVelocity: bytes[2], onChannel: 0) }
        else { s.stopNote(bytes[1], onChannel: 0) }
    }

    // Renders everything together, as it will be heard, and returns the loudest moment and the
    // share of time the sound would be clipped (above full scale), which is heard as distortion.
    static func mix(_ notes: [RNote]) -> (peak: Float, clipped: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else { return (0, 0) }
        let e = AVAudioEngine()
        guard (try? e.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)) != nil,
              let s = try? build(on: e), (try? e.start()) != nil,
              let buffer = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 1024) else { return (0, 0) }
        let evs = events(notes).sorted { $0.t < $1.t }
        var next = 0, frame = 0, over = 0, count = 0
        var peak: Float = 0
        let total = Int(((notes.map { $0.end }.max() ?? 0) + 1) * 44100)
        while frame < total {
            let t = Double(frame) / 44100
            while next < evs.count, evs[next].t <= t {
                let b = evs[next].bytes
                if let sampler = s[b[0] & 0x0F] {
                    if b[0] & 0xF0 == 0xB0 { sampler.sendController(b[1], withValue: b[2], onChannel: 0) }
                    else if b[0] & 0xF0 == 0x90 { sampler.startNote(b[1], withVelocity: b[2], onChannel: 0) } else { sampler.stopNote(b[1], onChannel: 0) }
                }
                next += 1
            }
            guard (try? e.renderOffline(1024, to: buffer)) != nil, let data = buffer.floatChannelData else { break }
            for i in 0..<Int(buffer.frameLength) {
                let v = max(abs(data[0][i]), abs(data[1][i]))
                peak = max(peak, v); count += 1
                if v > 1 { over += 1 }
            }
            frame += 1024
        }
        e.stop()
        return (peak, count > 0 ? Double(over) / Double(count) : 0)
    }

    // Renders notes to sound without playing them and returns the average level of each part.
    static func levels(_ notes: [RNote]) -> [UInt8: Float] {
        var result: [UInt8: Float] = [:]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else { return result }
        for ch in Set(notes.map { UInt8($0.ch) }).sorted() {
            let e = AVAudioEngine()
            guard (try? e.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)) != nil,
                  let s = try? build(on: e), (try? e.start()) != nil, let sampler = s[ch],
                  let buffer = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 1024) else { continue }
            let evs = events(notes.filter { $0.ch == Int(ch) }).sorted { ($0.t, $0.bytes[0] & 0xF0 == 0xB0 ? 0 : 1) < ($1.t, $1.bytes[0] & 0xF0 == 0xB0 ? 0 : 1) }
            var next = 0, frame = 0
            var sum = 0.0, count = 0.0
            let total = Int(((notes.filter { $0.cc < 0 }.map { $0.end }.max() ?? 0) + 1) * 44100)
            while frame < total {
                let t = Double(frame) / 44100
                while next < evs.count, evs[next].t <= t {
                    let b = evs[next].bytes
                    if b[0] & 0xF0 == 0xB0 { sampler.sendController(b[1], withValue: b[2], onChannel: 0) }
                    else if b[0] & 0xF0 == 0x90 { sampler.startNote(b[1], withVelocity: b[2], onChannel: 0) } else { sampler.stopNote(b[1], onChannel: 0) }
                    next += 1
                }
                guard (try? e.renderOffline(1024, to: buffer)) != nil, let data = buffer.floatChannelData else { break }
                for i in 0..<Int(buffer.frameLength) { sum += Double(data[0][i] * data[0][i]); count += 1 }
                frame += 1024
            }
            e.stop()
            result[ch] = count > 0 ? Float((sum / count).squareRoot()) : 0
        }
        return result
    }

    // Measures one built-in sound without playing it: how long a note takes to reach full
    // strength, how loud it is, how bright it is (0 is dull, towards 1 is harsh), and how much
    // quieter it gets when told to play softly with the expression control. Since nobody can
    // listen during a build, this is how sounds are compared and chosen.
    static func probe(program: UInt8, pitch: UInt8) -> (attack: Double, level: Double, bright: Double, expression: Double) {
        func render(_ cc11: UInt8?) -> [Float] {
            let e = AVAudioEngine(), s = AVAudioUnitSampler()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
                  (try? e.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)) != nil else { return [] }
            e.attach(s); e.connect(s, to: e.mainMixerNode, format: nil)
            guard (try? s.loadSoundBankInstrument(at: bank, program: program, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))) != nil,
                  (try? e.start()) != nil, let buffer = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 1024) else { return [] }
            if let c = cc11 { s.sendController(11, withValue: c, onChannel: 0) }
            s.startNote(pitch, withVelocity: 64, onChannel: 0)
            var out: [Float] = []
            for _ in 0..<86 {       // two seconds
                guard (try? e.renderOffline(1024, to: buffer)) != nil, let d = buffer.floatChannelData else { break }
                out += UnsafeBufferPointer(start: d[0], count: Int(buffer.frameLength))
            }
            e.stop()
            return out
        }
        func rms(_ x: ArraySlice<Float>) -> Double { x.isEmpty ? 0 : (x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot() }
        let full = render(nil), soft = render(40)
        guard full.count > 44100 else { return (0, 0, 0, 0) }
        let windows = stride(from: 0, to: full.count - 1024, by: 1024).map { rms(full[$0..<$0 + 1024]) }
        let peak = windows.max() ?? 0
        let attack = Double(windows.firstIndex { $0 >= peak * 0.8 } ?? 0) * 1024 / 44100
        let body = full[22050..<66150]
        var diff = 0.0, sum = 0.0
        var prev: Float = 0
        for v in body { diff += Double(abs(v - prev)); sum += Double(abs(v)); prev = v }
        return (attack, rms(body), sum > 0 ? diff / sum : 0, rms(body) > 0 ? rms(soft[22050..<min(66150, soft.count)]) / rms(body) : 0)
    }

    // Renders a bass note and a snare hit without playing them, and returns how loud they came out.
    static func offlineCheck() -> Float {
        let e = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else { return 0 }
        do {
            try e.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            let s = try build(on: e)
            try e.start()
            s[1]?.startNote(36, withVelocity: 100, onChannel: 0)
            s[9]?.startNote(38, withVelocity: 100, onChannel: 0)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 4096) else { return 0 }
            var peak: Float = 0
            for _ in 0..<10 {
                _ = try e.renderOffline(4096, to: buffer)
                if let data = buffer.floatChannelData {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][i])) }
                }
            }
            e.stop()
            return peak
        } catch {
            return 0
        }
    }
}

// "New" (the default) is the band rebuilt on 16 October: see bandbest.swift.
// "Early" is the band of 7 to 9 October, word for word, the one first called perfect.
// "Full" adds the high strings, the horn and the warm pad. "Simple" keeps bass, strings and cello.
// "Classic" is the later rewrite that followed the player's own note starts (it measured choppy).
// Remembered between sessions; a new file, so everyone starts on the new band.
let bandStyleURL = baseDir.appendingPathComponent("band-style-3.txt")
var bandStyle: String = {
    let saved = ((try? String(contentsOf: bandStyleURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return ["new", "early", "classic", "full", "simple"].contains(saved) ? saved : "new"
}()
var bandSimple: Bool { bandStyle == "simple" }
/// The plainer, closer sound of the first band: used by the new band, the early band and the classic one.
var bandClassic: Bool { ["new", "early", "classic"].contains(bandStyle) }

extension Engine {
    func toggleBandStyle() { setBandStyle(bandStyle == "new" ? "full" : bandStyle == "full" ? "early" : "new") }

    func setBandStyle(_ style: String) {
        bandStyle = style
        if !Opt.fast {
            try? style.write(to: bandStyleURL, atomically: true, encoding: .utf8)
            midi.sounds?.revive("the band style changed", wait: true)        // the classic band has its own, plainer sound
        }
        ui("bandstyle \(style)")
        let line = ["new": "The new band: bass, strings and cello, smooth and full, and out of the way of your notes.",
                    "early": "The original band, exactly as it was in the first days.",
                    "classic": "The classic band.",
                    "simple": "Simple band: bass, strings and cello, in the hall sound.",
                    "full": "Full band: with high strings, horn and pad."][style] ?? "Band changed."
        run { g in self.say(line, g) }
    }
}

func bassOnsets(_ notes: [RNote]) -> [Double] {
    let low = notes.filter { $0.pitch < 60 }.sorted { $0.t < $1.t }
    var out: [Double] = []
    for (i, n) in low.enumerated() {
        // Not a bass note if a clearly lower note came just before (a broken chord going up),
        // is still being held underneath, or lands a moment later (a chord rolled downwards).
        let before = low[..<i].contains { $0.pitch <= n.pitch - 3 && (n.t - $0.t < 0.9 || ($0.end > n.t + 0.05 && n.t - $0.t < 2.5)) }
        let after = low[(i + 1)...].contains { $0.t - n.t < 0.15 && $0.pitch < n.pitch }
        if before || after { continue }
        if let last = out.last, n.t - last < 0.35 { continue }
        out.append(n.t)
    }
    return out
}

func detectChords(_ notes: [RNote], beat: Double?, length: Double, tonic: Int, minor: Bool) -> [Chord] {
    // A new chord starts where the left hand plays a new bass note. The upper notes of a
    // rolled or broken chord belong to the bass note under them, not to a chord of their own.
    var bounds = bassOnsets(notes)
    if bounds.count < 2 {
        bounds = [0.0]
        let step = (beat ?? 1.0) * 2
        var t = step
        while t < length - step * 0.5 { bounds.append(t); t += step }
    }
    bounds.append(length)
    let scale = Set((minor ? [0, 2, 3, 5, 7, 8, 10, 11] : [0, 2, 4, 5, 7, 9, 11]).map { ($0 + tonic) % 12 })
    var out: [Chord] = []
    for (a, b) in zip(bounds, bounds.dropFirst()) where b - a > 0.05 {
        var w = [Double](repeating: 0, count: 12)
        var bass = 128
        for n in notes {
            let overlap = min(n.end, b) - max(n.t, a)
            if overlap <= 0 { continue }
            w[n.pitch % 12] += overlap * (n.pitch < 60 ? 1.5 : 1.0)
            bass = min(bass, n.pitch)
        }
        let total = w.reduce(0, +)
        if w.filter({ $0 > total * 0.05 }).count < 2 {
            if !out.isEmpty { out[out.count - 1].end = b }
            continue
        }
        var best: (Double, Int, Int) = (-.infinity, 0, 0)
        for root in 0..<12 {
            for (qi, shape) in chordShapes.enumerated() {
                let tones = Set(shape.1.map { (root + $0) % 12 })
                var score = 0.0
                for pc in 0..<12 { score += tones.contains(pc) ? w[pc] : -0.6 * w[pc] }
                if bass % 12 == root { score += 0.3 * total }
                if shape.1.count == 4, !tones.allSatisfy({ w[$0] > total * 0.04 }) { score -= 0.3 * total }
                if shape.1.contains(where: { w[(root + $0) % 12] == 0 }) { score -= 0.15 * total }
                // Chords that belong to the key, and chords that simply carry on, are more likely.
                if tones.isSubset(of: scale) { score += 0.12 * total }
                if let last = out.last, last.root == root, last.quality == shape.0 { score += 0.15 * total }
                // A passing melody note easily looks like a suspended chord, so those need more proof.
                if shape.0.hasPrefix("sus") { score -= 0.1 * total }
                score -= Double(qi) * 0.001 * total
                if score > best.0 { best = (score, root, qi) }
            }
        }
        let shape = chordShapes[best.2]
        if let last = out.last, last.root == best.1, last.quality == shape.0 {
            out[out.count - 1].end = b
        } else {
            out.append(Chord(start: a, end: b, root: best.1, quality: shape.0, tones: shape.1))
        }
    }
    // A chord that lasts less than a beat is almost always a passing note, so fold it into its neighbour.
    let shortest = max(0.35, (beat ?? 0.5) * 0.75)
    var smooth: [Chord] = []
    for c in out {
        if c.end - c.start < shortest, !smooth.isEmpty {
            smooth[smooth.count - 1].end = c.end
        } else if let last = smooth.last, last.root == c.root, last.quality == c.quality {
            smooth[smooth.count - 1].end = c.end
        } else {
            smooth.append(c)
        }
    }
    return smooth
}

// The last word on every band note: it must not rub against what the player is playing.
// A band note a semitone away from a note the player is sounding (in any octave) is the
// harshest clash there is, and it happens whenever a chord was guessed slightly wrong or
// the melody leans on a note next to a held one. A note that rubs from its start is
// wrong for that moment: the bass moves onto the player's note, any other part leaves it
// out. A note that only starts to rub later is let go just before that moment.
func settle(_ band: [RNote], against piano: [RNote]) -> [RNote] {
    func rubs(_ pitch: Int, _ from: Double, _ to: Double) -> [(start: Double, len: Double, pitch: Int)] {
        piano.compactMap { p in
            let d = ((p.pitch - pitch) % 12 + 12) % 12
            guard d == 1 || d == 11 else { return nil }
            let start = max(from, p.t), len = min(to, min(p.end, p.t + 4)) - start
            return len > 0.3 ? (start, len, p.pitch) : nil
        }
    }
    var out: [RNote] = []
    for var b in band {
        if b.cc >= 0 || b.ch == 9 { out.append(b); continue }
        let r = rubs(b.pitch, b.t, b.end)
        guard let first = r.map({ $0.start }).min() else { out.append(b); continue }
        let length = b.end - b.t
        if first - b.t < 0.35 || min(length, r.reduce(0) { $0 + $1.len }) > length * 0.5 {
            guard let strongest = r.max(by: { $0.len < $1.len }) else { continue }
            // Take the player's own note instead, in this part's octave, so the band stays full
            // and is right by construction. If another voice already has that note, leave it out.
            let up = ((strongest.pitch - b.pitch) % 12 + 12) % 12 == 1
            b.pitch += up ? 1 : -1
            let taken = out.contains { $0.ch == b.ch && $0.cc < 0 && $0.pitch == b.pitch && $0.t < b.end && $0.end > b.t }
            if !taken, rubs(b.pitch, b.t, b.end).isEmpty { out.append(b) }
        } else if b.ch == 1 {
            // A melody note brushing past the bass is ordinary; the bass holds.
            out.append(b)
        } else if first - b.t >= 0.5 {
            b.end = first - 0.03
            out.append(b)
        }
    }
    return out
}

// Writes the band: bass on channel 2, strings on 3, cello on 4, high strings on 7, horn on 8,
// a warm pad on 9 and drums on 10.
//
// The band accompanies the way a person would. Every note it plays starts on a moment the
// player actually played, so it breathes with free timing instead of cutting chords into
// equal slices. It plays louder and softer with the player, holds notes that two chords
// share, and only brings in drums when the playing has a steady beat.
func bandParts(_ notes: [RNote], _ a: Analysis) -> [RNote] {
    // The classic band: written exactly as in the first days. The one later improvement kept is
    // the check that takes out a band note sitting a semitone from what the player is playing.
    if bandStyle == "new" { return bandBest(notes, a) }
    if bandStyle == "early" { return bandEarly(notes, a) }
    if bandStyle == "classic" { return settle(classicBandParts(notes, a), against: notes) }
    guard !a.chords.isEmpty else { return [] }
    var out: [RNote] = []
    let scale = (a.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { ($0 + a.tonic) % 12 }
    func inScale(_ p: Int) -> Bool { scale.contains(((p % 12) + 12) % 12) }
    func bassPitch(_ root: Int) -> Int { 28 + ((root - 28) % 12 + 12) % 12 }   // E1 up to D sharp 2
    func melody(at t: Double) -> Int? {
        notes.filter { $0.t <= t + 0.03 && $0.end > t && $0.pitch >= 60 }.map { $0.pitch }.max()
    }
    // The moments the player played, with notes struck together counted once.
    var onsets: [Double] = []
    for t in notes.map({ $0.t }).sorted() where onsets.last == nil || t - onsets.last! > 0.05 { onsets.append(t) }
    func onset(near t: Double, within w: Double) -> Double? {
        onsets.min { abs($0 - t) < abs($1 - t) }.flatMap { abs($0 - t) <= w ? $0 : nil }
    }
    // How loudly the player is playing around a moment, as a factor around 1.
    func loud(_ t: Double) -> Double {
        let near = notes.filter { abs($0.t - t) < 2.5 }
        guard !near.isEmpty else { return 0.8 }
        return max(0.55, min(1.3, Double(near.reduce(0) { $0 + $1.vel }) / Double(near.count) / 66))
    }
    // Small repeatable variations, so nothing sounds machine-stamped.
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func wobble(_ range: Double) -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return (Double(seed >> 40) / Double(1 << 24) * 2 - 1) * range
    }
    func vel(_ base: Double, _ t: Double, vary: Double = 4) -> Int { max(18, min(112, Int(base * loud(t) + wobble(vary)))) }

    let steady = a.beat != nil
    let counts = a.chords.map { c -> Int in
        guard let b = a.beat else { return 1 }
        return max(1, min(16, Int(((c.end - c.start) / b).rounded())))
    }
    let longer = counts.filter { $0 >= 3 }
    let triple = !longer.isEmpty && longer.filter { $0 % 3 == 0 && $0 % 4 != 0 }.count * 2 > longer.count
    let group = triple ? 3 : 4
    var padCentre = 62
    var padOpen: [Int: Int] = [:]   // string notes still sounding: pitch to index in out
    var cello = 55
    var lastBass = -1
    var high = 79                   // the high strings' last note
    var highOpen: Int? = nil        // index in out of the high note still sounding
    var horn = 62
    // What the player is doing above middle C: the melody's own moments.
    let tune = notes.filter { $0.pitch >= 60 }.map { $0.t }.sorted()
    func playerHas(_ pcs: [Int], from: Double, to: Double) -> Bool {
        notes.contains { $0.t < to && $0.end > from && pcs.contains((($0.pitch % 12) + 12) % 12) }
    }

    for (i, c) in a.chords.enumerated() {
        let d = c.end - c.start
        let last = i == a.chords.count - 1
        let root = bassPitch(c.root)
        let fifth = c.tones.contains(7) ? (root + 7 > 40 ? root - 5 : root + 7) : root
        let next = last ? nil : a.chords[i + 1]

        // Beats inside this chord. With a steady beat they are counted out and nudged onto
        // what the player played; in free time the only "beat" is the chord itself.
        let n = counts[i]
        var beats = (0..<n).map { c.start + d * Double($0) / Double(n) }
        if n > 1 { for k in 1..<n { beats[k] = onset(near: beats[k], within: d / Double(n) * 0.22) ?? beats[k] } }
        beats.append(c.end)

        // Bass.
        if steady && n >= 2 {
            var k = 0
            var hits: [(k: Int, pitch: Int, span: Int, v: Double)] = []
            while k < n {
                hits.append((k, root, min(2, n - k), 84))
                if group == 4, k + 2 < n { hits.append((k + 2, fifth, min(2, n - k - 2), 70)) }
                k += group
            }
            // A step into the next chord, but only on a single short beat.
            if let nx = next, nx.root != c.root, n >= 3, d / Double(n) < 0.9 {
                let target = bassPitch(nx.root)
                var approach = target - 1
                while !inScale(approach), approach > target - 3 { approach -= 1 }
                if approach % 12 == root % 12 { approach = target + 1; while !inScale(approach), approach < target + 3 { approach += 1 } }
                hits = hits.filter { $0.k < n - 1 }.map { h in var h = h; h.span = min(h.span, n - 1 - h.k); return h }
                hits.append((n - 1, approach, 1, 62))
            }
            for h in hits {
                out.append(RNote(t: beats[h.k], end: beats[h.k + h.span] - 0.03, pitch: h.pitch, vel: vel(h.v, beats[h.k]), ch: 1))
            }
        } else {
            // Free time: one long note under the chord. A long chord gets a second, softer
            // note, placed on something the player played around the middle.
            var split: Double? = nil
            if d > 3.2, fifth != root { split = onsets.filter { $0 > c.start + d * 0.35 && $0 < c.start + d * 0.7 }.min { abs($0 - c.start - d / 2) < abs($1 - c.start - d / 2) } }
            let tail = last ? 0.0 : (root == lastBass ? -0.04 : 0.03)
            // On some chords the bass walks one step into the next chord, on the last thing the
            // player played before the change. It never invents a moment of its own.
            var walk: (t: Double, pitch: Int)? = nil
            if let nx = next, nx.root != c.root, d > 2.2, i % 2 == 1 || d > 4.5,
               let o = onsets.last(where: { $0 > c.end - 1.1 && $0 < c.end - 0.25 }) {
                let target = bassPitch(nx.root)
                let from = split == nil ? root : fifth
                var step = target + (from > target ? 1 : -1)
                while !inScale(step), abs(step - target) < 3 { step += from > target ? 1 : -1 }
                if inScale(step), step % 12 != from % 12, !playerHas([((step + 1) % 12 + 12) % 12, ((step - 1) % 12 + 12) % 12], from: o, to: c.end) {
                    walk = (o, step)
                }
            }
            if let wk = walk, split == nil || split! < wk.t - 0.3 {
                let firstEnd = split ?? wk.t
                out.append(RNote(t: c.start, end: firstEnd + 0.03, pitch: root, vel: vel(76, c.start), ch: 1))
                if let s = split { out.append(RNote(t: s, end: wk.t + 0.02, pitch: fifth, vel: vel(58, s), ch: 1)) }
                out.append(RNote(t: wk.t, end: c.end + 0.02, pitch: wk.pitch, vel: vel(54, wk.t), ch: 1))
                lastBass = wk.pitch
            } else if let s = split {
                out.append(RNote(t: c.start, end: s + 0.03, pitch: root, vel: vel(76, c.start), ch: 1))
                out.append(RNote(t: s, end: c.end + tail, pitch: fifth, vel: vel(58, s), ch: 1))
                lastBass = fifth
            } else {
                out.append(RNote(t: c.start, end: max(c.start + 0.1, c.end + tail), pitch: root, vel: vel(76, c.start), ch: 1))
                lastBass = root
            }
        }

        // Strings: a soft pad that moves as little as possible. A note shared with the
        // previous chord is simply held, so the pad changes like a slow breath.
        var pcs = c.tones.map { (c.root + $0) % 12 }
        if pcs.count == 4 { pcs.removeFirst() }
        // On a suspended chord the band keeps to the root and fifth, which can never clash
        // with wherever the player takes the middle note next.
        let open = c.quality.hasPrefix("sus")
        if open { pcs = [c.root, (c.root + 7) % 12] }
        // Kept above the left hand's register, where close notes turn to mud under a piano.
        let voicing = pcs.compactMap { pc in (57...77).filter { $0 % 12 == pc }.min { abs($0 - padCentre) < abs($1 - padCentre) } }
        if !voicing.isEmpty { padCentre = voicing.reduce(0, +) / voicing.count }
        let padEnd = c.end + (last ? 0.1 : 0.22)
        var stillOpen: [Int: Int] = [:]
        for p in voicing {
            if let idx = padOpen[p] {
                out[idx].end = padEnd
                stillOpen[p] = idx
            } else {
                out.append(RNote(t: c.start + (i == 0 ? 0 : 0.03 + 0.045 * Double(stillOpen.count)), end: padEnd, pitch: p, vel: vel(44, c.start, vary: 3), ch: 2))
                stillOpen[p] = out.count - 1
            }
        }
        // On a long major chord one string voice leans up to the ninth and stays there, the
        // small inner movement that keeps a held chord from standing still. It moves on a
        // moment the player played, and never against a note the player is holding next to it.
        if !open, c.quality == "major" || c.quality == "major seventh", d > 3.4, i % 2 == 0,
           let rootVoice = voicing.first(where: { $0 % 12 == c.root }), let idx = stillOpen[rootVoice],
           inScale(rootVoice + 2), !voicing.contains(rootVoice + 2),
           let m = onsets.filter({ $0 > c.start + d * 0.4 && $0 < c.start + d * 0.7 }).min(by: { abs($0 - c.start - d * 0.5) < abs($1 - c.start - d * 0.5) }),
           !playerHas([(c.root + 1) % 12, (c.root + 3) % 12], from: m, to: c.end) {
            out[idx].end = m + 0.08
            out.append(RNote(t: m, end: padEnd, pitch: rootVoice + 2, vel: vel(42, m, vary: 3), ch: 2))
            stillOpen[rootVoice] = nil
            stillOpen[rootVoice + 2] = out.count - 1
        }
        padOpen = stillOpen

        // High strings: one quiet note far above everything, which joins once the piece has
        // found its feet and gives the later part its lift. It holds across chords when it can.
        let place = c.start / max(1, a.length)
        if a.chords.count >= 5, place > 0.3, !last || highOpen != nil, loud(c.start) > 0.8 || place > 0.55 {
            let wanted = open || !c.tones.contains(7) ? [c.root] : [c.root, (c.root + 7) % 12]
            let p = (74...88).filter { wanted.contains($0 % 12) }.min { abs($0 - high) < abs($1 - high) } ?? high
            if let idx = highOpen, out[idx].pitch == p {
                out[idx].end = padEnd
            } else {
                out.append(RNote(t: c.start + 0.05, end: padEnd, pitch: p, vel: vel(34, c.start, vary: 2), ch: 6))
                highOpen = out.count - 1
            }
            high = p
        } else {
            highOpen = nil
        }

        // Horn: when the melody rests for a while, a soft horn answers with one long note from
        // the heart of the chord, and steps aside the moment the melody comes back.
        if a.chords.count >= 5, place > 0.25, d > 2.4, !open {
            let inside = tune.filter { $0 >= c.start - 0.05 && $0 < c.end }
            var gap: (from: Double, to: Double)? = nil
            for (x, y) in zip([c.start] + inside, inside + [c.end]) where y - x > 1.7 && (gap == nil || y - x > gap!.to - gap!.from) { gap = (x, y) }
            if let gp = gap, let enter = onsets.first(where: { $0 > gp.from + 0.45 && $0 < gp.to - 0.9 }) {
                let colour = [(c.root + c.tones[1]) % 12, (c.root + (c.tones.count == 4 ? c.tones[3] : c.tones[2])) % 12]
                let cap = notes.filter { $0.pitch >= 60 && $0.t <= enter }.max { $0.t < $1.t }?.pitch ?? 72
                let range = (53...69).filter { colour.contains($0 % 12) && $0 < cap - 2 }
                if let p = range.min(by: { abs($0 - horn) < abs($1 - horn) }), !out.contains(where: { $0.ch == 3 && $0.pitch == p && $0.t <= enter && $0.end > enter }) {
                    out.append(RNote(t: enter, end: min(gp.to - 0.08, c.end), pitch: p, vel: vel(40, enter, vary: 3), ch: 7))
                    horn = p
                }
            }
        }

        // Cello: a slow singing line on the notes that give the chord its colour, kept under
        // the melody. On a longer chord it moves once, on a moment the player played.
        let all = c.tones.map { (c.root + $0) % 12 }
        let guides = open ? [(c.root + 7) % 12, c.root] : (c.tones.count == 4 ? [all[1], all[3]] : [all[1], all[2]])
        func nearest(_ wanted: [Int], to p: Int, under cap: Int?) -> Int {
            let range = (45...67).filter { wanted.contains($0 % 12) && (cap == nil || $0 < cap! - 2) }
            return range.min { abs($0 - p) < abs($1 - p) } ?? (45...67).filter { wanted.contains($0 % 12) }.min { abs($0 - p) < abs($1 - p) } ?? p
        }
        // The band comes in gradually: the cello waits for the third chord of a longer piece.
        if a.chords.count < 6 || i >= 2 {
        let first = nearest(guides, to: cello, under: melody(at: c.start))
        let move = d > 1.8 ? onsets.filter { $0 > c.start + d * 0.4 && $0 < c.start + d * 0.75 }.min { abs($0 - c.start - d * 0.55) < abs($1 - c.start - d * 0.55) } : nil
        let overlap = last ? 0.0 : 0.06
        if let m = move {
            let second = nearest((open ? [c.root, (c.root + 7) % 12] : all).filter { $0 != first % 12 }, to: first, under: melody(at: m))
            out.append(RNote(t: c.start, end: m + 0.06, pitch: first, vel: vel(58, c.start), ch: 3))
            out.append(RNote(t: m, end: c.end + overlap, pitch: second, vel: vel(50, m), ch: 3))
            cello = second
        } else {
            out.append(RNote(t: c.start, end: c.end + overlap, pitch: first, vel: vel(56, c.start), ch: 3))
            cello = first
        }

        }

        // Drums: only with a steady beat, and played lightly, following the player's loudness.
        if steady, n >= 2 {
            let len = d / Double(n)
            let soft = len > 0.6 || loud(c.start) < 0.9
            func hit(_ t: Double, _ drum: Int, _ v: Double) {
                // A drum only ever lands on something the player played. A beat the player left
                // empty stays empty, so the drums can never run ahead or fall out of step.
                guard let anchor = onset(near: t, within: 0.07) else { return }
                let t = anchor
                let at = max(0, t + (t == c.start ? 0 : wobble(0.006)))
                out.append(RNote(t: at, end: at + 0.1, pitch: drum, vel: vel(v, t, vary: 6), ch: 9))
            }
            for k in 0..<n {
                let t = beats[k], pos = k % group
                if group == 4 {
                    if pos == 0 { hit(t, 36, 80) } else if pos == 2 { hit(t, 36, 62) }
                    if pos == 1 || pos == 3 { hit(t, soft ? 37 : 38, soft ? 50 : 64) }
                } else {
                    if pos == 0 { hit(t, 36, 76) } else { hit(t, 37, 42) }
                }
                hit(t, 42, pos == 0 ? 44 : 36)
                if len > 0.4 { hit((t + beats[k + 1]) / 2, 42, 24) }
            }
            if i == 0 { hit(c.start, 49, 46) }
        }
    }
    out = settle(out, against: notes)
    if bandSimple { return out.filter { [1, 2, 3, 9].contains($0.ch) } }
    // A warm pad doubles the strings very quietly, which gives them body and a softer edge.
    out += out.filter { $0.ch == 2 }.map { RNote(t: $0.t, end: $0.end, pitch: $0.pitch, vel: max(18, $0.vel - 10), ch: 8) }
    return out
}

// The band with its breathing added: every sustained part swells into each chord and eases
// off again, grows with the piece, follows how loudly the player plays, and fades at the end.
func bandFull(_ notes: [RNote], _ a: Analysis) -> [RNote] {
    let band = bandParts(notes, a)
    if bandClassic { return band }            // no added swells: it plays as written
    guard let lastChord = a.chords.last, !band.isEmpty else { return band }
    func loud(_ t: Double) -> Double {
        let near = notes.filter { abs($0.t - t) < 3 }
        guard !near.isEmpty else { return 0.8 }
        return max(0.6, min(1.25, Double(near.reduce(0) { $0 + $1.vel }) / Double(near.count) / 66))
    }
    let end = lastChord.end
    var out = band
    for ch in [2, 3, 6, 7, 8] where band.contains(where: { $0.ch == ch }) {
        var lastValue = -1
        var t = 0.0
        while t <= end + 0.2 {
            let c = a.chords.last { $0.start <= t + 0.001 } ?? a.chords[0]
            let pos = max(0, min(1, (t - c.start) / max(0.5, c.end - c.start)))
            // Inside one chord: in, up to full by a third of the way, then easing off.
            var e = pos < 0.35 ? 0.74 + 0.26 * (pos / 0.35) : 1.0 - 0.2 * ((pos - 0.35) / 0.65)
            e *= 0.72 + 0.28 * min(1, t / max(1, end * 0.5))    // the piece grows through its first half
            e *= 0.55 + 0.45 * loud(t)                           // and follows the player
            if t < 1.5 { e *= 0.45 + 0.55 * t / 1.5 }           // the band fades in at the very start
            if c.start == lastChord.start { e *= 1.0 - 0.6 * pos }   // and fades away on the last chord
            let value = max(38, min(127, Int(52 + 75 * e)))
            if abs(value - lastValue) >= 2 { out.append(RNote(t: t, end: t, pitch: 0, vel: value, ch: ch, cc: 11)); lastValue = value }
            t += 0.2
        }
        // Leave the instrument at full strength for whatever plays on it next.
        out.append(RNote(t: end + 2.5, end: end + 2.5, pitch: 0, vel: 127, ch: ch, cc: 11))
    }
    return out
}

// The band as named tracks, for saving. Each track carries its own swells.
func bandTracks(_ band: [RNote]) -> [(name: String, notes: [RNote])] {
    let names: [(String, Int)] = [("Bass", 1), ("Strings", 2), ("Cello", 3), ("High strings", 6), ("Horn", 7), ("Warm pad", 8), ("Drums", 9)]
    var out: [(name: String, notes: [RNote])] = []
    for (name, ch) in names {
        let part = band.filter { $0.ch == ch }
        if part.contains(where: { $0.cc < 0 }) { out.append((name, part)) }
    }
    return out
}
