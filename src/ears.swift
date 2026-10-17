// The ears: deciding what, in a stream of recognised words, is meant for the assistant.
//
// The app window only turns speech into text and passes every update here. Everything else
// is decided in this file: finding the wake word, ignoring the assistant's own voice,
// waiting for the speaker to finish, and keeping the door open for a request after a bare
// "Jarvis". Keeping it here means it can be improved without rebuilding the app, which
// would make macOS ask for the microphone permission again.

import Foundation

final class Ears {
    // By the time these are looked for, every way of hearing the chosen name has been rewritten as this one word.
    static let wakeWords = ["hey jarvis", "jarvis"]
    static let urgent = ["stop", "quiet", "cancel", "home", "pause", "enough"]
    static let logURL = baseDir.appendingPathComponent("voice-log.txt")
    private let lock = NSLock()
    private var handled = ""          // the part of the running transcript already dealt with
    private var lastMiss = 0.0
    private var softUntil = 0.0       // until when a request counts as following a merely possible name
    private var lastChatter = 0.0     // when ordinary talk, not meant for it, was last heard
    private var credits: [Double] = []   // one for each time it has said its own name and may yet hear it back; each has a time it lapses
    private var stretchStart = true      // the next text begins a new stretch of listening
    private var splitTail = "", splitAt = -100.0, joining = false
    private var owners: [Bool] = []   // for each name in the recogniser's text so far: true if it was its own voice
    private var sessionOver = false   // the recogniser finished its text; the next one starts afresh
    private var nameIsReal = false    // a name not yet dealt with was said by a person, not by itself

    /// The assistant is about to say this. Each time its own name is in it, the microphone may hand that name back.
    func spoke(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let n = Ears.words(Ears.tidy(text)).filter { $0 == "jarvis" }.count
        credits += Array(repeating: Double.infinity, count: n)
    }
    func lapseCreditsForTest() { lock.lock(); credits = []; lock.unlock() }
    func cutOff() { lock.lock(); settleCredits(within: 1.5); lock.unlock() }
    /// It has stopped (finished, or was cut off): its own name can only come back for a few seconds more.
    func settleCredits(within seconds: Double) {
        let until = now() + seconds
        credits = credits.map { $0 == .infinity ? until : $0 }
    }
    private var nameAt = -1           // which word of the sentence was first heard as the name
    private var nameSeen = 0.0        // and when: the recogniser sometimes rewrites it a moment later
    private var lastText = ""
    private weak var lastEngine: Engine?
    private var token = 0
    var openUntil = 0.0               // after "Jarvis" on its own, the next sentence is the request
    var awaiting = false
    var casualUntil = 0.0             // until when a short reply without the name is still listened to
    var openByName = false            // the open window began with the name being called, not with a question of its own

    // Words the recogniser sometimes writes when "Jarvis" was said. They only count at the very
    // start of a sentence, and only when what follows is plainly a request, so ordinary talk
    // that happens to contain one of them is left alone.
    static let looseNames: Set<String> = ["service", "nervous", "jarred", "java", "javas", "jobs", "drivers", "jars", "chavis", "davis", "jeeves", "jarvey", "harvest"]

    /// Does this word sound like the name? J, CH, G, D or Y, then an AR sound, then V, B, F or TH, then an ISS sound:
    /// "Charvis", "Jarbis", "Javas", "Davis", "Jarthis". Looser than `isName`, so it is only trusted at the start
    /// of a sentence that turns out to be a plain request.
    static let soundsLike = try! NSRegularExpression(pattern: "^(j|ch|g|dj|d|y|sh|zh|dr|tr)(a|ar|er|ur|or|ah|aa|o|ai|ea)r?(v|b|f|ph|th|rv|w)(i|e|u|a|ee|y|ou)(s|ss|ce|z|sh|x|st)(e|es)?$")
    static func soundsLikeName(_ word: String) -> Bool {
        guard (4...8).contains(word.count), !["gives", "doves", "dives", "drives", "office", "towards", "others", "jokes", "divas", "traces", "offers", "devise", "device", "devices", "debts", "chases", "gathers", "jabs", "dabs", "tabs", "gabs", "drabs", "travis"].contains(word) else { return false }
        return looseNames.contains(word) || soundsLike.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil
    }

    /// Is this one word the name, allowing for how it gets misheard?
    /// The name is whatever the person chose. Inside the program a heard name is always written
    /// "Jarvis", the name this was first built around, so every later step has one word to look for.
    static func isName(_ word: String) -> Bool {
        let name = Me.key
        if word == name { return true }
        if let known = Profile.known[name], known.strict.contains(word) { return true }
        if name == "jarvis" { return word.hasPrefix("jarv") || word.hasPrefix("jerv") || ((5...7).contains(word.count) && oneApart(word, "jarvis")) }
        // A name of five letters or more may be one letter out, or be spelt differently but sound the same.
        // Shorter ones must be exact: too many real words sit one letter away.
        if name.count >= 5 && abs(word.count - name.count) <= 1 && word.first == name.first && oneApart(word, name) { return true }
        return Profile.known[name] == nil && word.count >= 4 && !everyday.contains(word) && sound(word) == sound(name)
    }

    static func looseName(_ word: String) -> Bool {
        if Me.key == "jarvis" { return soundsLikeName(word) }
        if let known = Profile.known[Me.key] { return known.loose.contains(word) }
        // A name of the person's own: a word that sounds one step away from it, unless it is an everyday word.
        let name = sound(Me.key), heard = sound(word)
        return word.count >= 3 && !everyday.contains(word) && heard.first == name.first && steps(heard, name) <= (name.count >= 5 ? 2 : 1)
    }

    static let everyday: Set<String> = ["the", "and", "you", "that", "was", "for", "are", "with", "his", "they", "this", "have", "from", "one", "had", "word", "but", "not", "what", "all", "were", "when",
        "your", "can", "said", "there", "use", "each", "which", "she", "how", "their", "will", "other", "about", "out", "many", "then", "them", "these", "some", "her", "would", "make", "like", "him",
        "into", "time", "has", "look", "two", "more", "write", "see", "number", "way", "could", "people", "than", "first", "water", "been", "call", "who", "now", "find", "long", "down", "day", "did",
        "get", "come", "made", "may", "part", "over", "never", "know", "just", "yes", "yeah", "okay", "well", "really", "very", "here", "going", "want", "need", "think", "right", "good", "back"]

    /// A word boiled down to how it sounds: letters that sound alike become one letter, and vowels become
    /// "a" (said at the back of the mouth) or "e" (at the front). "Nova" and "Novah" both come out as "nafa".
    static func sound(_ word: String) -> String {
        var w = word.lowercased().filter { $0.isLetter }
        for (a, b) in [("kn", "n"), ("ph", "f"), ("ck", "k"), ("sh", "j"), ("ch", "j"), ("th", "t"), ("wh", "w"), ("qu", "k"), ("gh", "")] { w = w.replacingOccurrences(of: a, with: b) }
        let classes: [Character: Character] = ["b": "p", "p": "p", "d": "t", "t": "t", "g": "k", "k": "k", "c": "k", "q": "k", "f": "f", "v": "f", "s": "s", "z": "s", "x": "s", "m": "m", "n": "n",
                                               "l": "l", "r": "r", "j": "j", "w": "w", "a": "a", "o": "a", "u": "a", "e": "e", "i": "e", "y": "e"]
        var out: [Character] = []
        for ch in w { if let c = classes[ch], c != out.last { out.append(c) } }
        return String(out)
    }

    /// How many letters must be changed, added or dropped to turn one string into the other.
    static func steps(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var last = row[0]; row[0] = i
            for j in 1...y.count { let keep = row[j]; row[j] = min(row[j] + 1, row[j - 1] + 1, last + (x[i - 1] == y[j - 1] ? 0 : 1)); last = keep }
        }
        return row[y.count]
    }

    /// The same sentence with every way of mishearing the name written as "Jarvis".
    static func tidy(_ text: String) -> String {
        var out: [String] = []
        let parts = text.split(separator: " ").map(String.init)
        let name = Me.key
        let pairs = Profile.known[name]?.pairs ?? []
        var i = 0
        while i < parts.count {
            let a = parts[i].lowercased().filter { $0.isLetter }
            let b = i + 1 < parts.count ? parts[i + 1].lowercased().filter { $0.isLetter } : ""
            let split = !b.isEmpty && (a + b == name || pairs.contains([a, b]))
            let jarvisSplit = name == "jarvis" && ["jar", "char", "jah", "jaw", "ja", "jarv", "jav", "jor", "jer"].contains(a) && ["vis", "this", "viss", "vez", "vous", "vice", "fis", "bis", "vus", "vas", "ves", "vase", "viz", "us", "ice"].contains(b)
            // "Hey" or "okay" in front of a word that merely sounds like the name settles it: nobody says "hey no" by chance.
            let called = ["hey", "ok", "okay", "hi", "yo", "hello"].contains(a) && !b.isEmpty && !isName(b) && looseName(b)
            if split || jarvisSplit || called {
                if called { out.append(parts[i]) }
                out.append("Jarvis"); i += 2
            } else if isName(a) { out.append("Jarvis"); i += 1 }
            else if a == "jarvis" { out.append("somebody"); i += 1 }          // the old name, when it is no longer the name, is just a word
            else { out.append(parts[i]); i += 1 }
        }
        return out.joined(separator: " ")
    }

    // MARK: Talking over it
    //
    // The microphone hears the assistant's own voice, which drowns out anyone speaking at the
    // same time. So the loudness of the microphone is watched while it talks: its own voice
    // arrives at a steady strength, and a clear jump above that means somebody else has started.
    // The voice then drops right down for a moment so they can be heard. If the name or "stop"
    // follows, it stops; if not, it carries on at full strength.
    private var ownPeak = 0.0         // how loud its own voice usually arrives at the microphone
    private var thisPeak = 0.0        // the loudest moment of the sentence being spoken now
    private var speechStart = 0.0
    private var wasSpeaking = false
    private var overCount = 0
    private var overLevel = 0.0
    var overUntil = 0.0               // until when someone seems to be talking over it
    private var fruitless = 0         // times in this sentence the voice dropped for nothing

    static let bargeByLevel = ((try? String(contentsOf: baseDir.appendingPathComponent("barge.txt"), encoding: .utf8)) ?? "").hasPrefix("1")

    func level(_ v: Double, engine: Engine) {
        guard Ears.bargeByLevel || Opt.fast else { return }
        lock.lock(); defer { lock.unlock() }
        let t = now()
        let speaking = engine.lastSpokenAt > t
        if speaking != wasSpeaking {
            wasSpeaking = speaking
            if speaking { speechStart = t; thisPeak = 0; overCount = 0; fruitless = 0 }
            else {
                if thisPeak > 0 { ownPeak = ownPeak == 0 ? thisPeak : ownPeak * 0.7 + thisPeak * 0.3 }
                if overUntil > 0 { overUntil = 0; Kokoro.shared.duck(false) }
            }
        }
        guard speaking else { return }
        if overUntil > 0 {
            if t > overUntil {
                // Nothing came of it: carry on, and remember that this loudness is nothing special.
                overUntil = 0
                fruitless += 1
                ownPeak = max(ownPeak, overLevel)
                Kokoro.shared.duck(false)
                log("carried on speaking")
            }
            return
        }
        let learning = t - speechStart < 0.7
        // Nothing is turned down until one whole sentence has shown how loud its own voice arrives.
        let reference = max(ownPeak, thisPeak * 0.8)
        if !learning, ownPeak > 0, fruitless < 2, reference > 0.004, v > reference * 1.45 {
            overCount += 1
            overLevel = max(overLevel, v)
            if overCount >= 2 {
                overCount = 0
                overUntil = t + 2.2
                Kokoro.shared.duck(true)
                log("someone is talking over me: voice turned down to listen")
            }
        } else {
            overCount = 0
            overLevel = 0
            thisPeak = max(thisPeak, v)
        }
    }

    func log(_ text: String) {
        if Opt.fast { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(text)\n"
        if let h = try? FileHandle(forWritingTo: Ears.logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: Ears.logURL, atomically: true, encoding: .utf8) }
    }

    // Words a sentence cannot end on: if one is the last word heard, the speaker has not finished.
    static let dangling: Set<String> = ["open", "play", "the", "a", "an", "to", "for", "me", "my", "set", "add", "make", "turn", "and", "at", "on", "with", "of", "in", "put",
                                        "start", "launch", "search", "find", "what", "whats", "how", "can", "could", "you", "is", "it", "some", "that", "this", "teach", "save",
                                        "as", "call", "name", "rename", "tell", "give", "show", "go", "lets", "i", "im", "want", "need", "please", "hey", "about", "from", "by",
                                        "called", "named", "lesson", "track", "minus", "plus", "something", "like", "into", "up", "down", "little", "bit", "more", "less", "which", "should"]
    static let whole: Set<String> = ["stop", "home", "help", "again", "next", "back", "slower", "faster", "record", "undo", "redo", "pause", "yes", "no", "louder", "quieter",
                                     "jazz", "metronome", "quiet", "cancel", "continue", "repeat", "goodbye", "thanks", "enough", "yeah", "yep", "nope", "sure", "okay", "ok", "resume"]

    static let quick: Set<String> = ["stop", "home", "again", "next", "go back", "new composition", "play it back", "keep that", "save that", "what did i just play",
                                     "play my album", "jam with me", "surprise me", "ear training", "slower", "faster", "band louder", "band quieter", "undo", "undo that",
                                     "start recording", "stop recording", "say the notes", "yes", "no", "thank you", "thanks", "tell me a joke", "song menu", "pause", "continue"]

    /// How long to wait for more words before acting. Short when the request sounds finished,
    /// long when it plainly is not ("open...", "set the..."), so nobody is cut off mid-sentence.
    static func wait(for request: String, final: Bool, pause: Double) -> Double {
        let w = words(request)
        guard let last = w.last else { return 0.35 }                      // just the name
        let unfinished = (dangling.contains(last) && !(w.count == 1 && whole.contains(last))) || (w.count == 1 && !whole.contains(last))
        if unfinished { return final ? 0.9 : 1.5 }
        // Short commands that are plainly complete are acted on almost at once.
        if quick.contains(w.joined(separator: " ")) { return final ? 0.02 : 0.22 }
        // "Play smooth..." is rarely the whole thought: titles and searches run to several words,
        // so a short one that names no place to play it is given longer before it is acted on.
        let opener = ["play", "find", "search", "look", "watch", "put", "teach", "google", "listen"].contains(w[0])
        let placed = w.contains("spotify") || w.contains("youtube") || w.contains("band") || w.contains("back") || w.contains("album")
        if opener, w.count <= 3, !placed { return final ? 0.5 : 1.1 }
        return final ? 0.02 : max(0.25, min(2.5, pause))
    }

    func nameHeardForTest(at i: Int) { lock.lock(); nameAt = i; nameSeen = now(); lock.unlock() }
    func speechStartForTest(_ t: Double) { lock.lock(); speechStart = t; lock.unlock() }

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// The assistant has just finished speaking: the wait for a request starts now.
    func voiceFinished() {
        lock.lock(); defer { lock.unlock() }
        settleCredits(within: 3)
        if awaiting {
            openUntil = now() + 8
            // Anything said while it was answering is looked at as soon as its own echo has died away.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.65) { [weak self] in
                guard let self = self, let engine = self.lastEngine else { return }
                self.lock.lock(); let text = self.lastText, pending = self.awaiting && text != self.handled; self.lock.unlock()
                if pending { self.partial(text, final: false, engine: engine) }
            }
        }
        // For a few seconds after it speaks, a reply can follow without the name, as in conversation.
        // (Switch this off by putting 0 in follow-up.txt.)
        let wanted = (try? String(contentsOf: baseDir.appendingPathComponent("follow-up.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
        casualUntil = wanted ? now() + 6 : 0
    }

    /// The assistant has just asked a question ("Which one?", "Shall I go ahead?"), so the
    /// answer does not need the name in front of it.
    func expectAnswer() {
        lock.lock(); defer { lock.unlock() }
        settleCredits(within: 3)
        awaiting = true
        openByName = false
        openUntil = now() + 12
    }

    /// One update of the running transcript. Returns what was decided, for the tests.
    @discardableResult
    func partial(_ given: String, final: Bool, engine: Engine) -> String {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        // The recogniser sometimes ends one stretch of listening in the middle of the name and starts the
        // next with the rest ("Ja", then "rvis"). The two halves are put back together.
        var text = given
        if stretchStart, t - splitAt < 4, !splitTail.isEmpty, let first = given.split(separator: " ").first {
            let joined = (splitTail + first).lowercased().filter { $0.isLetter }
            if !Ears.isName(splitTail.lowercased().filter { $0.isLetter }), Ears.isName(joined) { joining = true }
        }
        if joining, let first = given.split(separator: " ").first { text = Me.name + given.dropFirst(first.count) }
        stretchStart = final
        if final {
            splitTail = given.split(separator: " ").last.map(String.init) ?? ""
            splitAt = t
            joining = false
        }
        let speaking = engine.lastSpokenAt > t
        let quietFor = t - engine.lastSpokenAt
        lastText = text; lastEngine = engine
        if engine.naming { handled = text; return "busy" }
        // The recogniser sometimes starts its text over; then nothing of it has been handled yet.
        var fresh = (text.hasPrefix(handled) ? String(text.dropFirst(handled.count)) : text).trimmingCharacters(in: .whitespaces)
        fresh = Ears.tidy(fresh)
        let own = Ears.words(Ears.tidy(engine.lastSpoken))
        let mine = Set(own)
        var interrupted = false
        // Whose "Jarvis" is it? Every time the assistant says its own name it notes that the microphone
        // may hand that name back. A name in the transcript is first set against those notes; only a
        // name left over after that was said by a person. This is counted over the whole stretch of
        // transcript still to be dealt with, so the recogniser rewriting its text cannot count a name twice.
        // Each name in the recogniser's whole text is given an owner once, in order, and keeps it while the
        // text is rewritten. Names taken back by a rewrite give their note back.
        credits.removeAll { $0 < t }
        if sessionOver {
            // A new stretch of listening: anything of its own still owed may yet arrive, but only briefly.
            credits += Array(repeating: speaking ? Double.infinity : t + 2, count: owners.filter { $0 }.count)
            owners = []; sessionOver = false
        }
        let allNames = Ears.words(Ears.tidy(text)).filter { $0 == "jarvis" }.count
        while owners.count > allNames {
            if owners.removeLast() { credits.insert(speaking ? Double.infinity : t + 3, at: 0) }
        }
        while owners.count < allNames {
            if !credits.isEmpty { credits.removeFirst(); owners.append(true) } else { owners.append(false) }
        }
        if final { sessionOver = true }
        // Only the names in the part not yet dealt with matter now.
        let before = text.hasPrefix(handled) && !handled.isEmpty ? Ears.words(Ears.tidy(handled)).filter { $0 == "jarvis" }.count : 0
        let namesNow = Ears.words(fresh).filter { $0 == "jarvis" }.count
        nameIsReal = owners.dropFirst(min(before, owners.count)).contains(false)
        // A name that was only its own voice coming back is taken out, so nothing below mistakes it for a call.
        if namesNow > 0, !nameIsReal { fresh = fresh.split(separator: " ").filter { Ears.words(String($0)).first != "jarvis" }.joined(separator: " ") }
        if speaking || quietFor < 0.6 {
            // While it is talking, the microphone mostly hears its own voice. But the name, or
            // "stop", cuts in: unless it is saying that very word itself.
            let heardNow = Ears.words(fresh)
            // If it is saying the name or "stop" itself, the word only counts when it is heard more
            // often than it was said, or while somebody is plainly talking over it.
            func more(_ w: String) -> Bool { heardNow.filter { $0 == w }.count > own.filter { $0 == w }.count }
            let name = heardNow.contains("jarvis") && nameIsReal
            let halt = ["stop", "quiet", "enough", "cancel", "silence", "shush"].contains { heardNow.contains($0) && (!mine.contains($0) || more($0)) }
            guard name || halt else {
                // During its short "Yes, sir?" the request has often already begun. Those words are
                // kept and looked at again the moment it stops, not thrown away.
                if !(awaiting && own.count <= 6) { handled = text }
                return "busy"
            }
            interrupted = true
            overUntil = 0
            engine.interrupt()
            log("interrupted while speaking")
            // Keep only the words that were not its own.
            if !name { fresh = "jarvis stop" }
            else {
                let lowerAll = fresh.lowercased()
                var cut = lowerAll.startIndex
                for w in Ears.wakeWords { if let r = lowerAll.range(of: w, options: .backwards), r.lowerBound >= cut { cut = r.lowerBound } }
                let after = Ears.words(String(lowerAll[cut...])).dropFirst().filter { !mine.contains($0) || Ears.urgent.contains($0) }
                fresh = "jarvis " + after.joined(separator: " ")
            }
        }
        // After a bare "Jarvis", its own reply may be at the front of what was heard. Take it off.
        if !interrupted, t < openUntil, quietFor < 8 {
            var w = fresh.split(separator: " ").map(String.init)
            var left = own
            while let f = w.first, let i = left.firstIndex(of: Ears.words(f).first ?? "") { w.removeFirst(); left.remove(at: i) }
            fresh = w.joined(separator: " ")
        }
        guard !fresh.isEmpty else { return "nothing new" }
        var said = Ears.words(fresh)
        // The recogniser wrote the name a moment ago and has now rewritten it as something else.
        // The first hearing stands.
        if !said.contains("jarvis"), nameAt >= 0, t - nameSeen < 5, said.count > nameAt, t >= openUntil {
            var w = fresh.split(separator: " ").map(String.init)
            if w.count == said.count { w[nameAt] = "Jarvis"; fresh = w.joined(separator: " "); said = Ears.words(fresh) }
        }
        if let at = said.firstIndex(of: "jarvis") { if nameAt < 0 || t - nameSeen > 5 { nameAt = at }; nameSeen = t }
        let lower = fresh.lowercased()
        // Its own words, arriving late.
        // That includes the end of a sentence in which it said its own name ("say Jarvis, stop, to end it"),
        // which must not be taken as someone calling it and telling it to stop.
        let ownTail = quietFor < 2.2 && said.count >= 2 && own.count >= said.count && Array(own.suffix(said.count)) == said
        if !interrupted, quietFor < 5, said.allSatisfy({ mine.contains($0) }), ownTail || !said.contains(where: { Ears.wakeWords.contains($0) || Ears.urgent.contains($0) }) {
            handled = text
            log("ignored my own voice")
            return "echo"
        }
        var request: String? = nil
        var casual = false
        var casualFromHey = false
        var guessedByName = false
        var best: Range<String.Index>? = nil
        for w in Ears.wakeWords {
            if let r = lower.range(of: w, options: .backwards), best == nil || r.lowerBound > best!.lowerBound || (r.lowerBound == best!.lowerBound && r.upperBound > best!.upperBound) { best = r }
        }
        if let r = best {
            request = String(fresh[fresh.index(fresh.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.upperBound))...])
            // The name at the end, as people often put it: "open Spotify, Jarvis".
            let before = String(fresh[..<fresh.index(fresh.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))])
            if Ears.words(request ?? "").isEmpty, (2...9).contains(Ears.words(before).filter({ $0 != "hey" }).count) { request = before }
        } else if t < openUntil {
            request = fresh
            // Called by name a moment ago: anything goes. Waiting for an answer to its own question: only plain requests and answers.
            if !openByName { casual = true }
        } else if t < casualUntil, said.count <= 9 {
            request = fresh
            casual = true
        } else if let first = said.first(where: { $0 != "hey" && $0 != "ok" && $0 != "okay" }), Ears.looseName(first), said.count >= 2, said.count <= 12,
                  let at = said.firstIndex(of: first), at <= 1 {
            // Possibly the name, misheard. Taken only if the rest turns out to be a plain request.
            request = said[(at + 1)...].joined(separator: " ")
            casual = true
            guessedByName = true
        }
        // One word on its own that sounds like the name is the name: a single word after silence is
        // the hardest thing for the recogniser to get right. If more words follow and they are
        // ordinary talk, the next update cancels this before anything is said.
        var lone = false
        if request == nil {
            let core = said.filter { !["hey", "ok", "okay", "hi", "yo"].contains($0) }
            let unsure = core.count == 1 && (Profile.uncertainAlone[Me.key]?.contains(core[0]) ?? false)
            // A word on its own is only the name if it is one of the name's own measured mishearings and is
            // not also an everyday word. "No" is never the name: answering it made Nova wake to ordinary talk.
            let everydayWord = Ears.everyday.contains(core.first ?? "") || ["no", "know", "now", "nope", "hello", "next", "call", "mail", "memory", "minutes", "area", "lower", "over"].contains(core.first ?? "")
            if core.count == 1, said.count <= 2, Ears.looseName(core[0]), !unsure, !everydayWord { request = ""; lone = true }
        }
        if casualFromHey { casual = true }
        guard let found = request else {
            nameAt = -1
            if said.count >= 2 { lastChatter = t }
            token += 1          // whatever was waiting belonged to a sentence that has turned out to be ordinary talk
            if said.count <= 2, t - lastMiss > 3 { lastMiss = t; log("a word or two went by that did not sound like my name") }
            return "not for me"
        }
        // The name was only guessed at (a sound-alike word, a bare "hey", or the quiet listening after a
        // possible name). Then the request has to be an unmistakable one.
        let guessed = casual && (casualFromHey || guessedByName || t < softUntil)
        var outcome = "acted"
        token += 1
        let mine2 = token
        let pause = (try? String(contentsOf: baseDir.appendingPathComponent("voice-pause.txt"), encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0.45
        let wait = lone ? (final ? 0.25 : 0.7) : Ears.wait(for: found, final: final, pause: pause)
        let act = { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard mine2 == self.token else { self.lock.unlock(); return }
            let clean = found.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
            self.awaiting = clean.isEmpty
            self.openByName = clean.isEmpty
            self.openUntil = clean.isEmpty ? now() + 10 : 0
            self.handled = text
            self.nameAt = -1
            self.lock.unlock()
            self.log("acting on: \(clean.isEmpty ? "(just the name)" : clean)")
            ui("earreset")
            // A tiny tick the instant a request is taken, so there is never a silent wait.
            if casual {
                // Only plain requests count here; ordinary talk in the room is let go without a sound.
                engine.lock.lock()
                engine.casualHearing = true
                engine.guessedName = guessed
                let got = clean.isEmpty ? "ignored" : engine.hear(clean)
                engine.casualHearing = false
                engine.guessedName = false
                engine.lock.unlock()
                if got == "ignored" { self.log("let a remark go by"); outcome = "ignored" }
                return
            }
            if !clean.isEmpty, Engine.effects { engine.chime([96], vel: 30, hold: 0.06) }
            engine.hear(clean)
        }
        if Opt.fast { lock.unlock(); act(); lock.lock(); return outcome }
        // Act once the speaker has been quiet for a moment, or at once if the recogniser says the sentence is over.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait, execute: act)
        return "waiting"
    }
}

func earsSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let ears = Ears()
    engine.goHomeQuietly()
    engine.lastSpoken = "Welcome back. Your last piece was in C major, saved earlier today."
    engine.lastSpokenAt = now() - 1
    // The exact sequence from the player's log: the greeting is overheard, then the text starts over with "Jarvis".
    let a = ears.partial("Earlier today", final: false, engine: engine)
    let b = ears.partial("Earlier", final: false, engine: engine)
    engine.lastSpokenAt = now() - 30
    let c = ears.partial("Jarvis", final: true, engine: engine)
    check("ears: its own greeting is ignored, and Jarvis is still heard when the recogniser starts its text over", a == "echo" && b == "echo" && c == "acted" && ears.awaiting, "\(a), \(b), \(c)")
    engine.lastSpokenAt = now() - 30
    engine.lastSpoken = "Yes, sir?"
    let d = ears.partial("Jarvis open composition mode", final: true, engine: engine)
    check("ears: after a bare Jarvis, the next words are taken as the request", d == "acted" && engine.mode == .compose && !ears.awaiting, d)
    engine.goHomeQuietly()
    engine.lastSpokenAt = now() - 30
    let e = ears.partial("Jarvis open composition mode can you open reaper", final: true, engine: engine)
    check("ears: talk without the name is left alone", e == "not for me", e)
    engine.lastSpoken = "Say Jarvis stop, or press home, to end it."
    engine.lastSpokenAt = now() - 1
    let f = ears.partial("Jarvis open composition mode can you open reaper Jarvis stop", final: true, engine: engine)
    check("ears: stop is obeyed even right after the assistant said the word itself", f == "acted", f)
    // Interrupting: it is in the middle of a long answer, and the name is said over it.
    engine.goHomeQuietly()
    let ears2 = Ears()
    engine.lastSpoken = "I am here and ready to help, but I am not quite sure what you are opening."
    engine.lastSpokenAt = now() + 30
    let g1 = ears2.partial("I am here and ready to", final: false, engine: engine)
    let g2 = ears2.partial("I am here and ready to help Jarvis new composition", final: true, engine: engine)
    check("ears: saying Jarvis over its voice interrupts it and the request is still taken", g1 == "busy" && g2 == "acted" && engine.mode == .compose && engine.lastSpokenAt <= now(), "\(g1), \(g2)")
    engine.goHomeQuietly()
    // Misheard names, and a word that only sounds like the name.
    engine.lastSpokenAt = now() - 30
    engine.lastSpoken = ""
    let m1 = Ears().partial("Jar vis new composition", final: true, engine: engine)
    let m1ok = engine.mode == .compose
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let m2 = Ears().partial("Hey Jarvus, new composition", final: true, engine: engine)
    let m2ok = engine.mode == .compose
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let m3 = Ears().partial("service new composition", final: true, engine: engine)
    let m3ok = engine.mode == .compose
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let m4 = Ears().partial("the service at that restaurant was terrible", final: true, engine: engine)
    let m5 = Ears().partial("service was really slow today", final: true, engine: engine)
    check("ears: the name is caught when it is misheard, and a word that only sounds like it does not set it off", m1 == "acted" && m1ok && m2 == "acted" && m2ok && m3ok && m4 == "not for me" && engine.mode != .compose,
          "\(m1) \(m1ok), \(m2) \(m2ok), \(m3) \(m3ok), \(m4), \(m5), \(engine.mode)")
    engine.goHomeQuietly()
    // The recogniser first writes "Jarvis", then changes its mind. The first hearing stands.
    engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let ears4 = Ears()
    ears4.nameHeardForTest(at: 3)      // as if "we were talking Jarvis" had just gone by
    let s0 = "", s1 = ""
    let s2 = ears4.partial("we were talking drivers new composition", final: true, engine: engine)
    let s2ok = engine.mode == .compose
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let p1 = Ears().partial("Charvis new composition", final: true, engine: engine)
    let p1ok = engine.mode == .compose
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let p2 = Ears().partial("Davis gives me a lift to school", final: true, engine: engine)
    check("ears: a name the recogniser rewrites is still caught, sound-alikes work for a real request and not for ordinary talk", s2 == "acted" && s2ok && p1ok && engine.mode != .compose && Ears.soundsLikeName("jarbis") && !Ears.soundsLikeName("service".replacingOccurrences(of: "service", with: "serve")) && !Ears.soundsLikeName("drives"),
          "\(s0) \(s1) \(s2) \(s2ok), \(p1) \(p1ok), \(p2) \(engine.mode)")
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let ears6 = Ears()
    let l1 = ears6.partial("Jarbis", final: true, engine: engine)
    let l1ok = ears6.awaiting
    engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let l2 = Ears().partial("Thursday", final: true, engine: engine)
    check("ears: one word on its own that sounds like the name is answered, and any other single word is not", l1 == "acted" && l1ok && l2 == "not for me", "\(l1) \(l1ok) \(l2)")
    engine.goHomeQuietly()
    // It says its own name in a sentence: neither hearing that during the sentence, nor its tail just after, sets it off.
    let ears7 = Ears()
    engine.lastSpoken = "Say Jarvis stop, or press home, to end it. Say Jarvis stop"
    ears7.spoke(engine.lastSpoken)
    engine.lastSpokenAt = now() + 30
    let self1 = ears7.partial("say Jarvis", final: false, engine: engine)
    let self1b = ears7.partial("say Jarvis stop or", final: false, engine: engine)      // the same name again as the text grows: still its own
    let self1c = ears7.partial("say Jarvis", final: false, engine: engine)              // and when the recogniser takes words back
    let talking = engine.lastSpokenAt > now()
    engine.lastSpokenAt = now() - 1
    let self2a = ears7.partial("say Jarvis stop or press home to end it say Jarvis stop", final: true, engine: engine)
    let still = engine.lastSpokenAt
    ears7.lapseCreditsForTest()
    engine.lastSpokenAt = now() - 4
    let self3 = ears7.partial("say Jarvis stop or press home to end it say Jarvis stop Jarvis stop", final: true, engine: engine)
    check("ears: its own voice saying Jarvis never sets it off, yet Jarvis stop from a person still works a moment later", self1 == "busy" && self1b == "busy" && self1c == "busy" && talking && self2a != "acted" && still <= now() && self3 == "acted", "\(self1) \(self1b) \(self1c) \(talking) \(self2a) \(self3)")
    engine.goHomeQuietly()
    // The case from the log: the wake word is Jarvis, it introduces itself by name, and a person then calls it over that.
    let ears8 = Ears()
    engine.lastSpoken = "I'm Jarvis. Say Jarvis, then what you need."
    ears8.spoke(engine.lastSpoken)
    engine.lastSpokenAt = now() + 30
    let w1 = ears8.partial("I'm Jarvis", final: false, engine: engine)
    let w2 = ears8.partial("I'm Jarvis say Jarvis", final: false, engine: engine)
    let w3 = ears8.partial("I'm Jarvis say Jarvis then what you", final: false, engine: engine)
    let unbroken = engine.lastSpokenAt > now()
    let w4 = ears8.partial("I'm Jarvis say Jarvis then what you Jarvis new composition", final: true, engine: engine)
    check("ears: introducing itself by name does not wake it, and a third Jarvis from a person does", w1 == "busy" && w2 == "busy" && w3 == "busy" && unbroken && w4 == "acted" && engine.mode == .compose, "\(w1) \(w2) \(w3) \(unbroken) \(w4) \(engine.mode)")
    engine.goHomeQuietly()
    // Starting the request while it is still saying "Yes, sir?": the words are kept.
    let ears5 = Ears()
    engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    _ = ears5.partial("Jarvis", final: false, engine: engine)
    engine.lastSpoken = "Yes, sir?"; engine.lastSpokenAt = now() + 30
    let k1 = ears5.partial("Jarvis yes sir new", final: false, engine: engine)
    engine.lastSpokenAt = now() - 1
    ears5.openUntil = now() + 8; ears5.openByName = true
    let k2 = ears5.partial("Jarvis yes sir new composition", final: true, engine: engine)
    check("ears: a request begun while it is still answering the name is not lost", k1 == "busy" && k2 == "acted" && engine.mode == .compose, "\(k1) \(k2) \(engine.mode)")
    engine.goHomeQuietly()
    // Talking over it: its own voice arrives at a steady level, then someone much louder starts.
    let ears3 = Ears()
    engine.lastSpoken = "Say Jarvis and tell me what you would like, any time."
    engine.lastSpokenAt = now() - 30
    ears3.level(0.003, engine: engine)
    engine.lastSpokenAt = now() + 30
    for _ in 0..<3 { ears3.level(0.02, engine: engine) }
    engine.lastSpokenAt = now() - 30
    ears3.level(0.003, engine: engine)          // one whole sentence has gone by: its own loudness is known
    engine.lastSpokenAt = now() + 30
    ears3.level(0.02, engine: engine)
    ears3.speechStartForTest(now() - 2)
    for _ in 0..<5 { ears3.level(0.021, engine: engine) }
    let calm = ears3.overUntil == 0
    ears3.level(0.06, engine: engine); ears3.level(0.07, engine: engine)
    let ducked = ears3.overUntil > now()
    // It is saying "Jarvis" itself in this sentence, yet the name said over it still counts now.
    let o1 = ears3.partial("and tell me what Jarvis stop", final: true, engine: engine)
    check("ears: someone talking over it is noticed from the loudness, and can then stop it even mid-sentence", calm && ducked && o1 == "acted" && engine.lastSpokenAt <= now(), "\(calm) \(ducked) \(o1)")
    Kokoro.shared.duck(false)
    engine.goHomeQuietly()
    let waits = [Ears.wait(for: "open", final: false, pause: 0.45), Ears.wait(for: "open spotify", final: false, pause: 0.45), Ears.wait(for: "set the", final: true, pause: 0.45), Ears.wait(for: "stop", final: false, pause: 0.45), Ears.wait(for: "", final: false, pause: 0.45)]
    engine.lastSpokenAt = now() - 30
    engine.lastSpoken = ""
    let tail = Ears().partial("open composition mode Jarvis", final: true, engine: engine)
    check("ears: the name can come at the end of the sentence", tail == "acted" && engine.mode == .compose, tail)
    engine.goHomeQuietly()
    check("ears: an unfinished sentence is waited for, a finished one is acted on quickly", waits == [1.5, 0.45, 0.9, 0.22, 0.35] && Ears.wait(for: "play smooth", final: false, pause: 0.45) == 1.1 && Ears.wait(for: "play smooth jazz on youtube", final: false, pause: 0.45) == 0.45, waits.map { String($0) }.joined(separator: ", "))
    engine.goHomeQuietly()
}

/// Its own sentences, as the Mac's recogniser actually wrote them down from recordings of its natural voice,
/// with a wake word a friend chose (Houstin). Fed in word by word, as the recogniser reports them, with the
/// text taken back and rewritten now and then, and once more after it stops: none may wake it or cut it off.
func ownVoiceReplayTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let kept = Profile.current
    defer { Profile.current = kept }
    Profile.current.assistant = "Houstin"
    let heard: [(said: String, wrote: String)] = [
        ("All set, Sam. I'm Houstin. Whenever you need me, say Houstin, then what you'd like. Try: Houstin, what can you do?", "All set Sam I'm Houstin whenever you need me say Houston than what you'd like try Houstin what can you do"),
        ("All set, Sam. I'm Houstin. Whenever you need me, say Houstin, then what you'd like. Try: Houstin, what can you do?", "All set Sam I'm Houstin whenever you need me say Houston and then what you'd like try Houstin and what can you do"),
        ("All set, Sam. I'm Houstin. Whenever you need me, say Houstin, then what you'd like. Try: Houstin, what can you do?", "All set Sam I'm Houstin whenever you need me say Houstin then what you'd like try Houstin what can you do"),
        ("From now on, call me Houstin.", "From now on call me Houstin"),
        ("From now on, call me Houstin.", "From now on call me Houstin"),
        ("From now on, call me Houstin.", "From now on call me Houstin"),
        ("I'm Houstin. Say Houstin, then what you'd like.", "I'm Houstin say Houstin then what you'd like"),
        ("I'm Houstin. Say Houstin, then what you'd like.", "I'm Houstin say Houstin than what you'd like"),
        ("I'm Houstin. Say Houstin, then what you'd like.", "I'm Houstin say Houstin then what you'd like"),
        ("Change my name from Nova to Houstin? Say yes or no.", "Change my name from nova to Houstin say yes or no"),
        ("Change my name from Nova to Houstin? Say yes or no.", "Change my name from nova to Houstin say yes or no"),
        ("Change my name from Nova to Houstin? Say yes or no.", "Change my name from nova to Houstin say yes or no"),
        ("Done. From now on, call me Houstin. Nova won't work any more.", "Done from now on call me Houstin nova won't work anymore"),
        ("Done. From now on, call me Houstin. Nova won't work any more.", "Done from now on call me Houstin nova won't work anymore"),
        ("Done. From now on, call me Houstin. Nova won't work any more.", "Done from now on call me Houstin nova won't work anymore"),
        ("All set, Sam. I'm Houston. Whenever you need me, say Houston, then what you'd like. Try: Houston, what can you do?", "All set Sam I'm Houstin whenever you need me say Houstin then what you'd like try Houstin what can you do"),
        ("All set, Sam. I'm Houston. Whenever you need me, say Houston, then what you'd like. Try: Houston, what can you do?", "All set Sam I'm Houstin whenever you need me say Houstin then what you'd like try Houstin what can you do"),
        ("All set, Sam. I'm Houston. Whenever you need me, say Houston, then what you'd like. Try: Houston, what can you do?", "All set Sam I'm Houstin whenever you need me say Houstin then what you'd like try Houstin what can you do"),
        ("From now on, call me Houston.", "From now on call me Houstin"),
        ("From now on, call me Houston.", "From now on call me Houstin"),
        ("From now on, call me Houston.", "From now on call me Houstin"),
        ("I'm Houston. Say Houston, then what you'd like.", "I'm Houstin say Houstin than what you'd like"),
        ("I'm Houston. Say Houston, then what you'd like.", "I'm Houstin say Houstin then what you'd like"),
        ("I'm Houston. Say Houston, then what you'd like.", "I'm Houstin say Houstin then what you'd like"),
        ("Change my name from Nova to Houston? Say yes or no.", "Change my name from nova to Houstin say yes or no"),
        ("Change my name from Nova to Houston? Say yes or no.", "Change my name from nova to Houstin say yes or no"),
        ("Change my name from Nova to Houston? Say yes or no.", "Change my name from nova to Houstin say yes or no"),
        ("Done. From now on, call me Houston. Nova won't work any more.", "Done from now on call me Houstin nova won't work anymore"),
        ("Done. From now on, call me Houston. Nova won't work any more.", "Done from now on call me Houstin nova won't work anymore"),
        ("Done. From now on, call me Houston. Nova won't work any more.", "Done from now on call me Houstin nova won't work anymore")]
    var bad: [String] = []
    for (said, wrote) in heard {
        engine.goHomeQuietly()
        let ears = Ears()
        engine.lastSpoken = said
        ears.spoke(said)
        engine.lastSpokenAt = now() + 30
        let w = wrote.split(separator: " ").map(String.init)
        var got: [String] = []
        for n in 1...w.count {
            got.append(ears.partial(w.prefix(n).joined(separator: " "), final: false, engine: engine))
            if n % 4 == 0, n > 1 { got.append(ears.partial(w.prefix(n - 1).joined(separator: " "), final: false, engine: engine)) }   // taken back
        }
        let cut = engine.lastSpokenAt <= now()
        engine.lastSpokenAt = now()
        ears.voiceFinished()
        got.append(ears.partial(wrote, final: true, engine: engine))
        // The recogniser starting afresh with only the end of the sentence.
        got.append(ears.partial(w.suffix(5).joined(separator: " "), final: true, engine: engine))
        if got.contains("acted") || cut { bad.append("\(wrote) -> \(got.joined(separator: ","))\(cut ? " (cut off)" : "")") }
    }
    engine.goHomeQuietly()
    // And a person saying the name straight after it has finished speaking is still answered.
    let ears = Ears()
    engine.lastSpoken = heard[0].said
    ears.spoke(heard[0].said)
    engine.lastSpokenAt = now() + 30
    _ = ears.partial(heard[0].wrote, final: false, engine: engine)
    engine.lastSpokenAt = now() - 1
    ears.voiceFinished()
    ears.lapseCreditsForTest()
    let person = ears.partial(heard[0].wrote + " Houston what's the weather", final: true, engine: engine)
    check("ears: its own recorded sentences with a custom name never wake it, and a person right after still does", bad.isEmpty && person == "acted", bad.prefix(3).joined(separator: " | ") + " person: " + person)
    engine.goHomeQuietly()
}

func splitNameSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    // From a real log: "Ja" ended one stretch of listening and "rvis" began the next.
    engine.goHomeQuietly(); engine.lastSpoken = ""; engine.lastSpokenAt = now() - 30
    let ears = Ears()
    let a = ears.partial("Ja", final: true, engine: engine)
    let b = ears.partial("rvis", final: false, engine: engine)
    usleep(300_000); engine.lastSpoken = "Yes?"; engine.lastSpokenAt = now() - 30
    let c = ears.partial("rvis new composition", final: true, engine: engine)
    let ok = engine.mode == .compose
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30
    let d = Ears().partial("rvis new composition", final: true, engine: engine)
    check("ears: the name split across two stretches of listening (Ja, then rvis) is still heard; \"rvis\" alone is not", ok && a != "acted" && b == "acted" && c == "acted" && d != "acted" && engine.mode != .compose, "\(a) \(b) \(c) \(ok) \(d)")
    engine.goHomeQuietly()
}
