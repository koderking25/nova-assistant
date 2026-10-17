// The band, rebuilt (October 16) from everything the earlier versions taught.
//
// Measured over 52 of the player's own pieces ("--band-lab"):
//  - The early band (7 to 9 October) was smooth and full: bass, strings and cello never fell
//    silent while the piano played. But its sustained notes often rubbed a semitone against the
//    piano (about half a minute of every minute), and it struck shared notes again at every chord.
//  - Every later version fixed the rubbing by cutting notes out, and that is what made it choppy:
//    parts dropping out mid phrase several times a piece.
// So this one keeps the early band whole and fixes the rubbing note by note instead: a note that
// would rub is moved, for just that stretch, to the nearest pitch that fits (often the player's own
// note, doubled underneath), so nothing ever goes silent. Notes two chords share are held, not struck
// again. And the band leans with the player's own loudness.

import Foundation

func bandBest(_ notes: [RNote], _ a: Analysis) -> [RNote] {
    let base = bandEarly(notes, a)
    let piano = notes
    func rubs(_ pitch: Int, _ from: Double, _ to: Double) -> [(Double, Double, Int)] {
        piano.compactMap { p in
            let d = ((p.pitch - pitch) % 12 + 12) % 12
            guard d == 1 || d == 11 else { return nil }
            let s = max(from, p.t), e = min(to, p.end)
            return e - s >= 0.2 ? (s, e, p.pitch) : nil
        }
    }
    func fits(_ pitch: Int, _ from: Double, _ to: Double) -> Bool { rubs(pitch, from, to).isEmpty }
    // How loudly the player is playing around a moment, as a gentle factor.
    func loud(_ t: Double) -> Double {
        let near = piano.filter { abs($0.t - t) < 2.5 }
        guard !near.isEmpty else { return 0.85 }
        return max(0.7, min(1.2, Double(near.reduce(0) { $0 + $1.vel }) / Double(near.count) / 70))
    }
    let ranges: [Int: ClosedRange<Int>] = [1: 28...52, 2: 52...79, 3: 43...69]

    var out: [RNote] = []
    for n in base {
        guard n.cc < 0, n.ch != 9, let range = ranges[n.ch] else { out.append(n); continue }
        // Where along this note it would rub, merged into stretches.
        var spans = rubs(n.pitch, n.t, n.end).map { ($0.0, $0.1) }.sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for s in spans { if let l = merged.last, s.0 <= l.1 + 0.05 { merged[merged.count - 1].1 = max(l.1, s.1) } else { merged.append(s) } }
        spans = merged
        // Cut the note at the edges of those stretches, and give each rubbing piece a pitch that fits.
        var cuts = [n.t]
        for s in spans { cuts += [s.0, s.1] }
        cuts.append(n.end)
        cuts = cuts.sorted().reduce(into: [Double]()) { if $0.last == nil || $1 - $0.last! > 0.15 { $0.append($1) } }
        if cuts.last! < n.end - 0.01 { cuts[cuts.count - 1] = n.end }
        var pieces: [RNote] = []
        for k in 0..<(cuts.count - 1) {
            var piece = n
            piece.t = cuts[k]; piece.end = cuts[k + 1]
            if !fits(piece.pitch, piece.t, piece.end) {
                // The player's own rubbing note, in this part's register, first; then the nearest pitch that fits.
                let theirs = rubs(piece.pitch, piece.t, piece.end).map { $0.2 }
                let doubled = theirs.compactMap { p in range.filter { $0 % 12 == p % 12 }.min { abs($0 - piece.pitch) < abs($1 - piece.pitch) } }
                let near = (1...5).flatMap { [piece.pitch - $0, piece.pitch + $0] }.filter { range.contains($0) }
                if let p = (doubled + near).first(where: { fits($0, piece.t, piece.end) }) { piece.pitch = p }
            }
            pieces.append(piece)
        }
        // A fragment too short to sound like a note of its own is folded into its neighbour, so a line
        // never stutters: a brief rub passes far less noticeably than a note chopped in two.
        var k = 0
        while pieces.count > 1, k < pieces.count {
            if pieces[k].end - pieces[k].t < 0.35 {
                if k > 0 { pieces[k - 1].end = pieces[k].end } else { pieces[1].t = pieces[0].t }
                pieces.remove(at: k)
                k = max(0, k - 1)
            } else { k += 1 }
        }
        for var piece in pieces {
            piece.vel = max(20, min(118, Int(Double(piece.vel) * loud(piece.t))))
            out.append(piece)
        }
    }
    // Notes the same part plays twice in a row on the same pitch are held as one, not struck again.
    var joined: [RNote] = []
    for n in out.sorted(by: { ($0.ch, $0.pitch, $0.t) < ($1.ch, $1.pitch, $1.t) }) {
        if n.cc < 0, n.ch != 9, let last = joined.last, last.cc < 0, last.ch == n.ch, last.pitch == n.pitch, n.t - last.end < 0.15, n.t >= last.t {
            joined[joined.count - 1].end = max(last.end, n.end)
            continue
        }
        joined.append(n)
    }
    return joined.sorted { $0.t < $1.t }
}
