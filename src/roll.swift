// Playing a MIDI file for the visualiser: the notes fall onto the keyboard in the app window
// while the tool plays them on the Mac's built-in piano.

import Foundation

struct RollNote { var t: Double; var dur: Double; var pitch: Int; var vel: Int; var track: Int }

/// Reads any standard MIDI file: every track, tempo changes included, drums left out.
/// Returns the notes in seconds, and the moments the sustain pedal goes down and up.
func readMIDIForRoll(_ url: URL) -> (notes: [RollNote], pedal: [(t: Double, down: Bool)])? {
    guard let data = try? Data(contentsOf: url), data.count > 22 else { return nil }
    let b = [UInt8](data)
    guard b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64 else { return nil }
    let division = Int(b[12]) << 8 | Int(b[13])
    guard division > 0, division & 0x8000 == 0 else { return nil }
    var tempos: [(tick: Int, usPerBeat: Int)] = []
    var raw: [(tick: Int, end: Int, pitch: Int, vel: Int, track: Int)] = []
    var pedalTicks: [(Int, Bool)] = []
    var pos = 14, track = 0
    while pos + 8 <= b.count, b[pos] == 0x4D, b[pos + 1] == 0x54, b[pos + 2] == 0x72, b[pos + 3] == 0x6B {
        let length = Int(b[pos + 4]) << 24 | Int(b[pos + 5]) << 16 | Int(b[pos + 6]) << 8 | Int(b[pos + 7])
        var i = pos + 8
        let end = min(b.count, i + length)
        pos = end
        var tick = 0, status: UInt8 = 0
        var open: [Int: (Int, Int, Int)] = [:]     // channel and pitch -> start tick, velocity, index
        var sawNote = false
        while i < end {
            var delta = 0
            while i < end { let c = b[i]; i += 1; delta = delta << 7 | Int(c & 0x7F); if c & 0x80 == 0 { break } }
            tick += delta
            guard i < end else { break }
            var s = b[i]
            if s == 0xFF {
                guard i + 2 < end else { break }
                let type = b[i + 1]
                var j = i + 2, len = 0
                while j < end { let c = b[j]; j += 1; len = len << 7 | Int(c & 0x7F); if c & 0x80 == 0 { break } }
                if type == 0x51, len == 3, j + 2 < end { tempos.append((tick, Int(b[j]) << 16 | Int(b[j + 1]) << 8 | Int(b[j + 2]))) }
                i = j + len
                continue
            }
            if s == 0xF0 || s == 0xF7 {
                var j = i + 1, len = 0
                while j < end { let c = b[j]; j += 1; len = len << 7 | Int(c & 0x7F); if c & 0x80 == 0 { break } }
                i = j + len
                continue
            }
            if s & 0x80 != 0 { status = s; i += 1 } else { s = status }
            let kind = status & 0xF0, ch = Int(status & 0x0F)
            let size = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
            guard i + size <= end else { break }
            let d1 = Int(b[i]), d2 = size == 2 ? Int(b[i + 1]) : 0
            i += size
            if ch == 9 { continue }                 // drums are not piano keys
            let key = ch << 8 | d1
            if kind == 0x90, d2 > 0 {
                if let o = open[key] { raw[o.2].end = tick }
                raw.append((tick, -1, d1, d2, track))
                open[key] = (tick, d2, raw.count - 1)
                sawNote = true
            } else if kind == 0x80 || kind == 0x90 {
                if let o = open[key] { raw[o.2].end = tick; open[key] = nil }
            } else if kind == 0xB0, d1 == 64 {
                pedalTicks.append((tick, d2 >= 64))
            }
        }
        for (_, o) in open { raw[o.2].end = tick }
        if sawNote { track += 1 }
    }
    guard !raw.isEmpty else { return nil }
    tempos.sort { $0.tick < $1.tick }
    if tempos.first?.tick != 0 { tempos.insert((0, 500_000), at: 0) }
    func seconds(_ tick: Int) -> Double {
        var t = 0.0
        for (k, tempo) in tempos.enumerated() {
            let until = k + 1 < tempos.count ? min(tick, tempos[k + 1].tick) : tick
            if until > tempo.tick { t += Double(until - tempo.tick) * Double(tempo.usPerBeat) / 1e6 / Double(division) }
            if k + 1 < tempos.count, tick <= tempos[k + 1].tick { break }
        }
        return t
    }
    var notes = raw.filter { $0.pitch >= 21 && $0.pitch <= 108 }.map { n -> RollNote in
        let start = seconds(n.tick)
        return RollNote(t: start, dur: max(0.05, seconds(max(n.end, n.tick + 1)) - start), pitch: n.pitch, vel: n.vel, track: n.track)
    }
    // Start at the first note, whatever silence the file opens with.
    let first = notes.map { $0.t }.min() ?? 0
    for i in notes.indices { notes[i].t -= first }
    notes.sort { $0.t < $1.t }
    return (notes, pedalTicks.map { (max(0, seconds($0.0) - first), $0.1) })
}

extension Engine {
    /// Plays a MIDI file while the app window shows its notes falling onto the keys.
    func playFile(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let file = readMIDIForRoll(url) else {
            ui("rollstop")
            run { g in self.say("I could not read that MIDI file.", g) }
            return
        }
        autosaveTake()
        waiting = false; paused = false; roundOn = false
        accGen += 1
        midi.allOff()
        live.silence()
        let name = url.deletingPathExtension().lastPathComponent
        ui("rollnew " + name)
        // The notes go to the window first, a couple of hundred to a line.
        var line = ""
        for (i, n) in file.notes.enumerated() {
            line += String(format: "%.3f,%.3f,%d,%d,%d;", n.t, n.dur, n.pitch, n.vel, n.track)
            if i % 200 == 199 || i == file.notes.count - 1 { ui("rolln " + line); line = "" }
        }
        // Then everything is played a little later, so the first notes have time to fall.
        let lead = 3.0
        var ev: [Ev] = []
        for n in file.notes {
            ev.append(Ev(t: lead + n.t, bytes: [0x90, UInt8(n.pitch), UInt8(max(1, min(127, n.vel)))]))
            ev.append(Ev(t: lead + n.t + max(0.04, n.dur - 0.01), bytes: [0x80, UInt8(n.pitch), 0]))
        }
        for p in file.pedal { ev.append(Ev(t: lead + p.t, bytes: [0xB0, 64, p.down ? 127 : 0])) }
        let length = (file.notes.map { $0.t + $0.dur }.max() ?? 0)
        run { g in
            ui(String(format: "rollstart %.2f %.2f", lead, length))
            // A file always plays on the Mac's own piano. Sending it to Logic only makes a
            // sound when a track there happens to be set up and selected, and otherwise the
            // notes fall in silence.
            self.midi.pianoHere = true
            self.play(ev, g)
            self.midi.send([0xB0, 64, 0])
            self.midi.pianoHere = false
            if self.alive(g) { usleep(1_200_000) }
            ui("rollstop")
        }
    }
}
