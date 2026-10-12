// The song library: easy songs written out here, MIDI files from the songs folder,
// five difficulty levels, and the song menu that is played from the piano.

import Foundation

let levelNames = ["Easy", "Moderately easy", "Moderate", "Hard", "Very hard"]

// Writes a tune from text. "E4" is a one-beat note, "G4/2" lasts two beats, "r/1" is a rest,
// and for the left hand "C/4" is a C major chord held for four beats.
func tune(_ text: String, hand: Int) -> [SNote] {
    let chords: [String: [Int]] = ["C": [48, 52, 55], "F": [48, 53, 57], "G": [47, 50, 55], "Dm": [50, 53, 57], "Am": [48, 52, 57]]
    var out: [SNote] = []
    var beat = 0.0
    for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
        let parts = token.split(separator: "/")
        let len = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
        let name = String(parts[0])
        if let chord = chords[name] {
            for p in chord { out.append(SNote(beat: beat, dur: len, pitch: p, vel: 72, hand: hand)) }
        } else if name != "r", let p = parseNoteName(name) {
            out.append(SNote(beat: beat, dur: len, pitch: p, vel: 84, hand: hand))
        }
        beat += len
    }
    return out
}

func builtInSongs() -> [Song] {
    func song(_ name: String, _ bpm: Double, _ right: String, _ left: String, level: Int = 1) -> Song {
        Song(name: name, bpm: bpm, notes: tune(right, hand: 0) + tune(left, hand: 1), level: level)
    }
    var songs: [Song] = []
    songs.append(song("Hot Cross Buns", 100,
        "E4 D4 C4/2 E4 D4 C4/2 C4/.5 C4/.5 C4/.5 C4/.5 D4/.5 D4/.5 D4/.5 D4/.5 E4 D4 C4/2",
        "C/4 C/4 C/2 G/2 C/4"))
    songs.append(song("Mary Had a Little Lamb", 110,
        "E4 D4 C4 D4 E4 E4 E4/2 D4 D4 D4/2 E4 G4 G4/2 E4 D4 C4 D4 E4 E4 E4 E4 D4 D4 E4 D4 C4/4",
        "C/4 C/4 G/4 C/4 C/4 C/4 G/4 C/4"))
    let twinkleA = "C4 C4 G4 G4 A4 A4 G4/2 F4 F4 E4 E4 D4 D4 C4/2 "
    let twinkleB = "G4 G4 F4 F4 E4 E4 D4/2 "
    songs.append(song("Twinkle Twinkle Little Star", 100,
        twinkleA + twinkleB + twinkleB + twinkleA,
        "C/4 F/2 C/2 F/2 C/2 G/2 C/2 C/2 F/2 C/2 G/2 C/2 F/2 C/2 G/2 C/4 F/2 C/2 F/2 C/2 G/2 C/2"))
    songs.append(song("Frere Jacques", 110,
        "C4 D4 E4 C4 C4 D4 E4 C4 E4 F4 G4/2 E4 F4 G4/2 G4/.5 A4/.5 G4/.5 F4/.5 E4 C4 G4/.5 A4/.5 G4/.5 F4/.5 E4 C4 C4 G3 C4/2 C4 G3 C4/2",
        "C/4 C/4 C/4 C/4 C/4 C/4 C/1 G/1 C/2 C/1 G/1 C/2"))
    let lightA = "C4 C4 C4 D4 E4/2 D4/2 C4 E4 D4 D4 C4/4 "
    songs.append(song("Au Clair de la Lune (folk song)", 100,
        lightA + lightA + "D4 D4 D4 D4 A3/2 A3/2 D4 C4 B3 A3 G3/4 " + lightA,
        "C/4 C/2 G/2 C/2 G/2 C/4 C/4 C/2 G/2 C/2 G/2 C/4 G/4 Dm/4 G/4 G/4 C/4 C/2 G/2 C/2 G/2 C/4"))
    songs.append(song("London Bridge", 110,
        "G4/1.5 A4/.5 G4 F4 E4 F4 G4/2 D4 E4 F4/2 E4 F4 G4/2 G4/1.5 A4/.5 G4 F4 E4 F4 G4/2 D4/2 G4/2 E4/2 C4/2",
        "C/4 C/4 G/4 C/4 C/4 C/4 G/4 C/4"))
    let jingleA = "E4 E4 E4/2 E4 E4 E4/2 E4 G4 C4/1.5 D4/.5 E4/4 F4 F4 F4/1.5 F4/.5 F4 E4 E4 E4/.5 E4/.5 "
    songs.append(song("Jingle Bells", 120,
        jingleA + "E4 D4 D4 E4 D4/2 G4/2 " + jingleA + "G4 G4 F4 D4 C4/4",
        "C/4 C/4 C/4 C/4 F/4 C/4 G/4 G/4 C/4 C/4 C/4 C/4 F/4 C/4 G/4 C/4"))
    songs.append(song("Happy Birthday", 100,
        "G4/.75 G4/.25 A4 G4 C5 B4/2 G4/.75 G4/.25 A4 G4 D5 C5/2 G4/.75 G4/.25 G5 E5 C5 B4 A4 F5/.75 F5/.25 E5 C5 D5 C5/3",
        "r/1 C/3 G/3 G/3 C/3 C/3 F/3 C/2 G/1 C/3"))
    let odeA = "E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 "
    songs.append(song("Ode to Joy", 100,
        odeA + "E4/1.5 D4/.5 D4/2 " + odeA + "D4/1.5 C4/.5 C4/2",
        "C/4 G/4 C/4 G/4 C/4 G/4 C/4 G/2 C/2"))

    // Fur Elise, opening theme. Times in sixteenth notes.
    func seq(_ items: [(Double, Double, [Int])], hand: Int) -> [SNote] {
        items.flatMap { item in item.2.map { SNote(beat: item.0 * 0.25, dur: item.1 * 0.25, pitch: $0, vel: 80, hand: hand) } }
    }
    let E5 = 76, Ds5 = 75, B4 = 71, D5 = 74, C5 = 72, A4 = 69, C4 = 60, E4 = 64, Gs4 = 68
    let A2 = 45, E3 = 52, A3 = 57, E2 = 40, Gs3 = 56
    var r: [(Double, Double, [Int])] = []
    for (t, p) in [E5, Ds5, E5, Ds5, E5, B4, D5, C5].enumerated() { r.append((Double(t), 1, [p])) }
    r += [(8, 2, [A4]), (11, 1, [C4]), (12, 1, [E4]), (13, 1, [A4]),
          (14, 2, [B4]), (17, 1, [E4]), (18, 1, [Gs4]), (19, 1, [B4]),
          (20, 2, [C5]), (23, 1, [E4]), (24, 1, [E5]), (25, 1, [Ds5])]
    for (t, p) in [E5, Ds5, E5, B4, D5, C5].enumerated() { r.append((Double(26 + t), 1, [p])) }
    r += [(32, 2, [A4]), (35, 1, [C4]), (36, 1, [E4]), (37, 1, [A4]),
          (38, 2, [B4]), (41, 1, [E4]), (42, 1, [C5]), (43, 1, [B4]), (44, 4, [A4])]
    var l: [(Double, Double, [Int])] = []
    for (t, ps) in [(8.0, [A2, E3, A3]), (14, [E2, E3, Gs3]), (20, [A2, E3, A3]), (32, [A2, E3, A3]), (38, [E2, E3, Gs3]), (44, [A2, E3, A3])] {
        for (i, p) in ps.enumerated() { l.append((t + Double(i), 1, [p])) }
    }
    songs.append(Song(name: "Fur Elise, opening only", bpm: 60, notes: seq(r, hand: 0) + seq(l, hand: 1), level: 2))
    return songs
}

// A rough difficulty guess for MIDI files that were not put in a level folder.
func guessLevel(_ s: Song) -> Int {
    guard let last = s.notes.map({ $0.beat }).max(), last > 0 else { return 1 }
    let perSecond = Double(s.notes.count) / (last * 60 / s.bpm)
    let big = makeSteps(s.notes.filter { $0.hand == 0 }).filter { $0.pitches.count >= 3 }.count
    var level = perSecond < 2.5 ? 1 : perSecond < 4.5 ? 2 : perSecond < 7 ? 3 : perSecond < 10 ? 4 : 5
    if big > 20, level < 5 { level += 1 }
    return level
}

// Tidies a file name into a title: drops copy numbers and cut-off brackets.
func cleanTitle(_ name: String) -> String {
    var s = name
    if let open = s.lastIndex(of: "("), !s[open...].contains(")") { s = String(s[..<open]) }
    for junk in ["(Sheet Music)", "(Official Audio)", "(Audio)", "(1)", "(2)"] { s = s.replacingOccurrences(of: junk, with: "") }
    var words = s.split(separator: " ").map(String.init)
    while let last = words.last, words.count > 1, Int(last) != nil, last.count == 1 { words.removeLast() }
    return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -"))
}

// library.txt gives chosen levels and titles for known files, one per line:
//   part of the file name | level 1 to 5 | title to say
// A level of 0 hides the file.
func libraryRules() -> [(match: String, level: Int, title: String, fact: String)] {
    guard let text = try? String(contentsOf: baseDir.appendingPathComponent("library.txt"), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !line.hasPrefix("#"), parts.count >= 2, let level = Int(parts[1]) else { return nil }
        return (parts[0].lowercased(), level, parts.count > 2 ? parts[2] : "", parts.count > 3 ? parts[3] : "")
    }
}

// Built-in songs, then every MIDI file in the songs folder and in the Nova Songs folder.
// The level comes from library.txt, or a folder whose name starts with 1 to 5, or a guess.
func loadLibrary() -> [Song] {
    var songs = builtInSongs()
    let rules = libraryRules()
    let own = baseDir.appendingPathComponent("songs")
    let midify = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/Nova Songs")
    var seen = Set(songs.map { $0.name.lowercased() })
    for dir in [own, midify] {
        let found = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for f in found.sorted(by: { $0.path < $1.path }) where ["mid", "midi"].contains(f.pathExtension.lowercased()) {
            let file = f.deletingPathExtension().lastPathComponent
            if file.hasPrefix(".") { continue }
            let rule = rules.first { file.lowercased().contains($0.match) }
            if rule?.level == 0 { continue }
            guard var s = loadMIDIFile(f), s.notes.count >= 8 else { continue }
            s.name = rule.map { $0.title.isEmpty ? cleanTitle(file) : $0.title } ?? cleanTitle(file)
            s.fact = rule?.fact ?? ""
            if !seen.insert(s.name.lowercased()).inserted { continue }   // same song twice
            let folder = f.deletingLastPathComponent().lastPathComponent
            if let r = rule, (1...5).contains(r.level) { s.level = r.level }
            else if f.deletingLastPathComponent().path != dir.path, let n = Int(folder.prefix(1)), (1...5).contains(n) { s.level = n }
            else { s.level = guessLevel(s) }
            songs.append(s)
        }
    }
    // Stable order: by level, then in the order found.
    return songs.enumerated().sorted { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }.map { $0.element }
}

extension Engine {
    // In the song menu, each level has its own octave, starting two octaves below middle C.
    // White keys come first, then the black keys, so twelve songs fit in a level.
    func menuKeys(level: Int) -> [Int] {
        let base = 36 + 12 * (level - 1)
        return ([0, 2, 4, 5, 7, 9, 11] + [1, 3, 6, 8, 10]).map { base + $0 }.filter { !commandKeys.contains($0) }
    }

    func menuKey(forSong index: Int) -> Int? {
        guard songs.indices.contains(index) else { return nil }
        let level = songs[index].level
        let place = songs[..<index].filter { $0.level == level }.count
        let keys = menuKeys(level: level)
        return place < keys.count ? keys[place] : nil
    }

    func menuSong(forKey pitch: Int) -> Int? {
        songs.indices.first { menuKey(forSong: $0) == pitch }
    }

    func openMenu() {
        lock.lock(); defer { lock.unlock() }
        autosaveTake()
        mode = .menu
        waiting = false; paused = false; roundOn = false
        menuPick = nil
        accGen += 1
        midi.allOff()
        run { g in self.say("Song menu." + self.intro("menu", " Five octaves, starting two octaves below middle C. The lowest octave is easy, and each octave up is harder. Press any key to hear a song. Press it again to learn it.") + self.intro("menujazz", " The octave below the easy songs is the jazz course, one lesson per white key."), g) }
    }

    // Says the song's name and level, then plays its opening.
    func preview(_ index: Int) {
        menuPick = index
        menuJazz = nil
        let s = songs[index]
        let secPerBeat = 60 / s.bpm
        let first = s.notes.map { $0.beat }.min() ?? 0
        let ev = s.notes.filter { ($0.beat - first) * secPerBeat < 7 }.flatMap { n -> [Ev] in
            let t = (n.beat - first) * secPerBeat
            return [Ev(t: t, bytes: [0x90, UInt8(n.pitch), UInt8(max(1, min(127, n.vel)))]),
                    Ev(t: min(8, t + max(0.08, n.dur * secPerBeat * 0.95)), bytes: [0x80, UInt8(n.pitch), 0])]
        }
        let saved = progress[s.name] ?? 0
        let place = saved > 0 ? " You are on step \(saved + 1)." : ""
        run { g in self.say("\(s.name). \(levelNames[s.level - 1]).\(place)", g); self.play(ev, g) }
    }

    func menuNote(_ pitch: Int) {
        if let k = jazzMenuKeys.firstIndex(of: pitch), k < jazzLessons.count {
            // The octave below the easy songs is the jazz course: one lesson per key.
            if menuJazz == k { startJazz(k); return }
            menuJazz = k; menuPick = nil
            let done = (mem.jazzLesson ?? -1) == k ? " This is where you are." : ""
            run { g in self.say("Jazz lesson \(k + 1). \(jazzLessons[k].title).\(done)", g) }
            return
        }
        guard let index = menuSong(forKey: pitch) else { return }
        if menuPick == index { chooseSong(index) } else { preview(index) }
    }

    // Returns true when the key was handled here.
    func menuCommand(_ key: Int) -> Bool {
        guard mode == .menu else { return false }
        switch key {
        case keyHear:
            if let j = menuJazz { startJazz(j) } else { chooseSong(menuPick ?? songIdx) }
        case keyNext, keyBack:
            // With a jazz lesson picked, these two keys step through the jazz lessons, so every
            // lesson can be reached even when its own key on the piano does not work.
            if let j = menuJazz {
                let k = (j + (key == keyNext ? 1 : jazzLessons.count - 1)) % jazzLessons.count
                menuJazz = k
                let done = (mem.jazzLesson ?? -1) == k ? " This is where you are." : ""
                run { g in self.say("Jazz lesson \(k + 1). \(jazzLessons[k].title).\(done) The top key starts it.", g) }
                return true
            }
            let from = menuPick ?? songIdx
            preview((from + (key == keyNext ? 1 : songs.count - 1)) % songs.count)
        case keyNotes:
            // Counts the songs in each level.
            let text = (1...5).map { l in "\(levelNames[l - 1]), \(songs.filter { $0.level == l }.count)" }.joined(separator: ". ")
            run { g in self.say("\(self.songs.count) songs. " + text + ".", g) }
        default:
            return false
        }
        return true
    }
}
