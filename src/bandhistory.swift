// Earlier versions of the band, kept word for word so they can be compared with the current one
// ("--band-lab"). Taken from the code as it was written on 7 October (first) and 7 to 9 October (the one called perfect).

import Foundation

func bandFirst(_ notes: [RNote], _ a: Analysis) -> [RNote] {
    var out: [RNote] = []
    func melody(at t: Double) -> Int? {
        notes.filter { $0.t <= t + 0.03 && $0.end > t && $0.pitch >= 60 }.map { $0.pitch }.max()
    }
    var prevCounter = 64
    var prevMelody: Int? = nil
    for c in a.chords {
        let dur = c.end - c.start
        var bass = 36 + c.root
        if bass > 43 { bass -= 12 }
        if let b = a.beat, dur >= b * 3.5 {
            out.append(RNote(t: c.start, end: c.start + dur / 2, pitch: bass, vel: 88, ch: 1))
            out.append(RNote(t: c.start + dur / 2, end: c.end, pitch: bass + 7, vel: 78, ch: 1))
        } else {
            out.append(RNote(t: c.start, end: c.end, pitch: bass, vel: 88, ch: 1))
        }
        for tone in c.tones {
            let p = 57 + (c.root + tone - 57 % 12 + 24) % 12
            out.append(RNote(t: c.start, end: c.end, pitch: p, vel: 58, ch: 2))
        }
        let pcs = Set(c.tones.map { (c.root + $0) % 12 })
        let step = max(0.25, a.beat ?? dur / 2)
        var t = c.start
        var count = 0
        while t < c.end - 0.05, count < 16 {
            let mel = melody(at: t)
            var dir = 0
            if let m = mel, let p = prevMelody { dir = m > p ? -1 : (m < p ? 1 : 0) }
            var cands = (55...79).filter { p in pcs.contains(p % 12) && (mel == nil || p < mel! - 2) }
            if cands.isEmpty { cands = (55...79).filter { pcs.contains($0 % 12) } }
            let target = prevCounter + dir * 3
            func cost(_ p: Int) -> Int { abs(p - target) + (p == prevCounter && dir != 0 ? 4 : 0) }
            if let pick = cands.min(by: { cost($0) < cost($1) }) {
                out.append(RNote(t: t, end: min(t + step, c.end), pitch: pick, vel: 64, ch: 3))
                prevCounter = pick
            }
            prevMelody = mel ?? prevMelody
            t += step
            count += 1
        }
    }
    return out
}

// 0 backwards, 1 upside down within the key, 2 major and minor swapped.
func bandEarly(_ notes: [RNote], _ a: Analysis) -> [RNote] {
    guard !a.chords.isEmpty else { return [] }
    var out: [RNote] = []
    let scale = (a.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { ($0 + a.tonic) % 12 }
    func inScale(_ p: Int) -> Bool { scale.contains(((p % 12) + 12) % 12) }
    func bassPitch(_ root: Int) -> Int { 28 + ((root - 28) % 12 + 12) % 12 }   // E1 up to D sharp 2
    func melody(at t: Double) -> Int? {
        notes.filter { $0.t <= t + 0.03 && $0.end > t && $0.pitch >= 60 }.map { $0.pitch }.max()
    }
    let counts = a.chords.map { c -> Int in
        let d = c.end - c.start
        if let b = a.beat { return max(1, min(16, Int((d / b).rounded()))) }
        return d > 1.4 ? 2 : 1
    }
    let longer = counts.filter { $0 >= 3 }
    let triple = !longer.isEmpty && longer.filter { $0 % 3 == 0 && $0 % 4 != 0 }.count * 2 > longer.count
    let group = triple ? 3 : 4
    var padCentre = 64
    var cello = 57

    for (i, c) in a.chords.enumerated() {
        let n = counts[i]
        let len = (c.end - c.start) / Double(n)
        func at(_ k: Double) -> Double { c.start + k * len }
        let root = bassPitch(c.root)
        let next = i + 1 < a.chords.count ? a.chords[i + 1] : nil

        // Bass: root on the strong beats, fifth in between, and a step into the next chord.
        var hits: [(k: Int, pitch: Int, beats: Int, vel: Int)] = []
        var k = 0
        while k < n {
            hits.append((k, root, min(2, n - k), 96))
            if group == 4, k + 2 < n {
                hits.append((k + 2, root + 7 > 43 ? root - 5 : root + 7, min(2, n - k - 2), 82))
            }
            k += group
        }
        if n >= 2, let nx = next, nx.root != c.root {
            let target = bassPitch(nx.root)
            var approach = target - 1
            while !inScale(approach), approach > target - 3 { approach -= 1 }
            if approach % 12 == root % 12 {
                approach = target + 1
                while !inScale(approach), approach < target + 3 { approach += 1 }
            }
            hits = hits.filter { $0.k < n - 1 }.map { h in
                var h = h
                h.beats = min(h.beats, n - 1 - h.k)
                return h
            }
            hits.append((n - 1, approach, 1, 74))
        }
        for h in hits {
            out.append(RNote(t: at(Double(h.k)), end: at(Double(h.k + h.beats)) - 0.02, pitch: h.pitch, vel: h.vel, ch: 1))
        }

        // Strings: a soft pad that moves as little as possible from chord to chord.
        var pcs = c.tones.map { (c.root + $0) % 12 }
        if pcs.count == 4 { pcs.removeFirst() }
        let voicing = pcs.compactMap { pc in (55...76).filter { $0 % 12 == pc }.min { abs($0 - padCentre) < abs($1 - padCentre) } }
        if !voicing.isEmpty { padCentre = voicing.reduce(0, +) / voicing.count }
        for p in voicing { out.append(RNote(t: c.start, end: c.end + 0.04, pitch: p, vel: 54, ch: 2)) }

        // Cello: a slow line on the notes that define the chord, kept under the melody.
        let all = c.tones.map { (c.root + $0) % 12 }
        let guides = c.tones.count == 4 ? [all[1], all[3]] : [all[1]]
        func nearest(_ wanted: [Int], to p: Int, under cap: Int?) -> Int {
            let range = (45...67).filter { wanted.contains($0 % 12) && (cap == nil || $0 < cap! - 2) }
            return range.min { abs($0 - p) < abs($1 - p) } ?? (45...67).filter { wanted.contains($0 % 12) }.min { abs($0 - p) < abs($1 - p) } ?? p
        }
        let first = nearest(guides, to: cello, under: melody(at: c.start))
        if n >= 2 {
            let half = Double((n + 1) / 2)
            let second = nearest(all.filter { $0 != first % 12 }, to: first, under: melody(at: at(half)))
            out.append(RNote(t: c.start, end: at(half), pitch: first, vel: 68, ch: 3))
            out.append(RNote(t: at(half), end: c.end, pitch: second, vel: 60, ch: 3))
            cello = second
        } else {
            out.append(RNote(t: c.start, end: c.end, pitch: first, vel: 64, ch: 3))
            cello = first
        }

        // Drums: only when there is a steady beat to follow.
        if a.beat != nil, n >= 2 {
            let gentle = len > 0.85
            func hit(_ t: Double, _ drum: Int, _ vel: Int) { out.append(RNote(t: t, end: t + 0.1, pitch: drum, vel: vel, ch: 9)) }
            for b in 0..<n {
                let t = at(Double(b)), pos = b % group
                if group == 4 {
                    if pos == 0 { hit(t, 36, 92) } else if pos == 2 { hit(t, 36, 74) }
                    if pos == 1 || pos == 3 { hit(t, gentle ? 37 : 38, gentle ? 62 : 78) }
                } else {
                    if pos == 0 { hit(t, 36, 90) } else { hit(t, 37, 54) }
                }
                hit(t, 42, 50)
                if len > 0.4 { hit(t + len / 2, 42, 34) }
            }
            if i == 0 { hit(c.start, 49, 58) }
        }
    }
    return out
}
