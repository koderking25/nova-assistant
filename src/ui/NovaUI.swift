// Nova: the app window.
//
// This file is the face. The brain is the `nova-engine` program inside the app; the window
// starts it, sends it single keys and short commands, and reads lines starting with "@"
// that say what is being spoken and played.
//
// Build with ../build.sh.

import AppKit
import AVFoundation
import Combine
import ServiceManagement
import CoreAudio
import Speech
import SpriteKit
import SwiftUI
import UniformTypeIdentifiers

// Everything Nova remembers is kept in one folder in the user's Library.
let baseDir: String = {
    let dir = ProcessInfo.processInfo.environment["NOVA_HOME"] ?? (NSHomeDirectory() + "/Library/Application Support/Nova")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()

/// The answers given in the welcome, read here only to know the assistant's name before the engine has started.
func savedProfile() -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: baseDir + "/profile.json"), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

// MARK: - Colours

enum Hud {
    static let bg = Color(red: 0.008, green: 0.022, blue: 0.014)
    static let panel = Color(red: 0.02, green: 0.07, blue: 0.045)
    static let green = Color(red: 0.22, green: 1.0, blue: 0.53)
    static var contrast = UserDefaults.standard.bool(forKey: "contrast")   // near-white text for low vision
    static var soft: Color { contrast ? Color(red: 0.96, green: 1.0, blue: 0.97) : Color(red: 0.55, green: 1.0, blue: 0.78) }
    static var dim: Color { contrast ? Color(red: 0.72, green: 0.95, blue: 0.82) : Color(red: 0.24, green: 0.68, blue: 0.43) }
    static let faint = Color(red: 0.06, green: 0.24, blue: 0.14)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - The link to the tool

struct Spoken: Identifiable {
    let id: Int
    let time: String
    let text: String
}

struct Ripple {
    let pitch: Int
    let at: Double
    let strength: Double
    var off: Double? = nil     // when the key came back up
}

/// Names a chord from the keys being held, for the read-out.
func chordName(_ pitches: [Int]) -> String? {
    let pcs = Set(pitches.map { $0 % 12 })
    guard pcs.count >= 3, let bass = pitches.min() else { return nil }
    let names = ["C", "C#", "D", "E♭", "E", "F", "F#", "G", "A♭", "A", "B♭", "B"]
    let shapes: [(String, [Int])] = [("MAJOR 7", [0, 4, 7, 11]), ("MINOR 7", [0, 3, 7, 10]), ("7", [0, 4, 7, 10]),
                                     ("MAJOR", [0, 4, 7]), ("MINOR", [0, 3, 7]), ("DIM", [0, 3, 6]), ("AUG", [0, 4, 8]),
                                     ("SUS 4", [0, 5, 7]), ("SUS 2", [0, 2, 7])]
    var best: (Int, String)? = nil
    for root in 0..<12 {
        for (name, shape) in shapes {
            let tones = Set(shape.map { ($0 + root) % 12 })
            guard tones.isSubset(of: pcs) else { continue }
            let score = tones.count * 10 - (pcs.count - tones.count) * 4 + (bass % 12 == root ? 3 : 0)
            if best == nil || score > best!.0 { best = (score, "\(names[root]) \(name)") }
        }
    }
    return best?.1
}

/// One note of a MIDI file being played, in seconds from its first note.
struct RollNote {
    let t: Double, dur: Double
    let pitch: Int, vel: Int, track: Int
}

final class Link: ObservableObject {
    static let shared = Link()

    // A MIDI file being played: its notes fall onto the keyboard in the visualiser.
    @Published var rollName = ""
    @Published var rolling = false
    var roll: [RollNote] = []
    var rollZero: Double? = nil            // the moment the file's first note sounds
    var rollLength = 0.0

    /// Asks for a MIDI file and plays it.
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a MIDI file to play"
        panel.allowedContentTypes = [UTType.midi]
        panel.allowsMultipleSelection = false
        let midify = URL(fileURLWithPath: NSHomeDirectory() + "/Music/Nova Songs")
        if FileManager.default.fileExists(atPath: midify.path) { panel.directoryURL = midify }
        if panel.runModal() == .OK, let url = panel.url { playFile(url) }
    }

    func playFile(_ url: URL) {
        visual = true
        send("~play " + url.path + "\n")
    }

    @Published var assistant = (savedProfile()["assistant"] as? String) ?? "Nova"     // the name it answers to
    @Published var user = (savedProfile()["user"] as? String) ?? ""
    @Published var updateVersion = ""      // a newer version is on offer: shown until answered
    @Published var updateNotes = ""
    @Published var welcome = false         // the first-run questions are on screen
    var welcomeKey: ((NSEvent) -> Bool)?   // the welcome's own handling of arrow keys; true means "that was mine"
    var tabbing = false                    // Tab has been used: Space and Return then press the control the keyboard is on
    var welcomeStepForSnapshot = 0
    @Published var caption = ""
    @Published var spokenTo = 0            // how far into the caption the voice has got (UTF-16 units)
    @Published var speaking = false
    @Published var transcript: [Spoken] = []
    @Published var mode = "idle"
    @Published var keyboards = ""
    @Published var voice = ""
    @Published var daw = false
    @Published var state = "STARTING"      // STARTING, ONLINE, OFFLINE
    @Published var jazz: [String] = []     // the jazz lessons' titles
    @Published var visual = false          // the full-window visualiser
    @Published var typing = false          // a name or a question is being typed: every key goes to the tool
    var echoes: [Ripple] = []              // notes the tool itself plays
    @Published var paused = false          // a lesson is paused: buttons wait until it is carried on
    @Published var live = false            // the live band is following the playing
    @Published var bandStyle = "full"
    @Published var now = ""                // what is happening: the song and part, the lesson, the piece
    @Published var bandLevel = ""
    @Published var heard = ""              // the last thing understood by voice or typing
    @Published var hands = "both"
    @Published var large = UserDefaults.standard.bool(forKey: "large")        // large captions
    @Published var contrast = UserDefaults.standard.bool(forKey: "contrast")
    @Published var flash = ""              // "wrong" or "good": a brief coloured frame, a cue that needs no hearing
    @Published var flashAt = 0.0
    @Published var beat = -1               // the metronome's beat, shown as well as heard
    weak var scene: RainScene?             // the visualiser, told about every note the instant it arrives

    // Read every frame by the drawings; changed on the main thread only.
    var down: [Int: Int] = [:]             // piano keys you are holding: pitch -> how hard
    var played: Set<Int> = []              // keys the tool is playing
    var buttons: [Int] = []                // the eight button keys, then home, then keep
    var ripples: [Ripple] = []
    var pulseAt = 0.0                      // last word or note, for the waveform
    var sayStarted = 0.0
    var gotWord = false
    var wordAt = 0.0                       // when the word being spoken started
    var wordTime = 0.0                     // how long that word takes to say, when the voice reports it
    var wordFrom = 0, wordLen = 0          // where that word sits in the caption
    var level = 0.05                       // the waveform's size right now, eased every frame
    var levelAt = 0.0
    var chord = ""
    var chordAt = 0.0

    // The real sound of the voice: sixty frames a second, sixteen bands each, measured by the
    // tool and played back here in step with the speech.
    var voiceId = 0
    var voiceFrames: [[Double]] = []
    var voiceAnchor: Double? = nil         // the moment frame 0 was heard
    var voiceStart = 0.0
    static let barCount = 120
    var bars = [Double](repeating: 0, count: Link.barCount)   // each bar's height right now
    var barsAt = 0.0

    /// The sixteen bands at this instant, blended between the two nearest frames. Nil when
    /// there is no voice data for now.
    func voiceBands(at t: Double) -> [Double]? {
        guard speaking, !voiceFrames.isEmpty else { return nil }
        // Until the first word mark arrives, assume the voice began just after it was started.
        let anchor = voiceAnchor ?? (voiceStart > 0 ? voiceStart + 0.04 : 0)
        guard anchor > 0 else { return nil }
        let x = (t - anchor) * 60
        guard x >= 0, Int(x) < voiceFrames.count else { return nil }
        let a = voiceFrames[Int(x)], b = voiceFrames[min(voiceFrames.count - 1, Int(x) + 1)]
        let f = x - Double(Int(x))
        return zip(a, b).map { $0 * (1 - f) + $1 * f }
    }

    /// Moves every bar towards where the sound says it should be. Called once per drawn frame.
    /// Rising is almost instant and falling is gentle, which is what makes it look alive.
    func updateBars(at t: Double) {
        let dt = min(0.1, max(0.001, t - barsAt))
        barsAt = t
        let n = Link.barCount
        var target = [Double](repeating: 0, count: n)
        let offline = state == "OFFLINE"
        if let bands = voiceBands(at: t) {
            for i in 0..<n {
                // Mirrored: low pitches at the top, high at the bottom, the same on both sides.
                let half = Double(i < n / 2 ? i : n - 1 - i) / Double(n / 2 - 1)
                let x = half * Double(bands.count - 1)
                let v = bands[Int(x)] * (1 - (x - Double(Int(x)))) + bands[min(bands.count - 1, Int(x) + 1)] * (x - Double(Int(x)))
                target[i] = pow(v, 1.5) * (0.9 + 0.1 * sin(Double(i) * 1.7 + t * 9))
            }
        } else if speaking && voiceFrames.isEmpty {
            // No measurements (the fallback voice): a soft made-up motion instead.
            let into = t - (gotWord ? wordAt : sayStarted)
            for i in 0..<n {
                target[i] = (0.25 + 0.4 * exp(-into * 3)) * (0.5 + 0.5 * abs(sin(Double(i) * 0.37 + t * 8) * sin(Double(i) * 0.11 - t * 5)))
            }
        } else if !offline {
            for i in 0..<n { target[i] = 0.035 + 0.03 * sin(Double(i) * 0.21 + t * 1.6) * sin(Double(i) * 0.05 - t * 0.7) }
        }
        // Every note on the piano pushes the bars at its own place on the ring.
        for r in ripples.suffix(16) {
            let age = t - r.at
            if age < 0 || age > 1.2 { continue }
            let centre = Double(r.pitch - 21) / 87 * Double(n / 2 - 1)
            let push = (0.35 + 0.65 * r.strength) * exp(-age * 3.5)
            for k in -5...5 {
                let j = Int(centre.rounded()) + k
                guard j >= 0, j < n / 2 else { continue }
                let bump = push * exp(-Double(k * k) / 6)
                target[j] = max(target[j], bump)
                target[n - 1 - j] = max(target[n - 1 - j], bump)
            }
        }
        let up = min(1, dt * 38), down = min(1, dt * 9)
        var sum = 0.0
        for i in 0..<n {
            bars[i] += (target[i] - bars[i]) * (target[i] > bars[i] ? up : down)
            sum += bars[i]
        }
        level = min(1, sum / Double(n) * 2.2)
        levelAt = t
    }

    /// The waveform's size, moved a little towards where it should be on every frame, so it
    /// rises and falls like breath instead of jumping.
    func easedLevel(at t: Double) -> Double {
        var target = 0.05 + 0.025 * sin(t * 1.3)
        if state == "OFFLINE" { target = 0.02 }
        else if speaking {
            // Each word swells and settles, with a syllable-sized ripple inside it.
            let into = t - (gotWord ? wordAt : sayStarted)
            let syllable = 0.5 + 0.5 * sin(into * 21)
            target = 0.36 + 0.42 * exp(-into * 2.6) + 0.2 * syllable * exp(-into * 1.2)
        } else {
            target += 0.55 * exp(-(t - pulseAt) * 2.8)
        }
        let dt = min(0.1, max(0, t - levelAt))
        levelAt = t
        level += (target - level) * min(1, dt * (target > level ? 16 : 5))
        return level
    }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var counter = 0
    private var stopping = false
    private var crashes: [Double] = []     // recent unexpected stops, so a restart cannot loop for ever

    static func clock() -> Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        stopping = false
        state = "STARTING"
        let p = Process()
        // The engine sits beside the window inside the app. The helper files it needs are put in the data folder.
        // The engine sits beside this window's code, in the payload folder the app's starter chose.
        let payload = ProcessInfo.processInfo.environment["NOVA_PAYLOAD"] ?? ((Bundle.main.resourcePath ?? "") + "/payload")
        let engine = URL(fileURLWithPath: payload + "/nova-engine")
        if let code = FileManager.default.contents(atPath: payload + "/talking_piano_bridge.lua") {
            try? FileManager.default.createDirectory(atPath: baseDir + "/reaper", withIntermediateDirectories: true)
            if FileManager.default.contents(atPath: baseDir + "/reaper/talking_piano_bridge.lua") != code { FileManager.default.createFile(atPath: baseDir + "/reaper/talking_piano_bridge.lua", contents: code) }
        }
        p.executableURL = engine
        p.arguments = []
        p.currentDirectoryURL = URL(fileURLWithPath: baseDir)
        var env = ProcessInfo.processInfo.environment
        env["TP_UI"] = "1"
        env["NOVA_HOME"] = baseDir
        env["NOVA_PAYLOAD"] = payload
        env["TERM"] = "dumb"
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.feed(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.process === p else { return }
                // If the engine stopped without being asked to, bring it straight back (but not in a loop).
                let now = Link.clock()
                self.crashes = self.crashes.filter { now - $0 < 120 }
                if p.terminationStatus != 0, !self.stopping, self.crashes.count < 3 {
                    self.crashes.append(now)
                    self.state = "RESTARTING"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if self.process === p { self.start() } }
                    return
                }
                if p.terminationStatus == 0, !self.stopping, AppDelegate.shared?.window.isVisible == false { NSApp.terminate(nil); return }
                self.state = "OFFLINE"
                self.speaking = false
                self.down = [:]
                self.played = []
            }
        }
        do {
            try p.run()
            process = p
            input = inPipe.fileHandleForWriting
        } catch {
            state = "OFFLINE"
        }
    }

    /// Sends the same key the Terminal window would have received.
    func setAccess(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        if key == "large" { large = on }
        if key == "contrast" { contrast = on; Hud.contrast = on; objectWillChange.send() }
    }

    func send(_ keys: String) {
        // Commands starting with "#" belong to the window itself.
        if keys.hasPrefix("#") {
            switch keys {
            case "#large": setAccess("large", !large)
            case "#contrast": setAccess("contrast", !contrast)
            case "#voice": VoiceControl.shared.toggle()
            default: break
            }
            return
        }
        guard let h = input, state != "OFFLINE", let data = keys.data(using: .utf8) else { return }
        try? h.write(contentsOf: data)
    }

    func stop() {
        guard let p = process, !stopping else { return }
        stopping = true
        send("q")                           // a normal quit, so anything you played is saved first
        let until = Date().addingTimeInterval(1.5)
        while p.isRunning && Date() < until { usleep(50_000) }
        try? input?.close()                 // the tool also quits when its input closes
        if p.isRunning { p.terminate() }
    }

    func restart() {
        stop()
        process = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.start() }
    }

    private func feed(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.hasPrefix("@") { handle(String(line.dropFirst())) }
        }
    }

    func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let what = String(parts.first ?? ""), rest = parts.count > 1 ? String(parts[1]) : ""
        if state != "ONLINE" { state = "ONLINE" }
        let t = Link.clock()
        switch what {
        case "spec":
            let a = rest.split(separator: " ", maxSplits: 2).map(String.init)
            guard a.count >= 2, let id = Int(a[0]) else { break }
            if a[1] == "new" { voiceId = id; voiceFrames = []; voiceAnchor = nil; voiceStart = 0; break }
            guard id == voiceId, a.count == 3, let first = Int(a[1]) else { break }
            let letters = Array(a[2].utf8)
            for k in 0..<(letters.count / 16) {
                let frame = letters[(k * 16)..<(k * 16 + 16)].map { Double(max(0, Int($0) - 97)) / 15 }
                if first + k == voiceFrames.count { voiceFrames.append(frame) } else if first + k < voiceFrames.count { voiceFrames[first + k] = frame }
            }
            return      // not a sign of anything else changing
        case "start":
            voiceStart = t
        case "say":
            caption = rest
            segments = Link.cut(rest)
            cursor = 0
            captionMark += 1
            captionLive = true
            spokenTo = 0
            speaking = true
            gotWord = false
            sayStarted = t
            pulseAt = t
            counter += 1
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            transcript.append(Spoken(id: counter, time: f.string(from: Date()), text: rest))
            if transcript.count > 60 { transcript.removeFirst(transcript.count - 60) }
        case "word":
            let n = rest.split(separator: " ").compactMap { Int($0) }
            wordTime = n.count >= 3 ? Double(n[2]) / 1000 : 0
            if n.count >= 2 {
                // The first word mark is when sound really begins: the measurements are lined up to it.
                if voiceAnchor == nil { voiceAnchor = t - 0.03 }
                spokenTo = n[0] + n[1]; wordFrom = n[0]; wordLen = n[1]; wordAt = t; gotWord = true; pulseAt = t
            }
        case "done":
            speaking = false
            doneAt = t
            // Keep drawing smoothly while the caption fades, then rest.
            let mark = captionMark
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.captionMark == mark, !self.speaking { self.captionLive = false } }

            spokenTo = (caption as NSString).length
        case "on":
            let n = rest.split(separator: " ").compactMap { Int($0) }
            guard n.count == 2 else { break }
            scene?.note(n[0], strength: Double(n[1]) / 127, mine: true)
            if n[1] > 0 {
                down[n[0]] = n[1]
                ripples.append(Ripple(pitch: n[0], at: t, strength: Double(n[1]) / 127))
                if ripples.count > 400 { ripples.removeFirst(ripples.count - 400) }
                pulseAt = t
                if let name = chordName(Array(down.keys)) { chord = name; chordAt = t }
            } else {
                down[n[0]] = nil
                if let i = ripples.lastIndex(where: { $0.pitch == n[0] && $0.off == nil }) { ripples[i].off = t }
            }
        case "out":
            let n = rest.split(separator: " ").compactMap { Int($0) }
            guard n.count == 2 else { break }
            scene?.note(n[0], strength: Double(n[1]) / 127, mine: false)
            if n[1] > 0 {
                played.insert(n[0])
                echoes.append(Ripple(pitch: n[0], at: t, strength: Double(n[1]) / 127))
                if echoes.count > 400 { echoes.removeFirst(echoes.count - 400) }
            } else {
                played.remove(n[0])
                if let i = echoes.lastIndex(where: { $0.pitch == n[0] && $0.off == nil }) { echoes[i].off = t }
            }
        case "mode": mode = rest
        case "kbd": keyboards = rest
        case "voice": voice = rest
        case "daw": daw = rest == "1"
        case "buttons": buttons = rest.split(separator: " ").compactMap { Int($0) }
        case "jazz": jazz = rest.split(separator: "|").map(String.init)
        case "typing": typing = rest == "1"
        case "rollnew":
            roll = []; rollZero = nil; rollName = rest; rolling = true; visual = true
            scene?.clearRoll()
        case "rolln":
            for item in rest.split(separator: ";") {
                let f = item.split(separator: ",")
                if f.count == 5, let a = Double(f[0]), let d = Double(f[1]), let p = Int(f[2]), let v = Int(f[3]), let k = Int(f[4]) {
                    roll.append(RollNote(t: a, dur: d, pitch: p, vel: v, track: k))
                }
            }
            return
        case "rollstart":
            let f = rest.split(separator: " ").compactMap { Double($0) }
            if f.count == 2 { rollZero = t + f[0]; rollLength = f[1] }
        case "rollstop":
            rolling = false; rollZero = nil
            scene?.clearRoll()
        case "paused": paused = rest == "1"
        case "live": live = rest == "1"
        case "bandstyle": bandStyle = rest
        case "now": now = rest
        case "bandlevel": bandLevel = rest
        case "earreset": VoiceControl.shared.startOver()
        case "vocab": VoiceControl.shared.vocabulary = rest.components(separatedBy: "|").filter { !$0.isEmpty }
        case "ears": if rest == "off" { VoiceControl.shared.stop() }
        case "heard":
            heard = rest
            // What you said goes into the conversation too, marked as yours.
            counter += 1
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            transcript.append(Spoken(id: counter, time: f.string(from: Date()), text: "\u{25B8} YOU: " + (rest.isEmpty ? "\(Link.shared.assistant)" : rest)))
        case "name":
            let parts = rest.components(separatedBy: "|")
            assistant = parts[0].isEmpty ? "Nova" : parts[0]
            user = parts.count > 1 && parts[1] != "friend" ? parts[1] : ""
        case "welcome": welcome = true; AppDelegate.shared?.showWindow()
        case "update":
            let parts = rest.components(separatedBy: "|")
            updateVersion = parts[0].trimmingCharacters(in: .whitespaces)
            updateNotes = parts.count > 1 ? parts[1] : ""
            if !updateVersion.isEmpty { Overlay.shared.show(for: 45) }
        case "relaunch":
            // The new version is in place. Start the app afresh, a moment after this copy has gone.
            stopping = true
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1.5; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
            try? p.run()
            NSApp.terminate(nil)
        case "hands": hands = rest
        case "beat": beat = Int(rest) ?? -1; flash = "beat"; flashAt = Link.clock()
        case "flash": flash = rest; flashAt = Link.clock()
        case "access":
            let parts = rest.split(separator: " ")
            if parts.count == 2 { setAccess(String(parts[0]), parts[1] == "1") }
        case "window":
            // Asked for by voice: "open the visualiser", "full screen".
            let parts = rest.split(separator: " ")
            guard parts.count == 2 else { break }
            let on = parts[1] == "1"
            if parts[0] == "visual" { visual = on; if on { AppDelegate.shared?.showWindow() } }
            if parts[0] == "show" { if on { AppDelegate.shared?.showWindow() } else { AppDelegate.shared?.hideWindow() } }
            if parts[0] == "login" { send("~login " + (LoginItem.set(on) ? (LoginItem.on ? "on" : "off") : "failed") + "\n") }
            if parts[0] == "full", let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), w.styleMask.contains(.fullScreen) != on { w.toggleFullScreen(nil) }
        default: break
        }
    }

    var modeName: String {
        switch mode {
        case "talk": return "TALK"
        case "teach": return "LESSON"
        case "compose": return "COMPOSE"
        case "menu": return "SONG MENU"
        case "jazz": return "JAZZ"
        case "logic": return "LOGIC CONTROL"
        case "reaper": return "REAPER CONTROL"
        default: return "STANDBY"
        }
    }

    private var spinExtra = 0.0, spinAt = 0.0
    /// Extra turning for the arcs, which builds up while it speaks and never jumps.
    func spin(at t: Double) -> Double {
        let dt = min(0.1, max(0, t - spinAt))
        spinAt = t
        spinExtra += dt * 1.6 * max(0, level - 0.08)
        return spinExtra
    }

    // MARK: Caption as a subtitle

    @Published var captionLive = false      // true while a caption is on screen and moving
    var segments: [NSRange] = []            // the caption cut into sentences short enough to show large
    var doneAt = 0.0                        // when the voice last stopped
    private var cursor = 0.0, cursorAt = 0.0, captionMark = 0

    /// Cuts a paragraph into subtitle-sized pieces: at the end of a sentence, or at a comma once a piece is getting long.
    static func cut(_ text: String) -> [NSRange] {
        let s = text as NSString
        var out: [NSRange] = []
        var start = 0
        var lastSpace = -1
        var i = 0
        while i < s.length {
            let c = s.character(at: i)
            let next: unichar = i + 1 < s.length ? s.character(at: i + 1) : 32
            let len = i - start + 1
            if c == 32 { lastSpace = i }
            let endOfSentence = (c == 46 || c == 63 || c == 33) && next == 32 && len >= 14
            let softBreak = (c == 44 || c == 59 || c == 58) && next == 32 && len >= 44
            let tooLong = len >= 74 && lastSpace > start
            if endOfSentence || softBreak {
                out.append(NSRange(location: start, length: len)); start = i + 2; i += 1
            } else if tooLong {
                out.append(NSRange(location: start, length: lastSpace - start)); start = lastSpace + 1
            }
            i += 1
        }
        if start < s.length { out.append(NSRange(location: start, length: s.length - start)) }
        // A very short tail joins the piece before it.
        if out.count >= 2, let last = out.last, last.length < 12 {
            let prev = out[out.count - 2]
            out.removeLast(2)
            out.append(NSRange(location: prev.location, length: last.location + last.length - prev.location))
        }
        return out.isEmpty ? [NSRange(location: 0, length: s.length)] : out
    }

    func segmentIndex(at position: Double) -> Int {
        let p = Int(position)
        return segments.lastIndex { $0.location <= p } ?? 0
    }

    /// Where the voice is in the caption, as a position between letters. It moves through each
    /// word over the time the word takes, then drifts across the gap to the next.
    func spokenExact(at t: Double) -> Double {
        let total = Double((caption as NSString).length)
        if !speaking { return total }
        if !gotWord { return 0 }
        let span = wordTime > 0 ? wordTime : max(0.12, Double(wordLen) * 0.06)
        let through = max(0, (t - wordAt) / span)
        let inWord = Double(wordLen) * min(1, through)
        let drift = through > 1 ? min(1.0, (t - wordAt - span) / 0.3) : 0
        return min(total, Double(wordFrom) + inWord + drift)
    }

    /// The light's position, eased toward where the voice is, so it never jumps.
    func glide(to target: Double, at t: Double) -> Double {
        let dt = min(0.1, max(0, t - cursorAt))
        cursorAt = t
        if target < cursor - 3 { cursor = target }                       // a new caption: start again
        else { cursor += (target - cursor) * (1 - exp(-dt * 16)) }
        return cursor
    }

    /// How far the caption has been spoken. Uses the voice's own word marks when there are any,
    /// otherwise an estimate from the time since it started.
    func spokenIndex(at t: Double) -> Int {
        let total = (caption as NSString).length
        if !speaking { return min(spokenTo, total) }
        // Nothing lights up until the voice has really begun: no guessing ahead of the sound.
        if !gotWord { return 0 }
        // Fill the word being spoken letter by letter over exactly the time it takes to say.
        let span = wordTime > 0 ? wordTime : max(0.12, Double(wordLen) * 0.06)
        let through = min(1, max(0, (t - wordAt) / span))
        return min(total, wordFrom + Int((Double(wordLen) * through).rounded()))
    }
}

// MARK: - Commands

struct Command: Identifiable {
    let id = UUID()
    let key: String       // what is shown on the key cap
    let send: String      // what the tool receives
    let lesson: String
    let compose: String?
    let only: String?     // shown only in this mode
    init(_ key: String, _ send: String, _ lesson: String, compose: String? = nil, only: String? = nil) {
        self.key = key; self.send = send; self.lesson = lesson; self.compose = compose; self.only = only
    }
}

let commandGroups: [(String, [Command])] = [
    ("ASSISTANT", [
        Command("♪", "~say play me something\n", "Play me something it makes up"),
        Command("ALBUM", "~say play my album\n", "Play my album: every piece I saved"),
        Command("JAM", "~say jam with me\n", "Jam: I play, it answers"),
        Command("LULL", "~say make it a lullaby\n", "My piece as a lullaby"),
        Command("8BIT", "~say make it a video game\n", "My piece as a video game"),
        Command("EPIC", "~say make it epic\n", "My piece as a film score"),
        Command("?!", "~say surprise me\n", "Surprise me"),
    ]),
    ("PLAY", [
        Command("⌫", "\u{7F}", "Start over, without saving", only: "compose"),
        Command("STOP", "~drop\n", "Stop learning this song for good", only: "teach"),
        Command("SPACE", " ", "Start the lesson, or hear the part again", compose: "Play it back as a band"),
        Command("N", "n", "Say the notes of the part", compose: "Say what you wrote"),
        Command("→", "\u{1B}[C", "Skip ahead", compose: "Play the next variation"),
        Command("←", "\u{1B}[D", "Go back", compose: "Save it as a MIDI file"),
        Command("RETURN", "\n", "Pause, and carry on", compose: "Stop the sound"),
        Command("S", "s", "Keep what you just played"),
        Command("0", "0", "Home: leave any mode"),
        Command("H", "h", "Spoken help"),
    ]),
    ("MODES", [
        Command("C", "c", "New composition"),
        Command("B", "b", "Live band: it follows you as you play"),
        Command("STYLE", "~bandstyle\n", "Band style: simple or full"),
        Command("T", "t", "Talk mode on or off", compose: "Learn a new composing idea"),
        Command("J", "j", "Jazz course"),
        Command("M", "m", "Song menu"),
        Command("L", "l", "List the songs"),
                Command("G", "g", "Logic control"),
        Command("R", "r", "REAPER control"),
    ]),
    ("SOUND", [
        Command("−", "-", "Slower demo"),
        Command("=", "=", "Faster demo"),
        Command("[", "[", "Band quieter"),
        Command("]", "]", "Band louder"),
        Command(",", ",", "Voice quieter"),
        Command(".", ".", "Voice louder"),
        Command("V", "v", "Change the voice"),
        Command("P", "p", "Also play through the piano"),
    ]),
    ("ACCESS", [
        Command("MIC", "#voice", "Voice control: say \(Link.shared.assistant), then what you want"),
        Command("A", "a", "Type to \(Link.shared.assistant): a command or a question"),
        Command("BIG", "#large", "Large captions, on or off"),
        Command("HC", "#contrast", "High contrast, on or off"),
        Command("HAND", "~hands\n", "Lessons for both hands, right only or left only"),
        Command("EAR", "~ear\n", "Ear training: find the note I play"),
        Command("TICK", "~metronome\n", "Metronome on (say a speed by voice)"),
    ]),
    ("SYSTEM", [
        Command("/", "/", "Open the large-print command page"),
        Command("⇧K", "K", "Set the top key again"),
    ]),
]

// MARK: - Cues for the eyes
//
// Everything the tool signals by sound is also shown: a wrong note frames the window in red
// for a moment, a part played right frames it in green, and the metronome pulses on each beat.

struct FlashFrame: View {
    @ObservedObject var link: Link
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let age = Link.clock() - link.flashAt
            let strength = max(0, 1 - age / (link.flash == "beat" ? 0.18 : 0.55))
            let colour: Color = link.flash == "wrong" ? Color(red: 1, green: 0.25, blue: 0.2) : link.flash == "good" ? Hud.green : .white
            Rectangle()
                .stroke(colour.opacity(strength * (link.flash == "beat" ? (link.beat == 0 ? 0.8 : 0.4) : 0.95)), lineWidth: link.flash == "beat" ? 6 : 14)
                .background(colour.opacity(link.flash == "beat" ? 0 : strength * 0.12))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Voice control: "\(Link.shared.assistant)", then what you want
//
// Speech is turned into text on this Mac by Apple's recogniser, kept on the device where the
// Mac supports that. Nothing is acted on unless it follows the word "\(Link.shared.assistant)". The words after
// it go to the tool as one sentence, which decides what they mean.

final class VoiceControl: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = VoiceControl()
    @Published var on = false
    @Published var status = "OFF"
    @Published var level = 0.0            // how loud the microphone is hearing, 0 to 1
    private var lastWords = ""            // the latest recognised text, kept only to notice when it changes
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "nova.ears")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var settle: Timer?
    private var refresh: Timer?
    private var consumed = 0          // letters of the running transcript already dealt with
    private var openUntil = 0.0       // after "\(Link.shared.assistant)" on its own, the next sentence is the command
    private var awaiting = false
    var vocabulary: [String] = []
    private var lastHeardAt = 0.0     // when words last arrived, so a sentence in progress is never cut off
    private var quietSince = 0.0      // when the assistant last stopped speaking
    private var buffers = 0, loudest = 0.0, lastReport = 0.0
    private var micName = ""
    static let wakeWords = ["hey jarvis", "jarvis", "jarvus", "jervis", "jarvas", "javis", "charvis", "jarvice", "jarvi", "jarves", "jarvis's", "travis", "garvis", "darvis", "service"]
    static let logURL = URL(fileURLWithPath: baseDir + "/voice-log.txt")

    /// Everything the ears do is written down, so a silent failure can be traced afterwards.
    func log(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(text)\n"
        if let h = try? FileHandle(forWritingTo: VoiceControl.logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: VoiceControl.logURL, atomically: true, encoding: .utf8) }
    }

    func toggle() { on ? stop() : begin() }

    func resumeIfWanted() { if UserDefaults.standard.bool(forKey: "voice") { begin() } }

    func begin() {
        status = "ASKING PERMISSION"
        log("turning on")
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async {
                self.log("speech recognition permission: \(auth == .authorized ? "allowed" : "not allowed (\(auth.rawValue))")")
                guard auth == .authorized else { self.status = "SPEECH NOT ALLOWED"; return }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        self.log("microphone permission: \(ok ? "allowed" : "not allowed")")
                        guard ok else { self.status = "MICROPHONE NOT ALLOWED"; return }
                        self.on = true
                        UserDefaults.standard.set(true, forKey: "voice")
                        guard self.startMicrophone() else { return }
                        self.listen()
                        self.refresh?.invalidate()
                        // A fresh start every so often keeps the transcript short and the recogniser quick.
                        self.refresh = Timer.scheduledTimer(withTimeInterval: 40, repeats: true) { _ in
                            if self.on, !Link.shared.speaking, Link.clock() - self.lastHeardAt > 6 { self.listen() }
                        }
                    }
                }
            }
        }
    }

    func stop() {
        on = false
        UserDefaults.standard.set(false, forKey: "voice")
        refresh?.invalidate(); settle?.invalidate(); settle = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        session?.stopRunning(); session = nil
        status = "OFF"
        level = 0
        log("turned off")
    }

    /// Opens the Mac's own microphone, so an audio interface with nothing plugged into it is not used by mistake.
    private func startMicrophone() -> Bool {
        if session?.isRunning == true { return true }
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, *) { types = [.microphone] }
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
        log("microphones found: " + (all.isEmpty ? "none" : all.map { $0.localizedName }.joined(separator: ", ")))
        let builtIn = all.first { $0.transportType == 0x626C746E }         // "bltn": built into the Mac
            ?? all.first { $0.localizedName.lowercased().contains("macbook") }
        guard let mic = builtIn ?? AVCaptureDevice.default(for: .audio) ?? all.first, let input = try? AVCaptureDeviceInput(device: mic) else {
            status = "NO MICROPHONE"; log("could not open any microphone"); return false
        }
        let s = AVCaptureSession()
        let out = AVCaptureAudioDataOutput()
        guard s.canAddInput(input), s.canAddOutput(out) else { status = "NO MICROPHONE"; log("could not attach \(mic.localizedName)"); return false }
        s.addInput(input)
        out.setSampleBufferDelegate(self, queue: queue)
        s.addOutput(out)
        session = s
        micName = mic.localizedName
        queue.async { s.startRunning() }
        log("using microphone: \(mic.localizedName)")
        return true
    }

    // Sound arriving from the microphone: hand it to the recogniser and measure how loud it is.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        request?.appendAudioSampleBuffer(sampleBuffer)
        var peak = 0.0
        if let block = CMSampleBufferGetDataBuffer(sampleBuffer), let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let p = pointer {
                let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
                if isFloat, asbd.mBitsPerChannel == 32 {
                    p.withMemoryRebound(to: Float.self, capacity: length / 4) { f in for i in stride(from: 0, to: length / 4, by: 8) { peak = max(peak, Double(abs(f[i]))) } }
                } else if asbd.mBitsPerChannel == 16 {
                    p.withMemoryRebound(to: Int16.self, capacity: length / 2) { f in for i in stride(from: 0, to: length / 2, by: 8) { peak = max(peak, Double(abs(Int32(f[i]))) / 32768) } }
                } else if asbd.mBitsPerChannel == 32 {
                    p.withMemoryRebound(to: Int32.self, capacity: length / 4) { f in for i in stride(from: 0, to: length / 4, by: 8) { peak = max(peak, abs(Double(f[i])) / 2147483648) } }
                }
            }
        }
        buffers += 1
        loudest = max(loudest, peak)
        let t = Link.clock()
        if t - lastReport > 0.08 {
            let shown = min(1, loudest * 6)
            let report = t - lastReport > 0 && buffers % 6000 < 8      // about once a minute: proof the microphone is alive
            let count = buffers, top = loudest
            loudest = 0
            lastReport = t
            DispatchQueue.main.async {
                self.level = shown
                Link.shared.send(String(format: "~lvl %.4f\n", top))
                if report { self.log(String(format: "hearing sound: %d buffers so far, recent peak %.3f", count, top)) }
            }
        }
    }

    private func listen() {
        settle?.invalidate(); settle = nil
        task?.cancel(); task = nil
        request?.endAudio()
        guard on else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else { status = "RECOGNISER UNAVAILABLE"; log("the speech recogniser is not available"); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // The promise is that speech never leaves this Mac. If macOS cannot do that here, Nova does not listen.
        guard recognizer.supportsOnDeviceRecognition else {
            status = "ON-DEVICE SPEECH NOT READY"
            log("on-device recognition is not available: not listening")
            Link.shared.send("~speak I can't listen yet. This Mac hasn't set up speech recognition that stays on the Mac. Turn on Dictation in System Settings, under Keyboard, wait a minute for it to download, then switch my listening back on.\n")
            stop()
            return
        }
        req.requiresOnDeviceRecognition = true
        // The recogniser is taught the assistant's name, so it writes it far more reliably.
        WakeModel.apply(to: req)
        WakeModel.prepare(name: Link.shared.assistant) { [weak self] in
            guard let self = self, self.on else { return }
            self.log("the recogniser has been taught the name")
            self.listen()
        }
        // Names it should expect to hear: sent by the tool, so they include the songs in the library.
        req.contextualStrings = vocabulary.isEmpty ? ["\(Link.shared.assistant)", "Hey \(Link.shared.assistant)", "composition", "metronome", "REAPER", "Clair de Lune", "ear training", "jazz lesson"] : vocabulary
        request = req
        consumed = 0
        status = "LISTENING FOR \u{201C}\(Link.shared.assistant.uppercased())\u{201D}"
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.on, self.request === req else { return }
                if let r = result { self.transcript(r.bestTranscription.formattedString, final: r.isFinal) }
                if let e = error as NSError? {
                    // "No speech detected" simply means a quiet minute; anything else is worth writing down.
                    if !(e.domain == "kAFAssistantErrorDomain" && [1110, 203, 216, 301].contains(e.code)) { self.log("recogniser error \(e.domain) \(e.code): \(e.localizedDescription)") }
                }
                if error != nil || (result?.isFinal ?? false) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if self.on, self.request === req { self.listen() } }
                }
            }
        }
    }

    /// The running transcript so far. Looks for the wake word and waits for the speaker to finish.
    /// Called when the assistant stops speaking. The microphone goes on hearing its voice for a
    /// moment, and after a bare "\(Link.shared.assistant)" this is when the wait for your request really begins.
    func voiceFinished() {
        quietSince = Link.clock()
        if awaiting { openUntil = Link.clock() + 8 }
    }

    private func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Passes what was recognised to the tool, which decides whether it was meant for \(Link.shared.assistant).
    private func transcript(_ text: String, final: Bool = false) {
        let link = Link.shared
        // What is overheard is private: it is not shown and not written down. Only the tool's
        // decision about words that followed "\(Link.shared.assistant)" ever appears, as "Heard" in the panel.
        if text != lastWords { lastWords = text; lastHeardAt = Link.clock() }
        guard !link.typing else { return }
        let safe = String(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 126 }.map(Character.init)).suffix(600)
        link.send("~ear \(final ? 1 : 0) \(safe)\n")
    }

    /// The tool has acted on a request: start a clean transcript for the next one.
    func startOver() { if on { listen() } }
}

/// A quiet line under the caption suggesting things to say, changing every few seconds.
struct TrySaying: View {
    @ObservedObject var voice = VoiceControl.shared
    static let ideas = ["play me something sad", "make it a lullaby", "play my album", "jam with me", "what did I just play", "teach me Clair de Lune",
                        "add reverb to track two", "metronome at ninety", "surprise me", "make it epic", "new composition", "ear training", "tell me a joke"]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let i = Int(context.date.timeIntervalSince1970 / 5) % TrySaying.ideas.count
            Text((voice.on ? "SAY  \u{201C}\(Link.shared.assistant.uppercased()), " : "PRESS A AND TYPE  \u{201C}") + TrySaying.ideas[i].uppercased() + "\u{201D}")
                .font(Hud.mono(11.5, .medium)).tracking(1.5).foregroundColor(Hud.dim)
                .frame(maxWidth: .infinity).padding(.bottom, 4)
        }
        .accessibilityHidden(true)
    }
}

struct VoiceButton: View {
    @ObservedObject var voice = VoiceControl.shared
    var body: some View {
        HudButton(title: voice.on ? "VOICE ON" : "VOICE OFF", hint: "Voice control. When it is on, say \(Link.shared.assistant), then what you want.") { voice.toggle() }
            .accessibilityLabel(voice.on ? "Voice control is on. Say \(Link.shared.assistant), then what you want." : "Voice control is off")
    }
}

struct VoiceReadout: View {
    @ObservedObject var voice = VoiceControl.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Readout(label: "EARS", value: voice.status, live: voice.on)
            if voice.on {
                // A bar that moves with the microphone, so it is plain whether anything is being heard.
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Hud.faint)
                        Rectangle().fill(Hud.green).frame(width: g.size.width * voice.level)
                    }
                }
                .frame(height: 5)
                .accessibilityLabel("Microphone level \(Int(voice.level * 100)) percent")
            }
        }
    }
}

// MARK: - Small pieces

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle().fill(Hud.green).frame(width: 14, height: 2)
                Text(title).font(Hud.mono(12, .semibold)).tracking(3).foregroundColor(Hud.green).lineLimit(1).fixedSize()
                Rectangle().fill(Hud.faint).frame(height: 1)
            }
            .accessibilityHidden(true)
            content
        }
        .padding(14)
        .background(Hud.panel.opacity(0.75))
        .overlay(Corners().stroke(Hud.green.opacity(0.7), lineWidth: 1.2))
        .overlay(Rectangle().stroke(Hud.faint, lineWidth: 1))
    }
}

/// Four little corner brackets, the classic heads-up-display frame.
struct Corners: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let n: CGFloat = 12
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + n * dx, y: y))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y + n * dy))
        }
        return p
    }
}

struct Readout: View {
    let label: String
    let value: String
    var live = true
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Hud.mono(11.5)).tracking(1.5).foregroundColor(Hud.dim)
            Spacer(minLength: 8)
            Text(value).font(Hud.mono(14, .semibold)).foregroundColor(live ? Hud.soft : Hud.dim)
                .lineLimit(2).multilineTextAlignment(.trailing).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized): \(value)")
    }
}

struct CommandButton: View {
    let command: Command
    let composing: Bool
    @State private var hover = false
    var body: some View {
        let text = composing ? (command.compose ?? command.lesson) : command.lesson
        Button(action: { Link.shared.send(command.send) }) {
            HStack(spacing: 10) {
                Text(command.key)
                    .font(Hud.mono(11.5, .bold))
                    .foregroundColor(hover ? Hud.bg : Hud.green)
                    .frame(width: 58, height: 26)
                    .background(hover ? Hud.green : Hud.green.opacity(0.08))
                    .overlay(Rectangle().stroke(Hud.green.opacity(0.6), lineWidth: 1))
                Text(text).font(Hud.mono(13)).foregroundColor(hover ? .white : Hud.soft.opacity(0.92))
                    .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusRing()
        .onHover { hover = $0 }
        .accessibilityLabel(text)
        .accessibilityHint("Key: \(command.key)")
    }
}

// MARK: - The core: a ring of liquid light that moves with the voice and with your playing
//
// Drawn entirely on the graphics chip. The wave itself is a small shader: for every pixel it
// asks "how far am I from the ring's edge here?", where the edge is pushed outward by the
// strength of the voice at that angle. Because the picture is computed fresh for each pixel
// on every screen refresh, there are no bars or steps to see, only a continuous surface.
// The sixteen voice bands are not used raw: each one rides on a spring, so the ring swells,
// overshoots a little and settles, like water.

final class CoreScene: SKScene {
    weak var link: Link?
    private var ringSprite = SKSpriteNode()
    private var scopeSprite = SKSpriteNode()
    private var arcs: [(node: SKShapeNode, speed: CGFloat)] = []
    private let modeLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let subLabel = SKLabelNode(fontNamed: "Menlo-Regular")
    private var uniforms: [SKUniform] = []
    private let uLevel = SKUniform(name: "u_level", float: 0)
    private let uScope = SKUniform(name: "u_amp", float: 0)
    // Spring state for the sixteen bands.
    private var value = [Double](repeating: 0, count: 16)
    private var speedOf = [Double](repeating: 0, count: 16)
    private var aim = [Double](repeating: 0, count: 16)
    private var last = 0.0
    private var smoothLevel = 0.0

    private static let ringShader = """
    void main() {
        vec2 uv = (v_tex_coord - 0.5) * 2.0;
        float r = length(uv);
        float ang = atan(uv.y, uv.x);
        // 0 at the top of the ring, 15 at the bottom, the same on both sides.
        float x = abs(atan(uv.x, uv.y)) / 3.14159265 * 15.0;
        vec4 k = vec4(0.0, 1.0, 2.0, 3.0);
        float s2 = 2.0 * 1.25 * 1.25;
        vec4 w0 = exp(-(x - k) * (x - k) / s2);
        vec4 w1 = exp(-(x - k - 4.0) * (x - k - 4.0) / s2);
        vec4 w2 = exp(-(x - k - 8.0) * (x - k - 8.0) / s2);
        vec4 w3 = exp(-(x - k - 12.0) * (x - k - 12.0) / s2);
        float amp = (dot(u_b0, w0) + dot(u_b1, w1) + dot(u_b2, w2) + dot(u_b3, w3))
                  / (dot(w0, vec4(1.0)) + dot(w1, vec4(1.0)) + dot(w2, vec4(1.0)) + dot(w3, vec4(1.0)));
        float t = u_time;
        float base = 0.50;
        vec3 green = vec3(0.22, 1.0, 0.53);
        vec3 pale = vec3(0.80, 1.0, 0.90);
        vec3 col = vec3(0.0);
        float alpha = 0.0;
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            // Slow waves travelling round the ring in both directions, like a swell.
            float flow = 0.5 + 0.5 * sin(ang * (3.0 + fi * 2.0) + t * (1.1 + fi * 0.6) + fi * 2.1);
            float swell = 0.010 * sin(ang * 5.0 - t * 1.6 + fi * 1.7) + 0.006 * sin(ang * 9.0 + t * 2.3 + fi);
            float R = base + swell + amp * (0.34 - fi * 0.085) * (0.6 + 0.4 * flow) + u_level * 0.02;
            float d = r - R;
            float line = exp(-d * d / (2.0 * 0.0045 * 0.0045));
            float halo = exp(-d * d / (2.0 * 0.035 * 0.035)) * (0.30 + 0.25 * u_level);
            float body = smoothstep(base - 0.006, base + 0.006, r) * (1.0 - smoothstep(R - 0.02, R, r)) * (0.16 - fi * 0.035);
            float a = line * (1.0 - fi * 0.28) + halo * (1.0 - fi * 0.2) + body;
            col += mix(green, pale, clamp(line, 0.0, 1.0)) * a;
            alpha += a;
        }
        // The steady inner edge the waves grow from, and the glowing heart.
        float edge = exp(-(r - base) * (r - base) / (2.0 * 0.003 * 0.003)) * 0.55;
        float hr = 0.30 + 0.035 * u_level;
        float rim = exp(-(r - hr) * (r - hr) / (2.0 * 0.004 * 0.004)) * 0.9;
        float glow = (1.0 - smoothstep(0.0, hr, r)) * (0.05 + 0.5 * u_level) * (0.35 + 0.65 * (1.0 - r / hr));
        col += green * (edge + rim + glow);
        alpha += edge + rim + glow;
        alpha = clamp(alpha, 0.0, 1.0);
        gl_FragColor = vec4(min(col, vec3(1.0)) * 1.0, alpha);
    }
    """

    private static let scopeShader = """
    void main() {
        vec2 uv = v_tex_coord;
        float t = u_time;
        float pin = sin(uv.x * 3.14159265);
        float y = (sin(uv.x * 19.0 - t * 5.0) * 0.5 + sin(uv.x * 41.0 + t * 7.5) * 0.28 + sin(uv.x * 7.0 - t * 2.2) * 0.42) * pin * u_amp;
        float d = (uv.y - 0.5) - y * 0.42;
        float line = exp(-d * d / (2.0 * 0.03 * 0.03));
        float halo = exp(-d * d / (2.0 * 0.16 * 0.16)) * 0.35;
        float a = clamp(line + halo, 0.0, 1.0) * smoothstep(0.0, 0.06, pin);
        gl_FragColor = vec4(mix(vec3(0.22, 1.0, 0.53), vec3(0.8, 1.0, 0.9), line) * a, a);
    }
    """

    override func didMove(to view: SKView) { build() }
    override func didChangeSize(_ oldSize: CGSize) { if view != nil { build() } }

    private func build() {
        removeAllChildren()
        arcs = []
        backgroundColor = .clear
        guard size.width > 60, size.height > 60 else { return }
        let scopeH: CGFloat = 34
        let side = min(size.width, size.height - scopeH - 6)
        let centre = CGPoint(x: size.width / 2, y: scopeH + 6 + (size.height - scopeH - 6) / 2)
        let R = side / 2 - 4
        let green = NSColor(red: 0.22, green: 1.0, blue: 0.53, alpha: 1)

        // Outer ring and tick marks: drawn once.
        let ring = SKShapeNode(circleOfRadius: R)
        ring.strokeColor = green.withAlphaComponent(0.18); ring.lineWidth = 1; ring.position = centre
        addChild(ring)
        let ticks = CGMutablePath()
        for i in 0..<72 {
            let a = CGFloat(i) / 72 * 2 * .pi
            let r1 = R * (i % 6 == 0 ? 0.925 : 0.955), r2 = R * 0.975
            ticks.move(to: CGPoint(x: cos(a) * r1, y: sin(a) * r1)); ticks.addLine(to: CGPoint(x: cos(a) * r2, y: sin(a) * r2))
        }
        let tickNode = SKShapeNode(path: ticks)
        tickNode.strokeColor = green.withAlphaComponent(0.35); tickNode.lineWidth = 1; tickNode.position = centre
        addChild(tickNode)
        // Turning arcs, each with a bright bead at its head.
        let plan: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.88, 0.26, 1.9, 0.0, 2), (0.88, 0.26, 0.7, 3.3, 2), (0.80, -0.42, 2.6, 1.0, 1), (0.71, 0.6, 1.1, 0.5, 2.5), (0.71, 0.6, 0.5, 3.0, 2.5),
        ]
        for (rf, speed, length, phase, width) in plan {
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: R * rf, startAngle: 0, endAngle: length, clockwise: false)
            let arc = SKShapeNode(path: path)
            arc.strokeColor = green.withAlphaComponent(width == 1 ? 0.45 : 0.85); arc.lineWidth = width; arc.lineCap = .round
            arc.position = centre; arc.zRotation = phase
            if width > 1 {
                let bead = SKShapeNode(circleOfRadius: 3)
                bead.fillColor = NSColor(red: 0.8, green: 1, blue: 0.9, alpha: 1); bead.strokeColor = .clear
                bead.position = CGPoint(x: cos(length) * R * rf, y: sin(length) * R * rf)
                arc.addChild(bead)
            }
            addChild(arc)
            arcs.append((arc, speed))
        }

        // The liquid ring.
        let names = ["u_b0", "u_b1", "u_b2", "u_b3"]
        uniforms = names.map { SKUniform(name: $0, vectorFloat4: vector_float4(0, 0, 0, 0)) }
        let shader = SKShader(source: CoreScene.ringShader, uniforms: uniforms + [uLevel])
        ringSprite = SKSpriteNode(color: .clear, size: CGSize(width: R * 1.72, height: R * 1.72))
        ringSprite.shader = shader
        ringSprite.position = centre; ringSprite.zPosition = 5
        addChild(ringSprite)

        modeLabel.fontSize = 15; modeLabel.fontColor = NSColor(red: 0.55, green: 1, blue: 0.78, alpha: 1)
        modeLabel.position = CGPoint(x: centre.x, y: centre.y - 2); modeLabel.zPosition = 10
        addChild(modeLabel)
        subLabel.fontSize = 8.5; subLabel.fontColor = NSColor(red: 0.11, green: 0.48, blue: 0.27, alpha: 1)
        subLabel.position = CGPoint(x: centre.x, y: centre.y - 20); subLabel.zPosition = 10
        addChild(subLabel)

        // The line of sound underneath.
        scopeSprite = SKSpriteNode(color: .clear, size: CGSize(width: max(60, size.width - 80), height: scopeH))
        scopeSprite.shader = SKShader(source: CoreScene.scopeShader, uniforms: [uScope])
        scopeSprite.position = CGPoint(x: size.width / 2, y: scopeH / 2)
        addChild(scopeSprite)
    }

    override func update(_ currentTime: TimeInterval) {
        guard let link = link else { return }
        let now = Link.clock()
        let dt = min(0.05, max(0.001, now - last))
        last = now
        let offline = link.state == "OFFLINE"

        // Where each band wants to be.
        var want = [Double](repeating: 0, count: 16)
        if let bands = link.voiceBands(at: now) {
            for i in 0..<16 { want[i] = pow(bands[i], 1.35) }
        } else if link.speaking && link.voiceFrames.isEmpty {
            let into = now - (link.gotWord ? link.wordAt : link.sayStarted)
            for i in 0..<16 { want[i] = (0.3 + 0.35 * exp(-into * 3)) * (0.55 + 0.45 * sin(Double(i) * 0.9 + now * 6)) }
        } else if !offline {
            for i in 0..<16 { want[i] = 0.05 + 0.035 * sin(Double(i) * 0.55 + now * 1.1) }      // a slow tide when quiet
        }
        // Each note on the piano lifts the ring at its own place.
        for r in link.ripples.suffix(16) {
            let age = now - r.at
            if age < 0 || age > 1.4 { continue }
            let centre = Double(r.pitch - 21) / 87 * 15
            let push = (0.4 + 0.6 * r.strength) * exp(-age * 3)
            for i in 0..<16 { want[i] = max(want[i], push * exp(-pow(Double(i) - centre, 2) / 5)) }
        }
        // Smooth the target a little (the measurements arrive in steps), then let a spring
        // carry the value: it rushes up, overshoots slightly and settles.
        let blend = min(1, dt * 26)
        let stiffness = 210.0, damping = 17.0
        var sum = 0.0
        for i in 0..<16 {
            aim[i] += (want[i] - aim[i]) * blend
            let force = stiffness * (aim[i] - value[i]) - damping * speedOf[i]
            speedOf[i] += force * dt
            value[i] += speedOf[i] * dt
            value[i] = max(0, min(1.4, value[i]))
            sum += value[i]
        }
        let level = min(1, sum / 16 * 1.7)
        smoothLevel += (level - smoothLevel) * min(1, dt * 10)
        link.level = smoothLevel
        for j in 0..<4 where j < uniforms.count {
            uniforms[j].vectorFloat4Value = vector_float4(Float(value[j * 4]), Float(value[j * 4 + 1]), Float(value[j * 4 + 2]), Float(value[j * 4 + 3]))
        }
        uLevel.floatValue = Float(smoothLevel)
        uScope.floatValue = Float(0.04 + smoothLevel)
        ringSprite.alpha = offline ? 0.35 : 1
        for arc in arcs { arc.node.zRotation += arc.speed * CGFloat(dt) * CGFloat(0.9 + 2.2 * smoothLevel) }

        let mode = link.state != "ONLINE" ? link.state : link.paused ? "PAUSED" : link.modeName
        if modeLabel.text != mode { modeLabel.text = mode }
        let sub = link.paused ? "RETURN OR KEY 6" : link.speaking ? "SPEAKING" : link.state == "ONLINE" ? "LISTENING" : ""
        if subLabel.text != sub { subLabel.text = sub }
    }
}

struct Core: NSViewRepresentable {
    let link: Link
    let active: Bool
    func makeNSView(context: Context) -> SKView {
        let view = SKView()
        view.allowsTransparency = true
        view.preferredFramesPerSecond = 120
        view.ignoresSiblingOrder = true
        let scene = CoreScene(size: CGSize(width: 500, height: 420))
        scene.scaleMode = .resizeFill
        scene.link = link
        view.presentScene(scene)
        return view
    }
    func updateNSView(_ view: SKView, context: Context) { view.isPaused = !active }
}

// MARK: - What is being said, filling with light as it is spoken

// The caption works like a subtitle. Only the sentence being spoken is on screen, in large
// type, and light runs through it letter by letter in step with the voice. The light has a
// soft leading edge and a bright tail that settles, and its position is eased from frame to
// frame, so it glides instead of jumping from word to word. When a sentence ends, the next
// one rises into its place; when the voice stops, the last one lingers and fades.
struct Caption: View {
    @ObservedObject var link: Link
    let active: Bool

    private func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
        let k = max(0, min(1, t))
        return Color(red: a.0 + (b.0 - a.0) * k, green: a.1 + (b.1 - a.1) * k, blue: a.2 + (b.2 - a.2) * k)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: active && link.captionLive ? 1.0 / 60 : 0.5)) { _ in
            let now = Link.clock()
            let cursor = link.glide(to: link.spokenExact(at: now), at: now)
            let index = link.segmentIndex(at: cursor)
            let range = link.segments.indices.contains(index) ? link.segments[index] : NSRange(location: 0, length: 0)
            let piece = Array((link.caption as NSString).substring(with: range).utf16)
            let dim: (Double, Double, Double) = Hud.contrast ? (0.55, 0.72, 0.62) : (0.16, 0.46, 0.30)
            let soft: (Double, Double, Double) = Hud.contrast ? (0.93, 1.0, 0.95) : (0.55, 1.0, 0.78)
            let white: (Double, Double, Double) = (1, 1, 1)
            let lit: AttributedString = {
                var out = AttributedString()
                for (i, unit) in piece.enumerated() {
                    var ch = AttributedString(String(utf16CodeUnits: [unit], count: 1))
                    let behind = cursor - Double(range.location + i)      // how long ago the light passed this letter
                    if behind >= 0 { ch.foregroundColor = mix(soft, white, 1 - behind / 9) }
                    else { ch.foregroundColor = mix(dim, white, 1 + behind / 2.2) }
                    out += ch
                }
                return out
            }()
            // Held for two seconds after the voice stops, then faded out.
            let fade = link.speaking ? 1.0 : max(0, min(1, 1 - (now - link.doneAt - 2.0) / 1.6))
            ZStack {
                Text(lit)
                    .font(.system(size: link.large ? 36 : 24, weight: .medium, design: .monospaced))
                    .lineSpacing(6)
                    .lineLimit(link.large ? 4 : 3)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .shadow(color: Hud.green.opacity(link.speaking ? 0.55 : 0.2), radius: 9)
                    .id(index)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity.combined(with: .offset(y: -10))))
            }
            .animation(.easeOut(duration: 0.3), value: index)
            .frame(maxWidth: .infinity, minHeight: link.large ? 190 : 96, maxHeight: link.large ? 190 : 96, alignment: .center)
            .opacity(link.caption.isEmpty ? 0 : fade)
        }
        // The voice already says this aloud; VoiceOver must not say it a second time.
        .accessibilityHidden(true)
    }
}

struct Keys: View {
    @ObservedObject var link: Link
    let active: Bool
    static let whites: [Int] = (21...108).filter { ![1, 3, 6, 8, 10].contains($0 % 12) }
    var body: some View {
        TimelineView(.periodic(from: .now, by: active ? 1.0 / 30 : 1.0 / 2)) { _ in
            Canvas { g, size in
                let w = size.width / CGFloat(Keys.whites.count)
                let rain: CGFloat = 64               // room above the keys for the rising light
                let top: CGFloat = rain + 16
                let h = size.height - top
                // Every note you play rises from its key as a bar of light: long notes make long
                // bars, loud notes bright ones.
                let t = Link.clock()
                func centre(_ pitch: Int) -> CGFloat {
                    let white = [1, 3, 6, 8, 10].contains(pitch % 12) ? pitch - 1 : pitch
                    let i = CGFloat(Keys.whites.firstIndex(of: white) ?? 0)
                    return white == pitch ? i * w + w / 2 : (i + 1) * w
                }
                for r in link.ripples {
                    let speed = 46.0
                    let head = (t - r.at) * speed
                    let tail = r.off.map { (t - $0) * speed } ?? 0
                    if tail > Double(rain) { continue }
                    let y0 = Double(rain) - min(Double(rain), head), y1 = Double(rain) - tail
                    if y1 - y0 < 1 { continue }
                    let rect = CGRect(x: centre(r.pitch) - w * 0.28, y: y0 + 10, width: w * 0.56, height: y1 - y0)
                    g.fill(Path(roundedRect: rect, cornerRadius: 2), with: .linearGradient(
                        Gradient(colors: [Hud.green.opacity(0), Hud.soft.opacity(0.35 + 0.6 * r.strength)]),
                        startPoint: CGPoint(x: 0, y: 10), endPoint: CGPoint(x: 0, y: Double(rain) + 10)))
                }
                for (i, pitch) in Keys.whites.enumerated() {
                    let r = CGRect(x: CGFloat(i) * w + 0.5, y: top, width: w - 1, height: h)
                    if let v = link.down[pitch] {
                        var glow = g
                        glow.addFilter(.blur(radius: 6))
                        glow.fill(Path(r), with: .color(Hud.green))
                        g.fill(Path(r), with: .color(Hud.green.opacity(0.55 + 0.45 * Double(v) / 127)))
                    } else if link.played.contains(pitch) {
                        g.fill(Path(r), with: .color(Hud.soft.opacity(0.35)))
                    }
                    g.stroke(Path(r), with: .color(Hud.dim.opacity(0.75)), lineWidth: 1)
                    // The button keys carry their number; home and keep carry a letter.
                    if let n = link.buttons.firstIndex(of: pitch) {
                        if link.down[pitch] == nil { g.fill(Path(r), with: .color(Hud.green.opacity(0.16))) }
                        g.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(Hud.green.opacity(0.8)), lineWidth: 1)
                        let label = n < 8 ? "\(n + 1)" : n == 8 ? "H" : "K"
                        g.draw(Text(label).font(Hud.mono(8.5, .bold)).foregroundColor(Hud.green),
                               at: CGPoint(x: r.midX, y: top - 8))
                    }
                }
                for (i, pitch) in Keys.whites.enumerated() where pitch < 108 && [0, 2, 5, 7, 9].contains(pitch % 12) {
                    let black = pitch + 1
                    let r = CGRect(x: CGFloat(i + 1) * w - w * 0.3, y: top, width: w * 0.6, height: h * 0.62)
                    let held = link.down[black] != nil
                    g.fill(Path(r), with: .color(held ? Hud.soft : link.played.contains(black) ? Hud.dim : Hud.bg))
                    g.stroke(Path(r), with: .color(Hud.dim), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// What the numbered keys on the piano do right now. It changes with the mode.
func buttonJobs(_ mode: String) -> [(String, String)] {
    let lesson = ["START / HEAR AGAIN", "SAY THE NOTES", "SKIP AHEAD", "GO BACK", "TALK MODE", "PAUSE", "COMPOSE", "HELP"]
    let compose = ["PLAY AS BAND", "SAY WHAT I WROTE", "VARIATION", "SAVE", "LEARN AN IDEA", "STOP SOUND", "NEW PIECE", "HELP"]
    let menu = ["START IT", "COUNT SONGS", "NEXT", "PREVIOUS", "TALK MODE", "PAUSE", "COMPOSE", "HELP"]
    let home = ["OPEN IT", "LIST CHOICES", "NEXT CHOICE", "PREVIOUS", "TALK MODE", "STOP", "COMPOSE", "HELP"]
    let jazz = ["JAM AGAIN", "THE IDEA", "NEXT LESSON", "PREVIOUS", "TALK MODE", "STOP BAND", "COMPOSE", "HELP"]
    let daw = ["CHOOSE", "BACK A LEVEL", "NEXT", "PREVIOUS", "TALK MODE", "STOP", "COMPOSE", "HELP"]
    let jobs = mode == "compose" ? compose : mode == "menu" ? menu : mode == "idle" ? home : mode == "jazz" ? jazz
        : (mode == "logic" || mode == "reaper") ? daw : lesson
    return jobs.enumerated().map { ("\($0.offset + 1)", $0.element) } + [("H", "HOME"), ("K", "KEEP")]
}

struct Legend: View {
    @ObservedObject var link: Link
    var body: some View {
        HStack(spacing: 6) {
            ForEach(buttonJobs(link.mode), id: \.0) { key, job in
                HStack(spacing: 5) {
                    Text(key).font(Hud.mono(11, .bold)).foregroundColor(Hud.bg)
                        .frame(width: 18, height: 18).background(Hud.green)
                    Text(job).font(Hud.mono(10.5, .medium)).foregroundColor(Hud.soft).lineLimit(1).fixedSize()
                }
                .padding(.trailing, 4)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Piano buttons: " + buttonJobs(link.mode).map { "\($0.0), \($0.1.lowercased())" }.joined(separator: ". "))
    }
}

// MARK: - Visualiser: your playing as rising light, filling the window
//
// Drawn by SpriteKit on the graphics chip, not by the window's own drawing code: every bar,
// glow and spark is a sprite, so it stays smooth however many notes are on screen. Notes are
// handed to it the moment they arrive from the piano, without waiting for the next redraw.

final class RainScene: SKScene {
    weak var link: Link?
    private struct Bar { let node: SKSpriteNode; let glow: SKSpriteNode; let born: Double; var held: Bool; let fire: SKEmitterNode? }
    private var held: [Int: Int] = [:]          // pitch (negative for the tool's notes) -> index in bars
    private var bars: [Bar?] = []
    private var keys: [Int: SKSpriteNode] = [:]
    private var lamps: [Int: SKSpriteNode] = [:]
    private var keyW: CGFloat = 20, floorY: CGFloat = 150
    private let rise: CGFloat = 330                  // how fast light rises, in points a second
    private var last = 0.0
    private var falling: [(node: SKSpriteNode, glow: SKSpriteNode, at: Double)] = []
    private var nextRoll = 0                         // the next note of the file still to appear
    private let playing = SKLabelNode(fontNamed: "Menlo-Bold")
    private let progress = SKSpriteNode(color: NSColor(red: 0.22, green: 1.0, blue: 0.53, alpha: 1), size: CGSize(width: 1, height: 3))
    private let chord = SKLabelNode(fontNamed: "Menlo-Bold")
    private let caption = SKLabelNode(fontNamed: "Menlo-Regular")
    private let notice = SKLabelNode(fontNamed: "Menlo-Bold")
    private static let green = NSColor(red: 0.22, green: 1.0, blue: 0.53, alpha: 1)
    private static let soft = NSColor(red: 0.55, green: 1.0, blue: 0.78, alpha: 1)
    private static let teal = NSColor(red: 0.2, green: 0.7, blue: 0.68, alpha: 1)
    private static let dark = NSColor(red: 0.008, green: 0.022, blue: 0.014, alpha: 1)

    // Three small pictures, drawn once and reused by every sprite.
    private static func picture(_ size: CGSize, _ draw: (CGContext) -> Void) -> SKTexture {
        let image = NSImage(size: size)
        image.lockFocus()
        if let g = NSGraphicsContext.current?.cgContext { draw(g) }
        image.unlockFocus()
        return SKTexture(image: image)
    }
    private static let barTexture = picture(CGSize(width: 24, height: 48)) { g in
        g.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1, width: 22, height: 46), cornerWidth: 7, cornerHeight: 7, transform: nil))
        g.clip()
        let colours = [CGColor(gray: 1, alpha: 0.72), CGColor(gray: 1, alpha: 1)] as CFArray
        let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1])!
        g.drawLinearGradient(fade, start: CGPoint(x: 0, y: 48), end: CGPoint(x: 0, y: 0), options: [])
    }
    private static let glowTexture = picture(CGSize(width: 64, height: 64)) { g in
        let colours = [CGColor(gray: 1, alpha: 0.9), CGColor(gray: 1, alpha: 0)] as CFArray
        let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1])!
        g.drawRadialGradient(fade, startCenter: CGPoint(x: 32, y: 32), startRadius: 0, endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
    }

    private func isBlack(_ p: Int) -> Bool { [1, 3, 6, 8, 10].contains(((p % 12) + 12) % 12) }
    private func centre(_ pitch: Int) -> CGFloat {
        let white = isBlack(pitch) ? pitch - 1 : pitch
        let i = CGFloat(Keys.whites.firstIndex(of: white) ?? 0)
        return white == pitch ? i * keyW + keyW / 2 : (i + 1) * keyW
    }

    override func didMove(to view: SKView) { build() }
    override func didChangeSize(_ oldSize: CGSize) { if view != nil { build() } }

    private func build() {
        removeAllChildren()
        bars = []; held = [:]; keys = [:]; lamps = [:]
        backgroundColor = RainScene.dark
        guard size.width > 100 else { return }
        keyW = size.width / CGFloat(Keys.whites.count)
        floorY = min(160, size.height * 0.2)

        // A faint line at every C, and soft lines that drift upward like paper on a roll.
        let guides = CGMutablePath()
        for (i, p) in Keys.whites.enumerated() where p % 12 == 0 {
            guides.move(to: CGPoint(x: CGFloat(i) * keyW, y: floorY)); guides.addLine(to: CGPoint(x: CGFloat(i) * keyW, y: size.height))
        }
        let lines = SKShapeNode(path: guides)
        lines.strokeColor = RainScene.green.withAlphaComponent(0.09); lines.lineWidth = 1; lines.zPosition = 0
        addChild(lines)
        let drift = CGMutablePath()
        var y: CGFloat = 0
        while y < size.height + 80 { drift.move(to: CGPoint(x: 0, y: y)); drift.addLine(to: CGPoint(x: size.width, y: y)); y += 80 }
        let roll = SKShapeNode(path: drift)
        roll.strokeColor = RainScene.green.withAlphaComponent(0.05); roll.lineWidth = 1; roll.zPosition = 0
        roll.position = CGPoint(x: 0, y: floorY)
        roll.run(.repeatForever(.sequence([.moveBy(x: 0, y: 80, duration: 1.6), .moveBy(x: 0, y: -80, duration: 0)])))
        addChild(roll)

        // The keyboard, in front of everything that rises.
        let board = SKSpriteNode(color: RainScene.dark, size: CGSize(width: size.width, height: floorY))
        board.anchorPoint = .zero; board.zPosition = 20
        addChild(board)
        for (i, pitch) in Keys.whites.enumerated() {
            let k = SKSpriteNode(color: RainScene.green.withAlphaComponent(0.07), size: CGSize(width: keyW - 1.5, height: floorY - 3))
            k.anchorPoint = CGPoint(x: 0.5, y: 0); k.position = CGPoint(x: CGFloat(i) * keyW + keyW / 2, y: 0); k.zPosition = 21
            addChild(k); keys[pitch] = k
        }
        for (i, pitch) in Keys.whites.enumerated() where pitch < 108 && [0, 2, 5, 7, 9].contains(pitch % 12) {
            let k = SKSpriteNode(color: RainScene.dark, size: CGSize(width: keyW * 0.6, height: floorY * 0.62))
            k.anchorPoint = CGPoint(x: 0.5, y: 1); k.position = CGPoint(x: CGFloat(i + 1) * keyW, y: floorY - 3); k.zPosition = 23
            let edge = SKShapeNode(rect: CGRect(x: -keyW * 0.3, y: -floorY * 0.62, width: keyW * 0.6, height: floorY * 0.62))
            edge.strokeColor = RainScene.green.withAlphaComponent(0.45); edge.lineWidth = 1
            k.addChild(edge)
            addChild(k); keys[pitch + 1] = k
        }
        let gaps = CGMutablePath()
        for i in 0...Keys.whites.count { gaps.move(to: CGPoint(x: CGFloat(i) * keyW, y: 0)); gaps.addLine(to: CGPoint(x: CGFloat(i) * keyW, y: floorY)) }
        let seams = SKShapeNode(path: gaps)
        seams.strokeColor = RainScene.green.withAlphaComponent(0.35); seams.lineWidth = 1; seams.zPosition = 22
        addChild(seams)
        let strike = SKSpriteNode(color: RainScene.green, size: CGSize(width: size.width, height: 2))
        strike.anchorPoint = .zero; strike.position = CGPoint(x: 0, y: floorY - 1); strike.zPosition = 25
        addChild(strike)
        // The button keys keep their numbers.
        for (n, pitch) in (link?.buttons ?? []).enumerated() {
            let label = SKLabelNode(fontNamed: "Menlo-Bold")
            label.text = n < 8 ? "\(n + 1)" : n == 8 ? "H" : "K"
            label.fontSize = 11; label.fontColor = RainScene.green
            label.position = CGPoint(x: centre(pitch), y: 8); label.zPosition = 26
            addChild(label)
        }

        chord.fontSize = 38; chord.fontColor = RainScene.soft; chord.horizontalAlignmentMode = .left
        chord.position = CGPoint(x: 26, y: size.height - 96); chord.zPosition = 30
        addChild(chord)
        let title = SKLabelNode(fontNamed: "Menlo-Bold")
        title.text = "NOVA  //  VISUALISER"; title.fontSize = 11; title.fontColor = RainScene.green.withAlphaComponent(0.5)
        title.horizontalAlignmentMode = .left; title.position = CGPoint(x: 26, y: size.height - 50); title.zPosition = 30
        addChild(title)
        caption.fontSize = 15; caption.fontColor = RainScene.soft; caption.numberOfLines = 2
        caption.preferredMaxLayoutWidth = min(620, size.width * 0.5); caption.verticalAlignmentMode = .top
        caption.position = CGPoint(x: size.width / 2, y: size.height - 40); caption.zPosition = 30
        addChild(caption)
        notice.fontSize = 22; notice.fontColor = RainScene.soft; notice.zPosition = 30
        notice.position = CGPoint(x: size.width / 2, y: size.height * 0.6)
        addChild(notice)
        playing.fontSize = 13; playing.fontColor = RainScene.soft; playing.horizontalAlignmentMode = .left
        playing.position = CGPoint(x: 26, y: size.height - 124); playing.zPosition = 30
        addChild(playing)
        progress.anchorPoint = .zero; progress.position = CGPoint(x: 0, y: size.height - 3); progress.zPosition = 30
        progress.size = CGSize(width: 0, height: 3)
        addChild(progress)
        falling = []; nextRoll = 0
    }

    /// Forgets the file that was playing.
    func clearRoll() {
        for f in falling { f.node.removeFromParent(); f.glow.removeFromParent() }
        falling = []; nextRoll = 0
        progress.size.width = 0
    }

    /// Notes of the file fall from the top and reach the keys exactly when they sound.
    private func updateRoll(_ link: Link, now: Double) {
        guard let zero = link.rollZero else { return }
        let song = now - zero                                   // where we are in the file, in seconds
        let fallTime = Double((size.height - floorY) / rise)    // how long a note takes to fall
        while nextRoll < link.roll.count, link.roll[nextRoll].t - fallTime <= song {
            let n = link.roll[nextRoll]
            nextRoll += 1
            if n.t + n.dur < song { continue }                  // already over (the window was just opened)
            let black = isBlack(n.pitch)
            let width = black ? keyW * 0.56 : keyW * 0.84
            let strength = Double(n.vel) / 127
            // Each hand (track) has its own green, so the two can be told apart.
            let tint = n.track % 2 == 0 ? RainScene.green : RainScene.teal
            let node = SKSpriteNode(texture: RainScene.barTexture)
            node.centerRect = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.size = CGSize(width: width, height: max(10, CGFloat(n.dur) * rise))
            node.color = tint.blended(withFraction: 0.1 + 0.3 * strength, of: .white) ?? tint
            node.colorBlendFactor = 1; node.alpha = 0.7 + 0.3 * strength; node.zPosition = 10
            let glow = SKSpriteNode(texture: RainScene.glowTexture)
            glow.centerRect = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
            glow.anchorPoint = CGPoint(x: 0.5, y: 0)
            glow.size = CGSize(width: width * 3, height: node.size.height + 28)
            glow.color = tint; glow.colorBlendFactor = 1; glow.blendMode = .add; glow.alpha = 0.22 + 0.25 * strength; glow.zPosition = 9
            node.position.x = centre(n.pitch); glow.position.x = centre(n.pitch)
            addChild(glow); addChild(node)
            falling.append((node, glow, n.t))
        }
        var kept: [(node: SKSpriteNode, glow: SKSpriteNode, at: Double)] = []
        for f in falling {
            let y = floorY + CGFloat(f.at - song) * rise        // the bottom edge: at the keys when the note sounds
            if y + f.node.size.height < floorY - 4 {
                f.node.removeFromParent(); f.glow.removeFromParent()
            } else {
                f.node.position.y = y; f.glow.position.y = y - 14
                kept.append(f)
            }
        }
        falling = kept
        progress.size.width = size.width * CGFloat(max(0, min(1, song / max(1, link.rollLength))))
    }

    /// A key went down (strength above zero) or came up. `mine` is your playing; otherwise the tool's.
    func note(_ pitch: Int, strength: Double, mine: Bool) {
        guard pitch >= 21, pitch <= 108, size.width > 100 else { return }
        let id = mine ? pitch : -pitch
        let now = Link.clock()
        if let i = held[id], i < bars.count, var bar = bars[i] {     // let go of the note that was there
            bar.held = false
            bar.fire?.particleBirthRate = 0
            bars[i] = bar
            held[id] = nil
        }
        let black = isBlack(pitch)
        if let key = keys[pitch] {
            key.removeAllActions()
            let rest = black ? RainScene.dark : RainScene.green.withAlphaComponent(0.07)
            if strength > 0 { key.color = mine ? RainScene.soft : RainScene.teal }
            else { key.run(.colorize(with: rest, colorBlendFactor: 0, duration: 0.12)) }
        }
        guard strength > 0 else { lamps[id]?.run(.sequence([.fadeOut(withDuration: 0.18), .removeFromParent()])); lamps[id] = nil; return }
        if !mine, link?.rollZero != nil {
            let burst = sparks(rate: 900, count: 8 + Int(12 * strength), speed: 150 + 240 * strength)
            burst.position = CGPoint(x: centre(pitch), y: floorY); addChild(burst)
            burst.run(.sequence([.wait(forDuration: 1.1), .removeFromParent()]))
            let lamp = SKSpriteNode(texture: RainScene.glowTexture)
            lamp.size = CGSize(width: keyW * 4.5, height: keyW * 4.5); lamp.position = CGPoint(x: centre(pitch), y: floorY)
            lamp.color = RainScene.soft; lamp.colorBlendFactor = 1; lamp.blendMode = .add; lamp.zPosition = 27
            lamp.alpha = 0.3 + 0.45 * strength
            addChild(lamp)
            lamps[id]?.removeFromParent(); lamps[id] = lamp
            return
        }

        let x = centre(pitch), width = black ? keyW * 0.56 : keyW * 0.84
        let tint = mine ? RainScene.green : RainScene.teal
        let node = SKSpriteNode(texture: RainScene.barTexture)
        node.centerRect = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)
        node.anchorPoint = CGPoint(x: 0.5, y: 0); node.position = CGPoint(x: x, y: floorY)
        node.size = CGSize(width: width, height: 6)
        node.color = mine ? RainScene.green.blended(withFraction: 0.1 + 0.35 * strength, of: .white) ?? tint : tint
        node.colorBlendFactor = 1; node.alpha = mine ? 0.75 + 0.25 * strength : 0.55; node.zPosition = 10
        let glow = SKSpriteNode(texture: RainScene.glowTexture)
        glow.centerRect = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        glow.anchorPoint = CGPoint(x: 0.5, y: 0); glow.position = CGPoint(x: x, y: floorY - 14)
        glow.size = CGSize(width: width * 3.2, height: 34)
        glow.color = tint; glow.colorBlendFactor = 1; glow.blendMode = .add
        glow.alpha = mine ? 0.3 + 0.35 * strength : 0.2; glow.zPosition = 9
        addChild(glow); addChild(node)

        var fire: SKEmitterNode? = nil
        if mine {
            // A burst of sparks on the strike, then a small flame for as long as the key is held.
            let burst = sparks(rate: 900, count: 10 + Int(16 * strength), speed: 170 + 300 * strength)
            burst.position = CGPoint(x: x, y: floorY); addChild(burst)
            burst.run(.sequence([.wait(forDuration: 1.1), .removeFromParent()]))
            let flame = sparks(rate: 34, count: 0, speed: 90 + 110 * strength)
            flame.position = CGPoint(x: x, y: floorY); addChild(flame)
            fire = flame
            let lamp = SKSpriteNode(texture: RainScene.glowTexture)
            lamp.size = CGSize(width: keyW * 5, height: keyW * 5); lamp.position = CGPoint(x: x, y: floorY)
            lamp.color = RainScene.soft; lamp.colorBlendFactor = 1; lamp.blendMode = .add; lamp.zPosition = 27
            lamp.alpha = 0; lamp.run(.fadeAlpha(to: 0.35 + 0.5 * strength, duration: 0.03))
            addChild(lamp)
            lamps[id]?.removeFromParent(); lamps[id] = lamp
        }
        held[id] = bars.count
        bars.append(Bar(node: node, glow: glow, born: now, held: true, fire: fire))
    }

    private func sparks(rate: CGFloat, count: Int, speed: CGFloat) -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleTexture = RainScene.glowTexture
        e.particleBirthRate = rate; e.numParticlesToEmit = count
        e.particleLifetime = 0.5; e.particleLifetimeRange = 0.35
        e.emissionAngle = .pi / 2; e.emissionAngleRange = 1.5
        e.particleSpeed = speed; e.particleSpeedRange = speed * 0.7
        e.yAcceleration = -520
        e.particleAlpha = 1; e.particleAlphaSpeed = -2.0
        e.particleScale = 0.09; e.particleScaleRange = 0.06; e.particleScaleSpeed = -0.08
        e.particleColor = .white; e.particleColorBlendFactor = 1; e.particleBlendMode = .add
        e.zPosition = 28
        return e
    }

    override func update(_ currentTime: TimeInterval) {
        let now = Link.clock()
        let dt = CGFloat(min(0.05, max(0, now - last)))
        last = now
        var alive = 0
        for i in bars.indices {
            guard let bar = bars[i] else { continue }
            if bar.held {
                // Still held: the bar grows out of the key.
                let h = min(size.height, max(6, CGFloat(now - bar.born) * rise))
                bar.node.size.height = h
                bar.glow.size.height = h + 28
            } else {
                // Let go: it floats away upward and is removed once it has left the top.
                bar.node.position.y += rise * dt
                bar.glow.position.y += rise * dt
                if bar.node.position.y > size.height {
                    bar.node.removeFromParent(); bar.glow.removeFromParent(); bar.fire?.removeFromParent()
                    bars[i] = nil
                    continue
                }
                if let f = bar.fire, f.particleBirthRate == 0, f.parent != nil, now - bar.born > 0 {
                    f.run(.sequence([.wait(forDuration: 0.9), .removeFromParent()]))
                }
            }
            alive += 1
        }
        if alive == 0, !bars.isEmpty { bars = []; held = [:] }      // nothing left: start the list afresh
        guard let link = link else { return }
        updateRoll(link, now: now)
        let title = link.rolling ? "NOW PLAYING  ·  " + link.rollName.uppercased() : ""
        if playing.text != title { playing.text = title }
        if chord.text != link.chord { chord.text = link.chord }
        let words = link.speaking ? link.caption : ""
        if caption.text != words { caption.text = words }
        let note = link.paused ? "PAUSED  ·  RETURN OR KEY 6 TO CARRY ON" : link.state == "OFFLINE" ? "ENGINE OFFLINE" : ""
        if notice.text != note { notice.text = note }
    }
}

struct Visualiser: NSViewRepresentable {
    let link: Link
    func makeNSView(context: Context) -> SKView {
        let view = SKView()
        view.preferredFramesPerSecond = 120          // as fast as the screen allows
        view.ignoresSiblingOrder = true
        let scene = RainScene(size: CGSize(width: 1240, height: 840))
        scene.scaleMode = .resizeFill
        scene.link = link
        link.scene = scene
        view.presentScene(scene)
        return view
    }
    func updateNSView(_ view: SKView, context: Context) {}
    static func dismantleNSView(_ view: SKView, coordinator: ()) { view.presentScene(nil) }
}

/// A clear white outline around whichever control the keyboard is on. The app's own buttons are
/// drawn by hand, so without this there would be no sign of where Tab has got to.
struct FocusRing: ViewModifier {
    @FocusState private var on: Bool
    func body(content: Content) -> some View {
        content.focused($on).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white, lineWidth: on ? 3 : 0).padding(-4))
    }
}
extension View { func focusRing() -> some View { modifier(FocusRing()) } }

/// "New update": shown across the top of the window, in the app's own green, until it is answered.
struct UpdateBanner: View {
    @ObservedObject var link: Link
    var body: some View {
        if !link.updateVersion.isEmpty {
            HStack(spacing: 18) {
                Circle().fill(Hud.green).frame(width: 10, height: 10).shadow(color: Hud.green, radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NEW UPDATE  //  VERSION \(link.updateVersion)").font(Hud.mono(16, .bold)).tracking(4).foregroundColor(Hud.green).shadow(color: Hud.green.opacity(0.7), radius: 10)
                    if !link.updateNotes.isEmpty { Text(link.updateNotes).font(Hud.mono(13)).foregroundColor(Hud.soft).lineLimit(2) }
                }
                Spacer()
                Button(action: { link.send("~update yes\n") }) {
                    Text("UPDATE NOW").font(Hud.mono(13, .bold)).tracking(3).foregroundColor(.black).padding(.horizontal, 20).padding(.vertical, 11).background(RoundedRectangle(cornerRadius: 10).fill(Hud.green))
                }.buttonStyle(.plain).focusRing().accessibilityLabel("Update now to version \(link.updateVersion)")
                Button(action: { link.send("~update no\n") }) {
                    Text("LATER").font(Hud.mono(13, .bold)).tracking(3).foregroundColor(Hud.soft).padding(.horizontal, 18).padding(.vertical, 11).overlay(RoundedRectangle(cornerRadius: 10).stroke(Hud.green.opacity(0.6), lineWidth: 1.5))
                }.buttonStyle(.plain).focusRing().accessibilityLabel("Update later")
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.01, green: 0.06, blue: 0.035)).shadow(color: Hud.green.opacity(0.45), radius: 22))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Hud.green, lineWidth: 1.5))
            .padding(.horizontal, 24).padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }
}

struct HudButton: View {
    let title: String
    let hint: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Hud.mono(10, .bold)).tracking(2).foregroundColor(Hud.green)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Hud.bg.opacity(0.6))
                .overlay(Rectangle().stroke(Hud.green.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain).focusRing()
        .accessibilityLabel(hint)
    }
}

struct VisualiserScreen: View {
    @ObservedObject var link: Link
    var body: some View {
        Visualiser(link: link)
            .accessibilityHidden(true)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 10) {
                    if link.rolling {
                        HudButton(title: "STOP  [ RETURN ]", hint: "Stop the MIDI file") { link.send("\n") }
                    }
                    VoiceButton()
            HudButton(title: "PLAY A MIDI FILE  [ O ]", hint: "Choose a MIDI file and watch its notes fall onto the keys") { link.chooseFile() }
                    HudButton(title: "BACK  [ F ]", hint: "Leave the visualiser") { link.visual = false }
                }
                .padding(.trailing, 20).padding(.top, 30)
            }
    }
}

/// Panels arrive one after another when the window opens.
struct Arrive: ViewModifier {
    let shown: Bool
    let order: Int
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .animation(.easeOut(duration: 0.7).delay(0.15 + Double(order) * 0.13), value: shown)
    }
}

// MARK: - Background

struct Grid: View {
    var body: some View {
        Canvas { g, size in
            var p = Path()
            var x: CGFloat = 0
            while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += 44 }
            var y: CGFloat = 0
            while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += 44 }
            g.stroke(p, with: .color(Hud.green.opacity(0.035)), lineWidth: 1)
        }
        .background(
            RadialGradient(colors: [Color(red: 0.02, green: 0.09, blue: 0.055), Hud.bg],
                           center: .center, startRadius: 40, endRadius: 760))
        .accessibilityHidden(true)
    }
}

// MARK: - The whole window

struct ContentView: View {
    @ObservedObject var link: Link
    @State private var active = true
    @State private var shown = CommandLine.arguments.contains("--snapshot")   // a snapshot shows everything at once
    @State private var time = ""
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            if link.welcome { WelcomeScreen(link: link) } else if link.visual { VisualiserScreen(link: link) } else { console }
            VStack { UpdateBanner(link: link); Spacer() }.animation(.easeOut(duration: 0.35), value: link.updateVersion)
        }
        .frame(minWidth: 1120, minHeight: 780)
        .preferredColorScheme(.dark)
        .onAppear { shown = true }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url, ["mid", "midi"].contains(url.pathExtension.lowercased()) else { return }
                DispatchQueue.main.async { link.playFile(url) }
            }
            return true
        }
        .onReceive(tick) { _ in
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            time = f.string(from: Date())
        }
        // Full speed whenever the window can be seen, even with another app in front (you are
        // usually in Logic while you play). Only a hidden or covered window slows down.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let w = note.object as? NSWindow { active = w.occlusionState.contains(.visible) }
        }
    }

    var console: some View {
        VStack(spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    status.modifier(Arrive(shown: shown, order: 1))
                    transcript.modifier(Arrive(shown: shown, order: 2))
                }
                .frame(width: 300)
                VStack(spacing: 6) {
                    Core(link: link, active: active).frame(minHeight: 260, maxHeight: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Mode: \(link.modeName.capitalized)")
                    Caption(link: link, active: active)
                    TrySaying()
                }
                .frame(maxWidth: .infinity)
                .modifier(Arrive(shown: shown, order: 0))
                commands.frame(width: 356).modifier(Arrive(shown: shown, order: 3))
            }
            Panel(title: "KEYBOARD  //  88 KEYS") {
                Legend(link: link)
                Keys(link: link, active: active).frame(height: 142)
            }
                .modifier(Arrive(shown: shown, order: 4))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .padding(.top, 30)
        .background(Grid())
        .overlay(FlashFrame(link: link).allowsHitTesting(false))
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("\(Link.shared.assistant.uppercased())")
                .font(Hud.mono(24, .bold)).tracking(9)
                .foregroundColor(Hud.soft)
                .shadow(color: Hud.green, radius: 10)
                .accessibilityAddTraits(.isHeader)
            Text("MUSIC ASSISTANT  //  V3").lineLimit(1).fixedSize().font(Hud.mono(11)).tracking(3).foregroundColor(Hud.dim)
                .accessibilityHidden(true)
            Spacer()
            VoiceButton()
            HudButton(title: "PLAY A MIDI FILE  [ O ]", hint: "Choose a MIDI file and watch its notes fall onto the keys") { link.chooseFile() }
            HudButton(title: "VISUALISER  [ F ]", hint: "Open the visualiser: your playing as rising light") { link.visual = true }
            HStack(spacing: 7) {
                Circle().fill(link.state == "ONLINE" ? Hud.green : Hud.dim).frame(width: 7, height: 7)
                    .shadow(color: Hud.green, radius: link.state == "ONLINE" ? 5 : 0)
                Text(link.state).font(Hud.mono(12, .semibold)).tracking(3)
                    .foregroundColor(link.state == "ONLINE" ? Hud.green : Hud.dim)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Nova is \(link.state.lowercased())")
            Text(time).font(Hud.mono(12)).foregroundColor(Hud.dim).accessibilityHidden(true)
        }
    }

    var status: some View {
        Panel(title: "SYSTEMS") {
            Readout(label: "MODE", value: link.modeName)
            if !link.now.isEmpty { Readout(label: "NOW", value: link.now.uppercased()) }
            Readout(label: "PIANO", value: link.keyboards.isEmpty ? "NOT FOUND" : link.keyboards.uppercased(),
                    live: !link.keyboards.isEmpty)
            Readout(label: "VOICE", value: link.voice.isEmpty ? "..." : link.voice.uppercased())
            Readout(label: "CHORD", value: link.chord.isEmpty ? "—" : link.chord, live: !link.chord.isEmpty)
            if link.live { Readout(label: "LIVE BAND", value: "FOLLOWING YOU") }
            Readout(label: "BAND", value: link.bandStyle.uppercased() + (link.bandLevel.isEmpty ? "" : ", " + link.bandLevel))
            Readout(label: "LOGIC / REAPER", value: link.daw ? "LINKED" : "NOT OPEN", live: link.daw)
            VoiceReadout()
            if !link.heard.isEmpty { Readout(label: "HEARD", value: "\u{201C}" + link.heard + "\u{201D}") }
            if link.hands != "both" { Readout(label: "HANDS", value: link.hands.uppercased() + " ONLY") }
            if link.state != "ONLINE" { Readout(label: "ENGINE", value: link.state, live: false) }
            if link.state == "OFFLINE" {
                Button(action: { link.restart() }) {
                    Text("RESTART ENGINE").font(Hud.mono(11, .bold)).tracking(2)
                        .foregroundColor(Hud.bg).frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Hud.green)
                }
                .buttonStyle(.plain).focusRing()
            }
        }
    }

    var transcript: some View {
        Panel(title: "CONVERSATION") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(link.transcript) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.time).font(Hud.mono(10)).foregroundColor(Hud.dim)
                                Text(line.text).font(Hud.mono(13, line.text.hasPrefix("\u{25B8}") ? .semibold : .regular))
                                    .foregroundColor(line.text.hasPrefix("\u{25B8}") ? .white : Hud.soft.opacity(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: link.transcript.count) { _ in
                    if let last = link.transcript.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityLabel("Voice log: everything Nova has said")
        }
    }

    var commands: some View {
        Panel(title: "COMMANDS") {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(commandGroups, id: \.0) { group in
                        Text(group.0).font(Hud.mono(11, .semibold)).tracking(3).foregroundColor(Hud.dim)
                            .padding(.top, group.0 == "ASSISTANT" ? 0 : 8)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.1.filter { $0.only == nil || $0.only == link.mode }) {
                            CommandButton(command: $0, composing: link.mode == "compose")
                        }
                    }
                    if !link.jazz.isEmpty {
                        Text("JAZZ LESSONS").font(Hud.mono(11, .semibold)).tracking(3).foregroundColor(Hud.dim)
                            .padding(.top, 8).accessibilityAddTraits(.isHeader)
                        ForEach(Array(link.jazz.enumerated()), id: \.offset) { i, title in
                            CommandButton(command: Command("\(i + 1)", "~jazz \(i + 1)\n", title), composing: false)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - App

// MARK: - Teaching the Mac's speech recogniser the assistant's name

/// The recogniser is far more likely to write a word it has been told to expect. This builds a
/// small custom language model around the chosen name ("Nova", "Hey Nova", "Nova, what's the
/// weather") and hands it to every recognition request. It is made once per name, on the Mac,
/// and kept in Nova's folder. Needs macOS 14 or later; before that the plain list of expected
/// words is used, as before.
enum WakeModel {
    static var ready: Any? = nil            // SFSpeechLanguageModel.Configuration, once prepared
    static var builtFor = ""
    static var building = false

    // How the offered names are said, in the notation the recogniser takes (X-SAMPA).
    static let pronunciations: [String: [String]] = ["nova": ["n oU v @"]]
    static let openers = ["what's the weather", "what time is it", "play some music", "stop", "pause", "next song", "open Safari", "set an alarm for seven", "what can you do", "play it back with the band",
                          "new composition", "read the window", "turn it up", "remember that", "add milk to my shopping list", "brief me", "help", "louder", "thank you", "yes", "no", "play", "open", "what", "can you", "tell me"]

    static func prepare(name: String, then done: @escaping () -> Void) {
        guard #available(macOS 14.0, *), !building, builtFor != name else { return }
        building = true
        let dir = URL(fileURLWithPath: baseDir + "/speech-model", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = name.lowercased().filter { $0.isLetter }
        let asset = dir.appendingPathComponent("\(key).bin"), lm = dir.appendingPathComponent("\(key)-lm"), vocab = dir.appendingPathComponent("\(key)-vocab")
        Task.detached(priority: .utility) {
            do {
                let config = SFSpeechLanguageModel.Configuration(languageModel: lm, vocabulary: vocab)
                if !FileManager.default.fileExists(atPath: lm.path) {
                    let data = SFCustomLanguageModelData(locale: Locale(identifier: "en_US"), identifier: "app.nova.assistant.wake", version: "3") {
                        SFCustomLanguageModelData.PhraseCount(phrase: name, count: 5000)
                        SFCustomLanguageModelData.PhraseCount(phrase: "Hey \(name)", count: 2500)
                        SFCustomLanguageModelData.PhraseCount(phrase: "Okay \(name)", count: 800)
                        for o in WakeModel.openers {
                            SFCustomLanguageModelData.PhraseCount(phrase: "\(name) \(o)", count: 400)
                            SFCustomLanguageModelData.PhraseCount(phrase: "Hey \(name) \(o)", count: 150)
                        }
                        if let said = WakeModel.pronunciations[key] { SFCustomLanguageModelData.CustomPronunciation(grapheme: name, phonemes: said) }
                    }
                    try await data.export(to: asset)
                    try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, clientIdentifier: "app.nova.assistant", configuration: config)
                }
                await MainActor.run { ready = config; builtFor = name; building = false; done() }
            } catch {
                await MainActor.run { building = false; VoiceControl.shared.log("the name could not be taught to the recogniser: \(error.localizedDescription)") }
            }
        }
    }

    static func apply(to request: SFSpeechRecognitionRequest) {
        if #available(macOS 14.0, *), let c = ready as? SFSpeechLanguageModel.Configuration, builtFor == Link.shared.assistant { request.customizedLanguageModel = c }
    }
}

/// A check that needs no microphone: the Mac's own voices say the name in a dozen ways, the
/// recogniser transcribes the recordings, and what it wrote is saved, with and without the
/// name having been taught. Run with:  open -n Nova.app --args --wake-test <file> [name]
enum WakeLab {
    static func run(out: String, name: String) {
        let dir = NSTemporaryDirectory() + "nova-wake-lab"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        SFSpeechRecognizer.requestAuthorization { auth in
            guard auth == .authorized, let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), rec.supportsOnDeviceRecognition else {
                lines.append("speech recognition is not allowed or not on-device here (\(auth.rawValue))"); save(); exit(1)
            }
            let voices = ["Alex", "Daniel", "Karen", "Moira", "Fred", "Kathy", "Ralph", "Reed", "Eddy", "Flo", "Junior", "Grandma"]
            let phrases = [name, "Hey \(name)", "\(name), what's the weather", "\(name) stop", "so anyway. \(name), play some music", "Okay \(name), what time is it"]
            var clips: [(String, String, URL)] = []
            for v in voices { for (i, p) in phrases.enumerated() {
                let url = URL(fileURLWithPath: "\(dir)/\(v)-\(i).aiff")
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/say"); t.arguments = ["-v", v, "-o", url.path, p]
                try? t.run(); t.waitUntilExit()
                if FileManager.default.fileExists(atPath: url.path) { clips.append((v, p, url)) }
            } }
            func pass(_ label: String, taught: Bool, then next: @escaping () -> Void) {
                var i = 0, hits = 0
                func one() {
                    guard i < clips.count else { lines.append("== \(label): the name was written correctly in \(hits) of \(clips.count)"); save(); next(); return }
                    let (v, p, url) = clips[i]; i += 1
                    // --stream feeds the sound in as the microphone does, piece by piece, with updates as it goes.
                    let streaming = CommandLine.arguments.contains("--stream")
                    let req: SFSpeechRecognitionRequest
                    if streaming, let file = try? AVAudioFile(forReading: url), let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)), (try? file.read(into: buf)) != nil {
                        let live = SFSpeechAudioBufferRecognitionRequest()
                        live.shouldReportPartialResults = true
                        live.append(buf)
                        live.endAudio()
                        req = live
                    } else {
                        let whole = SFSpeechURLRecognitionRequest(url: url)
                        whole.shouldReportPartialResults = false
                        req = whole
                    }
                    req.requiresOnDeviceRecognition = true
                    req.contextualStrings = [name, "Hey \(name)"]
                    if taught { WakeModel.apply(to: req) }
                    var finished = false
                    rec.recognitionTask(with: req) { result, error in
                        guard !finished, error != nil || (result?.isFinal ?? false) else { return }
                        finished = true
                        let problem = (error as NSError?).map { " [error \($0.domain) \($0.code)]" } ?? ""
                        let text = (result?.bestTranscription.formattedString ?? "(nothing)") + problem
                        let ok = text.lowercased().contains(name.lowercased())
                        if ok { hits += 1 }
                        lines.append("\(label) | \(ok ? "ok  " : "MISS") | \(v) | \(p) -> \(text)")
                        DispatchQueue.main.async { one() }
                    }
                }
                one()
            }
            DispatchQueue.main.async {
                pass("plain", taught: false) {
                    if CommandLine.arguments.contains("--quick") { lines.append("done"); save(); exit(0) }
                    WakeModel.prepare(name: name) { pass("taught", taught: true) { lines.append("done"); save(); exit(0) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 240) { lines.append("the taught model was not ready after four minutes"); save(); exit(0) }
                }
            }
        }
    }
}

// MARK: - The welcome: a few easy questions, the first time

/// One question to a screen, in large type, typed out as if being said. Everything can be
/// skipped, Return moves on, and each question is also spoken, so it works without looking.
struct WelcomeScreen: View {
    @ObservedObject var link: Link
    @State private var step = 0
    @State private var name = ""
    @State private var wake = "Nova"
    @State private var custom = ""
    @State private var city = ""
    @State private var month = 0          // 0 means "not given"
    @State private var day = 1
    @State private var fahrenheit = Locale.current.measurementSystem == .us
    @State private var large = UserDefaults.standard.bool(forKey: "large")
    @State private var contrast = UserDefaults.standard.bool(forKey: "contrast")
    @State private var reader = NSWorkspace.shared.isVoiceOverEnabled
    @State private var plays = true
    @State private var shown = 0
    @State private var listen = true
    @State private var natural = true
    @FocusState private var typing: Bool
    // Offered in the order the Mac hears them best, after Nova itself. (Measured: see Profile.measured in the engine.)
    static let names = ["Nova", "Apollo", "Harmony", "Phoenix", "Luna", "Melody", "Aria"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    private let ticker = Timer.publish(every: 0.022, on: .main, in: .common).autoconnect()

    private var chosen: String {
        let c = custom.trimmingCharacters(in: .whitespaces).filter { $0.isLetter }
        return (3...12).contains(c.count) ? c.prefix(1).uppercased() + c.dropFirst().lowercased() : wake
    }
    private var questions: [(title: String, sub: String)] {
        [("Hello. I\u{2019}m Nova.", "A few quick questions and I\u{2019}m set up for you. Your answers stay on this Mac, and every screen has a skip button."),
         ("What should I call you?", "A first name or a nickname. Whatever you like to hear."),
         ("And what will you call me?", "This is the word you say to get my attention. Longer names are the easiest for a Mac to hear: Apollo, Harmony and Phoenix are caught almost every time."),
         ("Where in the world are you?", "Only used to tell you the weather. A town or city is enough."),
         ("When\u{2019}s your birthday?", "Just the day and the month, so I can wish you a happy birthday. No year, so no age, and you don\u{2019}t have to be 18. Skip it if you\u{2019}d rather not say."),
         ("How can I fit you best?", "Switch on anything that helps. All of it can be changed later, just by asking."),
         ("One last thing: may I listen?", "To hear you say \u{201C}\(chosen)\u{201D}, I need the microphone. The listening happens on this Mac, and I only act on what follows my name.")]
    }

    /// Arrow keys choose among the answers on each screen, so nothing here needs a mouse.
    private func key(_ e: NSEvent) -> Bool {
        let left = e.keyCode == 123, right = e.keyCode == 124, down = e.keyCode == 125, up = e.keyCode == 126
        guard left || right || up || down else { return false }
        switch step {
        case 2:
            guard custom.isEmpty, left || right else { return false }
            let i = WelcomeScreen.names.firstIndex(of: wake) ?? 0
            wake = WelcomeScreen.names[(i + (right ? 1 : WelcomeScreen.names.count - 1)) % WelcomeScreen.names.count]
            announce(wake)
        case 3:
            guard up || down else { return false }
            fahrenheit.toggle(); announce(fahrenheit ? "Fahrenheit" : "Celsius")
        case 4:
            if left || right { month = right ? (month % 12) + 1 : (month <= 1 ? 12 : month - 1) }
            else { if month == 0 { month = 1 }; day = up ? (day % 31) + 1 : (day <= 1 ? 31 : day - 1) }
            announce("\(WelcomeScreen.monthNames[month - 1]) \(day)")
        case 6:
            if left || right { listen.toggle(); announce(listen ? "Yes, listen" : "Not now") }
            else { natural.toggle(); announce("Natural voice " + (natural ? "on" : "off")) }
        default: return false
        }
        return true
    }

    /// Said by VoiceOver, when it is running.
    private func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let w = NSApp.mainWindow ?? NSApp.windows.first else { return }
        NSAccessibility.post(element: w, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private var hint: String {
        switch step {
        case 2: return "Left and right arrows choose. Return continues."
        case 3: return "Up and down arrows switch between Celsius and Fahrenheit."
        case 4: return "Left and right arrows choose the month, up and down the day."
        case 5: return "Tab moves between these. Space switches one on or off."
        case 6: return "Left and right arrows choose. Up and down switch the natural voice."
        default: return "Return continues."
        }
    }

    private func say() {
        let q = questions[step]
        shown = 0
        // With VoiceOver running, VoiceOver reads the question. Nova saying it as well would be two voices at once.
        if NSWorkspace.shared.isVoiceOverEnabled {
            announce(q.title + " " + q.sub + " " + hint)
            typing = step == 1 || step == 3
            return
        }
        link.send("~speak " + (q.title + " " + q.sub).replacingOccurrences(of: "\u{201C}", with: "").replacingOccurrences(of: "\u{201D}", with: "").replacingOccurrences(of: "\n", with: " ") + "\n")
        typing = step == 1 || step == 3
    }

    private func next() {
        if step < questions.count - 1 { step += 1; say(); return }
        finish()
    }

    private func finish() {
        link.setAccess("large", large)
        link.setAccess("contrast", contrast)
        var about: [String] = []
        if reader { about.append("uses a screen reader, so never rely on anything visual") }
        if plays { about.append("plays piano or makes music") }
        func clean(_ t: String) -> String { t.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        link.send("~setup \(clean(name))|\(chosen)|\(clean(city))|\(fahrenheit ? "F" : "C")|\(about.joined(separator: "; "))|\(plays ? 1 : 0)|\(month > 0 ? String(format: "%02d-%02d", month, day) : "")|\(natural ? 1 : 0)\n")
        link.assistant = chosen
        link.user = clean(name)
        link.welcome = false
        if listen, !VoiceControl.shared.on { VoiceControl.shared.begin() }
    }

    @ViewBuilder private var answer: some View {
        switch step {
        case 1:
            TextField("Your name", text: $name)
                .textFieldStyle(.plain).font(.system(size: 34, weight: .medium, design: .monospaced)).foregroundColor(.white).multilineTextAlignment(.center)
                .focused($typing).onSubmit { next() }
                .padding(.vertical, 14).frame(maxWidth: 520)
                .overlay(Rectangle().frame(height: 2).foregroundColor(Hud.green.opacity(0.8)), alignment: .bottom)
                .accessibilityLabel("Your name")
        case 2:
            VStack(spacing: 22) {
                HStack(spacing: 10) {
                    ForEach(WelcomeScreen.names, id: \.self) { n in
                        Button(action: { wake = n; custom = "" }) {
                            Text(n.uppercased()).font(Hud.mono(15, .bold)).tracking(2)
                                .foregroundColor(chosen == n ? Color.black : Hud.soft)
                                .padding(.horizontal, 15).padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(chosen == n ? Hud.green : Hud.panel))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Hud.green.opacity(chosen == n ? 1 : 0.35), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain).focusRing()
                        .accessibilityLabel(n + (chosen == n ? ", chosen" : ""))
                    }
                }
                HStack(spacing: 12) {
                    Text("OR YOUR OWN").font(Hud.mono(12, .medium)).tracking(3).foregroundColor(Hud.dim)
                    TextField("one word", text: $custom)
                        .textFieldStyle(.plain).font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundColor(.white)
                        .frame(width: 220).padding(.vertical, 6).onSubmit { next() }
                        .overlay(Rectangle().frame(height: 1.5).foregroundColor(Hud.green.opacity(0.6)), alignment: .bottom)
                        .accessibilityLabel("Your own name for the assistant, one word")
                }
                Text("You\u{2019}ll say:  \u{201C}\(chosen), what\u{2019}s the weather?\u{201D}").font(Hud.mono(15)).foregroundColor(Hud.soft)
            }
        case 3:
            VStack(spacing: 22) {
                TextField("Town or city", text: $city)
                    .textFieldStyle(.plain).font(.system(size: 34, weight: .medium, design: .monospaced)).foregroundColor(.white).multilineTextAlignment(.center)
                    .focused($typing).onSubmit { next() }
                    .padding(.vertical, 14).frame(maxWidth: 520)
                    .overlay(Rectangle().frame(height: 2).foregroundColor(Hud.green.opacity(0.8)), alignment: .bottom)
                    .accessibilityLabel("Your town or city")
                HStack(spacing: 14) {
                    choice("CELSIUS", !fahrenheit) { fahrenheit = false }
                    choice("FAHRENHEIT", fahrenheit) { fahrenheit = true }
                }
            }
        case 4:
            VStack(spacing: 20) {
                HStack(spacing: 10) {
                    ForEach(1...12, id: \.self) { m in
                        Button(action: { month = month == m ? 0 : m }) {
                            Text(WelcomeScreen.months[m - 1].uppercased()).font(Hud.mono(14, .bold)).tracking(1.5)
                                .foregroundColor(month == m ? Color.black : Hud.soft)
                                .frame(width: 58, height: 46)
                                .background(RoundedRectangle(cornerRadius: 12).fill(month == m ? Hud.green : Hud.panel))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Hud.green.opacity(month == m ? 1 : 0.35), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain).focusRing()
                        .accessibilityLabel(WelcomeScreen.monthNames[m - 1] + (month == m ? ", chosen" : ""))
                    }
                }
                HStack(spacing: 18) {
                    Button(action: { day = day > 1 ? day - 1 : 31 }) { Text("\u{2212}").font(Hud.mono(26, .bold)).foregroundColor(Hud.soft).frame(width: 56, height: 50).background(RoundedRectangle(cornerRadius: 12).fill(Hud.panel)) }
                        .buttonStyle(.plain).focusRing().accessibilityLabel("Day before")
                    Text(month == 0 ? "PICK A MONTH" : "\(WelcomeScreen.monthNames[month - 1]) \(day)")
                        .font(.system(size: 26, weight: .semibold, design: .monospaced)).foregroundColor(month == 0 ? Hud.dim : .white).frame(minWidth: 280)
                        .accessibilityLabel(month == 0 ? "No birthday chosen" : "\(WelcomeScreen.monthNames[month - 1]) \(day)")
                    Button(action: { day = day < 31 ? day + 1 : 1 }) { Text("+").font(Hud.mono(26, .bold)).foregroundColor(Hud.soft).frame(width: 56, height: 50).background(RoundedRectangle(cornerRadius: 12).fill(Hud.panel)) }
                        .buttonStyle(.plain).focusRing().accessibilityLabel("Day after")
                }
                .opacity(month == 0 ? 0.55 : 1)
            }
        case 5:
            VStack(alignment: .leading, spacing: 14) {
                toggle("Larger captions", "Everything I say is shown in bigger type.", $large)
                toggle("High contrast", "Brighter text on a darker background.", $contrast)
                toggle("I use a screen reader", "I\u{2019}ll describe things in words and never point at the screen.", $reader)
                toggle("I play piano or make music", "Lessons, a band that follows you, and help with your ideas.", $plays)
            }
            .frame(maxWidth: 640)
        case 6:
            VStack(spacing: 24) {
                HStack(spacing: 14) {
                    choice("YES, LISTEN FOR \(chosen.uppercased())", listen) { listen = true }
                    choice("NOT NOW", !listen) { listen = false }
                }
                toggle("Give me my natural voice", "A free, one time download of about 400 megabytes, fetched in the background. It runs on this Mac and sounds far more human.", $natural)
                    .frame(maxWidth: 640)
            }
        default: EmptyView()
        }
    }

    private func choice(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Hud.mono(15, .bold)).tracking(2.5)
                .foregroundColor(on ? Color.black : Hud.soft)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(on ? Hud.green : Hud.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Hud.green.opacity(on ? 1 : 0.35), lineWidth: 1.5))
        }
        .buttonStyle(.plain).focusRing()
        .accessibilityLabel(title.capitalized + (on ? ", chosen" : ""))
    }

    private func toggle(_ title: String, _ sub: String, _ value: Binding<Bool>) -> some View {
        Button(action: { value.wrappedValue.toggle() }) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).stroke(Hud.green.opacity(0.8), lineWidth: 1.5).frame(width: 30, height: 30)
                    if value.wrappedValue { RoundedRectangle(cornerRadius: 5).fill(Hud.green).frame(width: 18, height: 18) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                    Text(sub).font(Hud.mono(13.5)).foregroundColor(Hud.soft.opacity(0.85))
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Hud.panel.opacity(value.wrappedValue ? 1 : 0.5)))
        }
        .buttonStyle(.plain).focusRing()
        .accessibilityLabel(title + ". " + sub)
        .accessibilityValue(value.wrappedValue ? "on" : "off")
    }

    var body: some View {
        let q = questions[step]
        ZStack {
            Hud.bg.ignoresSafeArea()
            Grid().opacity(0.5)
            VStack(spacing: 0) {
                Core(link: link, active: true).frame(height: 250).padding(.top, 10)
                Text(String(q.title.prefix(shown)))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                    .shadow(color: Hud.green.opacity(0.6), radius: 14)
                    .multilineTextAlignment(.center).frame(minHeight: 54)
                    .accessibilityLabel(q.title).accessibilityAddTraits(.isHeader)
                Text(q.sub)
                    .font(Hud.mono(16)).foregroundColor(Hud.soft.opacity(shown >= q.title.count ? 0.9 : 0))
                    .multilineTextAlignment(.center).lineSpacing(5).frame(maxWidth: 720).padding(.top, 12)
                    .animation(.easeOut(duration: 0.5), value: shown >= q.title.count)
                Spacer(minLength: 18)
                answer.opacity(shown >= q.title.count ? 1 : 0).animation(.easeOut(duration: 0.4), value: shown >= q.title.count)
                Text(hint).font(Hud.mono(13)).foregroundColor(Hud.soft.opacity(0.75)).padding(.top, 14)
                    .opacity(shown >= q.title.count && step > 0 ? 1 : 0)
                Spacer(minLength: 14)
                HStack(spacing: 16) {
                    if step > 0 {
                        Button(action: { step -= 1; say() }) { Text("BACK").font(Hud.mono(14, .semibold)).tracking(3).foregroundColor(Hud.soft).padding(.horizontal, 18).padding(.vertical, 12) }
                            .buttonStyle(.plain).focusRing().accessibilityLabel("Back to the question before")
                    }
                    Button(action: next) {
                        Text(step == 0 ? "BEGIN" : step == questions.count - 1 ? "FINISH" : "CONTINUE")
                            .font(Hud.mono(16, .bold)).tracking(4).foregroundColor(.black)
                            .padding(.horizontal, 44).padding(.vertical, 16)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Hud.green))
                            .shadow(color: Hud.green.opacity(0.5), radius: 16)
                    }
                    .buttonStyle(.plain).focusRing().keyboardShortcut(.defaultAction)
                    .accessibilityLabel(step == 0 ? "Begin" : step == questions.count - 1 ? "Finish" : "Continue")
                    if step > 0, step < questions.count - 1 {
                        Button(action: next) { Text("SKIP").font(Hud.mono(14, .semibold)).tracking(3).foregroundColor(Hud.soft).padding(.horizontal, 18).padding(.vertical, 12) }
                            .buttonStyle(.plain).focusRing().accessibilityLabel("Skip this question")
                    }
                }
                HStack(spacing: 10) {
                    ForEach(0..<questions.count, id: \.self) { i in
                        Capsule().fill(i == step ? Hud.green : Hud.faint).frame(width: i == step ? 28 : 10, height: 6).animation(.easeOut(duration: 0.3), value: step)
                    }
                }
                .padding(.top, 22).padding(.bottom, 30)
                .accessibilityElement().accessibilityLabel("Question \(step + 1) of \(questions.count)")
            }
            .padding(.horizontal, 40)
        }
        .onAppear {
            link.welcomeKey = { e in key(e) }
            if link.welcomeStepForSnapshot > 0 { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { step = link.welcomeStepForSnapshot; shown = 99 } }
            if let n = savedProfile()["user"] as? String { name = n }
            if let c = savedProfile()["city"] as? String { city = c }
            if let b = savedProfile()["birthday"] as? String, b.count == 5, let m = Int(b.prefix(2)), let d = Int(b.suffix(2)), (1...12).contains(m) { month = m; day = d }
            if let a = savedProfile()["assistant"] as? String { if WelcomeScreen.names.contains(a) { wake = a } else { custom = a } }
            if !CommandLine.arguments.contains("--snapshot") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { say() } }
        }
        .onReceive(ticker) { _ in if shown < questions[step].title.count { shown += 1 } }
    }
}

// MARK: - In the background: a panel that appears when \(Link.shared.assistant) is spoken to, and a menu bar icon

/// \(Link.shared.assistant) keeps running when its window is closed. While the window is away, or another app
/// is in front, this panel rises at the bottom of the screen whenever \(Link.shared.assistant) hears its name
/// or speaks, and slips away again a few seconds later.
struct OverlayView: View {
    @ObservedObject var link: Link
    @ObservedObject var overlay: Overlay
    var body: some View {
        HStack(spacing: 4) {
            Core(link: link, active: overlay.visible)
                .frame(width: 200, height: 176)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(Hud.green).frame(width: 8, height: 8).shadow(color: Hud.green, radius: 6)
                    Text("\(Link.shared.assistant.uppercased())").font(Hud.mono(13, .bold)).tracking(6).foregroundColor(Hud.green)
                    Text(!link.updateVersion.isEmpty ? "NEW UPDATE  //  \(link.updateVersion)" : link.speaking ? "SPEAKING" : "LISTENING").font(Hud.mono(!link.updateVersion.isEmpty ? 12 : 10, .bold)).tracking(3).foregroundColor(!link.updateVersion.isEmpty ? Hud.green : Hud.dim)
                    Spacer()
                }
                if !link.heard.isEmpty {
                    Text("\u{201C}" + link.heard + "\u{201D}")
                        .font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundColor(Hud.soft.opacity(0.85)).lineLimit(1).truncationMode(.tail)
                }
                Caption(link: link, active: overlay.visible)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 26)
        }
        .padding(.leading, 8).padding(.vertical, 10)
        .frame(width: 780, height: 204)
        .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(Color(red: 0.008, green: 0.03, blue: 0.02).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous)
            .stroke(LinearGradient(colors: [Hud.green.opacity(0.95), Hud.green.opacity(0.12), Hud.green.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.6))
        .shadow(color: Hud.green.opacity(link.speaking ? 0.5 : 0.28), radius: 26)
        .padding(34)
        .accessibilityHidden(true)          // the voice already says it; VoiceOver must not repeat it
    }
}

final class Overlay: ObservableObject {
    static let shared = Overlay()
    @Published var visible = false
    private var panel: NSPanel?
    private var bag: [AnyCancellable] = []
    private var hideAt = 0.0
    private var timer: Timer?
    static var enabled: Bool { UserDefaults.standard.object(forKey: "overlay") == nil ? true : UserDefaults.standard.bool(forKey: "overlay") }

    func setUp() {
        let size = NSSize(width: 848, height: 272)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: OverlayView(link: Link.shared, overlay: self))
        p.alphaValue = 0
        panel = p
        let link = Link.shared
        link.$speaking.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] on in if on { self?.show(for: 60) } else { self?.show(for: 3.5) } }.store(in: &bag)
        link.$heard.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.show(for: 9) }.store(in: &bag)
        link.$flashAt.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in if Link.shared.flash == "good" { self?.show(for: 9) } }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// The panel is only for when the main window is not what the player is looking at.
    private var needed: Bool {
        guard Overlay.enabled, let w = AppDelegate.shared?.window else { return false }
        // If any of the \(Link.shared.assistant) window can be seen on screen, it already shows all of this, so the
        // panel stays away: even when another app, such as one \(Link.shared.assistant) has just opened, is in front.
        return !(w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible))
    }

    func show(for seconds: Double) {
        guard needed, let p = panel else { return }
        hideAt = Link.clock() + seconds
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 26))
        }
        if !visible {
            visible = true
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.28; p.animator().alphaValue = 1 }
        }
    }

    private func tick() {
        guard visible, let p = panel else { return }
        if Link.shared.speaking { hideAt = max(hideAt, Link.clock() + 3.5) }
        if Link.clock() > hideAt || !needed {
            visible = false
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.45; p.animator().alphaValue = 0 }, completionHandler: { if !self.visible { p.orderOut(nil) } })
        }
    }
}

/// Starting with the Mac. Switched on and off by the player: from the menu bar icon, or by saying it.
enum LoginItem {
    static let agent = NSHomeDirectory() + "/Library/LaunchAgents/app.nova.assistant.plist"
    static var on: Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agent)
    }
    /// Returns false if the Mac refused.
    static func set(_ want: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if want { try SMAppService.mainApp.register() } else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                if !want { try? FileManager.default.removeItem(atPath: agent) }
                if want == (SMAppService.mainApp.status == .enabled) { return true }
            } catch {}
        }
        // The plain way, if the newer one is refused: a small file that opens the app at login.
        if !want { try? FileManager.default.removeItem(atPath: agent); return !FileManager.default.fileExists(atPath: agent) }
        let plist: [String: Any] = ["Label": "app.nova.assistant", "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--hidden"], "RunAtLoad": true]
        try? FileManager.default.createDirectory(atPath: (agent as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: agent))) != nil
    }
}

final class MenuBar: NSObject, NSMenuDelegate {
    static let shared = MenuBar()
    private var item: NSStatusItem?
    private let listening = NSMenuItem(title: "Listen for \u{201C}\(Link.shared.assistant)\u{201D}", action: #selector(toggleVoice), keyEquivalent: "")
    private let login = NSMenuItem(title: "Start when I log in", action: #selector(toggleLogin), keyEquivalent: "")
    private let panel = NSMenuItem(title: "Show the panel when \(Link.shared.assistant) speaks", action: #selector(togglePanel), keyEquivalent: "")

    func setUp() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "\(Link.shared.assistant)")
        item.button?.toolTip = "\(Link.shared.assistant)"
        let menu = NSMenu()
        menu.delegate = self
        let open = NSMenuItem(title: "Open the window", action: #selector(openWindow), keyEquivalent: "")
        let again = NSMenuItem(title: "Change my name, city or wake word\u{2026}", action: #selector(welcomeAgain), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Nova", action: #selector(quitApp), keyEquivalent: "")
        let natural = NSMenuItem(title: "Install the natural voice\u{2026}", action: #selector(naturalVoice), keyEquivalent: "")
        for i in [open, again, natural, .separator(), listening, panel, login, .separator(), quit] { i.target = self; menu.addItem(i) }
        item.menu = menu
        self.item = item
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        listening.title = "Listen for \u{201C}\(Link.shared.assistant)\u{201D}"
        panel.title = "Show the panel when \(Link.shared.assistant) speaks"
        listening.state = VoiceControl.shared.on ? .on : .off
        login.state = LoginItem.on ? .on : .off
        panel.state = Overlay.enabled ? .on : .off
    }
    @objc func openWindow() { AppDelegate.shared?.showWindow() }
    @objc func naturalVoice() { Link.shared.send("~say install the natural voice\n") }
    @objc func welcomeAgain() { Link.shared.welcome = true; AppDelegate.shared?.showWindow() }
    @objc func toggleVoice() { VoiceControl.shared.toggle() }
    @objc func toggleLogin() { _ = LoginItem.set(!LoginItem.on) }
    @objc func togglePanel() { UserDefaults.standard.set(!Overlay.enabled, forKey: "overlay") }
    @objc func quitApp() { NSApp.terminate(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    var window: NSWindow!
    var monitor: Any?
    private var toldBackground = false

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func hideWindow() { window.orderOut(nil) }

    /// Closing the window leaves \(Link.shared.assistant) running. It says so the first time, so the silence is not mistaken for quitting.
    func windowWillClose(_ note: Notification) {
        if !toldBackground { toldBackground = true; Link.shared.send("~bg\n") }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }

    /// Opened by the Mac at login, or asked to start out of sight.
    private var startHidden: Bool {
        if CommandLine.arguments.contains("--hidden") { return true }
        if NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem { return true }
        return LoginItem.on && ProcessInfo.processInfo.systemUptime < 120
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { return snapshot(to: args[i + 1]) }
        if let i = args.firstIndex(of: "--wake-test"), i + 1 < args.count { return WakeLab.run(out: args[i + 1], name: args[safe: i + 2] ?? "Nova") }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Nova"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.008, green: 0.022, blue: 0.014, alpha: 1)
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: ContentView(link: Link.shared))
        window.center()
        window.setFrameAutosaveName("NovaMain")
        window.isReleasedWhenClosed = false
        window.delegate = self
        AppDelegate.shared = self
        if !startHidden {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        Overlay.shared.setUp()
        MenuBar.shared.setUp()

        // The same single keys the Terminal window took. Command shortcuts stay with macOS.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { return event }
            let link = Link.shared
            if link.welcome { return link.welcomeKey?(event) == true ? nil : event }
            // Moving about with Tab: from then on Space and Return press the focused button, as anywhere
            // else on the Mac, until Escape hands those two keys back to the piano commands.
            if event.keyCode == 48 { link.tabbing = true; return event }
            if link.tabbing {
                if event.keyCode == 53 { link.tabbing = false; AppDelegate.shared?.window.makeFirstResponder(nil); return nil }
                if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 { return event }
            }
            if !link.typing {
                if event.keyCode == 53, link.visual { link.visual = false; return nil }        // Escape
                if event.charactersIgnoringModifiers?.lowercased() == "f" { link.visual.toggle(); return nil }
                if event.charactersIgnoringModifiers?.lowercased() == "o" { link.chooseFile(); return nil }
            }
            switch event.keyCode {
            case 123: Link.shared.send("\u{1B}[D")
            case 124: Link.shared.send("\u{1B}[C")
            case 36, 76: Link.shared.send("\n")
            case 48: return event                         // Tab moves between the buttons
            case 51: Link.shared.send("\u{7F}")           // Delete, when typing a name
            default:
                guard let chars = event.characters, !chars.isEmpty,
                      chars.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { return event }
                Link.shared.send(chars)
            }
            return nil
        }
        Link.shared.start()
        VoiceControl.shared.resumeIfWanted()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ note: Notification) { Link.shared.stop() }

    /// Draws the window with made-up activity into a picture, for checking the design. Starts nothing.
    func snapshot(to path: String) {
        let link = Link.shared
        for line in ["kbd Stage Piano", "voice Alex", "daw 1", "buttons 108 107 105 103 101 100 98 96 23 21", "mode compose", "now New piece, 42 seconds so far", "bandlevel +9 dB",
                     "say Welcome back. Last time you were writing in D major.", "done",
                     "heard play it back with the band", "say That was in G major. I heard G, E minor, C and D. Press the top key to hear it as a band.",
                     "word 20 7 400", "on 55 90", "on 59 70", "on 62 100", "on 66 64", "out 43 80", "out 71 80",
                     "jazz Swing|The blues scale|Less is more"] { link.handle(line) }
        link.visual = CommandLine.arguments.contains("--visual")
        for (i, p) in [48, 52, 55, 60, 64, 67, 72, 76, 79, 84, 61, 70].enumerated() {
            link.ripples.append(Ripple(pitch: p, at: Link.clock() - 0.2 - Double(i) * 0.33, strength: 0.4 + Double(i % 4) * 0.2,
                                       off: i < 3 ? nil : Link.clock() - 0.1 - Double(i) * 0.25))
            if i % 3 == 0 { link.echoes.append(Ripple(pitch: p - 24 + 7, at: Link.clock() - 1 - Double(i) * 0.3, strength: 0.6, off: Link.clock() - 0.3 - Double(i) * 0.2)) }
        }
        link.pulseAt = Link.clock() - 0.05
        link.wordAt = Link.clock() - 0.4
        link.level = 0.75
        link.levelAt = Link.clock()
        link.handle("spec 1 new")
        var fake = ""
        for f in 0..<240 {
            for b in 0..<16 {
                let v: Double = 13 - Double(b) * 0.7 + 4 * sin(Double(f) * 0.4 + Double(b))
                let step: Int = max(0, min(15, Int(v)))
                fake.append(Character(UnicodeScalar(UInt8(97 + step))))
            }
        }
        link.handle("spec 1 0 " + fake)
        link.speaking = true
        link.voiceAnchor = Link.clock() - 1.0
        for k in 0..<30 { link.updateBars(at: Link.clock() - 0.5 + Double(k) / 60) }
        for (i, p) in [43, 55, 59, 62, 66, 71, 74].enumerated() {
            link.ripples.append(Ripple(pitch: p, at: Link.clock() - 0.3 - Double(i) * 0.25, strength: 0.5 + Double(i % 3) * 0.2,
                                       off: i % 2 == 0 ? nil : Link.clock() - 0.1 - Double(i) * 0.1))
        }
        if CommandLine.arguments.contains("--core") {
            let sk = SKView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
            let scene = CoreScene(size: sk.frame.size)
            scene.scaleMode = .resizeFill; scene.link = link; scene.backgroundColor = NSColor(red: 0.02, green: 0.08, blue: 0.05, alpha: 1)
            let w = NSWindow(contentRect: sk.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = sk; w.orderFrontRegardless()
            sk.presentScene(scene)
            link.voiceAnchor = Link.clock()
            for (k, at) in [0.5, 0.62, 0.74].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    if let image = sk.texture(from: scene)?.cgImage() {
                        let out = path.replacingOccurrences(of: ".png", with: "-\(k).png")
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                    if k == 2 { exit(0) }
                }
            }
            return
        }
        if link.visual {
            let sk = SKView(frame: NSRect(x: 0, y: 0, width: 1240, height: 840))
            let scene = RainScene(size: sk.frame.size)
            scene.scaleMode = .resizeFill; scene.link = link
            let w = NSWindow(contentRect: sk.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = sk; w.orderFrontRegardless()
            sk.presentScene(scene)
            if CommandLine.arguments.contains("--roll") {
                link.handle("rollnew Clair de Lune")
                var line = ""
                for i in 0..<60 { line += String(format: "%.3f,%.3f,%d,%d,%d;", Double(i) * 0.22, 0.2 + Double(i % 5) * 0.25, [60, 64, 67, 72, 76, 79, 55, 48][i % 8] + (i % 3) * 2, 60 + (i * 7) % 60, i % 8 >= 6 ? 1 : 0) }
                link.handle("rolln " + line)
                link.handle("rollstart 0.6 13")
                for (at, p) in [(0.62, 60), (0.84, 66), (1.06, 71), (1.28, 72), (1.5, 78)] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) { scene.note(p, strength: 0.8, mine: false) }
                }
            }
            let plan: [(Double, Int, Double)] = CommandLine.arguments.contains("--roll") ? [] : [(0.1, 48, 0.8), (0.2, 55, 0.6), (0.35, 60, 0.9), (0.5, 64, 0.7), (0.65, 67, 1.0), (0.7, 48, 0),
                                                 (0.8, 72, 0.5), (0.9, 61, 0.8), (1.0, 55, 0), (1.1, 76, 0.9), (1.2, 64, 0), (1.3, 79, 0.7), (1.45, 84, 1.0)]
            for (at, pitch, strength) in plan {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { scene.note(pitch, strength: strength, mine: true) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { scene.note(43, strength: 0.7, mine: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if let image = sk.texture(from: scene)?.cgImage() {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--overlay") {
            Overlay.shared.visible = true
            let v = NSHostingView(rootView: ZStack { Color(red: 0.35, green: 0.38, blue: 0.45); OverlayView(link: link, overlay: Overlay.shared) })
            v.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
            let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = v
            w.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--update") { link.handle("update 1.2.0|Faster answers, and a new voice to choose.") }
        if let i = CommandLine.arguments.firstIndex(of: "--welcome") { link.welcome = true; link.welcomeStepForSnapshot = Int(CommandLine.arguments[safe: i + 1] ?? "") ?? 0 }
        let view = NSHostingView(rootView: ContentView(link: link))
        view.frame = NSRect(x: 0, y: 0, width: 1240, height: 840)
        let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}

/// The way in. The app's own program is a tiny fixed starter that loads this code and calls
/// this function. Because the starter never changes, macOS keeps the microphone and speech
/// permissions when the window's code is updated.
@_cdecl("tp_main")
public func tp_main() { Main.main() }

enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)

        // A small menu, so Quit, Close and Minimise work the usual way.
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Nova", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Nova", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let winItem = NSMenuItem(); bar.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        app.mainMenu = bar
        app.run()
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
