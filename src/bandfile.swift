// Any MIDI file, played with the band. Chosen in the window, dropped on it, or named aloud
// ("play Clair de Lune with the band"): Nova finds the file in the usual folders, takes its piano
// part (or its busiest part), and the band arranges around it as it does for a piece played live.
// Afterwards the band keys and "play it back with the band" work on that piece too.

import Foundation

extension Engine {
    /// The folders a MIDI file is looked for in, most likely first.
    static var midiFolders: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [home.appendingPathComponent("Music/Nova Songs"), baseDir.appendingPathComponent("ideas"), home.appendingPathComponent("Downloads"),
                home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents"), home.appendingPathComponent("Music")]
    }

    /// A file name as it should be said: "THE EAGLES.Hotel California K (1)" becomes "The Eagles, Hotel California K".
    static func spokenFileName(_ url: URL) -> String {
        var n = url.deletingPathExtension().lastPathComponent
        n = n.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: ", ").replacingOccurrences(of: " - ", with: ", ")
        let words = n.split(separator: " ").map { w -> String in
            let s = String(w)
            return s.count > 3 && s == s.uppercased() && s.rangeOfCharacter(from: .letters) != nil ? s.capitalized : s
        }
        return words.joined(separator: " ").replacingOccurrences(of: " ,", with: ",").trimmingCharacters(in: .whitespaces)
    }

    /// Every MIDI file in those folders (one level of subfolders too), newest first.
    static func midiFiles() -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for dir in midiFolders {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                if ["mid", "midi"].contains(u.pathExtension.lowercased()) { found.append(u) }
                if found.count > 400 { break }
            }
        }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return found.sorted { date($0) > date($1) }
    }

    /// The MIDI file whose name best matches what was said, if any matches well.
    static func midiNamed(_ name: String) -> URL? {
        let want = Ears.words(name).filter { !["the", "a", "my", "midi", "file", "song", "piece", "called", "named"].contains($0) }
        guard !want.isEmpty else { return nil }
        var best: (URL, Double)? = nil
        for u in midiFiles() {
            let have = Ears.words(u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "))
            let hits = want.filter { w in have.contains { $0 == w || Ears.close($0, w) } }.count
            let score = Double(hits) / Double(want.count) - Double(max(0, have.count - want.count)) * 0.02
            if hits > 0, score > (best?.1 ?? 0.5) { best = (u, score) }
        }
        return best?.0
    }

    /// The piece in a MIDI file, as the band expects it: the piano part if it has one, otherwise the busiest part.
    static func takeFromMIDI(_ url: URL) -> [RNote]? {
        guard let file = readMIDIForRoll(url), !file.notes.isEmpty else { return nil }
        let byTrack = Dictionary(grouping: file.notes, by: { $0.track })
        // A file with several parts already has its own band; the band joins its main part only.
        let main = byTrack.max { a, b in
            func weight(_ ns: [RollNote]) -> Double { Double(ns.count) * (ns.contains { $0.pitch < 55 } && ns.contains { $0.pitch > 64 } ? 1.5 : 1) }
            return weight(a.value) < weight(b.value)
        }?.value ?? file.notes
        let notes = main.filter { $0.t < 240 }                     // four minutes at most
        return tidyTake(notes.map { RNote(t: $0.t, end: $0.t + $0.dur, pitch: $0.pitch, vel: max(30, min(120, $0.vel))) }.sorted { $0.t < $1.t })
    }

    /// Plays a MIDI file with the band, and keeps it as the piece the band keys work on.
    func bandFile(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let name = Engine.spokenFileName(url)
        guard let take = Engine.takeFromMIDI(url), take.count >= 3 else {
            run { g in self.say("I couldn't read any notes in \(name).", g) }
            return
        }
        lock.lock()
        autosaveTake()
        waiting = false; paused = false; roundOn = false
        accGen += 1
        midi.allOff()
        live.silence()
        importedTake = take
        importedName = name
        importedAt = now()
        lock.unlock()
        let a = analyse(take)
        let ev = events(take + bandFull(take, a))
        let minutes = Int(((take.last?.end ?? 0) - (take.first?.t ?? 0)) / 60)
        ui("now " + name + " with the band")
        run { g in
            self.say("\(name), with the band. It's in \(a.keyName). " + (minutes >= 2 ? "About \(minutes) minutes. Say stop to end it." : ""), g)
            self.play(ev, g)
            if self.alive(g) { self.say(pick(["That was \(name) with the band.", "And that's \(name)."]) + " Say play it back with the band to hear it again.", g) }
        }
    }

    /// "Play Clair de Lune with the band", "band a MIDI file", "upload a MIDI for the band".
    func bandFileHear(_ h: Heard) -> String? {
        // The recogniser often stops after "band a" and loses "MIDI".
        if ["band a", "band an", "band the", "band a file", "band a song"].contains(h.text) { ui("pickmidi band"); run { g in self.say("Choose the MIDI file in the window that just opened, or say its name with the band.", g) }; return "band file pick" }
        let mentionsFile = h.has("midi", "midi file", "file")
        let withBand = h.has("with the band", "with a band", "for the band", "band mode", "to the band", "band play", "band a", "band this", "band my")
        guard withBand || (mentionsFile && h.has("band")) else { return nil }
        // "Play <name> with the band": find it by name.
        if let named = h.after("play", "band", "use", "load", "open")?.components(separatedBy: " with ")[0].components(separatedBy: " for ")[0],
           !Ears.words(named).filter({ !["a", "my", "the", "midi", "file", "this", "it", "back", "that", "some", "one", "song"].contains($0) }).isEmpty,
           let url = Engine.midiNamed(named) {
            bandFile(url.path); return "band file"
        }
        if mentionsFile || h.has("upload", "choose", "pick", "open", "load", "import") {
            ui("pickmidi band")
            let recent = Engine.midiFiles().prefix(3).map { Engine.spokenFileName($0) }
            run { g in
                self.say("Choose the MIDI file in the window that just opened." + (recent.isEmpty ? "" : " Or say its name with the band. The newest ones are: \(spokenList(Array(recent), limit: 3))."), g)
            }
            return "band file pick"
        }
        return nil
    }
}

func bandFileSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    // A small file, written here: a C major scale with a chord under it.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nova-bandfile-test")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("Morning Scale.mid")
    var track: [UInt8] = []
    for (i, p) in [60, 62, 64, 65, 67, 69, 71, 72].enumerated() {
        track += [0x00, 0x90, UInt8(p), 90] + (i == 0 ? [0x00, 0x90, 48, 70] : []) + [0x83, 0x60, 0x80, UInt8(p), 0]
    }
    track += [0x00, 0x80, 48, 0, 0x00, 0xFF, 0x2F, 0x00]
    var data: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0] + Array("MTrk".utf8)
    let n = track.count
    data += [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + track
    try? Data(data).write(to: url)
    let take = Engine.takeFromMIDI(url) ?? []
    let band = take.count >= 3 ? bandFull(take, analyse(take)) : []
    let routed = ["play my midi file with the band", "upload a midi for the band", "band a midi file"].map { engine.bandFileHear(Heard($0)) }
    let left = ["play it back with the band", "band louder", "open safari"].map { engine.bandFileHear(Heard($0)) }
    check("band a MIDI file: its notes are read, the band arranges around them, and asking for it opens the picker",
          take.count == 9 && !band.isEmpty && routed.allSatisfy { $0 == "band file pick" } && left.allSatisfy { $0 == nil }, "\(take.count) notes, \(band.count) band notes, \(routed) \(left)")
    try? FileManager.default.removeItem(at: dir)
}
