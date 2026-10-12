// The band as it was in its first days (9 October): bass, strings, cello, and drums when there
// is a steady beat. Every note it plays starts on a moment the player played. the player called this
// one perfect, so it is kept here exactly as it was written then, and it is the default.
// The later, larger band ("full": high strings, horn, pad, swells) is still there to switch to.

import Foundation

// Writes the band: bass on channel 2, strings on 3, cello on 4, drums on 10.
//
// The band accompanies the way a person would. Every note it plays starts on a moment the
// player actually played, so it breathes with free timing instead of cutting chords into
// equal slices. It plays louder and softer with the player, holds notes that two chords
// share, and only brings in drums when the playing has a steady beat.
func classicBandParts(_ notes: [RNote], _ a: Analysis) -> [RNote] {
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
            if let s = split {
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
        let voicing = pcs.compactMap { pc in (53...74).filter { $0 % 12 == pc }.min { abs($0 - padCentre) < abs($1 - padCentre) } }
        if !voicing.isEmpty { padCentre = voicing.reduce(0, +) / voicing.count }
        let padEnd = c.end + (last ? 0.1 : 0.22)
        var stillOpen: [Int: Int] = [:]
        for p in voicing {
            if let idx = padOpen[p] {
                out[idx].end = padEnd
                stillOpen[p] = idx
            } else {
                out.append(RNote(t: c.start + (i == 0 ? 0 : 0.03), end: padEnd, pitch: p, vel: vel(44, c.start, vary: 3), ch: 2))
                stillOpen[p] = out.count - 1
            }
        }
        padOpen = stillOpen

        // Cello: a slow singing line on the notes that give the chord its colour, kept under
        // the melody. On a longer chord it moves once, on a moment the player played.
        let all = c.tones.map { (c.root + $0) % 12 }
        let guides = c.tones.count == 4 ? [all[1], all[3]] : [all[1], all[2]]
        func nearest(_ wanted: [Int], to p: Int, under cap: Int?) -> Int {
            let range = (45...67).filter { wanted.contains($0 % 12) && (cap == nil || $0 < cap! - 2) }
            return range.min { abs($0 - p) < abs($1 - p) } ?? (45...67).filter { wanted.contains($0 % 12) }.min { abs($0 - p) < abs($1 - p) } ?? p
        }
        let first = nearest(guides, to: cello, under: melody(at: c.start))
        let move = d > 1.8 ? onsets.filter { $0 > c.start + d * 0.4 && $0 < c.start + d * 0.75 }.min { abs($0 - c.start - d * 0.55) < abs($1 - c.start - d * 0.55) } : nil
        let overlap = last ? 0.0 : 0.06
        if let m = move {
            let second = nearest(all.filter { $0 != first % 12 }, to: first, under: melody(at: m))
            out.append(RNote(t: c.start, end: m + 0.06, pitch: first, vel: vel(58, c.start), ch: 3))
            out.append(RNote(t: m, end: c.end + overlap, pitch: second, vel: vel(50, m), ch: 3))
            cello = second
        } else {
            out.append(RNote(t: c.start, end: c.end + overlap, pitch: first, vel: vel(56, c.start), ch: 3))
            cello = first
        }

        // Drums: only with a steady beat, and played lightly, following the player's loudness.
        if steady, n >= 2 {
            let len = d / Double(n)
            let soft = len > 0.6 || loud(c.start) < 0.9
            func hit(_ t: Double, _ drum: Int, _ v: Double) {
                let at = max(0, t + (t == c.start ? 0 : wobble(0.008)))
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
    return out
}
