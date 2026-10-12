// Nova: a tiny MIDI companion for Logic Pro.
//  - Talk mode: a key makes Logic's instrument "say" a sentence using only notes.
//  - Teach mode: learn a song by ear, phrase by phrase, with spoken guidance.
// It listens to every MIDI keyboard and plays into Logic through its own
// virtual MIDI port called "Nova". Nothing is installed.

import Foundation
import Accelerate
import CoreMIDI
import AVFoundation
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Options and command keys

struct Opt {
    static var textMode = false   // print instead of speaking (VoiceOver reads it)
    static var fast = false       // self-test: no sleeping, no speech
    static var toPiano = false    // also send demo notes to the piano itself
    static var voiceVolume: Float = 0.6
}

// The eight highest white keys of the piano act as buttons. They are counted
// down from the top key, which the player teaches the tool on first run.
var keyHear = 108   // top key: start the lesson, or hear the current part again
var keyNotes = 107  // next white key down: say the notes of the current part
var keyNext = 105   // next: skip to the next part
var keyBack = 103   // next: go back one part
var keyTalk = 101   // next: talk mode on or off
var keyPause = 100  // next: pause, and carry on
var keyCompose = 98 // next: composition mode on or off
var keyHelp = 96    // next: help for the current mode
var keyKeep = 21    // the very lowest key of an 88-key piano: keep what was just played
var keyHome = 23    // the second lowest white key: leave any mode and go back to the start
var commandKeys: Set<Int> = [keyHear, keyNotes, keyNext, keyBack, keyTalk, keyPause, keyCompose, keyHelp, keyKeep, keyHome]

func setTopKey(_ top: Int) {
    var whites: [Int] = []
    var n = top
    while whites.count < 8, n >= 0 {
        if [0, 2, 4, 5, 7, 9, 11].contains(n % 12) { whites.append(n) }
        n -= 1
    }
    guard whites.count == 8 else { return }
    keyHear = whites[0]; keyNotes = whites[1]; keyNext = whites[2]; keyBack = whites[3]; keyTalk = whites[4]; keyPause = whites[5]; keyCompose = whites[6]; keyHelp = whites[7]
    commandKeys = Set(whites)
    // The keep key is the bottom key of a full-size piano. Smaller keyboards do not get one.
    keyKeep = top - 87
    if keyKeep >= 0 { commandKeys.insert(keyKeep) }
    keyHome = top - 85
    if keyHome >= 0 { commandKeys.insert(keyHome) }
}

// Everything the app remembers lives in one folder in the user's Library, never inside the app itself.
let baseDir: URL = {
    let dir = ProcessInfo.processInfo.environment["NOVA_HOME"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Nova")
    try? FileManager.default.createDirectory(at: dir.appendingPathComponent("ideas"), withIntermediateDirectories: true)
    return dir
}()

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

// MARK: - Link to the app window
// When the Nova app starts this tool it sets TP_UI=1 and reads these lines (each starts
// with "@") to show what is being said and played. Without the app, nothing extra is printed.
let uiOn = ProcessInfo.processInfo.environment["TP_UI"] == "1"
let uiQueue = DispatchQueue(label: "talking-piano.ui")
func ui(_ line: String) {
    guard uiOn else { return }
    uiQueue.async {
        fputs("@" + line.replacingOccurrences(of: "\n", with: " ") + "\n", stdout)
        fflush(stdout)
    }
}

// MARK: - Note names

let sharpNames = ["C", "C sharp", "D", "D sharp", "E", "F", "F sharp", "G", "G sharp", "A", "A sharp", "B"]
let flatNames = ["C", "D flat", "D", "E flat", "E", "F", "G flat", "G", "A flat", "A", "B flat", "B"]

func parseNoteName(_ s: String) -> Int? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if let n = Int(t) { return (0...127).contains(n) ? n : nil }
    let chars = Array(t.uppercased())
    guard let first = chars.first, let pc = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(first)] else { return nil }
    var i = 1
    var acc = 0
    if i < chars.count, chars[i] == "#" { acc = 1; i += 1 } else if i < chars.count, chars[i] == "B", i + 1 < chars.count { acc = -1; i += 1 }
    guard let oct = Int(String(chars[i...])) else { return nil }
    let n = 12 * (oct + 1) + pc + acc
    return (0...127).contains(n) ? n : nil
}

func chordName(_ pitches: [Int], names: [String]) -> String? {
    let pcs = Set(pitches.map { $0 % 12 })
    let shapes: [(Set<Int>, String)] = [
        ([0, 4, 7], "major"), ([0, 3, 7], "minor"), ([0, 3, 6], "diminished"), ([0, 4, 8], "augmented"),
        ([0, 4, 7, 10], "seventh"), ([0, 4, 7, 11], "major seventh"), ([0, 3, 7, 10], "minor seventh"),
        ([0, 5, 7], "sus four"), ([0, 2, 7], "sus two"),
    ]
    for root in pitches.map({ $0 % 12 }) {
        let rel = Set(pcs.map { ($0 - root + 12) % 12 })
        if let hit = shapes.first(where: { $0.0 == rel }) { return "\(names[root]) \(hit.1)" }
    }
    return nil
}

func chordText(_ pitches: [Int], names: [String]) -> String {
    let list = pitches.map { names[$0 % 12] }.joined(separator: ", ")
    if let n = chordName(pitches, names: names) { return "\(n) chord: \(list)" }
    return "\(list) together"
}

// MARK: - Songs

struct SNote { var beat: Double; var dur: Double; var pitch: Int; var vel: Int; var hand: Int } // hand 0 right, 1 left
struct Step { var beat: Double; var pitches: [Int] }
struct Song { var name: String; var bpm: Double; var notes: [SNote]; var remark: String = ""; var level: Int = 1; var chordGap: Double = 0.04; var fact: String = "" }

// Notes that start within `gap` beats of each other are one step: a chord.
func makeSteps(_ notes: [SNote], gap: Double = 0.04) -> [Step] {
    var out: [Step] = []
    for n in notes.sorted(by: { ($0.beat, $0.pitch) < ($1.beat, $1.pitch) }) {
        if let last = out.last, n.beat - last.beat < gap {
            if !out[out.count - 1].pitches.contains(n.pitch) { out[out.count - 1].pitches.append(n.pitch) }
        } else {
            out.append(Step(beat: n.beat, pitches: [n.pitch]))
        }
    }
    for i in out.indices { out[i].pitches.sort() }
    return out
}

// Standard MIDI file reader (formats 0 and 1).
func loadMIDIFile(_ url: URL, track only: String? = nil) -> Song? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let b = [UInt8](data)
    var pos = 0
    func u32() -> Int { defer { pos += 4 }; return pos + 4 <= b.count ? Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3]) : 0 }
    func u16() -> Int { defer { pos += 2 }; return pos + 2 <= b.count ? Int(b[pos]) << 8 | Int(b[pos + 1]) : 0 }
    guard b.count > 14, b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64 else { return nil }
    pos = 4
    let headerLen = u32()
    let format = u16(), trackCount = u16(), division = u16()
    guard division & 0x8000 == 0, division > 0 else { return nil }
    pos = 8 + headerLen
    var groups: [Int: [SNote]] = [:]
    var trackNames: [Int: String] = [:]
    var bpm = 120.0
    var gotTempo = false
    for track in 0..<trackCount {
        guard pos + 8 <= b.count, b[pos] == 0x4D, b[pos + 1] == 0x54, b[pos + 2] == 0x72, b[pos + 3] == 0x6B else { break }
        pos += 4
        let len = u32()
        let end = min(pos + len, b.count)
        var tick = 0
        var status: UInt8 = 0
        var open: [Int: (Int, Int)] = [:]
        func varLen() -> Int {
            var v = 0
            while pos < end { let c = b[pos]; pos += 1; v = v << 7 | Int(c & 0x7F); if c & 0x80 == 0 { break } }
            return v
        }
        while pos < end {
            tick += varLen()
            guard pos < end else { break }
            var s = b[pos]
            if s & 0x80 != 0 { pos += 1 } else { s = status }
            if s == 0xFF {
                guard pos < end else { break }
                let type = b[pos]; pos += 1
                let l = varLen()
                if type == 0x03, pos + l <= end, format == 1 {
                    trackNames[track] = String(decoding: b[pos..<pos + l], as: UTF8.self).lowercased()
                }
                if type == 0x51, l == 3, pos + 3 <= end, !gotTempo {
                    let us = Int(b[pos]) << 16 | Int(b[pos + 1]) << 8 | Int(b[pos + 2])
                    if us > 0 { bpm = 60_000_000.0 / Double(us); gotTempo = true }
                }
                pos += l
            } else if s == 0xF0 || s == 0xF7 {
                pos += varLen()
            } else if s >= 0x80 {
                status = s
                let kind = s & 0xF0, ch = Int(s & 0x0F)
                let needs = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                guard pos + needs <= end else { break }
                let d1 = Int(b[pos]), d2 = needs == 2 ? Int(b[pos + 1]) : 0
                pos += needs
                let key = ch * 128 + d1
                let group = format == 0 ? ch : track
                if kind == 0x90, d2 > 0, ch != 9 {
                    open[key] = (tick, d2)
                } else if kind == 0x80 || (kind == 0x90 && d2 == 0), let o = open[key] {
                    open[key] = nil
                    let beat = Double(o.0) / Double(division)
                    let dur = max(0.05, Double(tick - o.0) / Double(division))
                    groups[group, default: []].append(SNote(beat: beat, dur: dur, pitch: d1, vel: o.1, hand: 0))
                }
            } else {
                break
            }
        }
        pos = end
    }
    let keys = groups.keys.filter { !(groups[$0] ?? []).isEmpty && (only == nil || trackNames[$0] == only) }.sorted()
    guard !keys.isEmpty else { return nil }
    func mean(_ p: [SNote]) -> Double { Double(p.reduce(0) { $0 + $1.pitch }) / Double(p.count) }
    var notes: [SNote] = []
    var remark = ""
    if keys.count == 1 {
        notes = (groups[keys[0]] ?? []).map { var n = $0; n.hand = $0.pitch >= 60 ? 0 : 1; return n }
        remark = "Hands are split at middle C."
    } else {
        // A track's name decides its hand when it says so; otherwise the higher parts are the right hand.
        let means = keys.map { mean(groups[$0] ?? []) }
        let middle = ((means.min() ?? 60) + (means.max() ?? 60)) / 2
        for (i, k) in keys.enumerated() {
            let name = trackNames[k] ?? ""
            var hand = means[i] >= middle ? 0 : 1
            if ["right", "upper", "treble"].contains(where: { name.contains($0) }) { hand = 0 }
            else if ["left", "lower", "bass"].contains(where: { name.contains($0) }) { hand = 1 }
            notes += (groups[k] ?? []).map { var n = $0; n.hand = hand; return n }
        }
    }
    // Files recorded from a real performance are not on a grid: the notes of a chord land
    // a few hundredths of a second apart. For those, treat anything within 55 ms as together.
    let onGrid = notes.filter { abs(($0.beat * 12).rounded() - $0.beat * 12) < 0.02 }.count
    let loose = onGrid * 10 < notes.count * 6
    let first = notes.map { $0.beat }.min() ?? 0
    notes = notes.map { var n = $0; n.beat -= first; return n }
    return Song(name: url.deletingPathExtension().lastPathComponent, bpm: bpm, notes: notes, remark: remark,
                chordGap: loose ? max(0.04, 0.055 * bpm / 60) : 0.04)
}

// MARK: - Lesson plan

struct Unit { var hand: Int; var from: Int; var to: Int } // hand 2 means both hands

struct Lesson {
    var song: Song
    var names: [String]
    var bounds: [Double] = []          // phrase start beats
    var steps: [[Step]] = [[], [], []] // right, left, both
    var units: [Unit] = []

    init(song: Song) {
        self.song = song
        let pcs = song.notes.map { $0.pitch % 12 }
        let flats = pcs.filter { $0 == 10 || $0 == 3 || $0 == 8 }.count > pcs.filter { $0 == 6 || $0 == 1 }.count
        names = flats ? flatNames : sharpNames
        let right = song.notes.filter { $0.hand == 0 }, left = song.notes.filter { $0.hand == 1 }
        steps = [makeSteps(right, gap: song.chordGap), makeSteps(left, gap: song.chordGap), makeSteps(song.notes, gap: song.chordGap)]
        let lead = steps[0].isEmpty ? steps[1] : steps[0]
        // Cut the melody into short parts: at a pause once there are 4 steps, or at 8 steps
        // (6 for harder songs, so each part stays small).
        let longest = song.level >= 3 ? 6 : 8
        let gaps = zip(lead.dropFirst(), lead).map { $0.beat - $1.beat }.sorted()
        let median = gaps.isEmpty ? 1 : gaps[gaps.count / 2]
        var count = 0
        for (i, s) in lead.enumerated() {
            let gap = i > 0 ? s.beat - lead[i - 1].beat : 0
            if i == 0 || count >= longest || (count >= 4 && gap >= median * 2) { bounds.append(s.beat); count = 0 }
            count += 1
        }
        if bounds.isEmpty { bounds = [0] }
        bounds[0] = -1
        if steps[0].isEmpty || steps[1].isEmpty || handsOnly != "both" {
            // One hand: because the song has only one, or because the player uses one.
            let h = steps[0].isEmpty ? 1 : (steps[1].isEmpty ? 0 : (handsOnly == "left" ? 1 : 0))
            var previous: Int? = nil
            for k in bounds.indices where !stepsIn(Unit(hand: h, from: k, to: k)).isEmpty {
                units.append(Unit(hand: h, from: k, to: k))
                if let p = previous { units.append(Unit(hand: h, from: p, to: k)) }
                previous = k
            }
            if bounds.count > 2 { units.append(Unit(hand: h, from: 0, to: bounds.count - 1)) }
        } else {
            // Finish each part completely before the next: right hand, left hand, both,
            // then join it to the part before. This way real music appears early.
            var previous: Int? = nil
            for k in bounds.indices {
                let hasRight = !stepsIn(Unit(hand: 0, from: k, to: k)).isEmpty
                let hasLeft = !stepsIn(Unit(hand: 1, from: k, to: k)).isEmpty
                if hasRight { units.append(Unit(hand: 0, from: k, to: k)) }
                if hasLeft { units.append(Unit(hand: 1, from: k, to: k)) }
                if hasRight && hasLeft { units.append(Unit(hand: 2, from: k, to: k)) }
                if !hasRight && !hasLeft { continue }
                if let p = previous { units.append(Unit(hand: 2, from: p, to: k)) }
                previous = k
            }
            if bounds.count > 2 { units.append(Unit(hand: 2, from: 0, to: bounds.count - 1)) }
        }
    }

    func window(_ u: Unit) -> (Double, Double) {
        // Each part runs one note into the next, so the joins are practised from the start.
        (bounds[u.from], u.to + 1 < bounds.count ? bounds[u.to + 1] + 0.03 : .infinity)
    }

    func stepsIn(_ u: Unit) -> [Step] {
        let w = window(u)
        return steps[u.hand].filter { $0.beat >= w.0 - 0.02 && $0.beat < w.1 - 0.02 }
    }

    func notesIn(_ u: Unit) -> [SNote] {
        let w = window(u)
        return song.notes.filter { (u.hand == 2 || $0.hand == u.hand) && $0.beat >= w.0 - 0.02 && $0.beat < w.1 - 0.02 }
    }

    func intro(_ u: Unit) -> String {
        let hand = ["right hand", "left hand", "both hands"][u.hand]
        if u.from == u.to { return "Part \(u.from + 1), \(hand)." }
        if u.from == 0 && u.to == bounds.count - 1 { return "Now all of it, \(hand)." }
        return "Parts \(u.from + 1) and \(u.to + 1) together."
    }

    // An earlier part of the same hand with exactly the same notes, if there is one.
    func sameAs(_ u: Unit) -> Int? {
        guard u.from == u.to else { return nil }
        let mine = stepsIn(u).map { $0.pitches }
        for k in 0..<u.from where stepsIn(Unit(hand: u.hand, from: k, to: k)).map({ $0.pitches }) == mine { return k }
        return nil
    }

    func describe(_ list: [Step]) -> String {
        var parts: [String] = []
        var prev: Int? = nil
        for (i, s) in list.enumerated() {
            var t: String
            let low = s.pitches[0]
            if s.pitches.count == 1 {
                t = names[low % 12]
                if i == 0 { t = "Start on \(t), octave \(low / 12 - 1)" }
                else if let q = prev, abs(low - q) >= 5 { t = (low > q ? "up to " : "down to ") + t }
            } else {
                t = chordText(s.pitches, names: names)
                if i == 0 { t = "Start with \(t), lowest note in octave \(low / 12 - 1)" }
            }
            prev = s.pitches.last
            parts.append(t)
        }
        return parts.joined(separator: ", ") + "."
    }

    func describe(_ u: Unit) -> String {
        if u.hand < 2 { return describe(stepsIn(u)) }
        let r = stepsIn(Unit(hand: 0, from: u.from, to: u.to)), l = stepsIn(Unit(hand: 1, from: u.from, to: u.to))
        return (r.isEmpty ? "" : "Right hand. " + describe(r) + " ") + (l.isEmpty ? "" : "Left hand. " + describe(l))
    }
}

// MARK: - MIDI

struct Ev { var t: Double; var bytes: [UInt8] }

final class MidiIO {
    var client = MIDIClientRef()
    var source = MIDIEndpointRef()
    var inPort = MIDIPortRef()
    var outPort = MIDIPortRef()
    var connectedRefs: [MIDIEndpointRef] = []
    private var sounding = Set<[UInt8]>()   // channel, note: everything this tool has left ringing
    private let soundLock = NSLock()
    var onNote: ((Int, Int) -> Void)?   // pitch, velocity (0 means released)
    var onPedal: ((Bool) -> Void)?
    var sounds: Sounds?            // built-in instruments for the band
    var logicRunning = true        // refreshed every few seconds
    var pianoHere = false          // while a MIDI file plays: use the Mac's own piano, whatever Logic is doing
    var keyboards: [String] = [] { didSet { if keyboards != oldValue { ui("kbd " + keyboards.joined(separator: ", ")) } } }

    func start() {
        MIDIClientCreateWithBlock("Nova" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.connectSources() }
        }
        MIDISourceCreate(client, "Nova" as CFString, &source)
        MIDIOutputPortCreate(client, "Nova Out" as CFString, &outPort)
        MIDIInputPortCreateWithBlock(client, "Nova In" as CFString, &inPort) { [weak self] list, _ in
            for packet in list.unsafeSequence() {
                let len = Int(packet.pointee.length)
                let raw = UnsafeRawPointer(packet) + MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
                self?.parse(UnsafeRawBufferPointer(start: raw, count: len))
            }
        }
        connectSources()
    }

    func property(_ obj: MIDIObjectRef, _ key: CFString) -> String {
        var s: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(obj, key, &s)
        return (s?.takeRetainedValue() as String?) ?? ""
    }

    func uniqueID(_ obj: MIDIObjectRef) -> Int32 {
        var id: Int32 = 0
        MIDIObjectGetIntegerProperty(obj, kMIDIPropertyUniqueID, &id)
        return id
    }

    func connectSources() {
        // Start from scratch each time, so a keyboard that was unplugged and plugged back in works again.
        for old in connectedRefs { MIDIPortDisconnectSource(inPort, old) }
        connectedRefs = []
        let mine = uniqueID(source)
        var found: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let s = MIDIGetSource(i)
            let name = property(s, kMIDIPropertyDisplayName)
            if uniqueID(s) == mine || name.contains("Nova") || name.contains("Talking Piano") || name.contains("Logic") { continue }
            found.append(name)
            MIDIPortConnectSource(inPort, s, nil)
            connectedRefs.append(s)
        }
        keyboards = found
    }

    func parse(_ bytes: UnsafeRawBufferPointer) {
        var i = 0
        while i < bytes.count {
            let s = bytes[i]
            if s >= 0xF8 { i += 1; continue }
            if s == 0xF0 { while i < bytes.count && bytes[i] != 0xF7 { i += 1 }; i += 1; continue }
            if s < 0x80 { i += 1; continue }
            let kind = s & 0xF0
            let size = s >= 0xF0 ? (s == 0xF2 ? 3 : (s == 0xF1 || s == 0xF3 ? 2 : 1)) : ((kind == 0xC0 || kind == 0xD0) ? 2 : 3)
            if i + 2 < bytes.count {
                if kind == 0x90 { ui("on \(bytes[i + 1]) \(bytes[i + 2])"); onNote?(Int(bytes[i + 1]), Int(bytes[i + 2])) }
                else if kind == 0x80 { ui("on \(bytes[i + 1]) 0"); onNote?(Int(bytes[i + 1]), 0) }
                else if kind == 0xB0, bytes[i + 1] == 64 { onPedal?(bytes[i + 2] >= 64) }
            }
            i += size
        }
    }

    // Silences every note this tool started, so nothing is left stuck in Logic.
    func allOff() {
        soundLock.lock(); let notes = sounding; soundLock.unlock()
        for n in notes { send([0x80 | n[0], n[1], 0]) }
    }

    func send(_ bytes: [UInt8]) {
        if Opt.fast { return }
        if bytes.count == 3 {
            let id = [bytes[0] & 0x0F, bytes[1]]
            soundLock.lock()
            if bytes[0] & 0xF0 == 0x90, bytes[2] > 0 { sounding.insert(id) } else if bytes[0] & 0xE0 == 0x80 { sounding.remove(id) }
            soundLock.unlock()
        }
        // Band parts (every channel but the first) play on the built-in instruments.
        // The piano part goes to Logic, or to the built-in piano if Logic is not open.
        let ch = bytes[0] & 0x0F
        if uiOn, ch == 0, bytes.count == 3, bytes[0] & 0xE0 == 0x80 {
            ui("out \(bytes[1]) \(bytes[0] & 0xF0 == 0x90 ? bytes[2] : 0)")
        }
        if let s = sounds, s.ready, bytes.count == 3 {
            if ch != 0 { s.send(bytes); return }
            if pianoHere { s.send(bytes); return }
            if !logicRunning { s.send(bytes) }
        }
        var list = MIDIPacketList()
        let packet = MIDIPacketListInit(&list)
        _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
        MIDIReceived(source, &list)
        if Opt.toPiano {
            for i in 0..<MIDIGetNumberOfDestinations() { MIDISend(outPort, MIDIGetDestination(i), &list) }
        }
    }
}

// MARK: - Speech

// Measures the voice for the app window. The sentence is rendered a second time, silently and
// faster than it is spoken, and cut into sixtieths of a second; for each one the strength of
// sixteen bands of pitch, low to high, is sent to the window. The window plays them back in
// step with the real voice, so what moves on screen is the actual sound of each syllable.
final class VoiceMeter {
    private let synth = AVSpeechSynthesizer()
    private let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: 512)
    private let queue = DispatchQueue(label: "talking-piano.meter", qos: .utility)
    private var id = 0
    static let bands = 16

    init() { vDSP_hann_window(&window, 512, Int32(vDSP_HANN_NORM)) }

    /// The same measurement for a finished recording (16-bit mono), used with the Kokoro voice.
    func measure(wav data: Data) {
        id += 1
        let mine = id
        ui("spec \(mine) new")
        queue.async {
            guard data.count > 46 else { return }
            let rate = Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) })
            let count = (data.count - 44) / 2
            var samples = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { raw in
                for i in 0..<count { samples[i] = Float(raw.loadUnaligned(fromByteOffset: 44 + i * 2, as: Int16.self)) / 32768 }
            }
            let hop = rate / 60
            var frame = 0
            var text = "", first = 0
            while Int(Double(frame) * hop) + 512 <= samples.count, mine == self.id {
                let at = Int(Double(frame) * hop)
                text += self.bands(Array(samples[at..<at + 512]), rate: rate)
                frame += 1
                if frame % 60 == 0 { ui("spec \(mine) \(first) \(text)"); text = ""; first = frame }
            }
            if !text.isEmpty, mine == self.id { ui("spec \(mine) \(first) \(text)") }
        }
    }

    func measure(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) {
        id += 1
        let mine = id
        ui("spec \(mine) new")
        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        if let v = voice { u.voice = v }
        var samples: [Float] = []
        var done = 0            // samples already turned into frames
        var frame = 0
        var hop = 367.0
        DispatchQueue.main.async {
            if self.synth.isSpeaking { self.synth.stopSpeaking(at: .immediate) }
            self.synth.write(u) { [weak self] buffer in
                guard let self = self, let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
                let n = Int(pcm.frameLength)
                var chunk = [Float](repeating: 0, count: n)
                if let f = pcm.floatChannelData { for i in 0..<n { chunk[i] = f[0][i] } }
                else if let d = pcm.int16ChannelData { for i in 0..<n { chunk[i] = Float(d[0][i]) / 32768 } }
                else if let d = pcm.int32ChannelData { for i in 0..<n { chunk[i] = Float(d[0][i]) / 2147483648 } }
                let rate = pcm.format.sampleRate
                self.queue.async {
                    guard mine == self.id else { return }
                    hop = rate / 60
                    samples += chunk
                    var text = ""
                    let first = frame
                    while Int(Double(frame) * hop) + 512 <= samples.count {
                        let at = Int(Double(frame) * hop)
                        text += self.bands(Array(samples[at..<at + 512]), rate: rate)
                        frame += 1
                    }
                    done = Int(Double(frame) * hop)
                    _ = done
                    if !text.isEmpty { ui("spec \(mine) \(first) \(text)") }
                }
            }
        }
    }

    // Sixteen letters, one per band, "a" for silence up to "p" for full strength.
    private func bands(_ x: [Float], rate: Double) -> String {
        guard let setup = setup else { return String(repeating: "a", count: VoiceMeter.bands) }
        var input = [Float](repeating: 0, count: 512)
        vDSP_vmul(x, 1, window, 1, &input, 1, 512)
        var real = [Float](repeating: 0, count: 256), imag = [Float](repeating: 0, count: 256)
        var mags = [Float](repeating: 0, count: 256)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 256) { vDSP_ctoz($0, 2, &split, 1, 256) }
                }
                vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, 256)
            }
        }
        var out = ""
        let lowest = 90.0, highest = min(7000.0, rate / 2 - 100)
        for b in 0..<VoiceMeter.bands {
            let f0 = lowest * pow(highest / lowest, Double(b) / Double(VoiceMeter.bands))
            let f1 = lowest * pow(highest / lowest, Double(b + 1) / Double(VoiceMeter.bands))
            let i0 = max(1, Int(f0 / rate * 512)), i1 = max(i0 + 1, min(256, Int(f1 / rate * 512) + 1))
            var energy: Float = 0
            for i in i0..<i1 { energy += mags[i] }
            // Turned into loudness as the ear hears it: about 50 decibels of range.
            let db = 10 * log10(max(1e-9, energy / Float(i1 - i0)) / 4000)
            let level = max(0, min(1, (db + 50) / 50))
            out.append(Character(UnicodeScalar(UInt8(97 + Int(level * 15 + 0.5)))))
        }
        return out
    }
}

final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var waiting: [ObjectIdentifier: DispatchSemaphore] = [:]
    private var startedAny = false
    private var useProcess = false
    private var proc: Process?
    private lazy var meter = VoiceMeter()
    var usingFastVoice: Bool { lock.lock(); defer { lock.unlock() }; return startedAny && !useProcess }

    // Proper voices only (no novelty ones), best quality first.
    static let voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") && !$0.identifier.contains("eloquence") && ($0.identifier.contains("com.apple.voice.") || $0.name == "Alex" || $0.identifier.contains("siri")) }
        .sorted { ($0.quality.rawValue, $0.language == "en-US" ? 1 : 0) > ($1.quality.rawValue, $1.language == "en-US" ? 1 : 0) }
    static let voiceFile = baseDir.appendingPathComponent("voice.txt")
    private(set) var voice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synth.delegate = self
        // The voice chosen last time, or else the best-sounding one installed.
        let saved = (try? String(contentsOf: Speaker.voiceFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        voice = Speaker.voices.first { $0.identifier == saved } ?? Speaker.voices.first
    }

    // Switches to the next installed voice and remembers it.
    func nextVoice() -> String {
        // The Kokoro voices come first; after the last of them, the Mac's own voice.
        if Kokoro.shared.state == .ready {
            if let k = Kokoro.shared.nextVoice() { ui("voice \(k) (Kokoro)"); return k }
            ui("voice " + (voice?.name ?? "Mac"))
            return (voice?.name ?? "the Mac voice") + ", the Mac's own voice"
        }
        guard !Speaker.voices.isEmpty else { return "No other voices" }
        let i = Speaker.voices.firstIndex { $0.identifier == voice?.identifier } ?? -1
        let v = Speaker.voices[(i + 1) % Speaker.voices.count]
        voice = v
        ui("voice " + v.name)
        try? v.identifier.write(to: Speaker.voiceFile, atomically: true, encoding: .utf8)
        return v.name
    }

    // Blocks until the sentence has been spoken or stop() is called.
    func say(_ text: String) {
        if Opt.textMode || Opt.fast { print(text); return }
        // The caption appears at the moment the voice starts, not before: with the Kokoro voice
        // there is a short wait while the sound is prepared, and longer just after launch.
        var shown = false
        defer { if shown { ui("done") } }
        if Kokoro.shared.usable() {
            if Kokoro.shared.say(text, meter: uiOn ? meter : nil, onStart: { ui("say " + text); shown = true }) { return }
        }
        if !shown { ui("say " + text); shown = true }
        lock.lock(); let slow = useProcess; lock.unlock()
        if slow { sayWithProcess(text); return }
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.5
        u.volume = Opt.voiceVolume
        if let v = voice { u.voice = v }
        if uiOn { meter.measure(text, voice: voice, rate: u.rate) }
        let sem = DispatchSemaphore(value: 0)
        lock.lock(); waiting[ObjectIdentifier(u)] = sem; lock.unlock()
        DispatchQueue.main.async { self.synth.speak(u) }
        if sem.wait(timeout: .now() + 3) == .timedOut {
            lock.lock(); let ok = startedAny; if !ok { useProcess = true }; lock.unlock()
            if ok { _ = sem.wait(timeout: .now() + 120); return }
            // The in-process voice never started, so use the say command from now on.
            DispatchQueue.main.async { self.synth.stopSpeaking(at: .immediate) }
            sayWithProcess(text)
        }
    }

    private func sayWithProcess(_ text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-r", "195", text.hasPrefix("-") ? " " + text : text]
        lock.lock(); proc = p; lock.unlock()
        do { try p.run() } catch { print(text); return }
        p.waitUntilExit()
    }

    func stop() {
        Kokoro.shared.stop()
        lock.lock()
        for (_, sem) in waiting { sem.signal() }
        waiting = [:]
        if let p = proc, p.isRunning { p.terminate() }
        lock.unlock()
        DispatchQueue.main.async { if self.synth.isSpeaking { self.synth.stopSpeaking(at: .immediate) } }
    }

    // Used when quitting: makes sure this copy is silent before it goes away.
    func silenceNow() {
        stop()
        if Thread.isMainThread { synth.stopSpeaking(at: .immediate) }
        else { DispatchQueue.main.sync { _ = self.synth.stopSpeaking(at: .immediate) } }
    }

    private func finish(_ u: AVSpeechUtterance) {
        lock.lock(); let sem = waiting.removeValue(forKey: ObjectIdentifier(u)); lock.unlock()
        sem?.signal()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        ui("start")
        lock.lock(); startedAny = true; lock.unlock()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        ui("word \(characterRange.location) \(characterRange.length)")
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish(utterance) }
}

// Turn a spoken sentence into bursts of notes that copy the shape of the voice.
func speechToNotes(_ text: String) -> [Ev]? {
    let path = NSTemporaryDirectory() + "talking-piano-\(getpid())-\(Int(now() * 1000)).wav"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-r", "110", "-o", path, "--data-format=LEI16@22050", text.hasPrefix("-") ? " " + text : text]
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let b = [UInt8](data)
    var pos = 12
    var samples: [Float] = []
    while pos + 8 <= b.count {
        let size = Int(b[pos + 4]) | Int(b[pos + 5]) << 8 | Int(b[pos + 6]) << 16 | Int(b[pos + 7]) << 24
        if b[pos] == 0x64, b[pos + 1] == 0x61, b[pos + 2] == 0x74, b[pos + 3] == 0x61 {
            let end = min(pos + 8 + size, b.count)
            var i = pos + 8
            samples.reserveCapacity((end - i) / 2)
            while i + 1 < end { samples.append(Float(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8)) / 32768); i += 2 }
            break
        }
        pos += 8 + size + (size & 1)
    }
    guard samples.count > 2000 else { return nil }

    let sr = 22050.0, frame = 0.045
    let hop = Int(sr * frame)
    let lowNote = 36, highNote = 100
    let frames = samples.count / hop
    var mags = [[Float]](repeating: [Float](repeating: 0, count: highNote - lowNote + 1), count: frames)
    var peak: Float = 0
    for n in lowNote...highNote {
        let f = 440.0 * pow(2.0, Double(n - 69) / 12.0)
        let len = min(2048, max(400, Int(sr * 10 / f)))
        var cosT = [Float](repeating: 0, count: len), sinT = [Float](repeating: 0, count: len)
        var wsum: Float = 0
        for k in 0..<len {
            let w = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(len - 1)))
            let ph = 2 * Double.pi * f * Double(k) / sr
            cosT[k] = w * Float(cos(ph)); sinT[k] = w * Float(sin(ph)); wsum += w
        }
        let tilt = Float(pow(f / 200.0, 0.5))
        for fi in 0..<frames {
            let start = fi * hop + hop / 2 - len / 2
            var re: Float = 0, im: Float = 0
            let a = max(0, -start), z = min(len, samples.count - start)
            if a < z { for k in a..<z { let x = samples[start + k]; re += x * cosT[k]; im += x * sinT[k] } }
            let m = (re * re + im * im).squareRoot() / wsum * tilt
            mags[fi][n - lowNote] = m
            peak = max(peak, m)
        }
    }
    guard peak > 0 else { return nil }

    let floorDB: Float = -32, voices = 9
    var events: [Ev] = []
    var held: [Int: (vel: Int, age: Int)] = [:]
    for fi in 0..<frames {
        let t = Double(fi) * frame * 1.5  // played slower than spoken, which is easier to follow
        let row = mags[fi]
        var cands: [(Int, Float)] = []
        for i in row.indices {
            let db = 20 * log10(max(row[i], 1e-9) / peak)
            if db < floorDB { continue }
            if (i > 0 && row[i - 1] > row[i]) || (i + 1 < row.count && row[i + 1] > row[i]) { continue }
            cands.append((i + lowNote, db))
        }
        cands.sort { $0.1 > $1.1 }
        var want: [Int: Int] = [:]
        for c in cands.prefix(voices) { want[c.0] = 25 + Int((c.1 - floorDB) / -floorDB * 95) }
        for (n, _) in held where want[n] == nil {
            events.append(Ev(t: t, bytes: [0x80, UInt8(n), 0])); held[n] = nil
        }
        for (n, v) in want {
            if let h = held[n], v <= h.vel + 12, h.age < 4 { held[n] = (h.vel, h.age + 1); continue }
            if held[n] != nil { events.append(Ev(t: t, bytes: [0x80, UInt8(n), 0])) }
            events.append(Ev(t: t + 0.001, bytes: [0x90, UInt8(n), UInt8(min(127, v))]))
            held[n] = (v, 0)
        }
    }
    let endT = Double(frames) * frame * 1.5
    for (n, _) in held { events.append(Ev(t: endT, bytes: [0x80, UInt8(n), 0])) }
    return events
}

// MARK: - Engine

enum Mode { case idle, talk, teach, compose, menu, jazz, logic, reaper }

final class Engine {
    let lock = NSRecursiveLock()
    let midi: MidiIO
    let speaker = Speaker()
    var gen = 0
    var mode = Mode.idle { didSet { if mode != oldValue { ui("mode \(mode)") } } }
    var songs: [Song] = []
    var songIdx = 0
    var lesson: Lesson?
    var unitIdx = 0
    var curSteps: [Step] = []
    var waiting = false
    var stepIdx = 0
    var pressed = Set<Int>()
    var mistakes = 0
    var missesHere = 0
    var stepTimes: [Double] = []
    var attempts = 0
    var verdictOverride: String? = nil
    var missAt: [Int: Int] = [:]               // misses per note of the current part
    var drill: (clean: Int, tries: Int)? = nil  // set while one trouble spot is being fixed
    var review: Unit? = nil                     // a part being recalled from memory as a warm-up
    var reviewed = Set<String>()
    var early = Set<Int>()
    var lateOK = Set<Int>()       // chord notes that may still arrive after the step moved on
    var lateUntil = 0.0
    var idleToken = 0
    var accompany: [SNote] = []   // the other hand's notes, when the tool plays along
    var accGen = 0
    var menuPick: Int? = nil      // the song last previewed in the song menu
    var topDownAt: Double? = nil  // when the top key went down, to tell a press from a hold
    var lastMistake = 0.0
    var tempo = 0.7
    var talkMap: [Int: String] = [:]
    var talkCache: [Int: [Ev]] = [:]
    var progress: [String: Int] = [:]
    let progressURL = baseDir.appendingPathComponent("progress.json")
    let topKeyURL = baseDir.appendingPathComponent("top-key.txt")
    var awaitingTop = false
    var paused = false { didSet { if paused != oldValue { ui("paused \(paused ? 1 : 0)") } } }
    var pauseToldAt = 0.0
    // Composition: after listening to a take, playing again carries the same piece on.
    let live = LiveBand()
    var liveTimer: DispatchSourceTimer?
    var resumeUntil = 0.0          // until this moment the next note continues the take
    var resumePressedAt = 0.0      // when the listening button was pressed
    var reaperStack: [RScreen] = []
    var typedThen: ((String) -> ROut)? = nil
    var typedScreen: RScreen? = nil
    var lastNotesPress = 0.0
    var metroToken = 0
    var metroBPM = 80
    var earTarget: Int? = nil          // the note to find in the ear training game
    var earRound = 0, earMisses = 0, earFirstTry = 0
    var lastGift: [RNote]? = nil       // a piece the assistant made up, in case the player wants to keep it
    var giftName = "", giftAt = 0.0
    var jamOn = false, jamFrom = 0.0, jamToken = 0
    let daw = Daw()                    // the DAW assistant: checked operations on a real project
    var dawForced = false              // the self-test's stand-in project is in use
    var dawMode = ((try? String(contentsOf: baseDir.appendingPathComponent("daw-mode.txt"), encoding: .utf8)) ?? "assisted").trimmingCharacters(in: .whitespacesAndNewlines)
    var pendingConfirm: (() -> Void)? = nil
    var pendingSentence: String? = nil
    var pendingUntil = 0.0
    var lastSpoken = ""
    var lastSpokenAt = 0.0             // when the assistant last finished speaking
    var warnedNoAI = false
    let ears = Ears()
    var lastFiles: [URL] = []          // files just read out, so "open it" knows which
    var lastFilesAt = 0.0
    var pretendApp: String? = nil      // lets the self-test stand in for an open app and its menus
    var pretendMenus: [MenuEntry] = []
    var lastFrontApp: String? = nil    // the app that was in front the last time something was asked
    var sequencing = false             // one part of "do this, then that" is being carried out
    var spotifyPausedAt = 0.0          // when Spotify was last paused by asking, so a plain "play" can bring it back
    var pretendSpotify = false         // lets the self-test check requests that depend on Spotify playing
    var guessedName = false            // the name was only guessed at: act on nothing but an unmistakable request
    var casualHearing = false          // the sentence came without the name, in the moments after it spoke
    var aiRouting = false              // the AI has named a command and it is being carried out
    var talk: [String] = []            // the last few things said to and by the AI, so it can follow a conversation
    var learned: [String: String] = [:]   // ways of saying things that it has been taught
    var lastRequest = ""                  // the last sentence addressed to it
    var correcting: String? = nil         // a sentence it was told it got wrong, waiting to be put right
    var secondPass = false             // a loosely worded sentence is being retried in plain words
    var lastWakeAt = -100.0, lastWakeReply = "", wakeCount = 0
    var pretendReaper = false          // lets the self-test check REAPER sentences without REAPER
    var homeIdx = 0               // the item last named in the home menu
    var typing = "name"           // what the typed text is for: a name, or a question
    var lastSummary = ""          // the latest description of a composition, for the AI
    var remarkToken = 0
    var lastRemark = 0.0
    var logicPath: [String]? = nil   // nil in the quick list; otherwise the menu being browsed
    var logicItems: [String] = []
    var logicIdx = 0
    var naming = false {          // a name is being typed on the computer
        didSet { if naming != oldValue { ui("typing \(naming ? 1 : 0)") } }
    }
    var nameBytes: [UInt8] = []
    var namingTake: [RNote] = []
    var lastTopPress = 0.0
    var namingRequested = false   // used by the self-test in place of a real double press
    var jazzIdx: Int? = nil       // the jazz lesson in progress
    var menuJazz: Int? = nil
    var lastComposePress = 0.0
    var mem = Memory.load()
    var takeSaved = true
    var resumeWaiting = false
    var lastPauseToggle = 0.0
    var lastStopPress = 0.0
    // Everything played is kept here so an idea is never lost.
    var history: [RNote] = []
    var openIdx: [Int: Int] = [:]
    var sustained = Set<Int>()
    var pedalDown = false
    var takeStart = 0.0
    var takeClosed = true
    var lastOnset = 0.0
    var variationIdx = 0
    var roundOn = false
    var roundDelay = 4.0
    var roundHeld = Set<Int>()
    var heardPiano = false

    init(midi: MidiIO) {
        self.midi = midi
        songs = loadLibrary()
        if let last = try? String(contentsOf: baseDir.appendingPathComponent("last-song.txt"), encoding: .utf8),
           let i = songs.firstIndex(where: { $0.name == last.trimmingCharacters(in: .whitespacesAndNewlines) }),
           !(mem.dropped ?? []).contains(songs[i].name) { songIdx = i }
        if let d = try? Data(contentsOf: progressURL), let p = try? JSONDecoder().decode([String: Int].self, from: d) { progress = p }
        if let t = try? String(contentsOf: topKeyURL, encoding: .utf8), let n = Int(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
            setTopKey(n)
        } else {
            awaitingTop = true
        }
        loadSentences()
    }

    func askForTopKey() {
        lock.lock(); awaitingTop = true; waiting = false; lock.unlock()
        run { g in self.say("Press the highest key on your piano.", g) }
    }

    func loadSentences() {
        talkMap = [60: "Hello \(You.name)", 62: "I am a piano, and I can talk", 64: "{time}", 65: "Logic Pro", 67: "Play me something beautiful"]
        guard let text = try? String(contentsOf: baseDir.appendingPathComponent("sentences.txt"), encoding: .utf8) else { return }
        var map: [Int: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let n = parseNoteName(String(parts[0])), !commandKeys.contains(n) {
                map[n] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        if !map.isEmpty { talkMap = map }
    }

    func alive(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return g == gen }

    // Cancels whatever is speaking or playing, then runs the new script in the background.
    func run(_ body: @escaping (Int) -> Void) {
        lock.lock(); gen += 1; let g = gen; lock.unlock()
        speaker.stop()
        if Opt.fast { body(g) } else { DispatchQueue.global(qos: .userInitiated).async { body(g) } }
    }

    /// Cuts off whatever is being said or played, at once.
    func interrupt() {
        lock.lock(); gen += 1; lock.unlock()
        speaker.stop()
        Kokoro.shared.duck(false)
        midi.allOff()
        lastSpokenAt = now() - 1
    }

    func say(_ text: String, _ g: Int) {
        guard alive(g) else { return }
        lastSpoken = text
        lastSpokenAt = now() + 30      // still speaking
        speaker.say(text)
        lastSpokenAt = now()
        if pendingConfirm != nil || pendingSentence != nil { ears.expectAnswer() } else { ears.voiceFinished() }
    }

    func play(_ events: [Ev], _ g: Int) {
        if Opt.fast { return }
        // When the band plays, the piano part is played here too, on the Mac's own piano, so the
        // two are mixed in one place and the piano is always clearly on top. (Sent to Logic, its
        // level depends on whatever track happens to be selected, and it can vanish under the band.)
        let withBand = events.contains { $0.bytes[0] & 0xF0 == 0x90 && $0.bytes[0] & 0x0F != 0 && $0.bytes[0] & 0x0F != 4 }
        if withBand { midi.pianoHere = true }
        defer { if withBand { midi.pianoHere = false } }
        let sorted = events.sorted { ($0.t, $0.bytes[0] & 0xF0) < ($1.t, $1.bytes[0] & 0xF0) }
        let start = now()
        var sounding = Set<[UInt8]>()   // channel, note
        for e in sorted {
            while now() - start < e.t {
                if !alive(g) { for n in sounding { midi.send([0x80 | n[0], n[1], 0]) }; return }
                usleep(UInt32(max(200, min(5000, (e.t - (now() - start)) * 1e6))))
            }
            midi.send(e.bytes)
            let id = [e.bytes[0] & 0x0F, e.bytes[1]]
            if e.bytes[0] & 0xF0 == 0x90 { sounding.insert(id) } else { sounding.remove(id) }
        }
    }

    func demoEvents(_ u: Unit, speed: Double = 1) -> [Ev] {
        guard let l = lesson else { return [] }
        return demoEvents(l.notesIn(u), speed: speed)
    }

    func demoEvents(_ notes: [SNote], speed: Double = 1) -> [Ev] {
        guard let l = lesson, let first = notes.map({ $0.beat }).min() else { return [] }
        let secPerBeat = 60 / l.song.bpm / (tempo * speed)
        return notes.flatMap { n -> [Ev] in
            let t = (n.beat - first) * secPerBeat
            return [Ev(t: t, bytes: [0x90, UInt8(n.pitch), UInt8(max(1, min(127, n.vel)))]),
                    Ev(t: t + max(0.08, n.dur * secPerBeat * 0.95), bytes: [0x80, UInt8(n.pitch), 0])]
        }
    }

    func saveProgress() {
        guard let l = lesson else { return }
        progress[l.song.name] = unitIdx
        mem.lastSong = l.song.name
        mem.save()
        if !Opt.fast, let d = try? JSONEncoder().encode(progress) { try? d.write(to: progressURL) }
    }

    func chooseSong(_ i: Int) {
        lock.lock(); defer { lock.unlock() }
        guard songs.indices.contains(i) else { return }
        autosaveTake()
        jazzIdx = nil
        songIdx = i
        if !Opt.fast { try? songs[i].name.write(to: baseDir.appendingPathComponent("last-song.txt"), atomically: true, encoding: .utf8) }
        let l = Lesson(song: songs[i])
        lesson = l
        mem.dropped?.removeAll { $0 == l.song.name }     // picking a song yourself brings it back
        unitIdx = min(progress[l.song.name] ?? 0, max(0, l.units.count - 1))
        mode = .teach
        let twoHands = !l.steps[0].isEmpty && !l.steps[1].isEmpty
        mem.lastSong = l.song.name
        mem.save()
        // Coming back to a song starts with recalling the last finished part from memory,
        // without hearing it first. Recalling is what makes it stick.
        review = nil
        if unitIdx > 0, !Opt.fast, reviewed.insert(l.song.name).inserted {
            review = l.units[..<unitIdx].last { $0.from == $0.to && ($0.hand == 2 || !twoHands) }
        }
        if review != nil {
            present(prefix: "\(l.song.name). " + pick(["Warm up first, from memory. ", "First, from memory. "]), full: true)
            return
        }
        let start = unitIdx > 0 && l.units.indices.contains(unitIdx)
            ? " " + pick(["Carrying on at", "Back to", "Picking up at"]) + " part \(l.units[unitIdx].to + 1) of \(l.bounds.count)."
            : (l.song.fact.isEmpty ? "" : " " + l.song.fact) + " \(l.bounds.count) short parts." + (twoHands ? " Each one goes right hand, left hand, then both." : "") + howItWorks()
        present(prefix: "\(l.song.name).\(start) ", full: true)
    }

    func present(prefix: String = "", full: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let l = lesson, l.units.indices.contains(unitIdx) else { return }
        let u = review ?? l.units[unitIdx]
        let recall = review != nil && full
        ui("now \(l.song.name): part \(u.to + 1) of \(l.bounds.count), \(["right hand", "left hand", "both hands"][u.hand])")
        drill = nil
        // The button keys can never be asked for as notes, or the lesson could not be passed.
        curSteps = l.stepsIn(u).compactMap { s in
            let p = s.pitches.filter { !commandKeys.contains($0) }
            return p.isEmpty ? nil : Step(beat: s.beat, pitches: p)
        }
        if curSteps.isEmpty { curSteps = l.stepsIn(u) }
        waiting = false
        // Asking to hear a part again plays it slower: slowing down is how hard spots get fixed.
        let demo = demoEvents(u, speed: full ? 1 : 0.75)
        let twin = full && !recall ? l.sameAs(u) : nil
        if full { attempts = 0 }
        accGen += 1
        accompany = []
        // Left hand alone becomes a duet: the right hand just learned is played along softly,
        // at the player's pace, so the two are heard fitting together before both are tried.
        var duet = ""
        if u.hand == 1, u.from == u.to, !recall {
            accompany = l.notesIn(Unit(hand: 0, from: u.from, to: u.to))
            if !accompany.isEmpty, full { duet = intro("duet", " I will play the right hand softly along with you.") }
        }
        stepIdx = 0; pressed = []; early = []; lateOK = []
        // Always the same clear order: what this is, the demo, then "your turn" and the
        // names of the notes. A new single-hand part gets its notes read out; parts that only
        // combine what was just learned do not. Listening starts the moment the demo ends, and
        // playing the first right note cuts off whatever is still being said.
        let steps = curSteps
        let names = full && !recall && u.hand < 2 && u.from == u.to ? " " + l.describe(steps) : ""
        let hears = twin == nil && !recall
        run { g in
            if full {
                if !Opt.fast, prefix.isEmpty { usleep(350_000) }
                self.say(prefix + l.intro(u) + (twin.map { " Same as part \($0 + 1)." } ?? "") + duet + (hears ? " Listen." : ""), g)
            }
            if hears { self.play(demo, g) }
            guard self.alive(g) else { return }
            self.beginWaiting(g)
            self.say(pick(["Your turn.", "Now you.", "Over to you.", "Have a go."]) + names, g)
        }
    }

    // Soft bell sounds on the built-in music box, used in place of spoken comments.
    func chime(_ notes: [Int], vel: UInt8 = 58, hold: Double = 0.6) {
        if Opt.fast { return }
        for (i, n) in notes.enumerated() {
            let p = UInt8(max(0, min(127, n)))
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.12 * Double(i)) {
                self.midi.send([0x94, p, vel])
                DispatchQueue.global().asyncAfter(deadline: .now() + hold) { self.midi.send([0x84, p, 0]) }
            }
        }
    }

    // A short wooden knock: the one and only sound for a wrong note.
    func knock() {
        if Opt.fast { return }
        midi.send([0x99, 77, 66])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { self.midi.send([0x89, 77, 0]) }
    }

    // Says which note is wanted, with the direction to move if a wrong one was just played,
    // then plays it once so the name and the sound go together.
    func tellNote(after wrong: Int? = nil) {
        guard let l = lesson, curSteps.indices.contains(stepIdx) else { return }
        let target = curSteps[stepIdx].pitches
        var text = target.count > 1 ? chordText(target, names: l.names) : l.names[target[0] % 12]
        if let w = wrong, target.count == 1 {
            text = ((w - target[0]) % 12 == 0 ? (w > target[0] ? "An octave lower. " : "An octave higher. ") : (w > target[0] ? "Lower. " : "Higher. ")) + text
        } else if wrong == nil {
            text = "Next is " + text
        }
        run { g in
            self.say(text + ".", g)
            guard self.alive(g) else { return }
            self.hint()
        }
    }

    // Plays the note or chord the lesson is waiting for.
    func hint() {
        guard curSteps.indices.contains(stepIdx) else { return }
        let target = curSteps[stepIdx].pitches
        if Opt.fast { return }
        for p in target { midi.send([0x94, UInt8(p), 52]) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { for p in target { self.midi.send([0x84, UInt8(p), 0]) } }
    }

    // If nothing right has been played for a while, give the hint without being asked.
    func armIdleHint() {
        if Opt.fast { return }
        idleToken += 1
        let token = idleToken
        DispatchQueue.global().asyncAfter(deadline: .now() + 7) {
            self.lock.lock(); defer { self.lock.unlock() }
            if token == self.idleToken, self.waiting, !self.paused, self.mode == .teach { self.tellNote() }
        }
    }

    func beginWaiting(_ g: Int) {
        lock.lock(); defer { lock.unlock() }
        guard g == gen else { return }
        waiting = true; stepIdx = 0; pressed = []; early = []; lateOK = []; mistakes = 0; missesHere = 0; stepTimes = []; missAt = [:]
        armIdleHint()
    }

    // Compares the gaps between the player's notes with the song's, ignoring overall speed.
    func rhythmVerdict() -> String {
        let beats = curSteps.map { $0.beat }
        guard beats.count >= 4, stepTimes.count == beats.count else { return "Clean. " }
        let played = zip(stepTimes.dropFirst(), stepTimes).map { $0 - $1 }
        let wanted = zip(beats.dropFirst(), beats).map { $0 - $1 }
        let total = played.reduce(0, +), totalBeats = wanted.reduce(0, +)
        guard total > 0.3, totalBeats > 0 else { return "Clean. " }
        let scale = total / totalBeats
        let off = zip(played, wanted).map { abs($0 - $1 * scale) }.reduce(0, +) / total
        return off < 0.2 ? "Clean, and in time. " : "Right notes. The rhythm was a little uneven. "
    }

    // Help interrupts a lesson's "your turn", so put the lesson back to listening afterwards.
    func resumeAfterHelp(_ g: Int) {
        lock.lock(); defer { lock.unlock() }
        if g == gen, mode == .teach, !paused, lesson != nil, !curSteps.isEmpty, !waiting, stepIdx < curSteps.count { waiting = true }
    }

    // Instructions are spoken in full the first two times a mode is opened. After that
    // only the mode's name is said; the help button still gives the full version.
    func intro(_ key: String, _ text: String) -> String {
        let url = baseDir.appendingPathComponent("intros.json")
        var heard = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url))) ?? [:]
        let n = heard[key] ?? 0
        heard[key] = n + 1
        if !Opt.fast, let d = try? JSONEncoder().encode(heard) { try? d.write(to: url) }
        return n < 2 ? text : ""
    }

    // Home: from anywhere, stops everything, saves an unsaved composition, and goes back to
    // the starting point, where every mode can be reached.
    func goHome() {
        autosaveTake()
        mode = .idle
        earTarget = nil
        jamOn = false
        ui("now ")
        homeIdx = 0
        paused = false; waiting = false; naming = false; roundOn = false
        jazzIdx = nil; review = nil; drill = nil
        accGen += 1; idleToken += 1
        midi.allOff()
        run { g in
            self.say(pick(["Back home.", "Home again.", "Home, all quiet."]) + self.intro("home2", " The third and fourth keys step through everything I can do: lessons, the song menu, jazz, composition, ask me anything, and Logic control. The top key opens the one you heard."), g)
        }
    }

    // Said the first two times any lesson starts.
    func howItWorks() -> String {
        intro("howlesson", " How this works. I play a short part, then tell you its notes, then you play it. A knock means a wrong note. Miss the same note twice and I tell you which note it is. I always say when you have it right. The second key from the top repeats the notes whenever you like.")
    }

    func togglePause() {
        let t = now()
        if !Opt.fast, t - lastPauseToggle < 0.35 { return }   // one press, even if the key bounces
        lastPauseToggle = t
        roundOn = false
        midi.allOff()
        accGen += 1
        guard mode == .teach, lesson != nil else {
            // Outside a lesson there is nothing to hold, so this is a stop button. Pressed twice
            // quickly it switches the live band on or off.
            if !Opt.fast, t - lastStopPress < 0.9 { lastStopPress = 0; toggleLive(); return }
            lastStopPress = t
            live.silence()
            run { g in self.say(pick(["Okay, stopped.", "All quiet now.", "Stopping there."]), g) }
            return
        }
        if !paused {
            paused = true
            resumeWaiting = waiting
            waiting = false
            run { g in self.say(pick(["Paused for now.", "Okay, paused."]), g) }
        } else if resumeWaiting, curSteps.indices.contains(stepIdx) {
            // Pick up at the exact note, without replaying the part.
            paused = false
            pressed = []; stepTimes = []
            let n = stepIdx + 1, total = curSteps.count
            run { g in
                self.say(n == 1 ? "Carrying on, from the first note." : "Carrying on. You are on note \(n) of \(total).", g)
                self.lock.lock()
                if g == self.gen { self.waiting = true }
                self.lock.unlock()
            }
        } else {
            paused = false
            present(prefix: "Carrying on. ", full: true)
        }
    }

    func command(_ key: Int) {
        lock.lock(); defer { lock.unlock() }
        if key == keyHelp { let text = helpText(); run { g in self.say(text, g); self.resumeAfterHelp(g) }; return }
        if key == keyHome { goHome(); return }
        if key == keyKeep { keepLast(); return }
        if key == keyPause { togglePause(); return }
        if key == keyCompose { paused = false }   // an idea beats a pause
        if paused {
            // Frozen until the pause key is pressed again. Say so, instead of seeming broken.
            let t = now()
            if t - pauseToldAt > 4 {
                pauseToldAt = t
                run { g in self.say("Paused. Press the sixth key, or Return, to carry on.", g) }
            }
            return
        }
        if key == keyTalk { autosaveTake() }
        if composeCommand(key) { return }
        if menuCommand(key) { return }
        if jazzCommand(key) { return }
        if logicCommand(key) { return }
        if reaperCommand(key) { return }
        if homeCommand(key) { return }
        switch key {
        case keyTalk:
            mode = mode == .talk ? .idle : .talk
            waiting = false
            let on = mode == .talk
            run { g in self.say(on ? "Talk mode." + self.intro("talk", " Try middle C, D, E, F or G.") : "Talk mode off.", g) }
        case keyHear:
            if mode != .teach || lesson == nil { chooseSong(songIdx) } else { present(full: false) }
        case keyNotes:
            guard mode == .teach, let l = lesson, l.units.indices.contains(unitIdx) else { return }
            let u = l.units[unitIdx]
            let rest = u.hand < 2 && curSteps.indices.contains(stepIdx) && stepIdx > 0
            let text = rest ? "Next. " + l.describe(Array(curSteps[stepIdx...])) : l.intro(u) + " " + l.describe(u)
            run { g in self.say(text, g); self.resumeAfterHelp(g) }
        case keyNext, keyBack:
            guard mode == .teach, let l = lesson else { return }
            let target = unitIdx + (key == keyNext ? 1 : -1)
            if target < 0 || target >= l.units.count {
                // In a jazz lesson, past the study is the jam; before it is the previous lesson.
                if let j = jazzIdx { if target < 0 { startJazz(j - 1) } else { startJam() }; return }
                // Past either end of a song moves to the neighbouring song.
                chooseSong((songIdx + (target < 0 ? songs.count - 1 : 1)) % songs.count)
                return
            }
            unitIdx = target
            review = nil
            saveProgress()
            present(full: true)
        default: break
        }
    }

    func noteOn(_ pitch: Int) {
        lock.lock(); defer { lock.unlock() }
        if awaitingTop {
            awaitingTop = false
            setTopKey(pitch)
            if !Opt.fast { try? String(pitch).write(to: topKeyURL, atomically: true, encoding: .utf8) }
            loadSentences()
            let name = sharpNames[pitch % 12]
            run { g in self.say("Got it. Your top key is \(name), octave \(pitch / 12 - 1). Press it again to start a lesson. The eighth white key down from it is help. It tells you what every button does.", g) }
            return
        }
        if commandKeys.contains(pitch) { command(pitch); return }
        if paused { return }
        if mode == .idle, !heardPiano {
            heardPiano = true
            run { g in self.say("I can hear your piano. Press your top key to start a lesson.", g) }
            return
        }
        switch mode {
        case .idle: if !earNote(pitch) { if jamOn { armJam() } else { armRemark() } }
        case .jazz, .logic, .reaper: break
        case .compose: speaker.stop()   // playing skips any instructions still being spoken
        case .menu: menuNote(pitch)
        case .talk:
            guard let template = talkMap[pitch] else { return }
            let cached = talkCache[pitch]
            run { g in
                var events = cached
                if events == nil {
                    let f = DateFormatter(); f.dateFormat = "h:mm a"
                    let text = template.replacingOccurrences(of: "{time}", with: "It is " + f.string(from: Date()))
                    events = speechToNotes(text)
                    if events != nil, !template.contains("{time}") {
                        self.lock.lock(); self.talkCache[pitch] = events; self.lock.unlock()
                    }
                }
                if let e = events { self.play(e, g) }
            }
        case .teach:
            guard waiting, let l = lesson, curSteps.indices.contains(stepIdx) else { return }
            // A chord's last note arriving a moment late belongs to that chord, not to what follows.
            if lateOK.contains(pitch), now() < lateUntil { lateOK.remove(pitch); return }
            let expected = Set(curSteps[stepIdx].pitches)
            if expected.contains(pitch) {
                gen += 1; speaker.stop()   // playing the right note hushes any talking
                pressed.insert(pitch)
                while stepIdx < curSteps.count {
                    // Chords of four or more notes pass with one note missing (two for six or more).
                    let all = Set(curSteps[stepIdx].pitches)
                    let need = all.count <= 3 ? all.count : (all.count <= 5 ? all.count - 1 : all.count - 2)
                    guard pressed.count >= need else { break }
                    lateOK = all.subtracting(pressed); lateUntil = now() + 0.35
                    stepTimes.append(now())
                    accompanyStep(stepIdx)
                    stepIdx += 1; missesHere = 0
                    armIdleHint()
                    // Notes that were played a touch early already count towards the next step.
                    pressed = stepIdx < curSteps.count ? early.intersection(curSteps[stepIdx].pitches) : []
                    early = []
                }
                if stepIdx == curSteps.count { finishUnit() }
                return
            }
            // Two notes that sound almost together in the song may be played in either order.
            if stepIdx + 1 < curSteps.count, curSteps[stepIdx + 1].pitches.contains(pitch),
               (curSteps[stepIdx + 1].beat - curSteps[stepIdx].beat) * 60 / l.song.bpm < 0.25 {
                early.insert(pitch)
                return
            }
            // A smudge of several wrong keys at once counts as one slip.
            let t = now()
            if !Opt.fast, t - lastMistake < 0.12 { return }
            lastMistake = t
            mistakes += 1; missesHere += 1
            missAt[stepIdx, default: 0] += 1
            // Every wrong note gets the same short knock, so there is never any doubt. The
            // second miss on the same note is answered with the note's name and which way to
            // go, and again on every third miss after that.
            knock()
            ui("flash wrong")
            if missesHere == 2 || (missesHere > 2 && (missesHere - 2) % 3 == 0) { tellNote(after: pitch) }
        }
    }

    // One trouble spot: the note that kept going wrong, with the note before and after it.
    // It is played slowly, then repeated until it comes out right twice in a row. Fixing the
    // exact spot, slowly, until it is stable is what the best practisers do; replaying the
    // whole part is not.
    func startDrill(around i: Int, _ l: Lesson) {
        let lo = max(0, i - 1), hi = min(curSteps.count - 1, i + 1)
        let spot = Array(curSteps[lo...hi])
        let endBeat = hi + 1 < curSteps.count ? curSteps[hi + 1].beat : Double.infinity
        let u = review ?? l.units[unitIdx]
        let notes = l.notesIn(u).filter { $0.beat >= spot[0].beat - 0.02 && $0.beat < endBeat - 0.02 }
        let demo = demoEvents(notes, speed: 0.6)
        curSteps = spot
        drill = (0, 0)
        accompany = []; accGen += 1
        run { g in
            self.say(pick(["Just this spot, slowly.", "One spot to fix. Slowly.", "Only these few notes."]) + " Listen.", g)
            self.play(demo, g)
            guard self.alive(g) else { return }
            self.beginWaiting(g)
            self.say("Your turn. " + l.describe(spot), g)
        }
    }

    func finishUnit() {
        guard let l = lesson else { return }
        waiting = false
        idleToken += 1
        attempts += 1
        if var d = drill {
            d.tries += 1
            d.clean = mistakes == 0 ? d.clean + 1 : 0
            if d.clean < 2, d.tries < 5 {
                drill = d
                let word = mistakes == 0 ? "Right. Once more to be sure." : "Not yet. Again."
                run { g in
                    self.beginWaiting(g)
                    self.say(word, g)
                }
                return
            }
            drill = nil
            verdictOverride = mistakes == 0 ? "Fixed. " : "Good enough for now. "
        } else if mistakes > max(3, curSteps.count), attempts < 2, review == nil {
            // Far more wrong notes than right ones: start the part over, with the demo and the notes.
            let keep = attempts
            present(prefix: "That was mostly wrong notes. Here it is again. ", full: true)
            attempts = keep
            return
        } else if curSteps.count >= 4, let worst = missAt.filter({ $0.value >= 2 }).max(by: { $0.value < $1.value })?.key {
            startDrill(around: worst, l)
            return
        }
        if review != nil {
            review = nil
            present(prefix: pick(["Still there. Carrying on. ", "Good. On we go. "]), full: true)
            return
        }
        // Always say plainly how the part went, then move on.
        var verdict = mistakes == 0 ? pick(["That's correct. ", "Yes, that's right. ", "That's it, well done. ", "Spot on. "])
                                    : (mistakes == 1 ? "Done, with one wrong note. " : "Done, with \(mistakes) wrong notes. ")
        if let v = verdictOverride { verdict = v; verdictOverride = nil }
        if mistakes == 0 { chime([84, 88, 91]); ui("flash good") }
        if unitIdx + 1 >= l.units.count, jazzIdx != nil {
            // The study is learned: bring in the band.
            unitIdx = 0
            startJam(saying: verdict + "You have the study. ")
            return
        }
        if unitIdx + 1 >= l.units.count {
            unitIdx = 0
            saveProgress()
            mode = .idle
            run { g in
                if !Opt.fast { usleep(500_000) }
                self.say(verdict + pick(["That is the whole song. You learned \(l.song.name).", "All of it, start to finish. \(l.song.name) is yours now.", "Done. You can play \(l.song.name)."]), g)
            }
            return
        }
        let word = milestone(from: l.units[unitIdx], to: l.units[unitIdx + 1], in: l)
        if l.units[unitIdx].hand == 2, l.units[unitIdx].from == l.units[unitIdx].to { mem.partsLearned += 1 }
        unitIdx += 1
        saveProgress()
        present(prefix: verdict + word, full: true)
    }

    func listSongs() {
        let text = (1...5).filter { l in songs.contains { $0.level == l } }.map { l in "\(levelNames[l - 1]): " + songs.filter { $0.level == l }.map { $0.name }.joined(separator: ", ") }.joined(separator: ". ")
        let more = songs.count < 20 ? " To add your own, put MIDI files in a folder called Nova Songs, inside your Music folder." : ""
        run { g in self.say("\(self.songs.count) songs. " + text + "." + more, g) }
    }

    func help() {
        let text = helpText() + " On the computer, slash opens the full list on screen."
        run { g in self.say(text, g); self.resumeAfterHelp(g) }
    }
}

// MARK: - Self-test

func selfTest(_ engine: Engine, _ midi: MidiIO) -> Never {
    Opt.fast = true
    // The checks were written around one person and one name, and still speak in those terms.
    Profile.current = Profile(user: "Sam", assistant: "Jarvis", city: "", fahrenheit: false, about: "", plays: true, done: true)
    engine.awaitingTop = false
    setTopKey(108)
    var ok = true
    func check(_ name: String, _ pass: Bool, _ detail: String = "") {
        print((pass ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  (" + detail + ")"))
        if !pass { ok = false }
    }
    var visible = false
    for i in 0..<MIDIGetNumberOfSources() where midi.property(MIDIGetSource(i), kMIDIPropertyDisplayName).contains("Nova") { visible = true }
    check("virtual port visible to other apps", visible)
    var testKeys = MIDIEndpointRef()
    MIDISourceCreate(midi.client, "Loopback Test Keys" as CFString, &testKeys)
    usleep(300_000)
    midi.connectSources()
    var got = -1
    midi.onNote = { p, v in if v > 0 { got = p } }
    var list = MIDIPacketList()
    let packet = MIDIPacketListInit(&list)
    _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, 3, [0x90, 61, 90] as [UInt8])
    // The Mac's MIDI service can take a moment to join a brand new source to the tool, so the
    // key is pressed again every so often until it arrives, for up to three seconds.
    for _ in 0..<15 where got < 0 { MIDIReceived(testKeys, &list); usleep(200_000) }
    midi.onNote = nil
    MIDIEndpointDispose(testKeys)
    check("a key press on a MIDI keyboard reaches the tool", got == 61)
    print("keyboards found: \(midi.keyboards.isEmpty ? "none" : midi.keyboards.joined(separator: ", "))")
    var plans = 0, broken: [String] = []
    for s in engine.songs {
        let l = Lesson(song: s)
        if !l.units.isEmpty && l.units.allSatisfy({ !l.stepsIn($0).isEmpty }) { plans += 1 } else { broken.append(s.name) }
    }
    check("every song in the library makes a lesson plan", broken.isEmpty, broken.isEmpty ? "\(plans) songs" : "broken: " + broken.joined(separator: ", "))
    let perLevel = (1...5).map { l in engine.songs.filter { $0.level == l }.count }
    let reachable = engine.songs.indices.filter { engine.menuKey(forSong: $0) != nil }.count
    check("song menu: every song has its own piano key", reachable == engine.songs.count && Set(engine.songs.indices.compactMap { engine.menuKey(forSong: $0) }).count == reachable,
          "songs per level: " + perLevel.map { String($0) }.joined(separator: ", "))
    engine.openMenu()
    let pickKey = engine.menuKey(forSong: 1) ?? 0
    engine.noteOn(pickKey)
    let previewed = engine.mode == .menu && engine.menuPick == 1
    engine.noteOn(pickKey)
    check("song menu: one press previews, a second press starts the lesson", previewed && engine.mode == .teach && engine.songIdx == 1)
    // Play the first song perfectly and expect to reach the end.
    engine.progress = [:]
    engine.chooseSong(engine.songs.firstIndex { $0.name == "Ode to Joy" } ?? 0)
    var guardCount = 0
    while engine.mode == .teach, guardCount < 5000 {
        guardCount += 1
        guard engine.waiting else { check("lesson waits for the player", false); break }
        for p in engine.curSteps[engine.stepIdx].pitches { engine.noteOn(p) }
    }
    check("perfect playing completes the song", engine.mode == .idle)
    engine.chooseSong(engine.songs.firstIndex { $0.name == "Ode to Joy" } ?? 0)
    guardCount = 0
    var repeats = 0, lastUnit = -1, sameUnit = 0
    while engine.mode == .teach, guardCount < 20000 {
        guardCount += 1
        guard engine.waiting else { break }
        if engine.unitIdx == lastUnit, engine.stepIdx == 0 { sameUnit += 1; repeats = max(repeats, sameUnit) } else if engine.unitIdx != lastUnit { sameUnit = 0 }
        lastUnit = engine.unitIdx
        engine.noteOn(30)   // a wrong note before every right one
        let unitNow = engine.unitIdx
        for p in engine.curSteps[engine.stepIdx].pitches where engine.unitIdx == unitNow && engine.mode == .teach { engine.noteOn(p) }
    }
    check("sloppy playing still gets through the song, never being held back", engine.mode == .idle && repeats == 0, "most repeats of one part: \(repeats)")
    engine.chooseSong(0)
    let wrong = engine.curSteps[0].pitches[0] + 1
    engine.noteOn(wrong)
    check("wrong note counts as a slip and does not advance", engine.mistakes == 1 && engine.stepIdx == 0)
    for i in 0..<2 { for p in engine.curSteps[i].pitches { engine.noteOn(p) } }
    engine.command(keyPause)
    engine.noteOn(engine.curSteps[2].pitches[0])
    engine.command(keyNext)
    let frozen = engine.paused && !engine.waiting && engine.stepIdx == 2 && engine.unitIdx == 0
    engine.command(keyPause)
    check("pause freezes the lesson, and resumes at the same note", frozen && !engine.paused && engine.waiting && engine.stepIdx == 2 && engine.mistakes == 1)
    // Miss the third note twice, then finish the part: only that spot should be drilled.
    engine.chooseSong(engine.songs.firstIndex { $0.name == "Ode to Joy" } ?? 0)
    let whole = engine.curSteps.count
    for (i, st) in engine.curSteps.enumerated() {
        if i == 2 { engine.noteOn(30); engine.noteOn(31) }
        for p in st.pitches { engine.noteOn(p) }
    }
    let drilling = engine.drill != nil && engine.curSteps.count == 3 && engine.unitIdx == 0
    for _ in 0..<2 { for st in engine.curSteps { for p in st.pitches { engine.noteOn(p) } } }
    check("a note missed twice gets a short drill of just that spot, then the lesson moves on", drilling && engine.drill == nil && engine.unitIdx == 1, "\(whole) notes in the part, 3 in the drill")
    engine.chooseSong(engine.songs.firstIndex { $0.name == "Ode to Joy" } ?? 0)
    composeSelfTest { check($0, $1, $2) }
    mindSelfTest { check($0, $1, $2) }
    jazzSelfTest { check($0, $1, $2) }
    aliveSelfTest(engine) { check($0, $1, $2) }
    brainSelfTest(engine) { check($0, $1, $2) }
    delightSelfTest(engine) { check($0, $1, $2) }
    dawSelfTest(engine) { check($0, $1, $2) }
    earsSelfTest(engine) { check($0, $1, $2) }
    looseSelfTest(engine) { check($0, $1, $2) }
    learnSelfTest(engine) { check($0, $1, $2) }
    reaperSelfTest(engine) { check($0, $1, $2) }
    engine.startJazz(0)
    let inStudy = engine.mode == .teach && engine.jazzIdx == 0
    engine.command(keyNext); for _ in 0..<40 where engine.mode == .teach { engine.command(keyNext) }
    check("jazz: a lesson goes from the study into the jam", inStudy && engine.mode == .jazz)
    engine.jazzIdx = nil; engine.mode = .idle
    greetSelfTest(engine) { check($0, $1, $2) }
    homeSelfTest(engine) { check($0, $1, $2) }
    moreSelfTest(engine) { check($0, $1, $2) }
    appsSelfTest(engine) { check($0, $1, $2) }
    extrasSelfTest(engine) { check($0, $1, $2) }
    updateSelfTest(engine) { check($0, $1, $2) }
    let loud = Sounds.offlineCheck()
    check("built-in band instruments make sound", loud > 0.01, String(format: "peak level %.2f", loud))
    // Skipping past the end of a song moves to the next song.
    engine.chooseSong(0)
    engine.unitIdx = (engine.lesson?.units.count ?? 1) - 1
    engine.command(keyNext)
    check("skipping past the last part goes to the next song", engine.songIdx == 1 && engine.mode == .teach)
    engine.noteEvent(keyHear, 100)
    usleep(1_400_000)
    engine.noteEvent(keyHear, 0)
    check("holding the top key opens the song menu", engine.mode == .menu)
    engine.command(keyCompose)
    engine.noteEvent(keyHear, 100)
    usleep(1_400_000)
    engine.noteEvent(keyHear, 0)
    check("in composition mode, holding the top key never leaves composition mode", engine.mode == .compose)
    let saved = engine.lastSavedIdea()
    for m in [Mode.compose, .jazz, .menu, .talk, .teach] {
        engine.mode = m; engine.paused = m == .teach
        engine.command(keyHome)
        if engine.mode != .idle || engine.paused { ok = false; print("FAIL home key from \(m)") }
    }
    check("the home key leaves every mode, even a paused lesson", engine.mode == .idle)
    engine.mode = .compose
    engine.namingRequested = true
    engine.command(keyHear)
    let asking = engine.naming
    for c in Array("My Tune!".utf8) + [127, 13] { engine.nameKey(c) }
    // (On a fresh install there is no saved piece yet, so there is nothing to name.)
    check("double press of the top key asks for a name and takes typing", saved == nil || asking && !engine.naming && String(decoding: engine.nameBytes, as: UTF8.self) == "My Tune")
    engine.mode = .idle
    check("the last saved piece can be loaded back for replay", (saved?.count ?? 0) >= 3 || saved == nil, saved.map { "\($0.count) notes, \(Int($0.last?.end ?? 0)) seconds" } ?? "no saved ideas")
    engine.command(keyCompose)
    engine.chooseSong(1)
    engine.command(keyHelp)
    check("help does not disturb the lesson", engine.waiting && engine.mode == .teach, engine.helpText().prefix(40) + "...")
    engine.mode = .idle
    // Play a short idea through the live path and ask what it was.
    engine.chooseSong(0)
    engine.command(keyPause)
    engine.command(keyCompose)
    check("the composition key starts a new composition from anywhere, even a paused lesson", engine.mode == .compose && !engine.paused && engine.notes(since: engine.takeStart).isEmpty)
    engine.command(keyCompose)
    check("pressing it again inside composition mode starts a fresh one", engine.mode == .compose)
    engine.command(keyCompose)
    engine.mode = .idle
    engine.mode = .idle
    let before = engine.history.count
    for (i, p) in [60, 64, 67, 72, 76].enumerated() { engine.record(p, 80, now() - 3 + Double(i) * 0.4); engine.record(p, 0, now() - 2.8 + Double(i) * 0.4) }
    let kept = engine.lastStretch()
    check("keep key: finds what was just played, without recording having been started", kept.count == 5 && engine.history.count == before + 5, "\(kept.count) notes")
    engine.command(keyCompose)
    for p in [48, 64, 67, 72] { engine.noteEvent(p, 80); usleep(60_000); engine.noteEvent(p, 0) }
    let live = engine.notes(since: engine.takeStart)
    check("composition: live playing is captured as a take", engine.mode == .compose && live.count == 4 && live.allSatisfy { $0.end > $0.t }, "\(live.count) notes")
    engine.command(keyNotes)
    engine.command(keyCompose)
    Opt.fast = false
    // The spoken check is only run when asked for, because it talks out loud through the speakers.
    if CommandLine.arguments.contains("--aloud") {
        let v0 = now()
        engine.speaker.say("Test.")
        let v1 = now()
        engine.speaker.say("Test.")
        let v2 = now()
        engine.speaker.say("Higher.")
        check("voice starts without delay", engine.speaker.usingFastVoice && now() - v2 < 1.5, String(format: "\(engine.speaker.voice?.name ?? "default voice"): first word %.2f s, then %.2f s and %.2f s", v1 - v0, v2 - v1, now() - v2))
    }
    Opt.textMode = true
    let t0 = now()
    if let ev = speechToNotes("Hello \(You.name)") {
        let ons = ev.filter { $0.bytes[0] == 0x90 }
        let offs = ev.filter { $0.bytes[0] == 0x80 }
        check("speech becomes notes", ons.count > 40 && ons.count == offs.count,
              "\(ons.count) notes over \(String(format: "%.1f", ev.map { $0.t }.max() ?? 0)) s, built in \(String(format: "%.2f", now() - t0)) s")
    } else {
        check("speech becomes notes", false)
    }
    print(ok ? "ALL PASS" : "SOME FAILED")
    exit(ok ? 0 : 1)
}

// MARK: - Main

let args = CommandLine.arguments.dropFirst()
Opt.textMode = args.contains("--text")

// Only one copy may run. A new copy asks the old one to quit and waits until it has gone,
// so opening the app several times never leaves several copies talking over each other.
let instanceLock = open(baseDir.appendingPathComponent(".running").path, O_CREAT | O_RDWR, 0o644)
func becomeOnlyCopy() {
    var tries = 0
    while flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
        var buf = [UInt8](repeating: 0, count: 32)
        let n = pread(instanceLock, &buf, 31, 0)
        if n > 0, let pid = Int32(String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), pid != getpid(), pid > 1 {
            kill(pid, tries < 30 ? SIGTERM : SIGKILL)
        }
        tries += 1
        usleep(100_000)
    }
    let me = Array("\(getpid())\n".utf8)
    ftruncate(instanceLock, 0)
    pwrite(instanceLock, me, me.count, 0)
}
if let i = args.firstIndex(of: "--drop"), i + 1 < CommandLine.arguments.count {
    // Sets a song aside for good: ./talking-piano --drop "<song name>". Run it while the app is closed.
    let name = CommandLine.arguments[i + 1]
    var mem = Memory.load()
    var list = mem.dropped ?? []
    if !list.contains(name) { list.append(name) }
    mem.dropped = list
    if mem.lastSong == name { mem.lastSong = "" }
    mem.save()
    let last = baseDir.appendingPathComponent("last-song.txt")
    if (try? String(contentsOf: last, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == name { try? FileManager.default.removeItem(at: last) }
    print("set aside: \(name)")
    exit(0)
}
if let i = args.firstIndex(of: "--livetest"), i + 1 < CommandLine.arguments.count {
    guard let s = loadMIDIFile(URL(fileURLWithPath: CommandLine.arguments[i + 1]), track: "piano") else { print("cannot read"); exit(1) }
    let spb = 60 / s.bpm
    let take = tidyTake(s.notes.map { RNote(t: $0.beat * spb, end: ($0.beat + $0.dur) * spb, pitch: $0.pitch, vel: $0.vel) }.sorted { $0.t < $1.t })
    liveBandTest(take, analyse(take))
    exit(0)
}
if let i = args.firstIndex(of: "--probe"), i + 2 < CommandLine.arguments.count {
    // Measures built-in sounds: ./talking-piano --probe <pitch> <program> [<program> ...]
    let pitch = UInt8(CommandLine.arguments[i + 1]) ?? 60
    for a in CommandLine.arguments[(i + 2)...] {
        guard let prog = UInt8(a) else { continue }
        let m = Sounds.probe(program: prog, pitch: pitch)
        print(String(format: "program %3d  attack %.2f s  level %.4f  bright %.3f  soft/full %.2f", Int(prog), m.attack, m.level, m.bright, m.expression))
    }
    exit(0)
}
if let i = args.firstIndex(of: "--reband"), i + 2 < CommandLine.arguments.count {
    // Rebuilds the band for a saved idea from its piano track, writes it to the given
    // file, and prints what the band did. Used to check the band without playing it.
    guard let s = loadMIDIFile(URL(fileURLWithPath: CommandLine.arguments[i + 1]), track: "piano") else { print("cannot read"); exit(1) }
    let spb = 60 / s.bpm
    let take = tidyTake(s.notes.map { RNote(t: $0.beat * spb, end: ($0.beat + $0.dur) * spb, pitch: $0.pitch, vel: $0.vel) }.sorted { $0.t < $1.t })
    let a = analyse(take)
    let band = bandFull(take, a)
    print(a.summary(noteCount: take.count))
    print("insights: " + insights(a, earlier: []).joined(separator: " "))
    print("chords: " + a.chords.map { String(format: "%@ %.1f-%.1f", a.name($0), $0.start, $0.end) }.joined(separator: " | "))
    let names: [UInt8: String] = [0: "piano", 1: "bass", 2: "strings", 3: "cello", 6: "high strings", 7: "horn", 8: "warm pad", 9: "drums"]
    for (ch, name) in names.sorted(by: { $0.key < $1.key }) where ch != 0 {
        let part = band.filter { $0.ch == Int(ch) && $0.cc < 0 }
        if !part.isEmpty { print(String(format: "notes %@ %d, sounding %.0f%% of the piece", name, part.count, 100 * part.reduce(0) { $0 + $1.end - $1.t } / max(1, a.length))) }
    }
    if let b = a.beat {
        let drums = band.filter { $0.ch == 9 && $0.pitch != 42 }
        var onsets: [Double] = []
        for t in take.map({ $0.t }).sorted() where onsets.last == nil || t - onsets.last! > 0.05 { onsets.append(t) }
        let off = drums.map { d in onsets.map { abs($0 - d.t) }.min() ?? 9 }
        let far = off.filter { $0 > 0.08 }.count
        print(String(format: "beat %.3f s (%.0f a minute), %d drum hits, %d of them more than 0.08 s from anything you played (worst %.2f s)", b, 60 / b, drums.count, far, off.max() ?? 0))
        let gaps = zip(onsets, onsets.dropFirst()).map { $1 - $0 }.filter { $0 > 0.12 }
        let ratios = gaps.map { ($0 / b) - ($0 / b).rounded() }
        print(String(format: "your timing against that beat: typical miss %.0f%% of a beat", 100 * (ratios.map { abs($0) }.reduce(0, +) / Double(max(1, ratios.count)))))
    } else { print("no steady beat found: free time, so no drums") }
    let swell = band.filter { $0.cc == 11 && $0.ch == 2 }.map { $0.vel }
    if let lo = swell.min(), let hi = swell.max() { print("strings expression moves between \(lo) and \(hi) in \(swell.count) steps") }
    for (ch, level) in Sounds.levels(take + band).sorted(by: { $0.key < $1.key }) { print(String(format: "level %@ %.4f", names[ch] ?? "?", level)) }
    let whole = Sounds.mix(take + bandFull(take, a))
    print(String(format: "mix peak %.2f, clipped %.2f%% of the time, band gain %+.0f dB", whole.peak, whole.clipped * 100, Sounds.gainDB))
    _ = writeMIDIFile(URL(fileURLWithPath: CommandLine.arguments[i + 2]), bpm: 120, tracks: ([("Piano", take)] + bandTracks(band)).filter { !$0.notes.isEmpty })
    exit(0)
}
if let i = args.firstIndex(of: "--speak"), i + 1 < CommandLine.arguments.count {
    // Says one thing aloud with the Kokoro voice and reports how long it took to begin.
    if args.contains("--mute") { Opt.voiceVolume = 0 }          // for checking timing without making a sound
    Kokoro.shared.start()
    let t = now()
    let ok = args.contains("--cold") ? Kokoro.shared.usable() : Kokoro.shared.available()   // --cold: speak while the voice is still loading, as at launch
    print(ok ? String(format: "Kokoro ready after %.1f s, voice %@", now() - t, Kokoro.shared.name) : "Kokoro is not available")
    let t1 = now()
    if ok { _ = Kokoro.shared.say(CommandLine.arguments[i + 1], meter: nil) }
    print(String(format: "voice began after %.2f s, finished after %.1f s", Kokoro.shared.firstSoundAt - t1, now() - t1))
    Kokoro.shared.shutDown()
    exit(0)
}
if let i = args.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
    // Asks the AI one question from the command line, to check that it is reachable.
    print(AI.ask(CommandLine.arguments[i + 1], context: "Right now: at home."))
    exit(0)
}
if let i = args.firstIndex(of: "--lookup"), i + 2 < CommandLine.arguments.count {
    // Shows what would be found for Spotify, YouTube or a file search, without playing or opening anything.
    let words = CommandLine.arguments[i + 2]
    switch CommandLine.arguments[i + 1] {
    case "spotify": print(Web.spotify(words, kind: words.contains(" by ") ? "track" : nil).map { "\($0.uri)  \($0.title)  (\($0.kind))" } ?? "nothing found")
    case "midi": print(Engine(midi: MidiIO()).midiFileNamed(Heard(words))?.lastPathComponent ?? "nothing found")
    case "menu":
        // --lookup menu "<app>|<request>": which menu command would be chosen, without choosing it.
        let parts = words.components(separatedBy: "|")
        guard parts.count == 2, let pid = AX.pid(of: parts[0]) else { print("that app is not running"); break }
        let t = now()
        let entries = AX.menus(pid)
        let m = matchCommand(Heard(parts[1]).text, in: entries, ignoring: commandWords(parts[0]) + ["logic", "pro", "chrome", "google"], strict: false)
        print(String(format: "trusted %@, %d commands read in %.2f s  ->  %@", AX.trusted ? "yes" : "no", entries.count, now() - t, m.map { ($0.sure ? "" : "(offer) ") + $0.entry.path.joined(separator: " > ") } ?? "nothing"))
    case "press":
        // --lookup press "<app>|<request>": really chooses the command. Only for harmless ones, when checking that pressing works.
        let parts = words.components(separatedBy: "|")
        guard parts.count == 2, let pid = AX.pid(of: parts[0]),
              let m = matchCommand(Heard(parts[1]).text, in: AX.menus(pid), ignoring: commandWords(parts[0]), strict: true), m.sure, let el = m.entry.element else { print("nothing chosen"); break }
        print("\(m.entry.path.joined(separator: " > ")): \(AX.press(el) ? "pressed" : "would not respond")")
    case "window":
        guard let pid = AX.pid(of: words), let w = AX.dialog(pid) ?? AX.focusedWindow(pid) else { print("no window"); break }
        let c = AX.contents(of: w)
        print("title: \(AX.text(w, kAXTitleAttribute))\ncontrols: \(spokenList(c.controls.map { $0.name }, limit: 12))\ntexts: \(c.texts.count)")
    case "youtube": print(Web.firstVideo(words).map { "\($0.id)  \($0.title)" } ?? "nothing found")
    case "files": for u in Files.search(words).prefix(5) { print(Files.spoken(u), "|", u.deletingLastPathComponent().lastPathComponent, "|", Files.age(Files.when(u))) }
    case "folder": for u in (Files.places.first { $0.say.contains(words) }.flatMap { Files.newest(in: $0.path) } ?? []).prefix(4) { print(Files.spoken(u), "|", Files.age(Files.when(u))) }
    default: break
    }
    exit(0)
}
if args.contains("--new-logic-project") {
    // Carries out "new project" in Logic exactly as the voice command does, and prints what Logic reported.
    print(LogicControl.logicNewProject())
    exit(0)
}
if args.contains("--sound-check") {
    // Checks, in silence, that the band's instruments really produce sound, and still do after being rebuilt.
    let s = Sounds()
    s.start()
    func heard() -> Float {
        s.engine.mainMixerNode.outputVolume = 0          // nothing reaches the speakers
        guard let strings = s.samplers[2] ?? s.samplers.values.first else { return -1 }
        var peak: Float = 0
        strings.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
            if let d = buf.floatChannelData { for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[0][i])) } }
        }
        let ch = s.samplers.first { $0.value === strings }?.key ?? 2
        s.send([0x90 | ch, 60, 100]); usleep(700_000); s.send([0x80 | ch, 60, 0]); usleep(200_000)
        strings.removeTap(onBus: 0)
        return peak
    }
    print(String(format: "ready %@, sound produced: %.4f", s.ready ? "yes" : "no", heard()))
    s.revive("a test", wait: true)
    print(String(format: "after rebuilding (%d): sound produced: %.4f", s.restarts, heard()))
    s.engine.stop()
    usleep(200_000)
    s.send([0x92, 60, 100]); usleep(600_000)
    print("after being stopped, a note started it again: \(s.engine.isRunning ? "yes" : "no")")
    exit(0)
}
if let i = args.firstIndex(of: "--wake-score"), i + 2 < CommandLine.arguments.count {
    // Takes what the recogniser really wrote for a name said many ways (a file made by the app's
    // --wake-test) and reports how many of those would have been answered. Silent.
    Opt.fast = true
    Profile.current = Profile(user: "", assistant: CommandLine.arguments[i + 2], city: "", fahrenheit: false, about: "", plays: true, done: true)
    let engine = Engine(midi: MidiIO())
    engine.awaitingTop = false
    let want = args.contains("--taught") ? "taught" : "plain"
    var total = 0, heard = 0, missed: [String] = []
    for line in ((try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)) ?? "").components(separatedBy: "\n") where line.hasPrefix(want + " |") {
        guard let r = line.range(of: " -> ") else { continue }
        let wrote = String(line[r.upperBound...])
        engine.goHomeQuietly(); engine.lastSpoken = ""; engine.lastSpokenAt = now() - 60
        let got = wrote == "(nothing)" ? "nothing" : Ears().partial(wrote, final: true, engine: engine)
        total += 1
        if got == "acted" || got == "soft" { heard += 1 } else { missed.append(wrote) }
    }
    print("\(CommandLine.arguments[i + 2]) (\(want)): answered \(heard) of \(total). Not answered: \(missed.joined(separator: "; "))")
    exit(0)
}
if args.contains("--update-test") {
    // Looks for an update and installs it, exactly as the app does after a "yes". For checking the whole path.
    guard let info = Updater.check() else { print("no newer version found (this is \(novaVersion))"); exit(0) }
    print("found \(info.version): \(info.notes)")
    print(Updater.install(info) ?? "installed")
    exit(0)
}
if args.contains("--install-voice") {
    // Runs the natural voice download exactly as the app does, printing each step. For checking it end to end.
    let t = now()
    let problem = VoiceInstaller.install { print(String(format: "%5.0f s  %@", now() - t, $0)) }
    print(String(format: "%5.0f s  %@", now() - t, problem ?? "installed"))
    exit(problem == nil ? 0 : 1)
}
if args.contains("--library") {
    // Prints one line per song, for checking the library without starting the tool.
    for s in loadLibrary() {
        let l = Lesson(song: s)
        let r = l.steps[0], lh = l.steps[1]
        let sizes = (r + lh).map { $0.pitches.count }
        let secs = (s.notes.map { $0.beat }.max() ?? 0) * 60 / s.bpm
        print("\(s.level) \(s.name.padding(toLength: 44, withPad: " ", startingAt: 0)) \(Int(secs))s  right \(r.count) steps, left \(lh.count) steps, biggest chord \(sizes.max() ?? 0), \(l.bounds.count) parts, \(l.units.count) lesson steps\(s.chordGap > 0.04 ? ", performance timing" : "")")
    }
    exit(0)
}
// Checks run from the command line must never disturb the copy the player is using, and a check
// given too few arguments must stop here, not carry on and start up as a second the assistant.
let checkFlags = ["--selftest", "--route", "--chat", "--lookup", "--reband", "--speak", "--ask", "--library", "--daw-test", "--reaper-test", "--new-logic-project", "--mute", "--cold", "--reaper", "--sound-check", "--install-voice", "--update-test", "--wake-score"]
let isCheck = args.contains { checkFlags.contains($0) }
if !isCheck, instanceLock >= 0 { becomeOnlyCopy() }
let midi = MidiIO()
midi.start()
let sounds = Sounds()
let engine = Engine(midi: midi)
if let i = args.firstIndex(of: "--chat") {
    // A short conversation with the AI session, printed with how long each answer took. Nothing is carried out.
    AISession.shared.library = engine.songs.filter { $0.level >= 2 }.prefix(30).map { $0.name }.joined(separator: "; ")
    AISession.shared.start()
    _ = AISession.shared.ask("Say ready.", state: "warming up")
    for q in CommandLine.arguments.dropFirst(i + 1) {
        let t = now()
        let a = AISession.shared.ask(q, state: engine.aiState()) ?? "(no answer)"
        print(String(format: "%.1f s  %@\n        -> %@", now() - t, q, a))
    }
    AISession.shared.shutDown()
    exit(0)
}
if args.contains("--daw-test") {
    // Speaks to a real, running REAPER in plain sentences and prints each answer.
    Opt.textMode = true
    DispatchQueue.global().async {
        let lines = (try? String(contentsOfFile: CommandLine.arguments.last ?? "", encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        for line in lines where !line.isEmpty {
            engine.daw.lastSaid = ""
            let kind = engine.hear(line)
            var waited = 0
            usleep(900_000)
            while engine.daw.lastSaid.isEmpty, waited < 60 { usleep(100_000); waited += 1 }
            usleep(500_000)
            print("YOU: \(line)\n  [\(kind)] \(engine.daw.lastSaid)\n")
        }
        exit(0)
    }
    dispatchMain()
}
if args.contains("--reaper-test") {
    // Walks the REAPER menu against a real, running REAPER and prints what would be spoken.
    Opt.textMode = true
    DispatchQueue.global().async {
        func press(_ k: Int, _ wait: Double = 0.9) { engine.command(k); usleep(UInt32(wait * 1e6)) }
        engine.openReaper(); usleep(3_000_000)
        press(keyNext); press(keyHear)            // Tracks
        press(keyHear)                            // first track
        press(keyHear); press(keyHear)            // arm, disarm
        for _ in 0..<8 { press(keyNext, 0.3) }    // to "Add an effect"
        press(keyHear); press(keyNext); press(keyHear, 1.5)   // add ReaComp
        for _ in 0..<7 { press(keyNext, 0.3) }    // to "Effects on this track"
        press(keyHear); press(keyHear); press(keyNext); press(keyHear)   // first effect, then remove it
        press(keyNotes); press(keyNotes); press(keyNotes)          // back to the root
        for _ in 0..<5 { press(keyNext, 0.3) }    // to "Find any action by typing"
        press(keyHear)
        if engine.typing == "reaper", engine.naming {
            for c in Array("toggle metronome".utf8) { engine.nameKey(c) }
            engine.nameKey(13); usleep(1_500_000)
            press(keyHear); press(keyHear)        // metronome on, then off
        }
        press(keyNotes)
        for _ in 0..<2 { press(keyBack, 0.3) }    // New track... then check the instrument list
        press(keyNext, 0.3); press(keyNext, 0.3); press(keyNext, 0.3)
        press(keyHear, 1.5); press(keyNext); press(keyNext); press(keyNotes)
        exit(0)
    }
    dispatchMain()
}
if let i = args.firstIndex(of: "--route") {
    // Shows how each sentence would be understood, and what would be said, without doing or saying anything.
    Opt.fast = true
    if args.contains("--as-jarvis") { Profile.current = Profile(user: "Sam", assistant: "Jarvis", city: "", fahrenheit: false, about: "", plays: true, done: true) }
    engine.awaitingTop = false
    engine.pretendReaper = args.contains("--reaper")
    for q in CommandLine.arguments.dropFirst(i + 1) where !q.hasPrefix("--") {
        engine.goHomeQuietly()
        engine.lastSpoken = ""; engine.lastSpokenAt = 0
        print(">>> \(q)")
        let got = engine.hear(q)
        usleep(150_000)
        print("    = \(got)")
    }
    exit(0)
}
if args.contains("--selftest") {
    DispatchQueue.global().async { selfTest(engine, midi) }
    dispatchMain()
}
if isCheck { print("That check was not given what it needs, so nothing was started."); exit(2) }
midi.onNote = { pitch, vel in engine.noteEvent(pitch, vel) }
midi.onPedal = { engine.pedal($0) }

// Leaving always silences the tool's notes first, including when the app is opened again.
// Every exit is written to log.txt with its reason, so an unexpected stop can be explained.
func logLine(_ text: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date()))  \(text)\n"
    let url = baseDir.appendingPathComponent("log.txt")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

func quit(_ reason: String = "Q pressed", code: Int32 = 0) -> Never {
    engine.autosaveTake()
    Kokoro.shared.shutDown()
    AISession.shared.shutDown()
    logLine("stopped: \(reason)")
    // Leaving must never hang, whatever the audio system is doing: if a tidy exit has not
    // happened within a second and a half, the program is simply ended.
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { _exit(code) }
    midi.allOff()
    engine.speaker.silenceNow()
    usleep(80_000)
    exit(code)
}
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let quitSignals: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { sig in
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler { quit(sig == SIGTERM ? "replaced by a newer copy, or asked to stop" : "interrupted") }
    src.resume()
    return src
}

var savedTerm = termios()
let isTTY = isatty(STDIN_FILENO) == 1
if isTTY {
    tcgetattr(STDIN_FILENO, &savedTerm)
    var raw = savedTerm
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    atexit { tcsetattr(STDIN_FILENO, TCSANOW, &savedTerm) }
}

Thread.detachNewThread {
    var esc = 0
    var appCommand: [UInt8]? = nil
    while true {
        var c: UInt8 = 0
        let got = read(STDIN_FILENO, &c, 1)
        if got < 0, errno == EINTR || errno == EAGAIN { continue }
        // Losing the keyboard (for example the window closing) must not stop the piano side.
        if uiOn, got == 0 { quit("the app window closed") }   // never keep running without its window
        guard got == 1 else { logLine("computer keyboard input ended (read \(got), errno \(errno)); piano buttons still work"); return }
        if engine.naming { engine.nameKey(c); continue }
        // A line starting with "~" is a command from the app window, such as "~jazz 2".
        if let soFar = appCommand {
            if c == 10 || c == 13 { appCommand = nil; engine.appCommand(String(decoding: soFar, as: UTF8.self)) } else if soFar.count < 2000 { appCommand = soFar + [c] }
            continue
        }
        if c == 126 { appCommand = []; continue }
        if c == 127 { engine.restartTake(); continue }   // Delete: start the composition over
        if c == 27 { esc = 1; continue }
        if esc == 1 { esc = c == 91 ? 2 : 0; continue }
        if esc == 2 {
            esc = 0
            if c == 67 { engine.command(keyNext) } else if c == 68 { engine.command(keyBack) }
            continue
        }
        switch Character(UnicodeScalar(c)) {
        case " ": engine.command(keyHear)
        case "n", "N": engine.command(keyNotes)
        case "t", "T": engine.command(keyTalk)
        case "l", "L": engine.listSongs()
        case "0": engine.command(keyHome)
        case "a", "A": engine.startAsk()
        case "g", "G": engine.openLogic()
        case "r", "R": engine.openReaper()
        case "m", "M": engine.openMenu()
        case "j", "J": engine.startJazz(engine.mem.jazzLesson ?? 0)
        case "h", "H": engine.help()
        case "/", "?": engine.openSheet()
        case "v", "V":
            let name = engine.speaker.nextVoice()
            engine.run { g in engine.say("This is \(name).", g) }
        case ",", ".":
            Opt.voiceVolume = max(0.2, min(1.0, Opt.voiceVolume + (c == 46 ? 0.15 : -0.15)))
            engine.run { g in engine.say(c == 46 ? "Voice louder." : "Voice quieter.", g) }
        case "[", "]":
            let before = sounds.level
            sounds.level += c == 93 ? 3 : -3
            ui("bandlevel \(sounds.level >= 0 ? "+" : "")\(Int(sounds.level)) dB")
            let edge = sounds.level == before ? (c == 93 ? " That is as loud as it goes." : " That is as quiet as it goes.") : ""
            engine.run { g in engine.say((c == 93 ? "Band louder." : "Band quieter.") + edge, g) }
        case "-": engine.tempo = max(0.3, engine.tempo - 0.1); engine.run { g in engine.say("A bit slower.", g) }
        case "=", "+": engine.tempo = min(1.2, engine.tempo + 0.1); engine.run { g in engine.say("A bit faster.", g) }
        case "p", "P":
            Opt.toPiano.toggle()
            engine.run { g in engine.say(Opt.toPiano ? "Also playing through the piano." : "Playing through Logic only.", g) }
        case "\n", "\r": engine.command(keyPause)
        case "c", "C": engine.command(keyCompose)
        case "b", "B": engine.toggleLive()
        case "s", "S": engine.command(keyKeep)
        case "K": engine.askForTopKey()   // capital only, so stray typing cannot change the buttons
        case "q", "Q": quit()
        case "1"..."9": engine.chooseSong(Int(c) - 49)
        default: break
        }
    }
}

logLine("started, keyboards: \(midi.keyboards.isEmpty ? "none" : midi.keyboards.joined(separator: ", ")), voice: \(engine.speaker.voice?.name ?? "default")")
ui("kbd " + midi.keyboards.joined(separator: ", "))
engine.loadLearned()
Weather.refresh()   // in the background, so the greeting can mention it
if !Opt.textMode {
    AISession.shared.library = engine.songs.filter { $0.level >= 2 }.prefix(30).map { $0.name }.joined(separator: "; ")
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        AISession.shared.start()
        _ = AISession.shared.ask("Reply with the single word ready.", state: "the app has just opened")   // so the first real answer is quick
    }
    Kokoro.shared.start()
    // The things said most often are prepared in the background and kept, so they play instantly.
    var common = ["That's correct.", "Yes, that's right.", "That's it, well done.", "Spot on.", "Your turn.", "Okay, stopped.", "All quiet now.", "Stopping there.", "Paused for now.", "Okay, paused.", "Kept that one.", "Got it, saved.", "Here it is with the band.", "With the band.", "Here comes the band.", "A bit slower.", "A bit faster.", "Still here, \(You.name).", "What do you need?", "I'm here, \(You.name).", "Composition mode.", "New composition.",
                  "Fresh start.", "New idea. Go.", "Song menu.", "Kept.", "Got it.", "Saved.", "Band.", "Let me think.", "One moment.", "Thinking.", "Slower.", "Faster.",
                  "Band louder.", "Band quieter.", "Voice louder.", "Voice quieter.", "Again.", "Once more.", "Talk mode.", "Not yet. Again.", "Right. Once more to be sure.",
                  "Okay. Nothing was changed.", "Fixed.", "Listen.", "Metronome off.", "Play something first.", "I did not understand that one. Say \(Me.name), help, to hear what I can do.",
                  "Carrying on.", "Jam with me.", "Undone.", "Playing.", "Recording stopped.", "At the start.", "Now you.", "Over to you.", "Have a go.", "Okay.", "All quiet.",
                  "Back home.", "Home again.", "Composition. I'm listening.", "Composition. Play me something.", "Done.", "There you go.", "Pressed."]
    for name in Set(flatNames + sharpNames) { common += ["Higher. \(name).", "Lower. \(name).", "Next is \(name)."] }
    Kokoro.shared.prewarm(Engine.hellos + Engine.wakeReplies + common + Engine.chatReplies)
    Kokoro.shared.makeSystemClips()
}
ui("voice " + (Kokoro.installed && Kokoro.shared.enabled ? Kokoro.shared.name + " (Kokoro)" : (engine.speaker.voice?.name ?? "default")))
ui("buttons " + engine.buttonKeys.map(String.init).joined(separator: " ") + " \(keyHome) \(keyKeep)")
ui("mode \(engine.mode)")
ui("jazz " + jazzLessons.map { $0.title }.joined(separator: "|"))
ui("bandstyle \(bandStyle)")
ui("live 0")
ui("hands " + handsOnly)
// Names the speech recogniser should expect: songs, apps, and the studio's own words.
engine.sendVocabulary()
ui("name \(Me.name)|\(You.name)")
ui("bandlevel \(Sounds.gainDB >= 0 ? "+" : "")\(Int(Sounds.gainDB)) dB")
let found = midi.keyboards.isEmpty ? "No piano found yet. Plug it in and I will pick it up." : "Piano connected."
// Built-in band instruments, and a check every few seconds for whether Logic is open.
// Started off to one side. If the Mac's audio system is slow to answer, or stuck (it can be, when
// another music program is holding the audio interface), the assistant still starts, listens
// and shows its window; the instruments simply join when the audio system lets them in.
midi.sounds = sounds
DispatchQueue.global(qos: .userInitiated).async { sounds.start() }
var dawTold = false
func checkLogic() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-q", "-x", "Logic Pro|REAPER"]
    p.terminationHandler = { done in
        let running = done.terminationStatus == 0
        if running != midi.logicRunning || !dawTold { dawTold = true; ui("daw \(running ? 1 : 0)") }
        midi.logicRunning = running
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { checkLogic() }
    }
    do { try p.run() } catch { midi.logicRunning = true }
}
checkLogic()

// The list of commands stays on screen in this window, and as a large-print page.
_ = engine.writeSheetHTML()
if !Opt.textMode { print(engine.sheetText()) }

engine.mem.sessions += 1
engine.restoreAlarms()
engine.startUpdates()
VoiceInstaller.placeHelper()
// Without a piano there are no button keys to learn. With one, its top key is asked for after the hello.
if midi.keyboards.isEmpty { engine.awaitingTop = false }
if !Profile.current.done {
    // First time: the welcome screens do the talking. Nothing is said until they have been through.
    ui("welcome 1")
} else {
    engine.fetchVoiceIfWanted(announce: false)        // an interrupted download carries on quietly
    let parts = engine.greetingParts()
    let learnTop = engine.awaitingTop
    engine.run { g in
        engine.say(parts.hello, g)
        let rest = (parts.rest + (learnTop ? " I can see a piano. Press its highest key once, so I know its size." : "")).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { engine.say(rest, g) }
    }
}
engine.mem.lastOpened = Date().timeIntervalSince1970
engine.mem.save()
dispatchMain()
