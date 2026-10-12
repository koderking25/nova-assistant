// Composition mode: listens to what is played, names the key and chords,
// plays it back as a band, makes variations, and saves ideas as MIDI files.

import Foundation

struct RNote {
    var t: Double; var end: Double; var pitch: Int; var vel: Int; var ch: Int = 0
    // 0 or more makes this a controller change instead of a note: `cc` is the controller number
    // (11 is expression, how hard the strings are bowed) and `vel` its value. Used for swells.
    var cc: Int = -1
}
struct Chord { var start: Double; var end: Double; var root: Int; var quality: String; var tones: [Int] }

let chordShapes: [(String, [Int])] = [
    ("major", [0, 4, 7]), ("minor", [0, 3, 7]), ("diminished", [0, 3, 6]), ("augmented", [0, 4, 8]),
    ("seventh", [0, 4, 7, 10]), ("major seventh", [0, 4, 7, 11]), ("minor seventh", [0, 3, 7, 10]),
    ("sus four", [0, 5, 7]), ("sus two", [0, 2, 7]),
]

struct Analysis {
    var tonic = 0
    var minor = false
    var beat: Double? = nil
    var chords: [Chord] = []
    var length = 0.0

    var names: [String] {
        let flatKeys: Set<Int> = minor ? [2, 7, 0, 5, 10] : [5, 10, 3, 8, 1]
        return flatKeys.contains(tonic) ? flatNames : sharpNames
    }
    var keyName: String { "\(names[tonic]) \(minor ? "minor" : "major")" }
    func name(_ c: Chord) -> String { "\(names[c.root]) \(c.quality)" }

    // The shortest chord pattern that the whole piece repeats, if any.
    var loop: (length: Int, times: Int)? {
        let seq = chords.map { name($0) }
        guard seq.count >= 4 else { return nil }
        for p in 2...(seq.count / 2) where seq.indices.allSatisfy({ seq[$0] == seq[$0 % p] }) { return (p, seq.count / p) }
        return nil
    }

    func summary(noteCount: Int) -> String {
        var s = "Key of \(keyName). "
        if let b = beat { s += "About \(Int((60 / b / 2).rounded()) * 2) beats per minute. " }
        if chords.isEmpty {
            s += "I could not pick out chords. "
        } else if let l = loop {
            s += "Chords: " + chords.prefix(l.length).map { name($0) }.joined(separator: ", ") + ". That loop of \(l.length) chords plays \(l.times) times. "
        } else {
            s += "Chords: " + chords.prefix(12).map { name($0) }.joined(separator: ", ")
            s += chords.count > 12 ? ", and \(chords.count - 12) more. " : ". "
        }
        return s + "\(Int(length.rounded())) seconds, \(noteCount) notes."
    }
}

// Scores for all 24 keys: index is the tonic, plus 12 for minor.
func keyScores(_ notes: [RNote]) -> [Double] {
    let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    var h = [Double](repeating: 0, count: 12)
    for n in notes { h[n.pitch % 12] += min(n.end - n.t, 2.0) + 0.1 }
    func corr(_ profile: [Double], _ tonic: Int) -> Double {
        let hm = h.reduce(0, +) / 12, pm = profile.reduce(0, +) / 12
        var num = 0.0, dh = 0.0, dp = 0.0
        for i in 0..<12 {
            let a = h[(i + tonic) % 12] - hm, b = profile[i] - pm
            num += a * b; dh += a * a; dp += b * b
        }
        return dh > 0 ? num / (dh * dp).squareRoot() : 0
    }
    return (0..<12).map { corr(major, $0) } + (0..<12).map { corr(minor, $0) }
}

func detectBeat(_ notes: [RNote]) -> Double? { steadyBeat(notes) }

func detectBeatRaw(_ notes: [RNote]) -> Double? {
    var onsets: [Double] = []
    for t in notes.map({ $0.t }).sorted() where onsets.last == nil || t - onsets.last! > 0.06 { onsets.append(t) }
    let gaps = zip(onsets.dropFirst(), onsets).map { $0 - $1 }.filter { $0 > 0.08 && $0 < 3 }
    guard gaps.count >= 5 else { return nil }
    let multiples: [(Double, Double)] = [(1, 1), (0.5, 0.85), (2, 0.85), (0.25, 0.6), (1.5, 0.6), (3, 0.6), (4, 0.6)]
    var best = (0.0, 0.0)
    var b = 0.33
    while b <= 1.0 {
        var score = 0.0
        for g in gaps {
            let r = g / b
            score += multiples.map { m -> Double in
                let d = abs(r - m.0) / m.0
                return m.1 * exp(-(d * d) / (2 * 0.06 * 0.06))
            }.max() ?? 0
        }
        if score > best.1 { best = (b, score) }
        b += 0.005
    }
    guard best.1 / Double(gaps.count) > 0.5 else { return nil }
    return best.0
}

// The beat a listener would tap, or nil in free time. The raw detector often locks on to the
// fast notes between the beats (it once gave 176 a minute for a gentle piece, and the drums
// rattled along at double speed). So a fast answer is halved to the pulse underneath it, and
// the two halves of the piece must agree, or it does not count as a steady beat at all.
func steadyBeat(_ notes: [RNote]) -> Double? {
    guard var b = detectBeatRaw(notes) else { return nil }
    let sorted = notes.sorted { $0.t < $1.t }
    if sorted.count >= 24 {
        let first = detectBeatRaw(Array(sorted[..<(sorted.count / 2)])), second = detectBeatRaw(Array(sorted[(sorted.count / 2)...]))
        guard let x = first, let y = second else { return nil }
        let ratio = max(x, y) / min(x, y)
        let near = [1.0, 2.0, 1.5, 3.0].contains { abs(ratio - $0) / $0 < 0.08 }
        if !near { return nil }
    }
    while b < 0.5 { b *= 2 }      // never faster than 120 a minute
    return b
}

func analyse(_ notes: [RNote]) -> Analysis {
    var a = Analysis()
    a.length = notes.map { $0.end }.max() ?? 0
    let scores = keyScores(notes)
    let best = scores.indices.max { scores[$0] < scores[$1] } ?? 0
    (a.tonic, a.minor) = (best % 12, best >= 12)
    a.beat = detectBeat(notes)
    a.chords = detectChords(notes, beat: a.beat, length: a.length, tonic: a.tonic, minor: a.minor)
    // A major key and its relative minor share the same notes, so the note count alone
    // cannot always tell them apart. When it is close, the first chord decides.
    let other = a.minor ? (a.tonic + 3) % 12 : (a.tonic + 9) % 12 + 12
    if let first = a.chords.first, scores[other] > scores[best] - 0.15 {
        let firstMinor = first.quality.hasPrefix("minor") || first.quality == "diminished"
        if first.root == other % 12, firstMinor == (other >= 12), first.root != a.tonic {
            (a.tonic, a.minor) = (other % 12, other >= 12)
        }
    }
    return a
}

// 0 backwards, 1 upside down within the key, 2 major and minor swapped.
func variation(_ kind: Int, _ notes: [RNote], _ a: Analysis) -> [RNote] {
    switch kind {
    case 0:
        return notes.map { var n = $0; n.t = a.length - $0.end; n.end = a.length - $0.t; return n }
    case 1:
        let scale = a.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        func degree(_ p: Int) -> (Int, Int) {
            let rel = p - a.tonic
            let oct = Int(floor(Double(rel) / 12)), pc = ((rel % 12) + 12) % 12
            let i = scale.lastIndex { $0 <= pc } ?? 0
            return (oct * 7 + i, pc - scale[i])
        }
        let sorted = notes.map { $0.pitch }.sorted()
        let axis = degree(sorted[sorted.count / 2]).0
        return notes.map {
            var n = $0
            let (d, alt) = degree($0.pitch)
            let m = 2 * axis - d
            var p = a.tonic + 12 * Int(floor(Double(m) / 7)) + scale[((m % 7) + 7) % 7] - alt
            while p < 24 { p += 12 }
            while p > 100 { p -= 12 }
            n.pitch = p
            return n
        }
    default:
        let shift: [Int: Int] = a.minor ? [3: 1, 8: 1, 10: 1] : [4: -1, 9: -1, 11: -1]
        return notes.map { var n = $0; n.pitch += shift[(($0.pitch - a.tonic) % 12 + 12) % 12] ?? 0; return n }
    }
}

func events(_ notes: [RNote]) -> [Ev] {
    notes.flatMap { n -> [Ev] in
        let p = UInt8(max(0, min(127, n.pitch))), ch = UInt8(n.ch & 0x0F)
        if n.cc >= 0 { return [Ev(t: n.t, bytes: [0xB0 | ch, UInt8(n.cc & 0x7F), UInt8(max(0, min(127, n.vel)))])] }
        return [Ev(t: n.t, bytes: [0x90 | ch, p, UInt8(max(1, min(127, n.vel)))]),
                Ev(t: max(n.t + 0.05, n.end - 0.01), bytes: [0x80 | ch, p, 0])]
    }
}

// Writes a multi-track MIDI file. Dragging it into Logic makes one track per part.
func writeMIDIFile(_ url: URL, bpm: Double, tracks: [(name: String, notes: [RNote])]) -> Bool {
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    func varLen(_ v: Int) -> [UInt8] {
        var out = [UInt8(v & 0x7F)]
        var x = v >> 7
        while x > 0 { out.insert(UInt8(x & 0x7F) | 0x80, at: 0); x >>= 7 }
        return out
    }
    func chunk(_ body: [UInt8]) -> [UInt8] { [0x4D, 0x54, 0x72, 0x6B] + be32(body.count + 4) + body + [0x00, 0xFF, 0x2F, 0x00] }
    let ticksPerSecond = 480 * bpm / 60
    let tempo = Int(60_000_000 / bpm)
    var bytes: [UInt8] = [0x4D, 0x54, 0x68, 0x64] + be32(6) + [0, 1, 0, UInt8(tracks.count + 1), 0x01, 0xE0]
    bytes += chunk([0x00, 0xFF, 0x51, 0x03, UInt8(tempo >> 16 & 255), UInt8(tempo >> 8 & 255), UInt8(tempo & 255)])
    for track in tracks {
        let name = Array(track.name.utf8)
        var body: [UInt8] = [0x00, 0xFF, 0x03, UInt8(name.count)] + name
        var evs: [(Int, [UInt8])] = []
        for n in track.notes {
            let p = UInt8(max(0, min(127, n.pitch))), ch = UInt8(n.ch & 0x0F)
            let on = Int((n.t * ticksPerSecond).rounded())
            if n.cc >= 0 { evs.append((on, [0xB0 | ch, UInt8(n.cc & 0x7F), UInt8(max(0, min(127, n.vel)))])); continue }
            evs.append((on, [0x90 | ch, p, UInt8(max(1, min(127, n.vel)))]))
            evs.append((max(on + 10, Int((n.end * ticksPerSecond).rounded())), [0x80 | ch, p, 0]))
        }
        evs.sort { ($0.0, $0.1[0] & 0xF0) < ($1.0, $1.1[0] & 0xF0) }
        var last = 0
        for e in evs { body += varLen(e.0 - last) + e.1; last = e.0 }
        bytes += chunk(body)
    }
    return (try? Data(bytes).write(to: url)) != nil
}

// Drops stray notes at the very start of a take (a key brushed long before the playing
// begins), so playback does not open with a long silence.
func tidyTake(_ notes: [RNote]) -> [RNote] {
    var take = notes
    for _ in 0..<3 {
        guard take.count > 8 else { break }
        guard let cut = (1...min(4, take.count - 1)).first(where: { take[$0].t - take[$0 - 1].t > 6 }) else { break }
        let shift = take[cut].t
        take = take[cut...].map { var n = $0; n.t -= shift; n.end -= shift; return n }
    }
    return take
}

extension Engine {
    func record(_ pitch: Int, _ vel: Int, _ t: Double) {
        if vel > 0 {
            if let i = openIdx[pitch] { history[i].end = t; sustained.remove(i) }
            history.append(RNote(t: t, end: -1, pitch: pitch, vel: vel))
            openIdx[pitch] = history.count - 1
        } else if let i = openIdx[pitch] {
            openIdx[pitch] = nil
            if pedalDown { sustained.insert(i) } else { history[i].end = t }
        }
        if history.count > 50000, openIdx.isEmpty, sustained.isEmpty { history.removeFirst(25000) }
    }

    func pedal(_ down: Bool) {
        lock.lock(); defer { lock.unlock() }
        pedalDown = down
        if !down {
            let t = now()
            for i in sustained { history[i].end = t }
            sustained = []
        }
    }

    // Every key press and release from the piano arrives here.
    func noteEvent(_ pitch: Int, _ vel: Int) {
        lock.lock(); defer { lock.unlock() }
        // A key above the top key means the top key was set wrong, so learn it again.
        if vel > 0, !awaitingTop, pitch > keyHear { awaitingTop = true }
        if pitch == keyHear, !awaitingTop, !paused, mode == .compose {
            // In composition mode the top key always means "play it back", at once,
            // however long it is held. It can never open the song menu from here.
            if vel > 0 { noteOn(pitch) }
            return
        }
        if pitch == keyHear, !awaitingTop, !paused {
            // The top key acts when it is let go: a quick press does its usual job,
            // and holding it for most of a second opens the song menu.
            if vel > 0 {
                let t = now()
                topDownAt = t
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
                    self.lock.lock()
                    let held = self.topDownAt == t
                    if held { self.topDownAt = nil }
                    self.lock.unlock()
                    if held { self.openMenu() }
                }
            } else if topDownAt != nil {
                topDownAt = nil
                noteOn(pitch)
            }
            return
        }
        if commandKeys.contains(pitch) || awaitingTop {
            if vel > 0 { noteOn(pitch) }
            return
        }
        let t = now()
        do {
            // Playing is always recorded, even while a lesson is paused.
            // A button press ends a take. The next note starts a new one.
            if vel > 0, mode == .compose, takeClosed {
                if t < resumeUntil, !commandKeys.contains(pitch) {
                    // Playing again while the band is still sounding, or just after it, carries
                    // the same piece on. A button pressed by accident no longer ends it: the
                    // playback stops at once and the time spent listening is closed up.
                    lock.lock(); gen += 1; lock.unlock()
                    speaker.stop()
                    accGen += 1
                    midi.allOff()
                    let before = history.last { $0.t >= takeStart && $0.t < resumePressedAt }?.t ?? resumePressedAt
                    let shift = max(0, t - before - 1.2)
                    for i in history.indices where history[i].t >= takeStart && history[i].t < resumePressedAt {
                        history[i].t += shift
                        if history[i].end >= 0 { history[i].end += shift }
                    }
                    takeStart += shift
                    takeClosed = false; takeSaved = false
                    resumeUntil = 0
                } else if !commandKeys.contains(pitch) || t >= resumeUntil {
                    takeStart = t; takeClosed = false; variationIdx = 0; takeSaved = false
                    resumeUntil = 0
                }
            }
            record(pitch, vel, t)
            if vel > 0 { lastOnset = t }
            // The live band follows free playing and composing, never a lesson.
            if live.on, mode == .compose || mode == .idle { if vel > 0 { live.note(pitch, vel, at: t) } else { live.release(pitch) } }
            if roundOn || vel == 0 && roundHeld.contains(pitch) {
                let echo = UInt8(pitch + 12 <= 108 ? pitch + 12 : pitch)
                if vel > 0 { roundHeld.insert(pitch) } else { roundHeld.remove(pitch) }
                let bytes: [UInt8] = vel > 0 ? [0x90, echo, UInt8(min(127, vel))] : [0x80, echo, 0]
                let isOn = vel > 0
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + roundDelay) {
                    if !isOn || self.roundOn { self.midi.send(bytes) }   // stopping the round silences pending echoes
                }
            }
        }
        if vel > 0 { noteOn(pitch) }
    }

    func notes(since start: Double) -> [RNote] {
        let t = now()
        let raw = history.filter { $0.t >= start }
        guard let first = raw.first?.t else { return [] }
        return raw.map {
            var n = $0
            let end = $0.end < 0 ? t : $0.end
            n.end = min(end, $0.t + 30) - first
            n.t -= first
            return n
        }
    }

    // Asks for a name, typed on the computer and finished with Return.
    func startNaming(_ take: [RNote], alreadySaved: Bool) {
        naming = true
        typing = "name"
        nameBytes = []
        namingTake = alreadySaved ? [] : take
        if !Opt.fast {
            // Bring the Terminal window forward so typing lands in it.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Terminal"]
            try? p.run()
            print("\nName this piece, then press Return (Escape cancels): ", terminator: "")
        }
        run { g in self.say("Type a name, then press Return.", g) }
    }

    // One typed character while a name is being entered.
    func nameKey(_ c: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard naming else { return }   // typing only counts when something asked for it
        switch c {
        case 27:
            naming = false
            print("")
            run { g in self.say("No name given.", g) }
        case 10, 13:
            if typing == "reaper" {
                naming = false
                print("")
                finishReaperTyping(String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces))
            } else if typing == "ask" {
                naming = false
                print("")
                hear(String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces))
            } else {
                finishNaming()
            }
        case 8, 127:
            // Remove one whole character, which may be several bytes.
            while let last = nameBytes.popLast(), last & 0xC0 == 0x80 {}
            print("\u{8} \u{8}", terminator: "")
        default:
            if c >= 32 { nameBytes.append(c); FileHandle.standardOutput.write(Data([c])) }
        }
    }

    func finishNaming() {
        naming = false
        print("")
        var name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        for bad in ["/", ":", "\\", "\n"] { name = name.replacingOccurrences(of: bad, with: " ") }
        if name.hasPrefix(".") { name = String(name.drop { $0 == "." }) }
        let dir = baseDir.appendingPathComponent("ideas")
        var ok = false
        if !name.isEmpty, !Opt.fast, !CommandLine.arguments.contains("--reaper-test") {   // tests never touch real files
            var target = dir.appendingPathComponent(name + ".mid")
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) { target = dir.appendingPathComponent("\(name) \(n).mid"); n += 1 }
            if namingTake.isEmpty {
                // Already saved: give the newest file its new name.
                if let newest = newestIdea() { ok = (try? FileManager.default.moveItem(at: newest, to: target)) != nil }
            } else {
                ok = saveIdea(namingTake, analyse(namingTake), named: target.deletingPathExtension().lastPathComponent) != nil
                if ok { takeSaved = true }
            }
        }
        let said = name
        run { g in self.say(said.isEmpty ? "No name given." : (ok ? "Saved as \(said)." : "I could not save it."), g) }
    }

    func newestIdea() -> URL? {
        let dir = baseDir.appendingPathComponent("ideas")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "mid" }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.max { date($0) < date($1) }
    }

    func saveIdea(_ notes: [RNote], _ a: Analysis, named: String? = nil) -> String? {
        let dir = baseDir.appendingPathComponent("ideas")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = named ?? "idea \(f.string(from: Date())) \(a.keyName)"
        let band = bandFull(notes, a)
        let tracks: [(name: String, notes: [RNote])] = ([("Piano", notes)] + bandTracks(band)).filter { !$0.notes.isEmpty }
        let ok = writeMIDIFile(dir.appendingPathComponent(name + ".mid"), bpm: a.beat.map { 60 / $0 } ?? 120, tracks: tracks)
        if ok { rememberPiece(a) }
        return ok ? name : nil
    }

    // The piano part of the most recently saved file in the ideas folder.
    func lastSavedIdea() -> [RNote]? {
        let dir = baseDir.appendingPathComponent("ideas")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "mid" }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        guard let newest = files.max(by: { date($0) < date($1) }), let song = loadMIDIFile(newest, track: "piano") else { return nil }
        let spb = 60 / song.bpm
        return tidyTake(song.notes.map { RNote(t: $0.beat * spb, end: ($0.beat + $0.dur) * spb, pitch: $0.pitch, vel: $0.vel) }.sorted { $0.t < $1.t })
    }

    // Called whenever composition mode is left, so a piece is never lost by a wrong button.
    // "I messed up, again": throws the take away without saving it and listens afresh.
    // (The composition key keeps what you played as an autosave; this does not.)
    func restartTake() {
        lock.lock(); defer { lock.unlock() }
        guard mode == .compose else { return }
        waiting = false
        accGen += 1
        midi.allOff()
        takeStart = now(); takeClosed = true; takeSaved = true; variationIdx = 0
        resumeUntil = 0
        run { g in self.say(pick(["Again.", "From the top.", "Clean slate."]), g) }
    }

    // Live band on or off. While it is on, a bass, strings and cello follow the playing as it happens.
    func toggleLive() {
        lock.lock(); defer { lock.unlock() }
        live.on.toggle()
        ui("live \(live.on ? 1 : 0)")
        if live.on {
            live.out = { [weak self] bytes in self?.midi.send(bytes) }
            if liveTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
                timer.schedule(deadline: .now(), repeating: .milliseconds(25))
                timer.setEventHandler { [weak self] in self?.live.tick(now()) }
                timer.resume()
                liveTimer = timer
            }
            run { g in self.say("Live band on. Just play, and the band follows you.", g) }
        } else {
            live.silence()
            run { g in self.say("Live band off.", g) }
        }
    }

    // Commands sent by the app window as a line of text.
    func appCommand(_ text: String) {
        if text.hasPrefix("play ") { playFile(String(text.dropFirst(5))); return }
        let parts = text.split(separator: " ").map(String.init)
        // Every update of what the microphone is hearing: "ear 1 words" when the sentence is finished, "ear 0 words" while it is still going.
        if text.hasPrefix("ear ") {
            let rest = text.dropFirst(4)
            ears.partial(String(rest.dropFirst(2)), final: rest.hasPrefix("1"), engine: self)
            return
        }
        if text == "bg" { run { g in self.say(pick(["I'm still here, in the background. Just say my name.", "The window's closed, but I'm still listening. Just say \(Me.name)."]), g) }; return }
        if text.hasPrefix("login ") {
            let r = String(text.dropFirst(6))
            run { g in self.say(r == "on" ? "Done. I'll start by myself whenever you log in, out of sight, and listen for my name." : r == "off" ? "Okay. I won't start by myself any more." : "The Mac wouldn't let me set that. You can add Nova yourself under System Settings, General, Login Items.", g) }
            return
        }
        // The welcome screens: lines to say aloud, and at the end, the answers that were given.
        if text.hasPrefix("speak ") { let line = String(text.dropFirst(6)); run { g in self.say(line, g) }; return }
        if text.hasPrefix("setup ") {
            let f = text.dropFirst(6).components(separatedBy: "|")
            guard f.count >= 6 else { return }
            Profile.current.user = f[0].trimmingCharacters(in: .whitespaces)
            Profile.current.assistant = Profile.cleanName(f[1]) ?? "Nova"
            Profile.current.city = f[2].trimmingCharacters(in: .whitespaces)
            Profile.current.fahrenheit = f[3] == "F"
            Profile.current.about = f[4].trimmingCharacters(in: .whitespaces)
            Profile.current.plays = f[5] == "1"
            Profile.current.birthday = f.count > 6 && f[6].count == 5 ? f[6] : ""
            // The natural voice is the default. It is only left out if the welcome's switch was turned off.
            if f.count > 7, f[7] == "0" { try? "declined".write(to: VoiceInstaller.declineFile, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: VoiceInstaller.declineFile) }
            Profile.current.done = true
            Profile.save()
            Weather.latest = nil; Weather.refresh()
            ui("name \(Me.name)|\(You.name)")
            sendVocabulary()
            run { g in self.say("All set\(Profile.current.user.isEmpty ? "" : ", \(You.name)"). I'm \(Me.name). Whenever you need me, say \(Me.name), then what you'd like. Try: \(Me.name), what can you do?", g); self.fetchVoiceIfWanted(announce: true) }
            return
        }
        if text.hasPrefix("lvl ") { ears.level(Double(text.dropFirst(4)) ?? 0, engine: self); return }   // how loud the microphone is, several times a second
        if text.hasPrefix("say ") { hear(String(text.dropFirst(4))); return }   // spoken or typed to the assistant
        if text == "say" { hear(""); return }
        switch parts.first ?? "" {
        case "ear": startEar()
        case "hands": setHands(handsOnly == "both" ? "right" : handsOnly == "right" ? "left" : "both")
        case "metronome": if metroBPM > 0, parts.count > 1, parts[1] == "off" { metronome(nil) } else { metronome(metroBPM) }
        case "restart": restartTake()
        case "live": toggleLive()
        case "bandstyle": toggleBandStyle()
        case "drop": dropSong()
        case "jazz": if parts.count > 1, let n = Int(parts[1]), jazzLessons.indices.contains(n - 1) { startJazz(n - 1) }
        default: break
        }
    }

    func autosaveTake() {
        guard mode == .compose, !takeSaved, !Opt.fast else { return }
        let take = tidyTake(notes(since: takeStart))
        guard take.count >= 8 else { return }
        if saveIdea(take, analyse(take)) != nil { takeSaved = true; logLine("autosaved a composition of \(take.count) notes") }
    }

    // The last unbroken stretch of playing: everything back to the last silence of ten
    // seconds or more, up to fifteen minutes. Everything is always being recorded, so
    // there is no need to press record first.
    func lastStretch() -> [RNote] {
        let t = now()
        let recent = history.filter { $0.t >= t - 900 }
        guard var start = recent.last?.t else { return [] }
        var reach = start
        for n in recent.reversed() {
            if reach - max(n.t, min(n.end < 0 ? t : n.end, n.t + 30)) > 10, reach - n.t > 10 { break }
            start = n.t
            reach = n.t
        }
        return tidyTake(notes(since: start - 0.001))
    }

    // "Keep that": saves what was just played, from any mode, without stopping anything else.
    func keepLast() {
        lock.lock(); defer { lock.unlock() }
        var piece = mode == .compose ? tidyTake(notes(since: takeStart)) : []
        if piece.count < 3 { piece = lastStretch() }
        guard piece.count >= 3 else { run { g in self.say("Nothing to keep yet.", g); self.resumeAfterHelp(g) }; return }
        let a = analyse(piece)
        let name = saveIdea(piece, a)
        if name != nil, mode == .compose { takeSaved = true; takeClosed = true }
        let secs = Int(a.length.rounded())
        logLine("kept \(piece.count) notes, \(secs) seconds")
        run { g in
            self.say(name != nil ? pick(["Kept that one.", "Got it, saved.", "That one's saved."]) + " \(secs) seconds, in \(a.keyName)." : "I could not save the file.", g)
            self.resumeAfterHelp(g)
        }
    }

    // Returns true when the key was handled here.
    func composeCommand(_ key: Int) -> Bool {
        roundOn = false
        if key == keyCompose {
            // This key always means "I have an idea": from anywhere it stops whatever is
            // playing or talking and starts a clean composition. Pressed twice quickly
            // inside composition mode, it leaves the mode instead.
            let t = now()
            let double = mode == .compose && t - lastComposePress < 1.2 && !Opt.fast
            lastComposePress = t
            waiting = false
            accGen += 1
            midi.allOff()
            autosaveTake()
            resumeUntil = 0
            if double {
                mode = .idle
                run { g in self.say("Composition mode off.", g) }
            } else if mode == .compose {
                takeStart = t; takeClosed = true; takeSaved = true; variationIdx = 0
                run { g in self.say(pick(["New composition.", "Fresh start.", "New idea. Go."]), g) }
            } else {
                mode = .compose
                ui("now A new piece")
                takeStart = t; takeClosed = true; takeSaved = true; variationIdx = 0
                run { g in self.say(pick(["Composition mode.", "Composition. I'm listening.", "Composition. Play me something."]) + self.intro("compose", " Just play. Then the top key plays it back as a band. The next key down tells you what you wrote. The next plays a variation. The next saves it."), g) }
            }
            return true
        }
        if mode == .compose, key == keyTalk { learnIdea(); return true }
        guard mode == .compose, [keyHear, keyNotes, keyNext, keyBack].contains(key) else { return false }
        var take = tidyTake(notes(since: takeStart))
        takeClosed = true
        // With nothing new played, the buttons work on the piece that was saved last,
        // so a saved piece can be heard again without leaving the piano.
        var fromFile = false
        if take.count < 3, let saved = lastSavedIdea() { take = saved; fromFile = true }
        guard take.count >= 3 else { run { g in self.say("Play something first.", g) }; return true }
        let a = analyse(take)
        if fromFile, key == keyBack { run { g in self.say("That piece is already saved.", g) }; return true }
        let lead = fromFile ? "Your last saved piece. " : ""
        switch key {
        case keyHear:
            // Pressed twice quickly, the top key names the piece instead of playing it.
            let t = now()
            if t - lastTopPress < 0.6 || namingRequested {
                namingRequested = false
                lastTopPress = 0
                startNaming(take, alreadySaved: fromFile || takeSaved)
                return true
            }
            lastTopPress = t
            let ev = events(take + bandFull(take, a))
            if !fromFile { resumePressedAt = t; resumeUntil = t + (take.last?.end ?? 0) - (take.first?.t ?? 0) + 6 }
            live.silence()      // the written band and the live band never play over each other
            run { g in self.say(lead + pick(["Here it is with the band.", "With the band.", "Here comes the band."]), g); self.play(ev, g) }
        case keyNotes:
            // The facts first, then what is interesting about them.
            // Pressed twice quickly, the second key asks the AI what it thinks of the piece.
            let t = now()
            if t - lastNotesPress < 0.7, !lastSummary.isEmpty, !Opt.fast {
                lastNotesPress = 0
                aiThoughts(lastSummary)
                return true
            }
            lastNotesPress = t
            let text = a.summary(noteCount: take.count) + " " + insights(a, earlier: fromFile ? Array(mem.pieces.dropLast()) : mem.pieces).joined(separator: " ")
            lastSummary = text
            if !fromFile { resumePressedAt = t; resumeUntil = t + 25 }
            run { g in self.say(text, g) }
        case keyNext:
            let kind = variationIdx % 4
            variationIdx += 1
            if kind == 3 {
                roundDelay = max(2, min(8, (a.beat ?? 0.5) * 8))
                roundOn = true
                let secs = Int(roundDelay.rounded())
                run { g in self.say("Round. Play it again, and I will follow \(secs) seconds behind you, one octave up. Any button key stops it.", g) }
            } else {
                let ev = events(variation(kind, take, a))
                let label = ["Backwards.", "Upside down.", a.minor ? "In major." : "In minor."][kind]
                if !fromFile { resumePressedAt = now(); resumeUntil = now() + (take.last?.end ?? 0) - (take.first?.t ?? 0) + 6 }
                run { g in self.say(label, g); self.play(ev, g) }
            }
        default:
            let name = saveIdea(take, a)
            if name != nil { takeSaved = true }
            run { g in self.say(name != nil ? "Saved in the ideas folder, in \(a.keyName). Drag it into Logic for piano, bass, strings, cello and drum tracks." : "I could not save the file.", g) }
        }
        return true
    }
}

// Self-test for this file: a two-hand loop of C, A minor, F, G at 100 beats per minute, twice.
func composeSelfTest(_ check: (String, Bool, String) -> Void) {
    let beat = 0.6
    var notes: [RNote] = []
    let bars: [(Int, [Int])] = [(48, [64, 67, 72, 67]), (45, [64, 69, 72, 69]), (53, [65, 69, 72, 69]), (55, [67, 71, 74, 71])]
    for rep in 0..<2 {
        for (i, bar) in bars.enumerated() {
            let t = Double(rep * 4 + i) * beat * 4
            notes.append(RNote(t: t, end: t + beat * 4 - 0.05, pitch: bar.0, vel: 80))
            for (k, p) in bar.1.enumerated() { notes.append(RNote(t: t + Double(k) * beat, end: t + Double(k + 1) * beat - 0.05, pitch: p, vel: 80)) }
        }
    }
    notes.sort { $0.t < $1.t }
    let a = analyse(notes)
    check("composition: key", a.keyName == "C major", a.keyName)
    check("composition: tempo", a.beat.map { abs($0 - beat) < 0.03 } ?? false, a.beat.map { String(format: "beat %.2f s", $0) } ?? "none")
    let names = a.chords.map { a.name($0) }
    check("composition: chords", names == ["C major", "A minor", "F major", "G major", "C major", "A minor", "F major", "G major"], names.joined(separator: ", "))
    check("composition: loop found", a.loop?.length == 4 && a.loop?.times == 2, a.summary(noteCount: notes.count))
    let band = bandParts(notes, a)
    check("composition: band has bass, strings, cello and drums", Set(band.map { $0.ch }).isSuperset(of: [1, 2, 3, 9]), "\(band.count) notes")
    let bass = band.filter { $0.ch == 1 }.sorted { $0.t < $1.t }
    check("composition: bass starts each chord on its root", a.chords.allSatisfy { ch in bass.first { abs($0.t - ch.start) < 0.01 }.map { $0.pitch % 12 == ch.root } ?? false },
          bass.prefix(6).map { sharpNames[$0.pitch % 12] }.joined(separator: " "))
    check("composition: no band note is stuck or out of range", band.allSatisfy { $0.end > $0.t && (24...100).contains($0.pitch) && $0.end <= a.length + 0.2 }, "\(band.filter { $0.ch == 9 }.count) drum hits")
    let vars = (0..<3).map { variation($0, notes, a) }
    check("composition: variations keep every note in range", vars.allSatisfy { v in v.count == notes.count && v.allSatisfy { (21...108).contains($0.pitch) && $0.end > $0.t } },
          "upside down starts on \(vars[1][0].pitch), minor version changes \(zip(vars[2], notes).filter { $0.pitch != $1.pitch }.count) notes")
    // The same loop played like a person: uneven timing, overlapping notes, slowing down.
    var rng = SystemRandomNumberGenerator()
    var human = notes.map { n -> RNote in
        var m = n
        let stretch = 1 + n.t / 60
        m.t = max(0, n.t * stretch + Double.random(in: -0.035...0.035, using: &rng))
        m.end = n.end * stretch + Double.random(in: 0...0.15, using: &rng)
        return m
    }
    human.sort { $0.t < $1.t }
    let h = analyse(human)
    check("composition: uneven human timing still gives the right chords", h.chords.map { h.name($0) } == names && h.keyName == "C major", h.keyName + ": " + h.chords.map { h.name($0) }.joined(separator: ", "))
    // Hundreds of random takes, including silly ones: nothing may crash or produce a broken note.
    var sound = true
    for trial in 0..<400 {
        let count = [1, 2, 3, 5, 12, 40, 120][trial % 7]
        var t = 0.0
        var take: [RNote] = []
        for _ in 0..<count {
            t += [0, 0, 0.01, 0.2, 0.5, 1.3, 6][Int.random(in: 0..<7, using: &rng)]
            let len = [0.02, 0.3, 1, 8][Int.random(in: 0..<4, using: &rng)]
            take.append(RNote(t: t, end: t + len, pitch: Int.random(in: 21...107, using: &rng), vel: Int.random(in: 1...127, using: &rng)))
        }
        let an = analyse(take)
        let parts = bandParts(take, an)
        let all = parts + (0..<3).flatMap { variation($0, take, an) }
        if !all.allSatisfy({ (0...127).contains($0.pitch) && $0.end > $0.t - 0.001 && $0.t > -0.001 && $0.t.isFinite && $0.end.isFinite }) { sound = false }
        _ = an.summary(noteCount: take.count)
        _ = events(all)
    }
    check("composition: 400 random takes, no crash and no broken notes", sound, "")
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talking-piano-test-\(getpid()).mid")
    let wrote = writeMIDIFile(url, bpm: 100, tracks: [("Piano", notes), ("Bass", band.filter { $0.ch == 1 })])
    let back = loadMIDIFile(url)
    try? FileManager.default.removeItem(at: url)
    check("composition: saved file reads back", wrote && back?.notes.count == notes.count + band.filter { $0.ch == 1 }.count, "\(back?.notes.count ?? 0) notes")
}
