// Live band: a bass, strings and cello that follow the player in real time.
//
// It never guesses. Each time the left hand lands on a new bass note the band moves at once:
// the bass and strings take that note, and the strings then gather the other notes of the
// chord from the left hand as it plays them. So the band only ever holds notes the player has
// just played, an octave or two away, and cannot clash with the harmony. The strings swell in
// after each change, follow how loudly the player plays, and fade away a few seconds after
// the playing stops.

import Foundation

final class LiveBand {
    var on = false
    var out: ([UInt8]) -> Void = { _ in }      // where the band's notes go
    private let lock = NSLock()
    private var recent: [(t: Double, pitch: Int)] = []
    private(set) var root: Int? = nil
    private var rootAt = -10.0
    private var down: [Int: Double] = [:]      // keys the player is holding right now, and since when
    var padClasses: Set<Int> { lock.lock(); defer { lock.unlock() }; return Set(pad.map { $0 % 12 }) }
    private var waiting: (pitch: Int, at: Double)? = nil   // a bass note not yet acted on
    private var bass: Int? = nil
    private var pad: Set<Int> = []
    private var cello: Int? = nil
    private var hasThird = false
    private var padCentre = 62, celloLast = 55
    private var offs: [(at: Double, ch: UInt8, pitch: Int)] = []     // notes to release a little later
    private var lastPlay = 0.0
    private var loud = 0.7                     // how hard the player is playing, smoothed
    private var swell = 0.0, aim = 0.0         // the strings' strength now, and where it is heading
    private var sentCC = -1

    // Starting a note that is only waiting to be released keeps it sounding instead of striking
    // it a second time, so no note can ever be left hanging.
    private func on(_ ch: UInt8, _ pitch: Int, _ vel: Double) {
        if let i = offs.firstIndex(where: { $0.ch == ch && $0.pitch == pitch }) { offs.remove(at: i); return }
        out([0x90 | ch, UInt8(pitch), UInt8(max(14, min(110, Int(vel))))])
    }
    private func off(_ ch: UInt8, _ pitch: Int) { out([0x80 | ch, UInt8(pitch), 0]) }
    private func nearest(_ pcs: [Int], _ range: ClosedRange<Int>, to centre: Int) -> [Int] {
        pcs.compactMap { pc in range.filter { $0 % 12 == pc }.min { abs($0 - centre) < abs($1 - centre) } }
    }

    /// The player pressed a key.
    func note(_ pitch: Int, _ vel: Int, at t: Double) {
        lock.lock(); defer { lock.unlock() }
        guard on else { return }
        recent.append((t, pitch))
        recent.removeAll { t - $0.t > 3 }
        lastPlay = t
        loud += (Double(vel) / 80 - loud) * 0.25
        loud = max(0.45, min(1.3, loud))
        let pc = ((pitch % 12) + 12) % 12
        // A bass note is a low note with nothing clearly lower just before it (so the upper
        // notes of a broken chord going up do not count).
        down[pitch] = t
        let lowerBefore = recent.contains { $0.pitch <= pitch - 3 && t - $0.t < 0.9 && t - $0.t > 0 }
        let lowerHeld = down.contains { $0.key <= pitch - 3 && t - $0.value < 2.5 }
        if pitch < 60, !lowerBefore, !lowerHeld {
            // Wait a twelfth of a second before moving: in a chord rolled downward, the real
            // bass note is the one that lands last.
            if let w = waiting { if pitch < w.pitch { waiting = (pitch, w.at) } } else { waiting = (pitch, t) }
        } else if root != nil, pitch < 64 {
            gather(pc, at: t)
        }
        aim = 1
    }

    /// The player let go of a key.
    func release(_ pitch: Int) { lock.lock(); down[pitch] = nil; lock.unlock() }

    private func change(to pc: Int, at t: Double) {
        root = pc; rootAt = t; hasThird = false
        // Bass.
        let b = 28 + ((pc - 28) % 12 + 12) % 12
        if let old = bass, old != b { offs.append((t + 0.05, 1, old)) }
        if bass != b { on(1, b, 70 * loud) }
        bass = b
        // Strings and cello start on the bass note itself, in their own octaves.
        let voicing = Set(nearest([pc], 55...72, to: padCentre))
        for p in pad.subtracting(voicing) { offs.append((t + 0.35, 2, p)) }     // the old chord overlaps the new one
        for p in voicing.subtracting(pad) { on(2, p, 46 * loud) }
        pad = voicing
        if let c = nearest([pc], 45...57, to: celloLast).first, c != cello {
            if let old = cello { offs.append((t + 0.3, 3, old)) }
            on(3, c, 50 * loud); cello = c; celloLast = c
        }
        hasThird = false
        // Notes of this chord the left hand has only just played (a chord rolled downward) count already.
        for n in recent where t - n.t < 0.5 && n.pitch < 64 { gather(((n.pitch % 12) + 12) % 12, at: t) }
        swell = min(swell, 0.6)     // a small breath in on every change
        aim = 1
    }

    /// A left-hand note of the current chord: the strings take it too, up to three notes in all.
    /// A note a semitone from one already held is passed over, so the strings never smear.
    private func gather(_ pc: Int, at t: Double) {
        let have = Set(pad.map { $0 % 12 })
        guard have.count < 3, !have.contains(pc), !have.contains(where: { [1, 11].contains(($0 - pc + 12) % 12) }) else { return }
        guard let p = nearest([pc], 55...74, to: padCentre).first, !pad.contains(p) else { return }
        on(2, p, 42 * loud)
        pad.insert(p)
        padCentre = pad.reduce(0, +) / pad.count
        // The cello leaves the bass note for the first new colour it hears.
        if !hasThird, let c = nearest([pc], 48...64, to: celloLast).first, c != cello {
            hasThird = true
            if let old = cello { offs.append((t + 0.25, 3, old)) }
            on(3, c, 48 * loud); cello = c; celloLast = c
        }
    }

    /// Called forty times a second: releases, the swell, and fading out when the playing stops.
    func tick(_ t: Double) {
        lock.lock(); defer { lock.unlock() }
        if let w = waiting, t - w.at >= 0.08 {
            waiting = nil
            let pc = ((w.pitch % 12) + 12) % 12
            if pc != root, t - rootAt > 0.3 { change(to: pc, at: t) }
        }
        for o in offs where o.at <= t { off(o.ch, o.pitch) }
        offs.removeAll { $0.at <= t }
        guard root != nil else { return }
        if t - lastPlay > 3.5 { aim = 0 }
        swell += (aim - swell) * (aim > swell ? 0.085 : 0.036)
        let value = max(0, min(127, Int((52 + 70 * swell * min(1.15, 0.5 + 0.55 * loud)).rounded())))
        if abs(value - sentCC) >= 2 {
            sentCC = value
            for ch: UInt8 in [2, 3] { out([0xB0 | ch, 11, UInt8(value)]) }
        }
        if aim == 0, swell < 0.06 { silenceLocked() }
    }

    private func silenceLocked() {
        for o in offs { off(o.ch, o.pitch) }
        offs = []
        if let b = bass { off(1, b) }
        for p in pad { off(2, p) }
        if let c = cello { off(3, c) }
        bass = nil; pad = []; cello = nil; root = nil; hasThird = false; waiting = nil; rootAt = -10
        swell = 0; aim = 0; sentCC = -1
        for ch: UInt8 in [2, 3] { out([0xB0 | ch, 11, 127]) }     // leave the instruments at full strength
    }

    func silence() { lock.lock(); silenceLocked(); lock.unlock() }
}

// Runs a saved piece through the live band at full speed without sound and prints what it
// would have played, next to what the careful after-the-fact analysis hears. Used to check the
// live band without a piano: ./talking-piano --livetest <idea.mid>
func liveBandTest(_ take: [RNote], _ a: Analysis) {
    let band = LiveBand()
    var t = 0.0
    var sent: [(Double, [UInt8])] = []
    band.on = true
    band.out = { sent.append((t, $0)) }
    var roots: [(Double, Int)] = []
    var last: Int? = nil
    var inChord = 0, held = 0, full = 0, steps = 0
    let notes = take.sorted { $0.t < $1.t }
    var i = 0
    var ends: [(Double, Int)] = []
    let end = (notes.map { $0.end }.max() ?? 0) + 6
    while t < end {
        while i < notes.count, notes[i].t <= t { band.note(notes[i].pitch, notes[i].vel, at: notes[i].t); ends.append((notes[i].end, notes[i].pitch)); i += 1 }
        for e in ends where e.0 <= t { band.release(e.1) }
        ends.removeAll { $0.0 <= t }
        band.tick(t)
        if band.root != last, let r = band.root { roots.append((t, r)); last = r } else if band.root == nil { last = nil }
        if let c = a.chords.last(where: { $0.start <= t }), t < c.end {
            let tones = Set(c.tones.map { (c.root + $0) % 12 })
            let pcs = band.padClasses
            held += pcs.count; inChord += pcs.filter { tones.contains($0) }.count
            steps += 1; if pcs.count >= 3 { full += 1 }
        }
        t += 0.025
    }
    let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    print("live band chord changes: \(roots.count); the careful analysis found \(a.chords.count) chords")
    // How often the live band is on the same root as the analysis, and how late it gets there.
    var agree = 0.0, total = 0.0
    var lag: [Double] = []
    for c in a.chords {
        var x = c.start
        while x < c.end {
            let r = roots.last { $0.0 <= x + 0.001 }?.1
            if r == c.root { agree += 0.1 }
            total += 0.1
            x += 0.1
        }
        if let hit = roots.first(where: { $0.1 == c.root && $0.0 >= c.start - 0.3 && $0.0 < c.end }) { lag.append(max(0, hit.0 - c.start)) }
    }
    print(String(format: "same root as the analysis %.0f%% of the time; typical time to reach a new chord %.2f s", 100 * agree / max(0.1, total), lag.sorted()[safe: lag.count / 2] ?? 0))
    print(String(format: "string notes that belong to the chord the analysis hears: %.0f%%; strings holding a full three-note chord %.0f%% of the time", 100 * Double(inChord) / Double(max(1, held)), 100 * Double(full) / Double(max(1, steps))))
    let ons = sent.filter { $0.1[0] & 0xF0 == 0x90 }
    for (ch, name) in [(1, "bass"), (2, "strings"), (3, "cello")] { print("\(name): \(ons.filter { Int($0.1[0] & 0x0F) == ch }.count) notes") }
    // Nothing may be left sounding once it has faded out.
    var open: [String: Int] = [:]
    for (_, b) in sent where b[0] & 0xE0 == 0x80 {
        let key = "\(b[0] & 0x0F)-\(b[1])"
        open[key, default: 0] += b[0] & 0xF0 == 0x90 ? 1 : -1
    }
    print("notes left sounding at the end: \(open.values.filter { $0 > 0 }.count)")
    print("first changes: " + roots.prefix(14).map { String(format: "%.1f %@", $0.0, names[$0.1]) }.joined(separator: " | "))
    print("analysis:      " + a.chords.prefix(14).map { String(format: "%.1f %@", $0.start, names[$0.root]) }.joined(separator: " | "))
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
