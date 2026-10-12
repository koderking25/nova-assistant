// Jazz mode: a nine-lesson course in playing and improvising jazz, taught by ear.
// Each lesson explains one idea, teaches a short study by imitation, then puts on a
// swinging rhythm section to improvise with, and says what it heard afterwards.
//
// The order follows how jazz teachers sequence beginners: feel first, then a small set of
// safe notes, space, call and response, the blues form with left-hand shells, landing on
// chord tones, the two five one, and developing a small idea.
//
// Also here: the "learn" ideas for composition mode.

import Foundation

struct JazzChord { let root: Int; let kind: String }   // kind: "7", "m7" or "maj7"

extension JazzChord {
    var third: Int { (root + (kind == "m7" ? 3 : 4)) % 12 }
    var seventh: Int { (root + (kind == "maj7" ? 11 : 10)) % 12 }
    var spoken: String { flatNames[root] + (kind == "7" ? " seven" : kind == "m7" ? " minor seven" : " major seven") }
}

enum JamGoal { case swing, scale, space, calls, shells, targets, free }

struct JazzLesson {
    var title: String
    var talk: String
    var right = ""          // study for the right hand
    var left = ""           // study for the left hand
    var bars: [JazzChord]   // one chord per bar of the backing
    var bpm = 96.0
    var choruses = 2
    var scale: Set<Int>
    var goal: JamGoal
    var tip: String
    var comp = true         // the band's keyboard plays the chords
    var calls: [String] = []
}

// "E3+Bb3/4" is two notes together for four beats, "r/1" a rest, "C4/.67" a long swung note.
func jazzTune(_ text: String, hand: Int, vel: Int = 80) -> [SNote] {
    var out: [SNote] = []
    var beat = 0.0
    for token in text.split(separator: " ") {
        let parts = token.split(separator: "/")
        let len = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
        if parts[0] != "r" {
            for name in parts[0].split(separator: "+") {
                if let p = parseNoteName(String(name)) { out.append(SNote(beat: beat, dur: len, pitch: p, vel: vel, hand: hand)) }
            }
        }
        beat += len
    }
    return out
}

let C7 = JazzChord(root: 0, kind: "7"), F7 = JazzChord(root: 5, kind: "7"), G7 = JazzChord(root: 7, kind: "7")
let Dm7 = JazzChord(root: 2, kind: "m7"), Cmaj7 = JazzChord(root: 0, kind: "maj7")
let bluesBars = [C7, C7, C7, C7, F7, F7, C7, C7, G7, F7, C7, G7]
let twoFiveOne = [Dm7, G7, Cmaj7, Cmaj7]
let bluesScale: Set<Int> = [0, 3, 5, 6, 7, 10]
let whiteKeys: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

let jazzLessons: [JazzLesson] = [
    JazzLesson(title: "Swing",
               talk: "Jazz starts with the feel, not the notes. Swing means notes come in pairs, long then short. The first leans back, the second skips into the next beat. Say doo, bah, doo, bah.",
               right: "C4/.67 C4/.33 Eb4/.67 F4/.33 G4/2 G4/.67 F4/.33 Eb4/.67 C4/.33 C4/2",
               bars: bluesBars, bpm: 88, scale: bluesScale, goal: .swing,
               tip: "Now with the band. Play long, short pairs on C, E flat, F and G."),
    JazzLesson(title: "The blues scale",
               talk: "Six notes: C, E flat, F, F sharp, G, B flat. Over a blues, every one of them sounds right, so you cannot play a wrong note. F sharp is the blue note. Pass through it, do not rest on it.",
               right: "C4 Eb4 F4 F#4 G4 Bb4 C5/2 C5 Bb4 G4 F#4 F4 Eb4 C4/2",
               bars: bluesBars, scale: bluesScale, goal: .scale,
               tip: "Now improvise. Any of the six notes, in any order."),
    JazzLesson(title: "Less is more",
               talk: "Beginners play too much. Miles Davis was famous for what he left out. A phrase, then silence, then another phrase. The silence is part of the solo. Try it with only three notes.",
               right: "C4/.67 Eb4/.33 F4/2 r/1 F4/.67 Eb4/.33 C4/2 r/1 Eb4/.67 F4/.33 Eb4/.67 C4/.33 C4/2",
               bars: bluesBars, scale: [0, 3, 5], goal: .space,
               tip: "Only C, E flat and F. Play a short phrase, then stop and listen for a whole bar."),
    JazzLesson(title: "Call and response",
               talk: "Jazz is a conversation. I play two bars, then you get two bars. Copy what I said, or answer it your own way. Start by copying my rhythm.",
               bars: bluesBars, bpm: 88, scale: bluesScale, goal: .calls,
               tip: "I go first. You answer in the gap.",
               calls: ["C4/.67 Eb4/.33 F4/2", "G4/.67 F4/.33 Eb4/.67 C4/1.33", "C5 Bb4/.67 G4/.33 F4/2", "Eb4/.67 F4/.33 F#4/.67 G4/1.33", "G4/.67 Bb4/.33 C5/2", "F4/.67 Eb4/.33 C4/2"]),
    JazzLesson(title: "The twelve bar blues, and shells",
               talk: "The blues is twelve bars: four of C seven, two of F seven, two of C seven, then G seven, F seven, C seven, G seven. In the left hand, jazz pianists play shells: just the third and seventh of each chord. C seven is E and B flat. F seven is E flat and A. G seven is F and B. Notice each note only moves one step.",
               left: "E3+Bb3/4 E3+Bb3/4 E3+Bb3/4 E3+Bb3/4 Eb3+A3/4 Eb3+A3/4 E3+Bb3/4 E3+Bb3/4 F3+B3/4 Eb3+A3/4 E3+Bb3/4 F3+B3/4",
               bars: bluesBars, bpm: 84, scale: bluesScale, goal: .shells,
               tip: "Now play the shells with the bass and drums. One shell at the start of each bar.", comp: false),
    JazzLesson(title: "Land on the third",
               talk: "A solo sounds like jazz when it lands on the third of each new chord, right as the chord changes. That is E for C seven, A for F seven, and B for G seven. The notes in between matter much less than where you land.",
               right: "E4/3 r/1 E4/3 r/1 E4/3 r/1 E4/3 r/1 A4/3 r/1 A4/3 r/1 E4/3 r/1 E4/3 r/1 B4/3 r/1 A4/3 r/1 E4/3 r/1 B4/3 r/1",
               bars: bluesBars, bpm: 88, scale: bluesScale.union([4, 9, 11]), goal: .targets,
               tip: "Improvise, and at each chord change, land on the third. I will tell you how many you caught."),
    JazzLesson(title: "The two five one",
               talk: "Three chords are in nearly every jazz tune: two, five, one. In C that is D minor seven, G seven, C major seven. As shells: F and C, then F and B, then E and B. One finger moves at a time.",
               left: "F3+C4/4 F3+B3/4 E3+B3/8 F3+C4/4 F3+B3/4 E3+B3/8",
               bars: twoFiveOne, bpm: 92, choruses: 6, scale: whiteKeys, goal: .shells,
               tip: "Play the three shells with the band, round and round.", comp: false),
    JazzLesson(title: "One idea, three ways",
               talk: "Great solos are not a stream of new ideas. They take one small idea and play with it: repeat it, move it higher, change its ending. Here is a lick over the two five one that ends by sliding onto the third.",
               right: "D4/.67 F4/.33 A4/.67 C5/.33 B4/.67 A4/.33 G4/.67 F4/.33 E4/4",
               bars: twoFiveOne, bpm: 92, choruses: 6, scale: whiteKeys, goal: .targets,
               tip: "White keys only. Play the lick, then change one thing about it each time round. Aim for F, then B, then E as the chords change."),
    JazzLesson(title: "Jam session",
               talk: "Everything together: swing, the blues scale, space, and landing on the thirds. Three times through the blues, and we trade: I play two bars, you play two.",
               bars: bluesBars, bpm: 100, choruses: 3, scale: bluesScale.union([4, 9, 11]), goal: .free,
               tip: "Here we go.",
               calls: ["E4/.67 G4/.33 Bb4/.67 C5/1.33", "C5/.67 Bb4/.33 G4/.67 F#4/.33 F4/.67 Eb4/.33 C4", "G4/.67 F4/.33 E4/2", "Eb4/.33 E4/.67 G4/.67 C5/1.33", "Bb4/.67 G4/.33 F4/.67 Eb4/.33 C4/2", "C4/.67 Eb4/.33 F4/.67 F#4/.33 G4/2"]),
]

let jazzMenuKeys = [24, 26, 28, 29, 31, 33, 35, 25, 27]   // the octave below the easy songs

func jazzStudy(_ i: Int) -> Song? {
    let l = jazzLessons[i]
    let notes = jazzTune(l.right, hand: 0) + jazzTune(l.left, hand: 1, vel: 70)
    return notes.isEmpty ? nil : Song(name: "Jazz \(i + 1), \(l.title)", bpm: l.bpm, notes: notes, level: 1)
}

// Walking bass, ride cymbal and hi-hat, optional keyboard chords, and the calls in a
// call and response. One bar of clicks comes first. Returns notes in seconds.
func jazzBacking(_ l: JazzLesson) -> (notes: [RNote], lead: Double, beat: Double) {
    let beat = 60 / l.bpm
    let lead = 4 * beat
    var out: [RNote] = []
    for k in 0..<4 { out.append(RNote(t: Double(k) * beat, end: Double(k) * beat + 0.1, pitch: 37, vel: 62, ch: 9)) }
    func bassNote(_ pc: Int) -> Int { var p = 36 + pc % 12; if p > 43 { p -= 12 }; return p }
    let total = l.bars.count * l.choruses
    var seed: UInt64 = 0x2545F4914F6CDD1D
    func vary(_ range: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % (2 * range + 1) - range }
    for n in 0..<total {
        let c = l.bars[n % l.bars.count], next = l.bars[(n + 1) % l.bars.count]
        let t0 = lead + Double(n) * 4 * beat
        func at(_ b: Double) -> Double { t0 + b * beat }
        // Bass: root, third, fifth, then a half step into the next root.
        let r = bassNote(c.root)
        let nr = bassNote(next.root)
        let approach = next.root == c.root ? r + 9 : (n % 2 == 0 ? nr - 1 : nr + 1)
        let line = [r, r + (c.kind == "m7" ? 3 : 4), r + 7, approach]
        for (k, p) in line.enumerated() {
            out.append(RNote(t: at(Double(k)), end: at(Double(k) + 0.92), pitch: p, vel: [86, 74, 78, 72][k] + vary(4), ch: 1))
        }
        // Ride cymbal: every beat, with the swung skip note before beats three and one.
        for k in 0..<4 {
            out.append(RNote(t: at(Double(k)), end: at(Double(k)) + 0.1, pitch: 51, vel: (k % 2 == 1 ? 58 : 48) + vary(4), ch: 9))
            if k % 2 == 1 {
                out.append(RNote(t: at(Double(k) + 2.0 / 3), end: at(Double(k) + 2.0 / 3) + 0.1, pitch: 51, vel: 38 + vary(4), ch: 9))
                out.append(RNote(t: at(Double(k)), end: at(Double(k)) + 0.1, pitch: 44, vel: 50, ch: 9))
            }
        }
        if l.comp {
            // The Charleston rhythm: beat one, and the "and" of two.
            let shell = [c.third, c.seventh].map { pc in (52...63).first { $0 % 12 == pc } ?? 60 }
            for p in shell {
                out.append(RNote(t: at(0), end: at(1.3), pitch: p, vel: 44 + vary(3), ch: 5))
                out.append(RNote(t: at(1 + 2.0 / 3), end: at(2.8), pitch: p, vel: 38 + vary(3), ch: 5))
            }
        }
        if !l.calls.isEmpty, n % 4 == 0 {
            for s in jazzTune(l.calls[(n / 4) % l.calls.count], hand: 0) {
                out.append(RNote(t: at(s.beat), end: at(s.beat + s.dur * 0.9), pitch: s.pitch, vel: 78 + vary(5), ch: 0))
            }
        }
    }
    let end = lead + Double(total) * 4 * beat
    out.append(RNote(t: end, end: end + 2 * beat, pitch: bassNote(l.bars[0].root), vel: 84, ch: 1))
    out.append(RNote(t: end, end: end + 0.2, pitch: 49, vel: 56, ch: 9))
    return (out, lead, beat)
}

// What was heard in a solo, in two short sentences: something true, and one thing to try.
// `played` holds each note's start in beats from the first bar, its pitch and its length in beats.
func jazzFeedback(_ l: JazzLesson, _ played: [(beat: Double, pitch: Int, len: Double)]) -> String {
    let total = Double(l.bars.count * l.choruses * 4)
    let notes = played.filter { $0.beat > -0.5 && $0.beat < total + 1 }.sorted { $0.beat < $1.beat }
    guard notes.count >= 4 else { return "I hardly heard you. Jump in, there are no wrong notes here." }
    func chord(at beat: Double) -> JazzChord { l.bars[max(0, Int(beat / 4)) % l.bars.count] }
    let names = flatNames

    func scaleLine() -> String {
        let outside = notes.filter { !l.scale.contains($0.pitch % 12) }
        let share = 100 - outside.count * 100 / notes.count
        if outside.isEmpty { return "Every note was in the scale." }
        var counts: [Int: Int] = [:]
        for n in outside { counts[n.pitch % 12, default: 0] += 1 }
        let worst = counts.max { $0.value < $1.value }!.key
        return share >= 85 ? "\(share) percent in the scale. That is plenty." : "\(share) percent in the scale. The stray one was mostly \(names[worst])."
    }
    func spaceLine() -> String {
        var phrases = 1
        var sounding = 0.0
        var phraseStart = notes[0].beat, last = notes[0].beat + min(notes[0].len, 2)
        for n in notes.dropFirst() {
            if n.beat - last >= 1.5 { phrases += 1; sounding += last - phraseStart; phraseStart = n.beat }
            last = max(last, n.beat + min(n.len, 2))
        }
        sounding += last - phraseStart
        let silent = max(0, 1 - sounding / total)
        if silent < 0.2 { return "You played almost non stop. Next time, stop for a whole bar and let the band play." }
        if silent > 0.8 { return "Plenty of space, maybe too much. Say a little more." }
        return "\(phrases) phrases with room between them. That breathing is exactly right."
    }
    func swingLine() -> String {
        let offs = notes.map { $0.beat - floor($0.beat) }.filter { $0 > 0.3 && $0 < 0.92 }
        guard offs.count >= 4 else { return "I heard mostly notes on the beat. Add the short note that skips in before each beat." }
        let mean = offs.reduce(0, +) / Double(offs.count)
        if mean < 0.57 { return "Your short notes land halfway between beats, which is straight, not swung. Wait longer, then skip in late." }
        if mean > 0.8 { return "Your short notes are very late, almost on the next beat. Relax them a little earlier." }
        return "That swings. Your short notes sit late in the beat, where they belong."
    }
    func targetLine() -> String {
        var changes = 0, hits = 0
        for bar in 0..<(l.bars.count * l.choruses) {
            let c = l.bars[bar % l.bars.count]
            let prev = l.bars[(bar + l.bars.count - 1) % l.bars.count]
            if bar > 0, prev.root == c.root, prev.kind == c.kind { continue }
            changes += 1
            let start = Double(bar * 4)
            if let first = notes.first(where: { $0.beat >= start - 0.34 && $0.beat < start + 1.2 && $0.pitch >= 55 }),
               first.pitch % 12 == c.third || first.pitch % 12 == c.seventh { hits += 1 }
        }
        if hits == 0 { return "You did not catch a chord change yet. Listen for the bass moving, and land on \(names[l.bars[0].third]) or the next chord's third right then." }
        return hits * 2 >= changes ? "You landed on the third or seventh at \(hits) of \(changes) chord changes. That is what makes it sound like jazz." : "You caught \(hits) of \(changes) chord changes. Aim at the third just as the bass moves."
    }
    func shellLine() -> String {
        var good = 0
        let bars = l.bars.count * l.choruses
        for bar in 0..<bars {
            let c = l.bars[bar % l.bars.count]
            let start = Double(bar * 4)
            let low = Set(notes.filter { $0.pitch < 62 && $0.beat >= start - 0.4 && $0.beat < start + 3.5 }.map { $0.pitch % 12 })
            if low.contains(c.third), low.contains(c.seventh) { good += 1 }
        }
        if good * 10 >= bars * 8 { return "\(good) of \(bars) bars had the right shell. You are holding down the harmony like a real rhythm section." }
        return "\(good) of \(bars) bars had the right shell. Listen for the bass to tell you when the chord changes."
    }
    func callsLine() -> String {
        var answered = 0, over = 0, groups = 0
        for g in stride(from: 0.0, to: total, by: 16) {
            groups += 1
            if notes.contains(where: { $0.beat >= g + 7.5 && $0.beat < g + 16 }) { answered += 1 }
            if notes.filter({ $0.beat >= g + 0.5 && $0.beat < g + 7 }).count >= 3 { over += 1 }
        }
        if over * 2 > groups { return "You played while I was talking. Wait for my phrase to end, then answer." }
        return answered == groups ? "You answered every call. That is a real conversation." : "You answered \(answered) of \(groups) calls. Do not think, just reply."
    }

    switch l.goal {
    case .swing: return swingLine()
    case .scale: return scaleLine() + " " + spaceLine()
    case .space: return spaceLine() + " " + scaleLine()
    case .calls: return callsLine()
    case .shells: return shellLine()
    case .targets: return targetLine() + " " + spaceLine()
    case .free: return targetLine() + " " + swingLine()
    }
}

// MARK: - Ideas taught by the learn button in composition mode

struct ComposeIdea {
    var title: String
    var talk: String
    var chords: [String]    // each chord as note names, low to high
    var melody = ""         // optional tune on top, four beats per chord
}

let composeIdeas: [ComposeIdea] = [
    ComposeIdea(title: "The four chord loop",
                talk: "C, G, A minor, F. Hundreds of songs live on these four chords. Loop them in your left hand and hunt for a melody on top.",
                chords: ["C3 G3 C4 E4 G4", "G2 G3 B3 D4 G4", "A2 E3 A3 C4 E4", "F2 F3 A3 C4 F4"]),
    ComposeIdea(title: "Start on the sad one",
                talk: "The same four chords, starting on A minor: A minor, F, C, G. Nothing changed but the starting point, and hopeful became wistful.",
                chords: ["A2 E3 A3 C4 E4", "F2 F3 A3 C4 F4", "C3 G3 C4 E4 G4", "G2 G3 B3 D4 G4"]),
    ComposeIdea(title: "The sigh",
                talk: "F major, then F minor, then home to C. One note drops a half step, A to A flat, and the whole chord sighs. You already reach for this by instinct.",
                chords: ["C3 G3 C4 E4 G4", "F2 F3 A3 C4 F4", "F2 F3 Ab3 C4 F4", "C3 G3 C4 E4 G4"]),
    ComposeIdea(title: "The falling bass",
                talk: "Keep the chords simple and let the bass walk down one step at a time: C, B, A, G, F. The harmony barely moves but the ground keeps falling.",
                chords: ["C3 G3 C4 E4", "B2 G3 B3 D4", "A2 E3 A3 C4", "G2 E3 G3 C4", "F2 F3 A3 C4", "G2 G3 B3 D4", "C3 G3 C4 E4"]),
    ComposeIdea(title: "Minor, but hopeful",
                talk: "C minor to F major. A minor key normally has F minor here. The brighter F major is the Dorian sound, and it lets light into a sad key.",
                chords: ["C3 G3 C4 Eb4 G4", "F2 F3 A3 C4 F4", "C3 G3 C4 Eb4 G4", "F2 F3 A3 C4 F4"]),
    ComposeIdea(title: "The spotlight chord",
                talk: "C, E seven, A minor, F. E seven does not belong to C major. Its G sharp pulls hard into A minor, like a spotlight swinging onto the next chord.",
                chords: ["C3 G3 C4 E4 G4", "E2 E3 G#3 D4 E4", "A2 E3 A3 C4 E4", "F2 F3 A3 C4 F4"]),
    ComposeIdea(title: "The Spanish walk down",
                talk: "A minor, G, F, E. Each chord steps down, and the last one, E major, aches to go back to the start. It is called the Andalusian cadence.",
                chords: ["A2 E3 A3 C4 E4", "G2 G3 B3 D4", "F2 F3 A3 C4", "E2 E3 G#3 B3 E4"]),
    ComposeIdea(title: "A note that will not move",
                talk: "Hold C in the bass and change the chords above it: C, F, G, C. The stubborn bass note is called a pedal point. It builds tension without going anywhere.",
                chords: ["C3 C4 E4 G4", "C3 C4 F4 A4", "C3 B3 D4 G4", "C3 C4 E4 G4"]),
    ComposeIdea(title: "The swerve",
                talk: "C, F, G, and then, where the ear expects home, A minor. Setting up an ending and dodging it is called a deceptive cadence. It buys you another phrase.",
                chords: ["C3 G3 C4 E4 G4", "F2 F3 A3 C4 F4", "G2 G3 B3 D4 G4", "A2 E3 A3 C4 E4"]),
    ComposeIdea(title: "Question and answer",
                talk: "A melody idea. Play a phrase that ends up in the air, on D. Then play it again and end on C. The first asks, the second answers.",
                chords: ["C3 G3 C4", "G2 G3 B3", "C3 G3 C4", "G2 G3 B3", "C3 G3 C4"],
                melody: "E5 E5 F5 G5 G5 F5 E5 D5/1 E5 E5 F5 G5 G5 F5 D5 E5 C5/4"),
    ComposeIdea(title: "One idea, three times",
                talk: "Another melody idea. Take three notes. Play them, play them one step higher, then change the ending. Repeating with small changes is what makes a tune stick.",
                chords: ["C3 G3 C4", "A2 E3 A3", "F2 F3 A3", "G2 G3 B3", "C3 G3 C4"],
                melody: "E5 G5 C5/2 F5 A5 D5/2 G5 B5 E5/2 D5 B4 G4/2 C5/4"),
]

func ideaDemo(_ idea: ComposeIdea) -> [RNote] {
    let secs = idea.melody.isEmpty ? 2.2 : 2.4
    var out: [RNote] = []
    for (i, chord) in idea.chords.enumerated() {
        let t = Double(i) * secs
        for (k, name) in chord.split(separator: " ").enumerated() {
            guard let p = parseNoteName(String(name)) else { continue }
            // Slightly rolled, the way a hand lays a chord down.
            out.append(RNote(t: t + Double(k) * 0.035, end: t + secs + (i == idea.chords.count - 1 ? 1.2 : -0.05), pitch: p, vel: k == 0 ? 72 : 60))
        }
    }
    for n in jazzTune(idea.melody, hand: 0) {
        out.append(RNote(t: n.beat * secs / 4, end: (n.beat + n.dur * 0.95) * secs / 4, pitch: n.pitch, vel: 86))
    }
    return out.sorted { $0.t < $1.t }
}

extension Engine {
    func startJazz(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        guard index < jazzLessons.count else {
            run { g in self.say("That was the last lesson. The jam session is always there when you want it.", g) }
            return
        }
        let i = max(0, index)
        autosaveTake()
        jazzIdx = i
        mem.jazzLesson = i
        mem.save()
        waiting = false; paused = false
        accGen += 1
        midi.allOff()
        let l = jazzLessons[i]
        let head = "Jazz lesson \(i + 1) of \(jazzLessons.count). \(l.title). \(l.talk) "
        if let study = jazzStudy(i) {
            lesson = Lesson(song: study)
            unitIdx = 0
            review = nil
            mode = .teach
            present(prefix: head + howItWorks() + " First, learn this short study, a few notes at a time. ", full: true)
        } else {
            startJam(saying: head)
        }
    }

    // The band plays, the player improvises, and afterwards the tool says what it heard.
    func startJam(saying head: String = "") {
        lock.lock(); defer { lock.unlock() }
        guard let j = jazzIdx else { return }
        let l = jazzLessons[j]
        mode = .jazz
        ui("now Jazz \(j + 1): \(l.title), with the band")
        waiting = false
        accGen += 1
        let backing = jazzBacking(l)
        let ev = events(backing.notes)
        run { g in
            self.say(head + l.tip + self.intro("jam", " This part is free. There is no right or wrong note to find: just play along, and when the band stops I will tell you what I heard."), g)
            guard self.alive(g) else { return }
            let t0 = now() + backing.lead
            self.play(ev, g)
            guard self.alive(g) else { return }
            self.lock.lock()
            let played = self.history.filter { $0.t >= t0 - 1 }.map { n in
                (beat: (n.t - t0) / backing.beat, pitch: n.pitch, len: ((n.end < 0 ? n.t + 0.3 : n.end) - n.t) / backing.beat)
            }
            self.lock.unlock()
            let more = j + 1 < jazzLessons.count ? pick([" Top key to go again. Third key for the next lesson.", " Again, or on to the next lesson."]) : " Top key to go again."
            self.say(jazzFeedback(l, played) + more, g)
        }
    }

    // Returns true when the key was handled here.
    func jazzCommand(_ key: Int) -> Bool {
        guard mode == .jazz, let j = jazzIdx else { return false }
        switch key {
        case keyHear: startJam()
        case keyNotes:
            let l = jazzLessons[j]
            run { g in self.say("\(l.title). \(l.talk) \(l.tip)", g) }
        case keyNext: startJazz(j + 1)
        case keyBack: startJazz(j - 1)
        default: return false
        }
        return true
    }

    // The learn button in composition mode: one idea at a time, heard, then tried.
    func learnIdea() {
        let i = (mem.composeIdea ?? 0) % composeIdeas.count
        mem.composeIdea = i + 1
        mem.save()
        let idea = composeIdeas[i]
        let demo = ideaDemo(idea)
        // The pedal-point idea is heard on the piano alone, so the band's bass cannot spoil it.
        let ev = events(demo + (idea.title.contains("will not move") ? [] : bandParts(demo, analyse(demo))))
        takeClosed = true
        run { g in
            self.say("Idea \(i + 1) of \(composeIdeas.count). \(idea.title). \(idea.talk)", g)
            self.play(ev, g)
            guard self.alive(g) else { return }
            self.lock.lock()
            self.takeStart = now(); self.takeClosed = true; self.takeSaved = true
            self.lock.unlock()
            self.say(pick(["Your turn. Make it yours.", "Now you. Change anything you like.", "Try it your own way."]), g)
        }
    }
}

func jazzSelfTest(_ check: (String, Bool, String) -> Void) {
    var plans = 0
    for i in jazzLessons.indices {
        if let s = jazzStudy(i) {
            let l = Lesson(song: s)
            if !l.units.isEmpty, l.units.allSatisfy({ !l.stepsIn($0).isEmpty }) { plans += 1 }
        } else { plans += 1 }
    }
    check("jazz: every lesson has a workable study", plans == jazzLessons.count, "\(jazzLessons.count) lessons")
    let b = jazzBacking(jazzLessons[0])
    let bars = jazzLessons[0].bars.count * jazzLessons[0].choruses
    let bass = b.notes.filter { $0.ch == 1 }
    check("jazz: the band walks four bass notes a bar and swings the ride", bass.count == bars * 4 + 1 && b.notes.allSatisfy { $0.end > $0.t && (0...127).contains($0.pitch) } &&
          b.notes.contains { $0.ch == 9 && abs((($0.t - b.lead) / b.beat).truncatingRemainder(dividingBy: 1) - 2.0 / 3) < 0.01 }, "\(b.notes.count) notes, bass starts on \(sharpNames[bass[0].pitch % 12])")
    // A swung solo that lands on the thirds, and a straight one that does not.
    var swung: [(beat: Double, pitch: Int, len: Double)] = [], straight: [(beat: Double, pitch: Int, len: Double)] = []
    let six = jazzLessons[5]
    for bar in 0..<(six.bars.count * six.choruses) {
        let third = 60 + six.bars[bar % 12].third
        for k in 0..<2 {
            swung.append((Double(bar * 4 + k), third, 0.6)); swung.append((Double(bar * 4 + k) + 0.67, 60, 0.3))
            straight.append((Double(bar * 4 + k), 61, 0.5)); straight.append((Double(bar * 4 + k) + 0.5, 61, 0.5))
        }
    }
    let good = jazzFeedback(six, swung), poor = jazzFeedback(six, straight)
    check("jazz: hears thirds landed on chord changes", good.contains("landed") && poor.contains("did not catch"), good)
    let sw = jazzFeedback(jazzLessons[0], swung), st = jazzFeedback(jazzLessons[0], straight)
    check("jazz: tells swung playing from straight", sw.contains("swings") && st.contains("straight"), st)
    check("composition ideas: every idea has a demo the band can follow", composeIdeas.allSatisfy { let d = ideaDemo($0); return d.count >= 8 && !analyse(d).chords.isEmpty }, composeIdeas.map { i in let an = analyse(ideaDemo(i)); return an.keyName + ": " + an.chords.map { an.name($0) }.joined(separator: ", ") }.joined(separator: " | "))
}
