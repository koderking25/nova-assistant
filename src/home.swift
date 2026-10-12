// Around the house: music on Spotify, videos on YouTube, the files on this Mac, and the forecast.
//
// The same rules as everywhere else: look first, act, then say only what really happened.
// Files are only ever listed and opened here. Nothing is moved, renamed or deleted.

import Foundation

enum Web {
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"

    static func address(_ base: String, _ query: [(String, String)]) -> String {
        var parts = URLComponents(string: base)!
        parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts.url?.absoluteString ?? base
    }

    static func get(_ url: String, seconds: Int = 8) -> String? {
        let r = runTool("/usr/bin/curl", ["-s", "-L", "-m", "\(seconds)", "-A", agent, "-H", "Accept-Language: en", url], timeout: Double(seconds) + 2)
        return r.ok && !r.out.isEmpty ? r.out : nil
    }

    /// Every match of a pattern, as its capture groups.
    static func find(_ pattern: String, in text: String, limit: Int = 12) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [[String]] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(limit) {
            out.append((1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" })
        }
        return out
    }

    /// Text as it was written inside a web page's data, with its escapes undone.
    static func plain(_ s: String) -> String {
        ((try? JSONSerialization.jsonObject(with: Data("[\"\(s)\"]".utf8))) as? [String])?.first ?? s
    }

    /// The first video YouTube offers for these words.
    static func firstVideo(_ query: String) -> (id: String, title: String)? {
        guard let page = get(address("https://www.youtube.com/results", [("search_query", query)])) else { return nil }
        let found = find("\"videoRenderer\":\\{\"videoId\":\"([A-Za-z0-9_-]{11})\",\"thumbnail\".{0,1500}?\"title\":\\{\"runs\":\\[\\{\"text\":\"((?:[^\"\\\\]|\\\\.)*)\"", in: page, limit: 1)
        if let f = found.first { return (f[0], plain(f[1])) }
        if let f = find("\"videoId\":\"([A-Za-z0-9_-]{11})\"", in: page, limit: 1).first { return (f[0], "") }
        return nil
    }

    /// Finds something on Spotify by an ordinary web search, then asks Spotify itself what it is called.
    static func spotify(_ query: String, kind: String?) -> (uri: String, title: String, kind: String)? {
        let words = "site:open.spotify.com " + query + (kind == nil || kind == "track" ? "" : " " + kind!)
        guard let page = get(address("https://search.brave.com/search", [("q", words)])) else { return nil }
        var seen = Set<String>()
        var hits: [(kind: String, id: String)] = []
        for f in find("open\\.spotify\\.com/(track|artist|album|playlist)/([A-Za-z0-9]{22})", in: page, limit: 60) where seen.insert(f[1]).inserted { hits.append((f[0], f[1])) }
        let wanted = kind.flatMap { k in hits.first { $0.kind == k } } ?? hits.first
        guard let hit = wanted else { return nil }
        var title = ""
        if let info = get(address("https://open.spotify.com/oembed", [("url", "https://open.spotify.com/\(hit.kind)/\(hit.id)")]), seconds: 5),
           let obj = try? JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any] { title = (obj["title"] as? String) ?? "" }
        return ("spotify:\(hit.kind):\(hit.id)", title, hit.kind)
    }
}

struct Place { let say: [String]; let path: String; let name: String }

enum Files {
    static var home: String { NSHomeDirectory() }

    static var oneDrive: String {
        let cloud = home + "/Library/CloudStorage"
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: cloud)) ?? []).filter { $0.hasPrefix("OneDrive") }.sorted { $0.count < $1.count }.first
        return found.map { cloud + "/" + $0 } ?? home + "/OneDrive"
    }

    static var places: [Place] {
        [Place(say: ["downloads", "download", "downloaded", "downloads folder"], path: home + "/Downloads", name: "Downloads"),
         Place(say: ["documents", "documents folder", "my documents"], path: home + "/Documents", name: "Documents"),
         Place(say: ["desktop"], path: home + "/Desktop", name: "the Desktop"),
         Place(say: ["onedrive", "one drive"], path: oneDrive, name: "OneDrive"),
         Place(say: ["icloud", "icloud drive", "i cloud"], path: home + "/Library/Mobile Documents/com~apple~CloudDocs", name: "iCloud Drive"),
         Place(say: ["ideas folder", "pieces folder", "compositions folder"], path: baseDir.appendingPathComponent("ideas").path, name: "your ideas folder"),
         Place(say: ["midify", "midi folder", "midi files"], path: home + "/Music/Nova Songs", name: "your songs folder"),
         Place(say: ["music folder"], path: home + "/Music", name: "the Music folder"),
         Place(say: ["pictures folder", "photos folder"], path: home + "/Pictures", name: "the Pictures folder"),
         Place(say: ["movies folder", "videos folder"], path: home + "/Movies", name: "the Movies folder"),
         Place(say: ["home folder"], path: home, name: "your home folder"),
         Place(say: ["applications folder", "apps folder"], path: "/Applications", name: "the Applications folder")]
    }

    static let kinds: [String: String] = ["pdf": "a PDF", "docx": "a Word document", "doc": "a Word document", "pptx": "a PowerPoint", "xlsx": "a spreadsheet", "csv": "a spreadsheet",
        "txt": "a text file", "md": "a text file", "rtf": "a text file", "pages": "a Pages document", "mid": "a MIDI file", "midi": "a MIDI file", "wav": "an audio file", "mp3": "an audio file",
        "m4a": "an audio file", "aif": "an audio file", "aiff": "an audio file", "flac": "an audio file", "png": "a picture", "jpg": "a picture", "jpeg": "a picture", "heic": "a picture",
        "gif": "a picture", "mov": "a video", "mp4": "a video", "zip": "a zip file", "dmg": "an installer", "pkg": "an installer", "logicx": "a Logic project", "rpp": "a REAPER project",
        "html": "a web page", "app": "an app", "key": "a Keynote", "numbers": "a spreadsheet", "band": "a GarageBand project", "musicxml": "a score", "mscz": "a score"]

    /// A file's name the way a person would say it: "History essay, a Word document".
    static func spoken(_ url: URL) -> String {
        var folder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &folder)
        let ext = url.pathExtension.lowercased()
        let name = (ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "  ", with: " ")
        let kind = kinds[ext] ?? (folder.boolValue ? "a folder" : ext.isEmpty ? "a file" : "a \(ext) file")
        return "\(name), \(kind)"
    }

    static func age(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) minutes ago" }
        if s < 7200 { return "an hour ago" }
        if s < 86400, Calendar.current.isDateInToday(date) { return "\(Int(s / 3600)) hours ago" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        if s < 86400 { return "\(Int(s / 3600)) hours ago" }
        let days = Int(s / 86400)
        return days < 14 ? "\(max(2, days)) days ago" : days < 60 ? "\(days / 7) weeks ago" : "\(days / 30) months ago"
    }

    static func when(_ url: URL) -> Date {
        let v = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast
    }

    /// What is in a folder, newest first. Nil means the Mac would not let the app look.
    static func newest(in path: String) -> [URL]? {
        guard let all = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.addedToDirectoryDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        return all.filter { !["localized", "ini"].contains($0.pathExtension) }.map { ($0, when($0)) }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Files anywhere in the home folder whose name contains these words, most recently changed first.
    static func search(_ words: String) -> [URL] {
        let r = runTool("/usr/bin/mdfind", ["-onlyin", home, "-name", words], timeout: 8)
        let paths = r.out.components(separatedBy: "\n").filter { p in
            !p.isEmpty && !p.contains("/Library/") && !p.contains("/.") && !p.contains("/node_modules/") && !p.contains(".app/") && !p.contains("/voice/cache/")
        }
        return paths.prefix(200).map { URL(fileURLWithPath: $0) }.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}

extension Engine {
    func homeHear(_ h: Heard) -> String? {
        if let done = spotifyHear(h) { return done }
        if let done = youtubeHear(h) { return done }
        if let done = filesHear(h) { return done }
        if let done = forecastHear(h) { return done }
        return nil
    }

    /// The words of a request with the service and the asking taken off: "play island in the sun on spotify" becomes "island in the sun".
    func subject(_ h: Heard, without service: [String]) -> String {
        var t = " " + h.text + " "
        for s in service { for lead in ["on ", "in ", "from ", "with ", "using ", "through ", ""] { t = t.replacingOccurrences(of: " " + lead + s + " ", with: " ") } }
        t = t.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for lead in ["play me some", "play me the song", "play me", "play the song", "play the video", "play some", "play a", "play", "put on some", "put on", "listen to", "i want to hear", "i want to watch",
                         "i want to listen to", "let me hear", "watch", "show me", "find me", "find", "queue up", "queue", "start playing", "the song", "the video", "a video of", "videos of", "some"]
            where t == lead || t.hasPrefix(lead + " ") {
                t = String(t.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return t
    }

    // MARK: Spotify

    func spotifyScript(_ body: String) -> (ok: Bool, out: String) {
        LogicControl.osa("tell application \"Spotify\"\n\(body)\nend tell")
    }

    /// What Spotify says it is doing: "playing|Island In The Sun|Weezer".
    func spotifyNow() -> (state: String, song: String, artist: String)? {
        let r = spotifyScript("set s to player state as text\ntry\nreturn s & \"|\" & (name of current track) & \"|\" & (artist of current track)\non error\nreturn s & \"||\"\nend try")
        let f = r.out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard r.ok, f.count >= 3 else { return nil }
        return (f[0], f[1], f[2])
    }

    static let spotifyDenied = "The Mac hasn't let me control Spotify yet. When it asks, choose Allow. If it doesn't ask, it's under System Settings, Privacy and Security, Automation, Nova."

    /// Is Spotify open and playing right now? (The self-test can pretend.)
    func spotifyPlaying() -> Bool {
        if Opt.fast { return pretendSpotify }
        guard runTool("/usr/bin/pgrep", ["-xq", "Spotify"], timeout: 2).ok else { return false }
        return spotifyNow()?.state == "playing"
    }

    /// Requests that are about Spotify without naming it: a song "by" someone that is not in the
    /// library, and "next song", "what song is this" or "turn it up" while Spotify is the thing playing.
    func spotifyMeant(_ h: Heard) -> Heard? {
        if h.has("spotify") { return h }
        if h.has("youtube", "you tube", "lesson", "teach", "band", "metronome", "my album", "my pieces") || (h.has("track") && !h.has("this track", "next track")) { return nil }
        if h.starts("play", "put on", "listen to"), h.has("by"), !h.has("it", "that", "back", "piano"), songNamed(h) == nil, h.words.count >= 4 { return Heard(h.text + " on spotify") }
        // With Spotify playing and nothing of the assistant's own going on, the short words mean the music too.
        if mode == .idle, ["next", "skip", "next one", "skip it", "skip this one", "previous", "previous one", "the one before", "go back one"].contains(h.text), spotifyPlaying() {
            return Heard((h.has("previous", "before", "back") ? "previous song" : "next song") + " on spotify")
        }
        if mode == .idle, ["play", "resume", "continue", "unpause", "keep playing", "carry on", "play this song", "play the song", "play the music", "play music", "resume the music", "play it"].contains(h.text),
           !Opt.fast || pretendSpotify, now() - spotifyPausedAt < 3600 {
            return Heard("resume on spotify")
        }
        let control = h.has("about this song", "about this track", "about the song", "about this artist", "about this band", "tell me about this", "what key is this", "which key is this", "what key is the song",
                            "the tempo", "what tempo", "bpm", "how fast is this", "who wrote this", "who made this", "when did this come out", "when was this released", "what year is this", "what album",
                            "which album", "how long is this", "how long is the song", "how much is left", "what is this song about", "whats this song about", "what genre", "restart the song",
                            "restart this song", "start the song over", "start it over", "from the beginning", "from the top", "play that again", "play this song again", "play it again", "skip ahead", "fast forward",
                            "rewind", "go back ten", "shuffle", "repeat this song", "repeat the song", "on repeat", "stop repeating", "more by this artist", "more from this artist", "play this artist",
                            "play this album", "play the album", "more like this", "mute the music", "next song", "skip this song", "skip the song", "skip song", "skip this", "next track", "previous song", "last song", "what song is this", "what song is that", "whats this song",
                            "what is this song", "whats playing", "what is playing", "who sings this", "who is this", "pause the music", "stop the music", "pause the song", "stop the song",
                            "resume the music", "turn it up", "turn it down", "volume up", "volume down", "turn the music up", "turn the music down", "music louder", "music quieter")
        guard control, mode != .teach, spotifyPlaying() || (h.has("resume the music") && !Opt.fast && runTool("/usr/bin/pgrep", ["-xq", "Spotify"], timeout: 2).ok) else { return nil }
        return Heard(h.text.replacingOccurrences(of: "last song", with: "previous song") + " on spotify")
    }

    /// Things to do with the song that is playing: hear about it, start it again, jump about in it, shuffle, more by the artist.
    func spotifyMore(_ h: Heard, _ asked: Heard) -> String? {
        let about = h.has("about this song", "about this track", "about the song", "about this artist", "about this band", "tell me about this", "what key", "which key", "the tempo", "what tempo", "bpm",
                          "how fast is this", "who wrote this", "who made this", "when did this come out", "when was this released", "what year", "what is this song about", "whats this song about", "what genre")
        let album = h.has("what album", "which album")
        let length = h.has("how long is this", "how long is the song", "how much is left")
        let restart = h.has("restart the song", "restart this song", "start the song over", "start it over", "from the beginning", "from the top", "play that again", "play this song again", "play it again")
        let ahead = h.has("skip ahead", "fast forward"), back = h.has("rewind", "go back ten")
        let shuffle = h.has("shuffle"), again = h.has("repeat this song", "repeat the song", "on repeat", "stop repeating")
        let artist = h.has("more by this artist", "more from this artist", "play this artist", "more like this"), wholeAlbum = h.has("play this album", "play the album")
        let mute = h.has("mute the music")
        guard about || album || length || restart || ahead || back || shuffle || again || artist || wholeAlbum || mute else { return nil }
        let tag = about ? "about" : album ? "album" : length ? "length" : restart ? "restart" : ahead ? "ahead" : back ? "back" : shuffle ? "shuffle" : again ? "repeat" : artist ? "artist" : wholeAlbum ? "this album" : "mute"
        if Opt.fast { run { g in self.say("Spotify.", g) }; return "spotify \(tag)" }
        guard runTool("/usr/bin/pgrep", ["-xq", "Spotify"], timeout: 2).ok else { run { g in self.say("Spotify isn't open.", g) }; return "spotify \(tag)" }
        guard let n = spotifyNow(), !n.song.isEmpty else { run { g in self.say("Nothing is loaded in Spotify.", g) }; return "spotify \(tag)" }
        if about {
            // Looked up, not guessed: the key and the tempo of a recording are facts to find.
            finishAsk("Search the web about the song \"\(n.song)\" by \(n.artist), which is playing right now. He asked: \(asked.text). If he asked about the key or the tempo, or simply to be told about the song, "
                      + "give its key and its tempo in beats per minute, then one or two interesting facts. If you cannot find the key, say so plainly. Three short spoken sentences at most.")
            return "spotify about"
        }
        run { g in
            func ask(_ script: String) -> String { self.spotifyScript(script).out.trimmingCharacters(in: .whitespacesAndNewlines) }
            func clock(_ seconds: Double) -> String { let s = Int(seconds); return s >= 60 ? "\(s / 60) minute\(s / 60 == 1 ? "" : "s")\(s % 60 == 0 ? "" : " \(s % 60)")" : "\(s) seconds" }
            if album {
                let a = ask("return album of current track")
                self.say(a.isEmpty ? "Spotify didn't say which album." : "It's from \(a), by \(n.artist).", g)
            } else if length {
                let total = (Double(ask("return duration of current track")) ?? 0) / 1000, at = Double(ask("return player position")) ?? 0
                self.say(total <= 0 ? "Spotify didn't say." : "\(n.song) is \(clock(total)) long, and there's \(clock(max(0, total - at))) left.", g)
            } else if restart {
                _ = ask("set player position to 0\nplay")
                self.say("\(n.song), from the top.", g)
            } else if ahead || back {
                let by = Double(h.number ?? (ahead ? 15 : 10))
                _ = ask("set player position to (player position \(ahead ? "+" : "-") \(Int(by)))")
                self.say(ahead ? "Skipped ahead \(Int(by)) seconds." : "Back \(Int(by)) seconds.", g)
            } else if shuffle {
                let on = !h.has("off", "stop", "no", "dont")
                _ = ask("set shuffling to \(on)")
                self.say(ask("return shuffling") == "\(on)" ? "Shuffle is \(on ? "on" : "off")." : "Spotify wouldn't change shuffle just now.", g)
            } else if again {
                let on = !h.has("off", "stop", "no", "dont", "stop repeating")
                _ = ask("set repeating to \(on)")
                self.say(ask("return repeating") == "\(on)" ? (on ? "Repeat is on." : "Repeat is off.") : "Spotify wouldn't change repeat just now.", g)
            } else if mute {
                _ = ask("set sound volume to 0")
                self.say("Spotify is muted. Say turn it up to bring it back.", g)
            } else {
                // More by the artist, or the whole album: found the same way as any other request.
                let words = wholeAlbum ? ask("return album of current track") + " " + n.artist : n.artist
                guard let hit = Web.spotify(words, kind: wholeAlbum ? "album" : "artist") else { self.say("I couldn't find \(wholeAlbum ? "that album" : n.artist) from here.", g); return }
                let r = self.spotifyScript("play track \(LogicControl.quote(hit.uri))")
                usleep(1_200_000)
                let now2 = self.spotifyNow()
                self.say(r.ok && now2?.state == "playing" ? "Playing \(hit.title.isEmpty ? words : hit.title). First up is \(now2?.song ?? "")." : "Spotify didn't start that.", g)
            }
        }
        return "spotify \(tag)"
    }

    func spotifyHear(_ first: Heard) -> String? {
        guard let h = spotifyMeant(first) else { return nil }
        // Louder and quieter: Spotify's own volume, which works whatever the sound goes out through.
        if h.has("turn it up", "turn it down", "volume up", "volume down", "louder", "quieter", "turn the music up", "turn the music down", "turn up", "turn down", "volume") && !h.has("play", "by") {
            let down = h.has("down", "quieter", "turn it down", "volume down", "turn down", "lower")
            let exact = h.has("volume") ? h.number : nil
            run { g in
                if Opt.fast { self.say("Spotify volume.", g); return }
                let r = self.spotifyScript(exact.map { "set sound volume to \(max(0, min(100, $0)))" } ?? "set sound volume to (sound volume \(down ? "- 15" : "+ 15"))" + "\nreturn sound volume")
                let v = self.spotifyScript("return sound volume").out.trimmingCharacters(in: .whitespacesAndNewlines)
                self.say(r.ok && Int(v) != nil ? "Spotify is at \(v) percent." : LogicControl.denied(r.out) ? Engine.spotifyDenied : "Spotify didn't answer me.", g)
            }
            return "spotify volume \(exact.map(String.init) ?? (down ? "down" : "up"))"
        }
        if let done = spotifyMore(h, first) { return done }
        let asking = h.has("whats playing", "what is playing", "what song", "which song", "whats this song", "what is this song", "who is this", "whos singing", "who sings this", "name of this song")
        let verb = h.has("play", "put on", "listen", "hear", "queue", "resume", "continue", "pause", "stop", "next", "skip", "previous", "start playing", "unpause")
        guard asking || verb else { return nil }                 // "open Spotify" and "quit Spotify" are about the app itself
        if Opt.fast {
            let q = subject(h, without: ["spotify"])
            let tag = asking ? "spotify now" : h.has("pause", "stop") ? "spotify pause" : h.has("next", "skip") ? "spotify next" : h.has("previous") ? "spotify previous" : q.isEmpty || ["music", "it", "resume", "continue", "unpause"].contains(q) ? "spotify resume" : "spotify play \(q)"
            run { g in self.say("Spotify.", g) }
            return tag
        }
        func open() -> Bool {
            if runTool("/usr/bin/pgrep", ["-xq", "Spotify"], timeout: 2).ok { return true }
            _ = runTool("/usr/bin/open", ["-g", "-a", "Spotify"], timeout: 10)
            for _ in 0..<40 { if runTool("/usr/bin/pgrep", ["-xq", "Spotify"], timeout: 2).ok { usleep(2_500_000); return true }; usleep(250_000) }
            return false
        }
        func failed(_ r: (ok: Bool, out: String), _ g: Int) {
            self.noteMistake("a Spotify action failed", String(r.out.prefix(120)))
            self.say(LogicControl.denied(r.out) ? Engine.spotifyDenied : "Spotify didn't answer me.", g)
        }
        if asking {
            run { g in
                guard runTool("/usr/bin/pgrep", ["-xq", "Spotify"], timeout: 2).ok else { self.say("Spotify isn't open.", g); return }
                guard let n = self.spotifyNow() else { self.say(Engine.spotifyDenied, g); return }
                self.say(n.song.isEmpty ? "Nothing is loaded in Spotify." : n.state == "playing" ? "That's \(n.song), by \(n.artist)." : "It's paused on \(n.song), by \(n.artist).", g)
            }
            return "spotify now"
        }
        for (words, command, tag) in [(["pause", "stop"], "pause", "pause"), (["next", "skip"], "next track", "next"), (["previous"], "previous track", "previous")] where words.contains(where: { h.has($0) }) && !h.has("play") {
            run { g in
                guard runTool("/usr/bin/pgrep", ["-xq", "Spotify"], timeout: 2).ok else { self.say("Spotify isn't open.", g); return }
                let r = self.spotifyScript(command)
                guard r.ok else { failed(r, g); return }
                if tag == "pause" { self.spotifyPausedAt = now() }
                usleep(700_000)
                let n = self.spotifyNow()
                if tag == "pause" { self.say(n?.state == "playing" ? "I asked Spotify to pause, but it's still playing." : "Spotify is paused.", g) }
                else if let n = n, !n.song.isEmpty { self.say("Now it's \(n.song), by \(n.artist).", g) }
                else { self.say("Done.", g) }
            }
            return "spotify \(tag)"
        }
        let q = subject(h, without: ["spotify"])
        if q.isEmpty || ["music", "it", "resume", "continue", "unpause", "something", "my music", "anything", "this song", "the song", "the music"].contains(q) {
            run { g in
                guard open() else { self.say("I couldn't open Spotify.", g); return }
                let r = self.spotifyScript("play")
                guard r.ok else { failed(r, g); return }
                usleep(900_000)
                if let n = self.spotifyNow(), n.state == "playing", !n.song.isEmpty { self.say("Spotify is playing \(n.song), by \(n.artist).", g) }
                else { self.say("I asked Spotify to play, but nothing started. It may not have anything loaded yet.", g) }
            }
            return "spotify resume"
        }
        let kind: String? = h.has("playlist") ? "playlist" : h.has("album") ? "album" : (h.has("songs by", "music by", "anything by", "something by", "stuff by") ? "artist" : h.has("by", "song") ? "track" : nil)
        var words = q
        for lead in ["songs by", "music by", "anything by", "something by", "stuff by", "the album", "the playlist", "my playlist"] where words.hasPrefix(lead + " ") { words = String(words.dropFirst(lead.count + 1)) }
        run { g in
            let found = Web.spotify(words, kind: kind)
            guard self.alive(g) else { return }
            guard open() else { self.say("I couldn't open Spotify.", g); return }
            guard let hit = found else {
                // Not found from here: hand the search to Spotify itself and say so.
                let encoded = words.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? words
                _ = runTool("/usr/bin/open", ["spotify:search:\(encoded)"], timeout: 8)
                self.say("I couldn't pick that out myself, so I've put the search for \(words) up in Spotify.", g)
                return
            }
            let r = self.spotifyScript("play track \(LogicControl.quote(hit.uri))")
            guard r.ok else { failed(r, g); return }
            var now = self.spotifyNow()
            for _ in 0..<8 where now?.state != "playing" { usleep(400_000); now = self.spotifyNow() }
            if let n = now, n.state == "playing", !n.song.isEmpty {
                self.say(hit.kind == "track" ? "Playing \(n.song), by \(n.artist)." : "Playing \(hit.title.isEmpty ? words : hit.title). First up is \(n.song), by \(n.artist).", g)
            } else {
                self.noteMistake("a Spotify action failed", "asked for \(hit.uri), not playing")
                self.say("I found \(hit.title.isEmpty ? words : hit.title) and asked Spotify to play it, but it hasn't started. Spotify may need you to sign in.", g)
            }
        }
        return "spotify play \(words)"
    }

    // MARK: YouTube

    func youtubeHear(_ h: Heard) -> String? {
        guard h.has("youtube", "you tube") else { return nil }
        guard h.has("play", "watch", "put on", "listen", "hear", "video", "videos", "find", "show me"), !h.has("search", "look up") else { return nil }
        let q = subject(h, without: ["youtube", "you tube"])
        guard !q.isEmpty, !["it", "something", "a video", "video", "videos"].contains(q) else { return nil }
        run { g in
            if Opt.fast { self.say("YouTube.", g); return }
            let browser = FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") ? ["-a", "Google Chrome"] : []
            if let v = Web.firstVideo(q) {
                guard self.alive(g) else { return }
                let r = runTool("/usr/bin/open", browser + ["https://www.youtube.com/watch?v=\(v.id)"], timeout: 10)
                self.say(!r.ok ? "I found it, but I couldn't open the browser." : v.title.isEmpty ? "I've opened the top video for \(q) on YouTube." : "Here's \(v.title), on YouTube.", g)
            } else {
                let r = runTool("/usr/bin/open", browser + [Web.address("https://www.youtube.com/results", [("search_query", q)])], timeout: 10)
                self.say(r.ok ? "I couldn't pick one video, so I've opened the YouTube results for \(q)." : "I couldn't open the browser.", g)
            }
        }
        return "youtube \(q)"
    }

    // MARK: Files

    func filesHear(_ h: Heard) -> String? {
        if h.has("menu", "track", "plugin", "save", "composition") || h.has("new project", "the project", "save the project") { return nil }
        // "Open it", "open the second one": about files that were just read out.
        if !lastFiles.isEmpty, now() - lastFilesAt < 180, h.has("open", "show me"), !h.has("back", "folder") {
            let which = h.has("second", "the second one") ? 1 : h.has("third") ? 2 : h.has("fourth") ? 3 : (h.has("it", "that", "that one", "first", "the first one", "newest", "latest") ? 0 : -1)
            if which >= 0, h.words.count <= 6 {
                guard lastFiles.indices.contains(which) else { run { g in self.say("I only read out \(self.lastFiles.count).", g) }; return "file none" }
                openFile(lastFiles[which])
                return "file open"
            }
        }
        let place = Files.places.first { p in p.say.contains { h.has($0) } }
        let wantsOpen = h.has("open", "show me", "go to", "take me to", "bring up", "pull up")
        let newest = h.has("latest", "newest", "last", "recent", "most recent", "just downloaded", "just download")
        let asks = h.has("what", "whats", "which", "list", "read", "tell me", "anything", "is there") || newest
        // Looking for a file by name.
        // "Find my history essay", "where is my science project": a search by name, unless it is about the music.
        if !h.has("track", "plugin", "piano", "keys", "phone", "composition", "piece", "song", "album", "idea", "ideas"),
           let name = h.after("find my", "wheres my", "where is my", "where did i put my", "where did i save my", "look for my"), name.split(separator: " ").count <= 5 {
            var words = name
            for tail in [" file", " document", " folder", " pdf"] where words.hasSuffix(tail) { words = String(words.dropLast(tail.count)) }
            findFiles(words, open: false)
            return "file find \(words)"
        }
        if let name = h.after("file called", "file named", "document called", "document named", "folder called", "folder named", "files called", "search my files for", "search my computer for", "find my file", "find the file", "find a file", "find file", "wheres my file", "where is my file", "where is the file", "wheres the file") {
            findFiles(name, open: h.starts("open"))
            return "file find \(name)"
        }
        guard let p = place else { return nil }
        if wantsOpen && newest {
            run { g in
                if Opt.fast { self.say("Files.", g); return }
                guard let all = Files.newest(in: p.path) else { self.say(self.blocked(p), g); return }
                guard let first = all.first else { self.say("\(p.name.capitalizedFirst) is empty.", g); return }
                self.lastFiles = [first]; self.lastFilesAt = now()
                self.openFile(first, g)
            }
            return "file newest \(p.name)"
        }
        if asks && !h.has("open") {
            listFiles(p)
            return "file list \(p.name)"
        }
        if wantsOpen {
            run { g in
                guard Opt.fast || FileManager.default.fileExists(atPath: p.path) else { self.say("I can't find \(p.name) on this Mac.", g); return }
                let r = Opt.fast ? (ok: true, out: "") : runTool("/usr/bin/open", [p.path], timeout: 10)
                self.say(r.ok ? pick(["\(p.name.capitalizedFirst) is open in Finder.", "There's \(p.name), open in Finder."]) : "I couldn't open \(p.name).", g)
            }
            return "folder \(p.name)"
        }
        return nil
    }

    func blocked(_ p: Place) -> String {
        FileManager.default.fileExists(atPath: p.path) ? "The Mac hasn't let me look in \(p.name) yet. When it asks, choose Allow. If it doesn't ask, it's under System Settings, Privacy and Security, Files and Folders, Nova."
            : "I can't find \(p.name) on this Mac."
    }

    func listFiles(_ p: Place) {
        run { g in
            if Opt.fast { self.say("Files.", g); return }
            guard let all = Files.newest(in: p.path) else { self.say(self.blocked(p), g); return }
            guard let first = all.first else { self.say("\(p.name.capitalizedFirst) is empty.", g); return }
            self.lastFiles = Array(all.prefix(4)); self.lastFilesAt = now()
            var text = "The newest thing in \(p.name) is \(Files.spoken(first)), from \(Files.age(Files.when(first)))."
            let rest = all.dropFirst().prefix(2).map { Files.spoken($0) }
            if !rest.isEmpty { text += " Before that, \(rest.joined(separator: ", and ")). " }
            text += all.count > 3 ? " There are \(all.count) things in there altogether. Say open it, or open the second one." : " Say open it, or open the second one."
            self.say(text.replacingOccurrences(of: "  ", with: " "), g)
        }
    }

    func findFiles(_ name: String, open: Bool) {
        run { g in
            let found = Opt.fast ? [] : Files.search(name)
            guard self.alive(g) else { return }
            guard let first = found.first else { self.say("I couldn't find a file with \(name) in its name.", g); return }
            self.lastFiles = Array(found.prefix(4)); self.lastFilesAt = now()
            func folder(_ u: URL) -> String { u.deletingLastPathComponent().lastPathComponent }
            if open && found.count == 1 { self.openFile(first, g); return }
            var text = found.count == 1 ? "I found one: \(Files.spoken(first)), in \(folder(first))."
                : "I found \(found.count >= 200 ? "a lot" : "\(found.count)"). The most recent is \(Files.spoken(first)), in \(folder(first)), from \(Files.age(Files.when(first)))."
            if found.count > 1 { text += " Then \(Files.spoken(found[1])), in \(folder(found[1]))." }
            text += found.count > 1 ? " Say open it, or open the second one." : " Say open it."
            self.say(text, g)
        }
    }

    func openFile(_ url: URL) { run { g in self.openFile(url, g) } }

    func openFile(_ url: URL, _ g: Int) {
        let r = Opt.fast ? (ok: true, out: "") : runTool("/usr/bin/open", [url.path], timeout: 10)
        say(r.ok ? "Opening \(Files.spoken(url))." : "I couldn't open \(Files.spoken(url)).", g)
    }

    // MARK: The forecast, and the weather somewhere else

    func forecastHear(_ h: Heard) -> String? {
        guard h.has("weather", "forecast", "temperature", "rain", "raining", "snow", "snowing", "umbrella", "jacket", "coat") else { return nil }
        let elsewhere = h.after("weather in", "weather like in", "forecast for", "forecast in", "temperature in", "raining in", "snowing in", "weather at")
        let day = h.has("day after tomorrow") ? 2 : h.has("tomorrow") ? 1 : 0
        let ahead = day > 0 || h.has("forecast", "tonight", "later", "this afternoon", "this evening", "today", "high", "low")
        guard ahead || elsewhere != nil else { return nil }       // plain "what's the weather" is answered from what is already known
        if h.has("my city", "i live", "set my") { return nil }
        var city = elsewhere ?? Weather.city
        for tail in [" tomorrow", " today", " tonight", " right now", " now", " like", " the day after tomorrow", " this week"] where city.hasSuffix(tail) { city = String(city.dropLast(tail.count)) }
        run { g in
            if Opt.fast { self.say("Tomorrow: a high of 20.", g); return }
            let where_ = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            guard let raw = Web.get("https://wttr.in/\(where_)?format=j1", seconds: 7), let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let days = obj["weather"] as? [[String: Any]], days.indices.contains(day) else {
                self.say("I couldn't reach the weather service just now.", g); return
            }
            let area = (((obj["nearest_area"] as? [[String: Any]])?.first?["areaName"] as? [[String: Any]])?.first?["value"] as? String) ?? city.capitalized
            let place = elsewhere != nil ? city.capitalized : area
            func temp(_ s: Any?) -> String { Weather.shown(Int((s as? String) ?? "") ?? 0) }
            if !ahead, let cur = (obj["current_condition"] as? [[String: Any]])?.first {
                let desc = (((cur["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                let w = WeatherNow(at: 0, condition: desc, temp: Int((cur["temp_C"] as? String) ?? "") ?? 0, feels: Int((cur["FeelsLikeC"] as? String) ?? "") ?? 0, place: place)
                self.say("It's \(Weather.sentence(w)).", g)
                return
            }
            let d = days[day]
            let hours = (d["hourly"] as? [[String: Any]]) ?? []
            let noon = hours.indices.contains(4) ? hours[4] : hours.first ?? [:]
            let desc = (((noon["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let rain = hours.compactMap { Int(($0["chanceofrain"] as? String) ?? "") }.max() ?? 0
            let snow = hours.compactMap { Int(($0["chanceofsnow"] as? String) ?? "") }.max() ?? 0
            let label = day == 2 ? "The day after tomorrow" : day == 1 ? "Tomorrow" : "Today"
            var text = "\(label) in \(place): a high of \(temp(d["maxtempC"])) and a low of \(temp(d["mintempC"]))\(desc.isEmpty ? "" : ", \(desc)")."
            text += snow >= 40 ? " Snow is likely." : rain >= 60 ? " Rain is likely, about \(rain) percent." : rain >= 25 ? " A \(rain) percent chance of rain." : " Rain isn't likely."
            if h.has("umbrella") { text = (rain >= 50 ? "Yes, take one. " : "You shouldn't need one. ") + text }
            if h.has("jacket", "coat") { text = ((Int((d["mintempC"] as? String) ?? "") ?? 20) < 12 ? "Yes, take one. " : "You'll be fine without. ") + text }
            self.say(text, g)
        }
        return "forecast"
    }
}

func homeSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    engine.goHomeQuietly()
    let a = engine.hear("play island in the sun by weezer on spotify")
    let b = engine.hear("can you put on some harry styles on spotify please")
    let c = engine.hear("pause spotify")
    let d = engine.hear("what song is this on spotify")
    let e = engine.hear("open spotify")
    let n1 = engine.hear("play island in the sun by weezer")
    let n2 = engine.hear("next song")
    engine.pretendSpotify = true
    let n3 = engine.hear("skip this song")
    let n4 = engine.hear("what song is this")
    let n5 = engine.hear("turn it up")
    engine.pretendSpotify = false
    let n6 = engine.hear("turn it up")
    let n7 = engine.hear("how do I play a C major chord")
    check("spotify: a song by an artist goes to Spotify without being told, and skip, what is this and turn it up mean Spotify only while it is playing",
          n1 == "spotify play island in the sun by weezer" && n2 == "next" && n3 == "spotify next" && n4 == "spotify now" && n5 == "spotify volume up" && n6 == "voice up" && n7 != "lesson",
          "\(n1) / \(n2) / \(n3) / \(n4) / \(n5) / \(n6) / \(n7)")
    engine.pretendSpotify = true
    let more = ["tell me about this song", "what key is this song in", "next", "start it over", "skip ahead thirty seconds", "shuffle on", "play more by this artist", "what album is this from", "how long is this song"].map { engine.hear($0) }
    engine.spotifyPausedAt = now()
    let again = engine.hear("play")
    engine.pretendSpotify = false
    engine.spotifyPausedAt = 0
    let notMusic = [engine.hear("next"), engine.hear("what key was that in")]
    check("spotify: while it plays, the song can be asked about, restarted, skipped through and shuffled, and without it those words keep their old meaning",
          more == ["spotify about", "spotify about", "spotify next", "spotify restart", "spotify ahead", "spotify shuffle", "spotify artist", "spotify album", "spotify length"] && again == "spotify resume"
          && notMusic == ["next", "describe"], more.joined(separator: " / ") + " / " + again + " / " + notMusic.joined(separator: " / "))
    let fm = engine.hear("where is my history essay")
    check("files: find my something searches by name", fm == "file find history essay", fm)
    check("spotify: a song, an artist, pausing and asking what is playing are all understood, and opening the app is left alone",
          a == "spotify play island in the sun by weezer" && b == "spotify play harry styles" && c == "spotify pause" && d == "spotify now" && e.hasPrefix("app"), "\(a) / \(b) / \(c) / \(d) / \(e)")
    let y1 = engine.hear("play harry styles on youtube")
    let y2 = engine.hear("I want to watch a video of a cat playing piano on YouTube")
    let y3 = engine.hear("open youtube")
    check("youtube: play something on YouTube finds the words, and open YouTube still just opens it", y1 == "youtube harry styles" && y2 == "youtube a cat playing piano" && y3 == "site YouTube", "\(y1) / \(y2) / \(y3)")
    // Files: a folder made for the test, never one of the player's.
    let dir = NSTemporaryDirectory() + "tp-files-test-\(ProcessInfo.processInfo.processIdentifier)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (i, n) in ["old_notes.txt", "History-essay.docx", "new song.mid"].enumerated() {
        FileManager.default.createFile(atPath: dir + "/" + n, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i - 3) * 4000)], ofItemAtPath: dir + "/" + n)
    }
    let listed = (Files.newest(in: dir) ?? []).sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
    let said = listed.first.map { Files.spoken($0) } ?? ""
    try? FileManager.default.removeItem(atPath: dir)
    check("files: names are read the way a person would say them", listed.count == 3 && said == "new song, a MIDI file" && Files.spoken(URL(fileURLWithPath: "/x/History-essay.docx")) == "History essay, a Word document", said)
    let f1 = engine.hear("what was that file in downloads")
    let f2 = engine.hear("open onedrive")
    let f3 = engine.hear("open my downloads folder")
    let f4 = engine.hear("find the file called history essay")
    let f5 = engine.hear("open the latest file in downloads")
    let f6 = engine.hear("can I save it in the ideas folder")
    check("files: asking what is in a folder, opening a folder, the newest file and finding by name", f1 == "file list Downloads" && f2 == "folder OneDrive" && f3 == "folder Downloads" && f4 == "file find history essay" && f5 == "file newest Downloads" && !f6.hasPrefix("f"),
          "\(f1) / \(f2) / \(f3) / \(f4) / \(f5) / \(f6)")
    let w1 = engine.hear("what's the weather tomorrow")
    let w2 = engine.hear("what's the weather in Paris")
    let w3 = engine.hear("what's the weather")
    check("weather: tomorrow and other cities go to the forecast, plain weather is answered as before", w1 == "forecast" && w2 == "forecast" && w3 != "forecast", "\(w1) / \(w2) / \(w3)")
    engine.goHomeQuietly()
}
