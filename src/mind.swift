// What the tool remembers and what it knows about music: a memory that lasts between
// sessions, a greeting that picks up where things were left, and plain-language
// observations about a composition.

import Foundation

struct SavedPiece: Codable { var date: Double; var key: String; var roots: [Int]; var seconds: Int }

struct Memory: Codable {
    var sessions = 0
    var lastOpened = 0.0
    var lastSong = ""
    var partsLearned = 0
    var pieces: [SavedPiece] = []
    var jazzLesson: Int?
    var composeIdea: Int?
    var greeted: [String]?     // what the last greeting talked about, so the next one talks about something else
    var streak: Int?           // days in a row the app has been opened
    var lastDay: String?
    var dropped: [String]?     // songs the player has finished with: never brought up again unless he picks them

    static let url = baseDir.appendingPathComponent("memory.json")
    static func load() -> Memory { (try? JSONDecoder().decode(Memory.self, from: Data(contentsOf: url))) ?? Memory() }
    func save() { if !Opt.fast, let d = try? JSONEncoder().encode(self) { try? d.write(to: Memory.url) } }
}

// Picks one of several ways to say the same thing, so the voice does not repeat itself.
func pick(_ options: [String]) -> String { options.randomElement() ?? "" }

func daysAgo(_ then: Double, from now: Date = Date()) -> Int {
    let cal = Calendar.current
    return cal.dateComponents([.day], from: cal.startOfDay(for: Date(timeIntervalSince1970: then)), to: cal.startOfDay(for: now)).day ?? 0
}

func whenText(_ then: Double) -> String {
    let d = daysAgo(then)
    if d <= 0 { return "earlier today" }
    if d == 1 { return "yesterday" }
    if d < 7 { let f = DateFormatter(); f.dateFormat = "EEEE"; return "on " + f.string(from: Date(timeIntervalSince1970: then)) }
    return "\(d) days ago"
}

// The chord roots of a piece as steps above its key note, with repeats in a row removed.
func rootPath(_ a: Analysis) -> [Int] {
    var out: [Int] = []
    for c in a.chords {
        let r = ((c.root - a.tonic) % 12 + 12) % 12
        if out.last != r { out.append(r) }
    }
    return out
}

// Well-known chord loops, as steps above the key note.
let knownLoops: [(minor: Bool, roots: [Int], text: String)] = [
    (false, [0, 7, 9, 5], "It uses the one, five, six, four loop, the most loved chord loop in pop."),
    (false, [9, 5, 0, 7], "It uses the six, four, one, five loop, the same one behind a lot of film and pop ballads."),
    (false, [0, 9, 5, 7], "It uses the one, six, four, five loop, the classic sound of nineteen fifties songs."),
    (false, [0, 5, 9, 7], "It uses a one, four, six, five loop, bright and open."),
    (false, [2, 7, 0], "It has a two, five, one, the cadence at the heart of jazz."),
    (false, [0, 5, 7], "It is built on one, four and five, the three main chords of the key."),
    (true, [0, 8, 3, 10], "It uses the one, six, three, seven minor loop, the big cinematic one."),
    (true, [0, 10, 8, 7], "It walks down one, seven, six, five: the Andalusian cadence, from flamenco."),
    (true, [0, 10, 8, 10], "It rocks between one, seven and six, a classic minor-key pattern."),
    (true, [0, 5, 7], "It is built on one, four and five in the minor."),
]

// Up to four short observations about a piece: a pattern it uses, a chord from outside the
// key and what that does, how it ends, and whether it resembles an earlier piece.
func insights(_ a: Analysis, earlier: [SavedPiece]) -> [String] {
    var out: [String] = []
    let path = rootPath(a)
    guard path.count >= 2 else { return out }
    func contains(_ loop: [Int]) -> Bool {
        guard path.count >= loop.count else { return false }
        return (0...(path.count - loop.count)).contains { Array(path[$0..<$0 + loop.count]) == loop }
    }
    if let known = knownLoops.first(where: { $0.minor == a.minor && contains($0.roots) }) { out.append(known.text) }

    // Chords from outside the key, counted only when they are held long enough to be meant.
    func held(_ step: Int, _ test: (String) -> Bool) -> Chord? {
        let hits = a.chords.filter { ((($0.root - a.tonic) % 12 + 12) % 12) == step && test($0.quality) }
        return hits.reduce(0) { $0 + $1.end - $1.start } >= 2 ? hits.first : nil
    }
    let isMajor: (String) -> Bool = { $0 == "major" || $0.hasSuffix("seventh") && !$0.hasPrefix("minor") }
    let isMinor: (String) -> Bool = { $0.hasPrefix("minor") }
    if !a.minor {
        if let c = held(5, isMinor) {
            out.append("The \(a.name(c)) chord is borrowed from the minor key. That is where the bittersweet colour comes from.")
        } else if let c = held(10, isMajor) {
            out.append("The \(a.name(c)) chord is from outside the key. It gives a warm, rock-like lift.")
        } else if let c = held(8, isMajor) {
            out.append("The \(a.name(c)) chord is borrowed from the minor key, a dramatic, film-score colour.")
        }
    } else {
        if let c = held(5, isMajor) {
            out.append("The \(a.name(c)) chord is brighter than a minor key normally allows. That is the Dorian sound: minor, but hopeful.")
        } else if let c = held(7, isMajor) {
            out.append("The \(a.name(c)) chord pulls strongly back home. That is the harmonic minor at work.")
        }
        if let last = a.chords.last, last.root == a.tonic, last.quality == "major" {
            out.append("It ends on a major chord in a minor key, an old trick called a Picardy third.")
        }
    }

    if let last = a.chords.last, a.chords.count >= 3 {
        let step = ((last.root - a.tonic) % 12 + 12) % 12
        if step == 0 {
            out.append(pick(["It ends at home, so it feels finished.", "It comes to rest on the home chord."]))
        } else if step == 7 {
            out.append("It stops on the five chord, which leaves a question hanging. End on \(a.names[a.tonic]) to answer it.")
        } else {
            out.append("It ends away from home, on \(a.name(last)), so it feels open. End on \(a.names[a.tonic]) if you want it to close.")
        }
    }

    let opening = Array(path.prefix(4))
    if opening.count == 4, let twin = earlier.last(where: { Array($0.roots.prefix(4)) == opening }) {
        out.append("It opens with the same chord movement as the piece you saved \(whenText(twin.date)).")
    } else if let prev = earlier.last, prev.key == a.keyName {
        out.append("Same key as your last piece.")
    }
    return Array(out.prefix(4))
}

extension Engine {
    // The first thing said after opening: short, and about where things were left.

    // "I am done with this song": it is never mentioned at start-up again and the top key no
    // longer goes back to it. It stays in the song menu, and picking it there brings it back.
    func dropSong() {
        lock.lock(); defer { lock.unlock() }
        let name = (mode == .teach && jazzIdx == nil ? lesson?.song.name : nil) ?? mem.lastSong
        guard !name.isEmpty, !name.hasPrefix("Jazz ") else {
            run { g in self.say("There is no song to set aside right now.", g) }
            return
        }
        var list = mem.dropped ?? []
        if !list.contains(name) { list.append(name) }
        mem.dropped = list
        mem.lastSong = ""
        mem.save()
        if !Opt.fast { try? FileManager.default.removeItem(at: baseDir.appendingPathComponent("last-song.txt")) }
        waiting = false; paused = false
        accGen += 1
        midi.allOff()
        lesson = nil
        songIdx = songs.firstIndex { !list.contains($0.name) } ?? 0
        mode = .idle
        run { g in self.say("Done. I will not bring up \(name) again. It is still in the song menu if you ever want it.", g) }
    }

    func rememberPiece(_ a: Analysis) {
        mem.pieces.append(SavedPiece(date: Date().timeIntervalSince1970, key: a.keyName, roots: rootPath(a), seconds: Int(a.length)))
        if mem.pieces.count > 200 { mem.pieces.removeFirst(mem.pieces.count - 200) }
        mem.save()
    }

    // A word at the turning points of a song, and nothing in between.
    func milestone(from old: Unit, to new: Unit, in l: Lesson) -> String {
        guard new.from == new.to, new.to != old.to || old.from != old.to, new.to > old.to || old.from != old.to else { return "" }
        guard new.to != old.to else { return "" }
        let parts = l.bounds.count
        if parts >= 4, new.to == parts - 1 { return pick(["Last part. ", "Final part now. "]) }
        if parts >= 6, new.to == parts / 2 { return pick(["Halfway. ", "That is half the song. "]) }
        if parts >= 30, new.to > 0, new.to % 25 == 0 { return "\(new.to) parts done. " }
        return ""
    }
}

func mindSelfTest(_ check: (String, Bool, String) -> Void) {
    func chord(_ root: Int, _ q: String, _ t: Double) -> Chord { Chord(start: t, end: t + 3, root: root, quality: q, tones: q == "minor" ? [0, 3, 7] : [0, 4, 7]) }
    var a = Analysis()
    a.tonic = 0; a.minor = false
    a.chords = [chord(0, "major", 0), chord(7, "major", 3), chord(9, "minor", 6), chord(5, "minor", 9), chord(0, "major", 12)]
    let one = insights(a, earlier: [])
    check("knowledge: hears a borrowed minor chord and a finished ending", one.contains { $0.contains("borrowed") } && one.contains { $0.contains("home") }, one.joined(separator: " "))
    a.chords = [chord(0, "major", 0), chord(7, "major", 3), chord(9, "minor", 6), chord(5, "major", 9), chord(7, "major", 12)]
    let two = insights(a, earlier: [SavedPiece(date: Date().timeIntervalSince1970, key: "C major", roots: [0, 7, 9, 5, 0], seconds: 30)])
    check("knowledge: names a famous loop, an open ending and a likeness to an earlier piece",
          two.contains { $0.contains("one, five, six, four") } && two.contains { $0.contains("question") } && two.contains { $0.contains("same chord movement") }, two.joined(separator: " "))
    var b = Analysis()
    b.tonic = 0; b.minor = true
    b.chords = [chord(0, "minor", 0), chord(3, "major", 3), chord(5, "major", 6), chord(0, "minor", 9)]
    let three = insights(b, earlier: [])
    check("knowledge: hears the Dorian colour in a minor piece", three.contains { $0.contains("Dorian") }, three.joined(separator: " "))
}
