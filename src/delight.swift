// Things that are not lessons and not tools: the assistant makes music itself.
//
//  - "Play me something sad": it composes a short original piece in that mood, on the spot,
//    in one of the player's own favourite keys, and performs it with the band.
//  - "Make it a lullaby / 8-bit / epic / electric": the player's latest piece, re-imagined.
//  - "Play my album": every piece the player has saved, back to back, introduced like a concert.
//  - "Jam with me": the player plays a phrase, the assistant answers with a variation of it.
//  - "Play Clair de Lune": it performs a whole piece from the library.
//  - "Surprise me": one of the above, or a music joke, or the piano saying the player's name.

import Foundation

struct Mood {
    let name: String
    let minor: Bool
    let chords: [(step: Int, minor: Bool)]   // steps above the key note
    let seconds: Double                      // per chord
    let busy: Double                         // how often the melody moves, 0 to 1
    let words: [String]                      // what the player might say
}

let moods: [Mood] = [
    Mood(name: "sad", minor: true, chords: [(0, true), (8, false), (3, false), (10, false), (0, true), (8, false), (5, true), (7, false)], seconds: 2.6, busy: 0.5,
         words: ["sad", "melancholy", "melancholic", "blue", "rainy", "lonely", "heartbroken", "emotional", "cry"]),
    Mood(name: "happy", minor: false, chords: [(0, false), (7, false), (9, true), (5, false), (0, false), (7, false), (5, false), (7, false)], seconds: 1.7, busy: 0.8,
         words: ["happy", "joyful", "bright", "cheerful", "upbeat", "sunny", "fun"]),
    Mood(name: "calm", minor: false, chords: [(0, false), (5, false), (0, false), (7, false), (9, true), (5, false), (0, false), (7, false)], seconds: 3.0, busy: 0.35,
         words: ["calm", "peaceful", "relaxing", "relax", "gentle", "soft", "quiet", "sleep", "sleepy", "soothing", "chill"]),
    Mood(name: "epic", minor: true, chords: [(0, true), (10, false), (8, false), (7, false), (0, true), (10, false), (8, false), (7, false)], seconds: 2.0, busy: 0.7,
         words: ["epic", "dramatic", "powerful", "heroic", "intense", "cinematic", "movie", "battle", "big"]),
    Mood(name: "dreamy", minor: false, chords: [(0, false), (2, false), (0, false), (2, false), (9, true), (2, false), (5, false), (0, false)], seconds: 2.8, busy: 0.45,
         words: ["dreamy", "dream", "magical", "mysterious", "floating", "space", "wonder", "starry", "night"]),
    Mood(name: "hopeful", minor: true, chords: [(0, true), (5, false), (0, true), (5, false), (8, false), (10, false), (0, true), (5, false)], seconds: 2.3, busy: 0.6,
         words: ["hopeful", "hope", "bittersweet", "nostalgic", "nostalgia", "warm", "beautiful", "pretty", "lovely"]),
]

let musicJokes = [
    "Why did the pianist keep banging his head against the keys? He was playing by ear.",
    "What do you get when you drop a piano down a mine shaft? A flat minor.",
    "Why couldn't the string quartet find their composer? He was Haydn.",
    "What is Beethoven's favourite fruit? Ba na na na.",
    "Why was the piano locked out of its house? It lost its keys. All eighty eight of them.",
    "What kind of music are balloons afraid of? Pop.",
    "Middle C, E flat and G walk into a bar. The barman says, sorry, no minors.",
    "How do you fix a broken tuba? With a tuba glue.",
]

extension Engine {
    func mood(in h: Heard) -> Mood? {
        moods.first { m in m.words.contains { h.words.contains($0) } } ?? moods.first { m in (moodWords[m.name] ?? []).contains { h.words.contains($0) } }
    }

    /// An original piece in a mood: broken chords in the left hand, a singing line in the right.
    func invent(_ mood: Mood) -> (notes: [RNote], key: String) {
        // One of the player's own keys if they have a favourite of the right kind.
        var tonic = mood.minor ? 9 : 0
        let wanted = mood.minor ? "minor" : "major"
        var counts: [String: Int] = [:]
        for p in mem.pieces where p.key.hasSuffix(wanted) { counts[p.key, default: 0] += 1 }
        if let best = counts.max(by: { $0.value < $1.value })?.key, let name = best.components(separatedBy: " " + wanted).first,
           let pc = (flatNames.firstIndex(of: name) ?? sharpNames.firstIndex(of: name)) { tonic = pc }
        let scale = (mood.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { ($0 + tonic) % 12 }
        var notes: [RNote] = []
        var t = 0.0
        var melody = 72 + (tonic > 6 ? tonic - 12 : tonic)       // around the C above middle C
        let all = mood.chords + [(mood.chords[0].step, mood.chords[0].minor)]
        for (i, c) in all.enumerated() {
            let last = i == all.count - 1
            // Slowing into the end, the way a person does.
            let d = mood.seconds * (last ? 1.9 : (i == all.count - 2 ? 1.18 : 1)) * Double.random(in: 0.97...1.03)
            let root = (tonic + c.step) % 12
            let tones = [root, (root + (c.minor ? 3 : 4)) % 12, (root + 7) % 12]
            var low = 36 + root; if low > 46 { low -= 12 }
            let swell = 0.75 + 0.35 * sin(Double.pi * Double(i) / Double(all.count - 1))    // rises to the middle, falls away
            func v(_ base: Double) -> Int { max(20, min(110, Int(base * swell + Double.random(in: -4...4)))) }
            // Left hand: root, fifth, then the third an octave up, all left ringing.
            let pattern = last ? [low, low + 7, low + 12, low + 12 + (c.minor ? 3 : 4)] : [low, low + 7, low + 12 + (c.minor ? 3 : 4), low + 7]
            for (k, p) in pattern.enumerated() {
                let at = t + (last ? Double(k) * 0.07 : d * Double(k) / 4) + Double.random(in: -0.012...0.012)
                notes.append(RNote(t: max(0, at), end: t + d + 0.1, pitch: p, vel: v(k == 0 ? 66 : 54)))
            }
            // Right hand: a chord note on the beat, steps of the scale in between.
            func nearestTone(to p: Int) -> Int { (p - 7...p + 7).filter { tones.contains($0 % 12) && $0 >= 64 && $0 <= 88 }.min { abs($0 - p) < abs($1 - p) } ?? p }
            func step(_ p: Int, _ dir: Int) -> Int { var q = p + dir; while !scale.contains(((q % 12) + 12) % 12) { q += dir }; return q }
            if last {
                let home = nearestTone(to: melody)
                notes.append(RNote(t: t + 0.3, end: t + d, pitch: (home - 3...home + 4).first { $0 % 12 == root } ?? home, vel: v(72)))
            } else {
                var slots: [(Double, Int)] = []
                melody = nearestTone(to: melody + Int.random(in: -2...3))
                slots.append((0, melody))
                var dir = Bool.random() ? 1 : -1
                for k in 1..<4 where Double.random(in: 0...1) < mood.busy {
                    if melody > 84 { dir = -1 } else if melody < 67 { dir = 1 }
                    melody = step(melody, dir)
                    slots.append((Double(k) / 4, melody))
                }
                for (k, s) in slots.enumerated() {
                    let at = t + d * s.0 + Double.random(in: -0.015...0.015)
                    let until = k + 1 < slots.count ? t + d * slots[k + 1].0 : t + d
                    notes.append(RNote(t: max(0, at), end: until + 0.05, pitch: s.1, vel: v(k == 0 ? 84 : 72)))
                }
            }
            t += d
        }
        return (notes.sorted { $0.t < $1.t }, "\((flatNames)[tonic]) \(wanted)")
    }

    func performGift(_ mood: Mood) {
        let piece = invent(mood)
        let a = analyse(piece.notes)
        // No drums: a made-up piece is a piano piece with strings behind it.
        let ev = events(piece.notes + bandFull(piece.notes, a).filter { $0.ch != 9 })
        lastGift = piece.notes
        giftName = "\(Me.name), \(mood.name), in \(piece.key)"
        giftAt = now() + (piece.notes.last?.end ?? 0)
        goHomeQuietly()
        ui("now Something \(mood.name), made up for you")
        run { g in
            self.say(pick(["Something \(mood.name), in \(piece.key). I am making this up as I go.", "One \(mood.name) piece, in \(piece.key). Nobody has heard this before.", "\(mood.name.capitalized), in \(piece.key). This one is just for you."]), g)
            self.play(ev, g)
            guard self.alive(g) else { return }
            self.say(pick(["That did not exist a minute ago. Say keep that, and it is yours.", "If you liked it, say keep that.", "Say keep that to save it, or ask for another."]), g)
        }
    }

    /// The player's most recent music: the piece being written, what was just played, or the last one saved.
    func latestPiece() -> [RNote]? {
        let take = mode == .compose ? tidyTake(notes(since: takeStart)) : []
        if take.count >= 6 { return take }
        let recent = lastStretch()
        if recent.count >= 12, now() - lastOnset < 600 { return recent }
        return lastSavedIdea()
    }

    /// The same notes, dressed differently.
    func restyle(_ style: String) {
        guard let piece = latestPiece(), piece.count >= 6 else { run { g in self.say("Play me something first, then I can dress it up.", g) }; return }
        let a = analyse(piece)
        var out: [RNote] = []
        var said = ""
        switch style {
        case "lullaby":
            // A music box, an octave up, slower and softer, over quiet strings.
            let slow = 1.25
            out = piece.map { RNote(t: $0.t * slow, end: $0.t * slow + min(1.2, ($0.end - $0.t) * slow), pitch: min(100, $0.pitch + 12), vel: max(30, Int(Double($0.vel) * 0.75)), ch: 4) }
            let stretched = piece.map { n -> RNote in var n = n; n.t *= slow; n.end *= slow; return n }
            out += bandParts(stretched, analyse(stretched)).filter { $0.ch == 2 }.map { n -> RNote in var n = n; n.vel = max(18, n.vel - 12); return n }
            said = "Your piece, as a lullaby."
        case "8-bit":
            // Square waves and short notes, like an old video game.
            out = piece.map { RNote(t: $0.t * 0.9, end: $0.t * 0.9 + min(0.28, ($0.end - $0.t) * 0.6), pitch: $0.pitch >= 55 ? $0.pitch : $0.pitch + 12, vel: 86, ch: 10) }
            var onsets: [Double] = []
            for n in out.sorted(by: { $0.t < $1.t }) where onsets.last == nil || n.t - onsets.last! > 0.12 { onsets.append(n.t) }
            out += onsets.enumerated().map { RNote(t: $0.element, end: $0.element + 0.05, pitch: $0.offset % 4 == 0 ? 36 : 42, vel: $0.offset % 4 == 0 ? 80 : 46, ch: 9) }
            said = "Your piece, as a video game."
        case "epic":
            // The full orchestra, a horn on the tune, and timpani on every chord.
            let wasStyle = bandStyle
            bandStyle = "full"
            out = piece.map { n -> RNote in var n = n; n.vel = min(120, Int(Double(n.vel) * 1.12)); return n } + bandFull(piece, a).map { n -> RNote in var n = n; if n.cc < 0 { n.vel = min(120, n.vel + 14) }; return n }
            bandStyle = wasStyle
            for c in a.chords {
                var p = 36 + c.root; if p > 45 { p -= 12 }
                out.append(RNote(t: c.start, end: c.start + 1.2, pitch: p, vel: 96, ch: 11))
                if let top = piece.filter({ abs($0.t - c.start) < 0.4 && $0.pitch >= 60 }).map({ $0.pitch }).max() {
                    out.append(RNote(t: c.start, end: c.end, pitch: top > 77 ? top - 12 : top, vel: 78, ch: 7))
                }
            }
            said = "Your piece, as a film score."
        default:
            // Electric piano and a round bass, late at night.
            out = piece.map { RNote(t: $0.t, end: $0.end, pitch: $0.pitch, vel: max(30, Int(Double($0.vel) * 0.9)), ch: 5) }
            out += bandParts(piece, a).filter { $0.ch == 1 }
            said = "Your piece, on an electric piano."
        }
        let ev = events(settle(out.filter { $0.ch != 4 && $0.ch != 10 && $0.ch != 5 }, against: piece) + out.filter { $0.ch == 4 || $0.ch == 10 || $0.ch == 5 })
        ui("now " + said)
        run { g in self.say(said, g); self.play(ev, g) }
    }

    /// Every saved piece, oldest first, announced and played with the band.
    func playAlbum() {
        let dir = baseDir.appendingPathComponent("ideas")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "mid" }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var pieces: [(title: String, notes: [RNote])] = []
        var seen = Set<Int>()
        for f in files.sorted(by: { date($0) < date($1) }) {
            guard let song = loadMIDIFile(f, track: "piano") else { continue }
            let spb = 60 / song.bpm
            let notes = tidyTake(song.notes.map { RNote(t: $0.beat * spb, end: ($0.beat + $0.dur) * spb, pitch: $0.pitch, vel: $0.vel) }.sorted { $0.t < $1.t })
            // Only real pieces, and each one once.
            guard notes.count >= 40, seen.insert(notes.count &* 31 &+ notes[0].pitch).inserted else { continue }
            var title = f.deletingPathExtension().lastPathComponent
            if title.hasPrefix("idea ") {
                let fmt = DateFormatter(); fmt.dateFormat = "EEEE"
                title = "A piece in \(title.components(separatedBy: " ").dropFirst(3).joined(separator: " ")), from \(fmt.string(from: date(f)))"
            }
            pieces.append((title, notes))
        }
        guard !pieces.isEmpty else { run { g in self.say("You have not saved any pieces yet. Play something and say keep that.", g) }; return }
        goHomeQuietly()
        run { g in
            self.say("Your album. \(pieces.count) pieces, all written by you. Say \(Me.name) stop, or press home, to end it.", g)
            for (i, p) in pieces.enumerated() {
                guard self.alive(g) else { return }
                ui("now Your album: \(i + 1) of \(pieces.count), \(p.title)")
                self.say("\(i + 1). \(p.title).", g)
                let a = analyse(p.notes)
                self.play(events(p.notes + bandFull(p.notes, a)), g)
                guard self.alive(g) else { return }
                if !Opt.fast { usleep(1_200_000) }
            }
            self.say("That was all of it. You wrote every note.", g)
        }
    }

    /// Performs a whole piece from the library, as written.
    func perform(_ index: Int) {
        guard songs.indices.contains(index) else { return }
        let s = songs[index]
        let spb = 60 / s.bpm
        let ev = events(s.notes.map { RNote(t: $0.beat * spb, end: ($0.beat + max(0.1, $0.dur)) * spb, pitch: $0.pitch, vel: $0.vel) })
        goHomeQuietly()
        ui("now Playing \(s.name)")
        run { g in self.say("\(s.name)." + (s.fact.isEmpty ? "" : " " + s.fact), g); self.play(ev, g) }
    }

    // MARK: Jam: a musical conversation

    func setJam(_ on: Bool) {
        jamOn = on
        if on { goHomeQuietly(); jamFrom = now() }
        run { g in self.say(on ? "Let's talk in music. Play me a short phrase, then stop, and I will answer. Say \(Me.name) stop when you have had enough." : "That was fun.", g) }
    }

    /// Called on every note while jamming: after a short silence, answer the phrase just played.
    func armJam() {
        if Opt.fast { return }
        jamToken += 1
        let token = jamToken
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.25) {
            self.lock.lock(); defer { self.lock.unlock() }
            guard token == self.jamToken, self.jamOn, self.mode == .idle, self.openIdx.isEmpty else { return }
            let t = now()
            var phrase = self.history.filter { $0.t >= max(self.jamFrom, t - 9) }
            guard phrase.count >= 3 else { return }
            phrase = Array(phrase.suffix(14))
            let first = phrase[0].t
            let take = phrase.map { RNote(t: $0.t - first, end: ($0.end < 0 ? t : $0.end) - first, pitch: $0.pitch, vel: $0.vel) }
            let a = analyse(self.lastStretch().count >= 8 ? self.lastStretch() : take)
            // Answer in kind: the same rhythm, turned upside down, moved up a step, or with a new ending.
            var answer: [RNote]
            switch Int.random(in: 0..<3) {
            case 0:
                var b = Analysis(); b.tonic = a.tonic; b.minor = a.minor; b.length = take.last?.end ?? 1
                answer = variation(1, take, b)
            case 1:
                let scale = (a.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { ($0 + a.tonic) % 12 }
                answer = take.map { n in var n = n; var p = n.pitch + 1; while !scale.contains(p % 12) { p += 1 }; n.pitch = p; return n }
            default:
                answer = take
                if let lastNote = answer.indices.last {
                    let home = (answer[lastNote].pitch - 6...answer[lastNote].pitch + 6).first { $0 % 12 == a.tonic } ?? answer[lastNote].pitch
                    answer[lastNote].pitch = home
                    answer[lastNote].end += 0.6
                }
            }
            let ev = events(answer.map { RNote(t: $0.t, end: max($0.t + 0.12, $0.end), pitch: max(36, min(96, $0.pitch)), vel: max(40, $0.vel - 6), ch: 5) })
            self.jamFrom = t + (answer.last?.end ?? 1) + 0.2
            self.run { g in self.play(ev, g) }
        }
    }

    func surprise() {
        switch Int.random(in: 0..<5) {
        case 0, 1:
            performGift(moods.randomElement()!)
        case 2:
            let joke = musicJokes.randomElement()!
            run { g in self.say(joke, g); if !Opt.fast { self.midi.send([0x99, 38, 90]); usleep(160_000); self.midi.send([0x99, 49, 96]) } }
        case 3:
            if latestPiece() != nil { restyle(["8-bit", "lullaby", "epic"].randomElement()!) } else { performGift(moods.randomElement()!) }
        default:
            // The piano itself says hello: speech turned into notes.
            run { g in
                self.say("Listen closely. The piano has something to say.", g)
                guard self.alive(g), !Opt.fast, let ev = speechToNotes("Hello \(You.name)") else { return }
                self.play(ev, g)
                self.say("It said, hello \(You.name).", g)
            }
        }
    }
}

func delightSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    var fine = true
    var keys: [String] = []
    for m in moods {
        for _ in 0..<20 {
            let p = engine.invent(m)
            let a = analyse(p.notes)
            let band = bandFull(p.notes, a)
            if p.notes.count < 30 || !(p.notes + band).allSatisfy({ $0.cc >= 0 || ((24...100).contains($0.pitch) && $0.end > $0.t) }) || a.chords.count < 4 { fine = false }
        }
        keys.append("\(m.name): \(engine.invent(m).key)")
    }
    check("invented pieces: 120 pieces in six moods are all playable and the band can follow them", fine, keys.joined(separator: ", "))
    let piece = engine.invent(moods[0])
    let a = analyse(piece.notes)
    check("invented pieces: a sad piece is heard as minor and ends on its home chord", a.minor && a.chords.last?.root == a.tonic, a.summary(noteCount: piece.notes.count))
    let got = ["play me something sad", "\(Me.name), make it a lullaby", "turn it into a video game", "play my album", "jam with me", "surprise me", "tell me a joke", "make it epic", "play something calm"].map { s -> String in
        engine.goHomeQuietly(); engine.jamOn = false
        return engine.hear(s)
    }
    engine.goHomeQuietly(); engine.jamOn = false
    check("delight: requests for music are understood", got == ["gift sad", "restyle lullaby", "restyle 8-bit", "album", "jam", "surprise", "joke", "restyle epic", "gift calm"], got.joined(separator: ", "))
}
