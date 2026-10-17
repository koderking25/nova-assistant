// The band lab: every version of the band, played over the same real pieces, measured, and
// written out as sound files to listen to side by side.
//
//   nova-engine --band-lab <folder> <piece.mid> [more pieces...]
//
// For each piece and each version it writes "<piece> - <version>.wav" (the Mac's own instruments,
// exactly as the band sounds in the app, rendered offline so nothing plays aloud) and a MIDI file,
// and prints how choppy each part is.

import Foundation
import AVFoundation

struct BandVersion {
    let name: String
    let mix: String            // "classic": dry and close, as the first band sounded; "full": the hall mix
    let make: ([RNote], Analysis) -> [RNote]
}

let bandVersions: [BandVersion] = [
    BandVersion(name: "1 first (7 Oct)", mix: "classic") { bandFirst($0, $1) },
    BandVersion(name: "2 early (7-9 Oct)", mix: "classic") { bandEarly($0, $1) },
    BandVersion(name: "3 classic (now)", mix: "classic") { n, a in let was = bandStyle; bandStyle = "classic"; defer { bandStyle = was }; return bandFull(n, a) },
    BandVersion(name: "4 full (now)", mix: "full") { n, a in let was = bandStyle; bandStyle = "full"; defer { bandStyle = was }; return bandFull(n, a) },
    BandVersion(name: "5 new", mix: "classic") { bandBest($0, $1) },
]

struct PartStats {
    var notes = 0, perSecond = 0.0, meanLength = 0.0, sounding = 0.0, stabs = 0.0, gaps = 0, restrikes = 0, clashes = 0.0, leaps = 0, unisons = 0
}

/// How each part behaves: how often it starts notes, how long they last, how much of the piece it fills,
/// how many notes are short stabs, how many times it falls silent while the piano plays, and how often it
/// strikes the same note again straight away. The last three are what makes a band sound choppy.
func bandStats(_ band: [RNote], piano: [RNote], length: Double) -> [Int: PartStats] {
    var out: [Int: PartStats] = [:]
    for ch in Set(band.filter { $0.cc < 0 }.map { $0.ch }) {
        let part = band.filter { $0.ch == ch && $0.cc < 0 }.sorted { $0.t < $1.t }
        var s = PartStats()
        s.notes = part.count
        s.perSecond = Double(part.count) / max(1, length)
        s.meanLength = part.reduce(0) { $0 + $1.end - $1.t } / Double(max(1, part.count))
        // Time covered by at least one note of this part.
        var covered = 0.0, reach = -1.0
        for n in part { if n.end > reach { covered += n.end - max(n.t, reach); reach = n.end } }
        s.sounding = covered / max(1, length)
        if ch != 9 {
            s.stabs = Double(part.filter { $0.end - $0.t < 0.25 }.count) / Double(max(1, part.count))
            // Silences of a third of a second or more in this part while the piano is still playing.
            var held = -1.0
            for n in part {
                if held > 0, n.t - held > 0.33, piano.contains(where: { $0.t < n.t && $0.end > held }) { s.gaps += 1 }
                held = max(held, n.end)
            }
            // Seconds this part spends a semitone (or a minor ninth) away from a note the piano is holding.
            for n in part { for p in piano where p.t < n.end && p.end > n.t {
                let d = ((p.pitch - n.pitch) % 12 + 12) % 12
                if d == 1 || d == 11 { s.clashes += max(0, min(n.end, p.end) - max(n.t, p.t)) }
            } }
            // Jumps of more than a fifth from one note to the next in a single line (bass, cello), and
            // two string voices landing on the same pitch at once (a thinner chord).
            if ch == 1 || ch == 3 { for (x, y) in zip(part, part.dropFirst()) where abs(y.pitch - x.pitch) > 7 { s.leaps += 1 } }
            for (i, x) in part.enumerated() { for y in part[(i + 1)...] where y.t < x.end - 0.05 && y.pitch == x.pitch && y.t > x.t - 0.01 { s.unisons += 1 } }
            var last: [Int: Double] = [:]
            for n in part { if let e = last[n.pitch], n.t - e < 0.12 { s.restrikes += 1 }; last[n.pitch] = n.end }
        }
        out[ch] = s
    }
    return out
}

/// Plays piano and band through the band's own instruments, offline, into a WAV file. Also returns how
/// often the band's sound suddenly drops away (falls by 12 dB or more within a tenth of a second), per minute.
@discardableResult
func renderBand(_ notes: [RNote], mix: String, to url: URL) -> Double {
    let was = bandStyle
    bandStyle = mix == "full" ? "full" : "classic"
    defer { bandStyle = was }
    let engine = AVAudioEngine()
    let rate = 44100.0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return -1 }
    do { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256) } catch { return -1 }
    guard let samplers = try? Sounds.build(on: engine), (try? engine.start()) != nil else { return -1 }
    let evs = events(notes).sorted { $0.t < $1.t }
    let length = (notes.map { $0.end }.max() ?? 0) + 2.5
    guard let file = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false),
          let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 256) else { return -1 }
    var i = 0, frame = 0.0
    var levels: [Float] = []
    var windowSum: Float = 0, windowN = 0
    while frame / rate < length {
        let t = frame / rate
        while i < evs.count, evs[i].t <= t {
            let b = evs[i].bytes, ch = b[0] & 0x0F
            if let s = samplers[ch] {
                switch b[0] & 0xF0 {
                case 0x90 where b.count > 2 && b[2] > 0: s.startNote(b[1], withVelocity: b[2], onChannel: 0)
                case 0x80, 0x90: s.stopNote(b[1], onChannel: 0)
                case 0xB0 where b.count > 2: s.sendController(b[1], withValue: b[2], onChannel: 0)
                default: break
                }
            }
            i += 1
        }
        guard (try? engine.renderOffline(256, to: buf)) == .success else { break }
        try? file.write(from: buf)
        if let d = buf.floatChannelData?[0] { for k in 0..<Int(buf.frameLength) { windowSum += d[k] * d[k] }; windowN += Int(buf.frameLength) }
        if windowN >= 2205 { levels.append(sqrt(windowSum / Float(windowN))); windowSum = 0; windowN = 0 }
        frame += 256
    }
    engine.stop()
    // Drops: from a sounding moment to 12 dB quieter within two 50 ms windows, while the piece is still going.
    var drops = 0
    let end = max(0, levels.count - 50)
    if end > 2 { for k in 2..<end where levels[k - 2] > 0.003 && levels[k] < levels[k - 2] / 4 { drops += 1 } }
    return Double(drops) / max(0.1, length / 60)
}

func bandLab(out: URL, files: [URL]) {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var totals: [String: (drops: Double, clash: Double, gaps: Int, restrikes: Int, n: Int)] = [:]
    for f in files {
        guard let s = loadMIDIFile(f, track: "piano") else { print("cannot read \(f.lastPathComponent)"); continue }
        let spb = 60 / s.bpm
        let take = tidyTake(s.notes.map { RNote(t: $0.beat * spb, end: ($0.beat + $0.dur) * spb, pitch: $0.pitch, vel: $0.vel) }.sorted { $0.t < $1.t })
        guard take.count >= 8 else { continue }
        let a = analyse(take)
        let piece = f.deletingPathExtension().lastPathComponent
        print("\n== \(piece): \(a.keyName), \(take.count) notes, \(String(format: "%.0f", a.length)) s, beat \(a.beat.map { String(format: "%.2f s", $0) } ?? "free")")
        for v in bandVersions {
            let band = v.make(take, a)
            let stats = bandStats(band, piano: take, length: a.length)
            let wav = out.appendingPathComponent("\(piece) - \(v.name).wav")
            let drops = ProcessInfo.processInfo.environment["NOVA_NOWAV"] != nil ? 0 : renderBand(take + band, mix: v.mix, to: wav)
            _ = writeMIDIFile(out.appendingPathComponent("\(piece) - \(v.name).mid"), bpm: 120, tracks: [("Piano", take)] + bandTracks(band))
            let melodic = stats.filter { $0.key != 9 }.map { $0.value }
            let stabs = melodic.isEmpty ? 0 : melodic.reduce(0) { $0 + $1.stabs } / Double(melodic.count)
            let gaps = melodic.reduce(0) { $0 + $1.gaps }, re = melodic.reduce(0) { $0 + $1.restrikes }
            let clash = melodic.reduce(0) { $0 + $1.clashes } / max(1, a.length) * 60
            let parts = stats.sorted { $0.key < $1.key }.map { ch, p in String(format: "ch%d %d notes %.1f/s len %.2f fill %.0f%%", ch, p.notes, p.perSecond, p.meanLength, p.sounding * 100) }.joined(separator: " | ")
            print(String(format: "  %-20@ clash %4.1f s/min  gaps %3d  restrikes %3d  stabs %2.0f%%  leaps %d  unisons %d", v.name as NSString, clash, gaps, re, stabs * 100, melodic.reduce(0) { $0 + $1.leaps }, melodic.reduce(0) { $0 + $1.unisons }))
            var tot = totals[v.name] ?? (0, 0, 0, 0, 0)
            tot.drops += drops; tot.clash += clash; tot.gaps += gaps; tot.restrikes += re; tot.n += 1
            totals[v.name] = tot
        }
    }
    print("\n== Overall (average per piece)")
    for v in bandVersions { if let t = totals[v.name], t.n > 0 {
        print(String(format: "  %-20@ clashing %4.1f s a minute   silences %5.1f   restrikes %5.1f", v.name as NSString, t.clash / Double(t.n), Double(t.gaps) / Double(t.n), Double(t.restrikes) / Double(t.n)))
    } }
}
