// The brain: understands a plain sentence, spoken after "the assistant" or typed, and does it.
//
// Following the usual design for a voice assistant, the common requests are matched here
// by meaning, on the Mac, with no delay and no network. Anything this does not recognise
// is handed to the AI, along with a description of what is going on. Also here: the things
// that are not about lessons or composing at all, such as the metronome, timers, the ear
// training game and the settings that adapt the tool to different abilities.

import Foundation

// Which hands lessons teach: "both", "right" or "left". For anyone who plays with one hand.
let handsURL = baseDir.appendingPathComponent("hands.txt")
var handsOnly: String = ((try? String(contentsOf: handsURL, encoding: .utf8)) ?? "both").trimmingCharacters(in: .whitespacesAndNewlines)

let numberWords: [String: Int] = ["one": 1, "two": 2, "to": 2, "three": 3, "four": 4, "for": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                                  "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "seventy": 70, "eighty": 80, "hundred": 100, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90, "half": 30,
                                  "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "a": 1, "an": 1]

// Long words the assistant listens for. A word one letter away from one of these is read as it.
let knownWords: Set<String> = ["composition", "compose", "metronome", "lullaby", "variation", "reaper", "volume", "quieter", "louder", "slower", "faster", "lesson", "training",
                               "surprise", "record", "recording", "compressor", "compression", "reverb", "threshold", "preset", "plugin", "plugins", "duplicate", "rename",
                               "delete", "remove", "bypass", "master", "album", "improvise", "captions", "contrast", "listening", "previous", "repeat", "another", "timer",
                               "minutes", "seconds", "tracks", "spotify", "chrome", "youtube", "settings", "search", "launch", "equalizer", "limiter", "selected", "describe"]

func oneApart(_ a: String, _ b: String) -> Bool {
    let x = Array(a), y = Array(b)
    if x.count == y.count { return zip(x, y).filter { $0 != $1 }.count == 1 }
    let (short, long) = x.count < y.count ? (x, y) : (y, x)
    var i = 0, j = 0, skipped = false
    while i < short.count, j < long.count {
        if short[i] == long[j] { i += 1; j += 1 } else if skipped { return false } else { skipped = true; j += 1 }
    }
    return true
}

struct Heard {
    let text: String          // lower case, no punctuation
    let words: [String]
    let near: Set<String>     // known words that a slightly wrong word was probably meant to be
    init(_ raw: String) {
        var t = raw.lowercased()
        for ch in [",", ".", "?", "!", ";", ":", "\""] { t = t.replacingOccurrences(of: ch, with: " ") }
        t = " " + t.replacingOccurrences(of: "  ", with: " ") + " "
        for (wrong, right) in mishearings { t = t.replacingOccurrences(of: " " + wrong + " ", with: " " + right + " ") }
        for (said, plain) in sayings { t = t.replacingOccurrences(of: " " + said + " ", with: " " + plain + " ") }
        t = t.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        var w = t.split(separator: " ").map(String.init)
        // Drop the wake word and politeness, wherever recognition put them.
        while let f = w.first, ["hey", "hi", "ok", "okay", "jarvis", "jarvis's", "please", "now", "um", "uh"].contains(f) { w.removeFirst() }
        for lead in [["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["i", "want", "to"], ["i", "want", "you", "to"], ["id", "like", "to"], ["lets"], ["let", "us"]] where Array(w.prefix(lead.count)) == lead {
            w.removeFirst(lead.count)
        }
        while let l = w.last, ["please", "jarvis", "thanks"].contains(l) { w.removeLast() }
        words = w
        text = w.joined(separator: " ")
        // Long words that are one letter off a word the assistant knows count as that word,
        // so a slip of the recogniser or of the fingers does not lose the request.
        var close = Set<String>()
        for x in w where x.count >= 6 && !knownWords.contains(x) {
            for k in knownWords where abs(k.count - x.count) <= 1 && k.first == x.first && oneApart(x, k) { close.insert(k) }
        }
        near = close
    }
    func has(_ phrases: String...) -> Bool { phrases.contains { p in p.contains(" ") ? (" " + text + " ").contains(" " + p + " ") : (words.contains(p) || near.contains(p)) } }
    func starts(_ phrases: String...) -> Bool { phrases.contains { text == $0 || text.hasPrefix($0 + " ") } }
    // The first number in the sentence, as digits or as a word.
    var number: Int? {
        for w in words { if let n = Int(w) { return n } }
        for w in words where !["a", "an", "to", "for"].contains(w) { if let n = numberWords[w] { return n } }
        return nil
    }
    func after(_ markers: String...) -> String? {
        for m in markers { if let r = (" " + text + " ").range(of: " " + m + " ") { let rest = (" " + text + " ")[r.upperBound...].trimmingCharacters(in: .whitespaces); if !rest.isEmpty { return rest } } }
        return nil
    }
}

extension Engine {
    // MARK: Understanding

    /// A sentence addressed to the assistant. Returns the name of what it understood, for the log and the tests.
    @discardableResult
    func hear(_ said: String) -> String {
        lock.lock(); defer { lock.unlock() }
        // Typed or spoken, the assistant's name at the front is written the one way the rest expects.
        let lead = said.split(separator: " ", maxSplits: 3).map(String.init)
        let raw = lead.isEmpty ? said : (Ears.tidy(lead.prefix(3).joined(separator: " ")) + (lead.count > 3 ? " " + lead[3] : ""))
        let h = Heard(raw)
        ui("heard " + raw)
        if !h.text.isEmpty { asked += 1 }
        // The microphone also hears the assistant's own voice. Words that it has just spoken
        // itself are an echo, not a request.
        let echo = Heard(raw).text
        let urgent = ["stop", "quiet", "cancel", "home", "pause", "enough", "silence"].contains { echo == $0 || echo.hasPrefix($0 + " ") }   // never mistaken for an echo
        if echo.count >= 2, !urgent, pendingConfirm == nil, pendingSentence == nil, now() - lastSpokenAt < 6, (" " + Heard(lastSpoken).text + " ").contains(" " + echo + " ") {
            ui("heard (my own voice: ignored)")
            return "echo"
        }
        // An answer to something the assistant just asked.
        let bare = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?")).replacingOccurrences(of: "jarvis ", with: "").replacingOccurrences(of: "hey ", with: "")
        if let go = pendingConfirm, now() < pendingUntil {
            let yes = ["yes", "yeah", "yep", "yes please", "do it", "go ahead", "ok", "okay", "sure", "please do", "confirm", "go on", "go for it", "sounds good"]
            let no = ["no", "nope", "cancel", "stop", "dont", "don't", "never mind", "nevermind", "no thanks", "leave it"]
            if yes.contains(bare) || yes.contains(where: { bare.hasPrefix($0 + " ") }) { pendingConfirm = nil; go(); return "confirmed" }
            if no.contains(bare) || no.contains(where: { bare.hasPrefix($0 + " ") }) {
                pendingConfirm = nil
                run { g in self.say("Okay. Nothing was changed.", g) }
                return "cancelled"
            }
        }
        pendingConfirm = nil
        if let earlier = pendingSentence, now() < pendingUntil, !h.words.isEmpty, h.words.count <= 5 {
            // The reply to "which one?" completes the sentence that raised the question.
            pendingSentence = nil
            if let done = dawHear(Heard(earlier + " " + h.text)) { return done }
        }
        pendingSentence = nil
        if h.has("repeat that", "say that again", "what did you say", "pardon", "come again", "say it again") && mode != .teach {
            let again = lastSpoken.isEmpty ? "I have not said anything yet." : lastSpoken
            // "Say that again slowly": the same words, at an easier pace, just this once.
            let slowly = h.has("slowly", "slower", "more slowly"), usual = Kokoro.rate
            run { g in if slowly { Kokoro.rate = usual * 0.78 }; self.say(again, g); Kokoro.rate = usual }
            return slowly ? "repeat slowly" : "repeat"
        }
        for m in ["guided", "assisted", "autonomous"] where h.has(m + " mode") {
            dawMode = m
            if !Opt.fast { try? m.write(to: baseDir.appendingPathComponent("daw-mode.txt"), atomically: true, encoding: .utf8) }
            let text = m == "guided" ? "Guided mode. I will explain every change and wait for a yes before I make it."
                : m == "assisted" ? "Assisted mode. I make ordinary changes straight away and tell you what happened. I still ask before deleting anything or running a plan of several steps."
                : "Autonomous mode. I carry out plans of several steps without asking first, and report at the end. I still ask before deleting anything."
            run { g in self.say(text, g) }
            return "mode " + m
        }
        // Being put right: "no, I meant ...", or simply "that's wrong".
        if !secondPass, !aiRouting, let done = correction(h) { return done }
        if let pending = correcting, !secondPass, !aiRouting, !h.words.isEmpty {
            // The sentence after "that's wrong" is what the earlier one should have meant.
            correcting = nil
            secondPass = true
            let done = hear(raw)
            secondPass = false
            if done != "ask" { learn(pending, means: h.text); return done }
        }
        // "Do this, and then that."
        if !secondPass, !sequencing, !casualHearing, !h.has("spotify", "youtube", "click menu"), let done = sequenceHear(raw) { return done }
        if !secondPass, !aiRouting, !casualHearing, !h.words.isEmpty { lastRequest = h.text }
        // A guessed name followed by a long sentence, or by "stop" inside a longer remark, is talk in the room.
        if guessedName, h.words.count > 8 || (h.words.count > 2 && h.starts("stop", "quiet", "be quiet", "silence", "enough", "cancel", "pause", "wait", "hold on", "home", "goodbye", "bye", "quit", "never mind", "yes", "no")) { return "ignored" }
        if h.words.isEmpty {
            // Just the name: a short spoken answer, never the same one twice running, and
            // fitted to the moment. These are all prepared in advance, so they come at once.
            ui("flash good")
            let reply = wakeReply()
            run { g in self.say(reply, g); self.resumeAfterHelp(g) }
            return "wake"
        }
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }

        // Spotify, YouTube, files and the forecast. First, because a song can be called anything: "play Home on Spotify".
        if let done = updateHear(h) { return done }
        if let done = profileHear(h) { return done }
        if h.has("your settings", "jarvis settings", "nova settings", "app settings", "quick settings", "your preferences", "assistant settings") && !h.has("system") {
            ui("settings 1")
            run { g in self.say(self.styled(classic: ["Settings, on screen."], warm: ["Here are my settings."], playful: ["Settings. Change anything you like."], brief: ["Settings."]), g) }
            return "settings"
        }
        if let done = personalityHear(h) { return done }
        if let done = brainHear(h) { return done }
        if let done = goonHear(h) { return done }
        if !h.text.isEmpty { lastDone = h.text }
        if let done = voiceInstallHear(h) { return done }
        if let done = extrasHear(h) { return done }
        if let done = homeHear(h) { return done }
        if let done = windowHear(h) { return done }
        if h.has("stop listening", "dont listen", "do not listen", "stop hearing", "mute yourself", "mute the microphone", "microphone off", "mic off", "turn off your ears", "privacy", "private conversation", "stop eavesdropping", "ears off") {
            ui("ears off")
            run { g in self.say("I have stopped listening. The microphone is off. Press the voice button when you want me back.", g) }
            return "ears off"
        }
        // Stopping comes first, so it always works.
        if h.starts("stop", "quiet", "be quiet", "silence", "shut up", "enough", "cancel", "never mind", "nevermind") || h.has("stop talking", "stop the music", "stop playing", "stop the band", "stop the metronome") {
            stopEverything(); return "stop"
        }
        if h.starts("pause", "wait", "hold on") { if mode == .teach, !paused { togglePause() } else { stopEverything() }; return "pause" }
        if h.starts("continue", "resume", "carry on", "keep going", "go on") { if paused { togglePause() } else { command(keyHear) }; return "resume" }
        if h.has("home", "main menu", "go back to the start", "exit", "leave this") && !h.has("homework") { goHome(); return "home" }
        if h.starts("goodbye", "good bye", "bye") || ["quit", "shut down", "go to sleep", "quit jarvis", "close jarvis", "exit"].contains(h.text) {
            run { g in self.say(pick(["Goodbye, \(You.name).", "See you soon.", "Until next time."]), g); if !Opt.fast { quit("asked to by voice") } }
            return "quit"
        }
        if h.has("what can you do", "what can i say", "what do you understand", "voice commands") || h.text == "help" || h.text == "help me" {
            reply(voiceHelp()); return "help"
        }
        if h.has("what time", "the time") { let f = DateFormatter(); f.dateFormat = "h:mm a"; reply("It is \(f.string(from: Date())).") ; return "time" }
        if h.has("what day", "todays date", "the date", "what is the date") { let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; reply("It is \(f.string(from: Date())).") ; return "date" }

        // Keys and menus in any app, and a new project in the music program that is open.
        if let done = macHear(h) { return done }
        // Reading and pressing what is in an app's window, and its menus: "click Create", "what buttons are there".
        if let done = axHear(h) { return done }
        // A command in an app that was named: "open the mixer in Logic", "new incognito window in Chrome".
        // (REAPER has its own, deeper connection, so its requests go there.)
        // (Apps named after everyday words, such as Notes or Music, only count when the request says "in".)
        if let t = targetApp(h), t.named, !(t.name == "REAPER" && (Reaper.running || pretendReaper)),
           h.has("in") || !["Notes", "Music", "Home", "Clock", "Calendar", "Maps", "Books", "News", "Mail", "Photos", "Stocks", "Tips", "Phone", "Games", "Weather", "Preview", "Shortcuts", "Reminders", "Contacts", "Messages", "Finder"].contains(t.name) {
            let said = Set(commandWords(h.text).filter { !commandNoise.contains($0) }).subtracting(commandWords(t.name)).subtracting(["logic", "chrome", "google"])
            if said.count >= 2 || (said.count == 1 && said.isDisjoint(with: ["show", "new", "close", "quit", "hide"])), let done = menuHear(h, app: t.name, explicit: true) { return done }
        }
        // Apps and websites: "open REAPER", "fire up Google", "search for jazz voicings".
        if let done = appsHear(h) { return done }
        // The DAW: requests about the project go to REAPER or Logic when one is open.
        if let done = dawHear(h) { return done }

        // Music made for the player: jokes, surprises, their own album, a jam, a new piece, a new costume.
        if h.has("joke", "make me laugh", "something funny") {
            let joke = musicJokes.randomElement() ?? ""
            run { g in self.say(joke, g) }
            return "joke"
        }
        if h.has("surprise me", "surprise", "blow my mind", "impress me", "something cool", "make me smile", "show off", "wow me") { surprise(); return "surprise" }
        if h.has("album", "my pieces", "my songs", "my compositions", "concert", "everything i wrote", "all my music", "my music") && h.has("play", "hear", "listen", "put", "start") {
            playAlbum(); return "album"
        }
        if h.has("jam", "duet", "answer me", "talk back", "musical conversation", "call and response", "trade phrases") && !h.has("jazz") {
            setJam(!h.has("stop", "off", "end")); return "jam"
        }
        if h.has("lullaby", "music box") { restyle("lullaby"); return "restyle lullaby" }
        if h.has("8-bit", "8 bit", "eight bit", "video game", "game boy", "nintendo", "retro", "chiptune", "arcade") { restyle("8-bit"); return "restyle 8-bit" }
        if h.has("electric piano", "lo fi", "lofi", "late night version") { restyle("electric"); return "restyle electric" }
        if h.has("epic", "orchestra", "orchestral", "film score", "movie", "cinematic") && h.has("make it", "turn it", "turn that", "make that", "make my", "turn my", "version", "as a", "into") {
            restyle("epic"); return "restyle epic"
        }
        if h.has("play me something", "play something", "improvise something", "make up", "made up", "compose something", "write me", "play me a", "something for me", "play me some") || (mood(in: h) != nil && h.has("play", "something", "music", "piece", "tune")) {
            if !h.has("teach", "lesson", "learn") {
                let m = mood(in: h) ?? moods.randomElement()!
                performGift(m); return "gift \(m.name)"
            }
        }
        if (h.starts("play", "perform") || h.has("let me hear", "can i hear", "i want to hear")) && !h.has("it", "that", "back"), let i = songNamed(h) {
            perform(i); return "perform \(songs[i].name)"
        }

        // Abilities.
        if h.has("right hand only", "only the right hand", "only my right hand", "one hand right", "i only have my right hand") { setHands("right"); return "hands right" }
        if h.has("left hand only", "only the left hand", "only my left hand", "one hand left", "i only have my left hand") { setHands("left"); return "hands left" }
        if h.has("both hands", "two hands") && h.has("teach", "use", "lessons", "back to", "again", "with") { setHands("both"); return "hands both" }
        if h.has("large text", "bigger text", "big text", "large captions", "bigger captions", "big captions", "larger captions", "i cant read", "hard to read", "text is too small") {
            ui("access large 1"); reply("Large captions on."); return "large"
        }
        if h.has("normal text", "smaller text", "small captions", "normal captions", "smaller captions") { ui("access large 0"); reply("Captions back to normal."); return "large off" }
        if h.has("high contrast", "more contrast") { ui("access contrast \(h.has("off", "no", "stop") ? 0 : 1)"); reply(h.has("off", "no", "stop") ? "High contrast off." : "High contrast on."); return "contrast" }
        if h.has("im deaf", "i am deaf", "hard of hearing", "i cant hear", "i cannot hear", "deaf mode") {
            ui("access large 1"); ui("access flash 1")
            reply("Everything I say is shown in large captions, a wrong note flashes the screen red, and a part you get right flashes green. The visualiser shows the music as light.")
            return "deaf"
        }
        if h.has("im blind", "i am blind", "i cant see", "i cannot see", "blind mode", "low vision") {
            reply("Everything here works by sound and by touch. The eight highest white keys are the buttons, and the eighth one from the top always tells you what they do. You can also just say \(Me.name) and ask.")
            return "blind"
        }

        // Metronome and timers.
        if h.has("metronome", "click track", "click") {
            if h.has("off", "stop", "no") { metronome(nil); reply("Metronome off.") } else { let bpm = max(30, min(240, h.number ?? metroBPM)); metronome(bpm); reply("Metronome at \(bpm).") }
            return "metronome"
        }
        if h.has("timer", "remind me", "practice for", "practise for") || (h.has("minutes", "minute") && h.has("set", "start", "in")) {
            guard let n = h.number else { reply("For how many minutes?"); return "timer?" }
            let seconds = h.has("second", "seconds") ? n : n * 60
            let label = h.has("remind me") ? (h.after("minutes to", "minute to", "seconds to", "second to", "remind me to") ?? "") : ""
            timer(seconds, label: label.components(separatedBy: " in ")[0]); if !label.isEmpty { reply("Okay. I'll remind you in \(n) \(h.has("second", "seconds") ? "second" : "minute")\(n == 1 ? "" : "s")."); return "timer" }
            reply("Timer set for \(n) \(h.has("second", "seconds") ? "second" : "minute")\(n == 1 ? "" : "s")."); return "timer"
        }

        // Sound.
        if h.has("band") && h.has("louder", "up", "more") { stdinKey("]"); return "band up" }
        // "Band mode" on its own: play back what was just written with the band, or explain the two ways to get one.
        if ["band mode", "band", "the band", "open band mode", "turn on the band", "start the band", "band on", "start band mode", "go to band mode", "band please", "i want the band"].contains(h.text) {
            if mode == .compose { _ = composeCommand(keyHear); return "band" }
            reply("There are two ways to get the band. Say new composition, play your idea, then say play it with the band. Or say live band, and it follows you while you play.")
            return "band how"
        }
        if h.has("band") && h.has("quieter", "down", "softer", "less") { stdinKey("["); return "band down" }
        if h.has("classic band", "original band", "old band", "early band", "first band", "band from before", "band like before", "the band i liked", "band how it was", "band the way it was") { setBandStyle("classic"); return "band classic" }
        if h.has("full band", "big band", "bigger band", "whole band", "orchestra band", "newer band") && !h.has("play", "back", "hear", "with") { setBandStyle("full"); return "band full" }
        if h.has("simple band", "small band", "smaller band") { setBandStyle("simple"); return "band simple" }
        if h.has("band style", "change the band", "different band", "another band") { toggleBandStyle(); return "band style" }
        if h.has("speak up", "voice louder", "talk louder", "louder", "turn it up", "volume up", "turn up the volume", "turn the volume up", "cant hear you", "too quiet") && !h.has("band") { stdinKey("."); return "voice up" }
        if h.has("voice quieter", "talk quieter", "speak quieter", "quieter", "too loud", "turn it down", "volume down", "turn down the volume", "turn the volume down") { stdinKey(","); return "voice down" }
        if h.has("audition", "all the voices", "all your voices", "which voices", "what voices", "try the voices", "hear the voices", "voice options") {
            // Each voice introduces itself, so one can be picked by ear.
            run { g in
                guard !Opt.fast, Kokoro.shared.state == .ready else { self.say("The new voices are not loaded.", g); return }
                for v in Kokoro.favourites where self.alive(g) {
                    // Said the same way as everything else it says, so the microphone knows this is its own voice.
                    let line = "This is \(v.name). How do I sound?"
                    ui("say " + line)
                    self.lastSpoken = line
                    self.lastSpokenAt = now() + 30
                    _ = Kokoro.shared.say(line, meter: nil, as: v.id)
                    self.lastSpokenAt = now()
                    ui("done")
                    usleep(250_000)
                }
                self.say("To pick one, say my name, then use, and the voice you liked.", g)
            }
            return "audition"
        }
        if h.starts("use", "pick", "choose", "i like", "i want", "switch to", "be"), let v = Kokoro.favourites.first(where: { h.words.contains($0.name.lowercased()) }) {
            let ok = Opt.fast ? v.name : Kokoro.shared.choose(v.name)
            if ok != nil { ui("voice \(v.name) (Kokoro)") }
            reply(ok != nil ? "This is \(v.name). I will use this voice from now on." : "I could not switch to that voice.")
            return "voice \(v.name)"
        }
        if h.has("change voice", "different voice", "another voice", "change your voice", "next voice") { stdinKey("v"); return "voice" }
        if h.has("slower", "slow down", "too fast") { tempo = max(0.3, tempo - 0.1); reply(pick(["A bit slower.", "Slowing it down."])); return "slower" }
        if h.has("faster", "speed up", "too slow") { tempo = min(1.2, tempo + 0.1); reply(pick(["A bit faster.", "Picking it up."])); return "faster" }
        if h.has("follow me", "play along", "play with me", "live band", "accompany me") {
            if live.on == h.has("off", "stop") { toggleLive() } else { reply(live.on ? "The live band is already following you." : "The live band is off.") }
            return "live"
        }

        // Composition.
        if h.has("start over", "from scratch", "throw that away", "scrap that", "delete that") && mode == .compose { restartTake(); return "restart" }
        if h.has("composition", "compose", "new piece", "new song", "new idea", "i have an idea", "write a song", "write something", "make a song", "composing") && !h.has("idea for", "learn", "teach") {
            command(keyCompose); return "compose"
        }
        if h.has("chord progression", "composing idea", "teach me to compose", "learn to compose", "how to compose", "give me an idea", "idea for") {
            if mode != .compose { mode = .compose; takeStart = now(); takeClosed = true; takeSaved = true }
            learnIdea(); return "learn idea"
        }
        if let name = h.after("save it as", "save that as", "save this as", "save as", "name it", "name that", "name this", "call it", "call that", "call this", "rename it to", "rename it", "rename that to", "rename this to") {
            saveNamed(name); return "save as"
        }
        if h.has("save", "keep that", "keep it", "keep this", "remember that") && !h.has("project") {
            // A piece the assistant just made up can be kept too.
            if let gift = lastGift, now() - giftAt < 240, mode != .compose {
                lastGift = nil
                let ok = Opt.fast || saveIdea(gift, analyse(gift), named: giftName) != nil
                run { g in self.say(ok ? "Kept. It is in your ideas as \(self.giftName)." : "I could not save it.", g) }
                return "keep gift"
            }
            keepLast(); return "keep"
        }
        if h.has("play it back", "play that back", "play it again", "hear it back", "with the band", "as a band", "add a band", "add the band") {
            if mode != .compose { keepLast(); command(keyCompose) }
            _ = composeCommand(keyHear); return "band"
        }
        if h.has("variation", "change it up", "play it differently") { if mode != .compose { command(keyCompose) }; _ = composeCommand(keyNext); return "variation" }
        if h.has("what chord") && h.has("this", "holding", "now", "am i") { reply(heldChord()); return "chord" }
        if h.has("what did i", "what was that", "what key", "what chords", "describe it", "describe that", "what am i playing", "what i wrote", "what i played", "analyse", "analyze") {
            if mode == .compose { _ = composeCommand(keyNotes) } else { describeLast() }
            return "describe"
        }

        if h.has("reaper") { openReaper(); return "reaper" }
        if h.has("logic") { openLogic(); return "logic" }
        if h.starts("record", "start recording") || h.has("start recording", "record this", "hit record") { dawRecord(); return "record" }
        if h.has("track", "tempo", "undo", "plugin", "plug in", "effect", "mixer") && !Opt.fast {
            reply("Open REAPER or Logic first, then ask me again."); return "no daw"
        }

        // Jazz, ear training, lessons.
        if h.has("jazz", "improvise", "improvisation", "blues") {
            let n = h.has("lesson") ? h.number : nil
            startJazz(n.map { $0 - 1 } ?? (mem.jazzLesson ?? 0)); return "jazz"
        }
        if h.has("ear training", "train my ear", "test my ear", "quiz me", "ear test", "ear game", "guess the note", "play a game") { startEar(); return "ear" }
        if h.has("talk mode", "talking piano") { command(keyTalk); return "talk" }
        if h.has("song menu", "list the songs", "list songs", "what songs", "which songs", "song list") { listSongs(); return "songs" }
        if h.has("say the notes", "which notes", "what notes", "what are the notes", "tell me the notes", "what comes next", "what is next", "whats next") { command(keyNotes); return "notes" }
        if h.has("again", "repeat", "one more time", "hear that again", "play that again") { command(keyHear); return "again" }
        if h.has("next", "skip", "skip ahead", "move on") { command(keyNext); return "next" }
        if h.has("previous", "go back") || h.text == "back" { command(keyBack); return "back" }
        if h.has("stop learning", "drop this song", "im done with this song") { dropSong(); return "drop" }
        if let i = songNamed(h) { chooseSong(i); return "song \(songs[i].name)" }
        if h.starts("teach me", "learn", "start a lesson", "lesson", "start the lesson", "piano lesson", "lets learn") {
            // A song was named, but it is not one in the library: say so, and do not start a different one.
            if let wanted = h.after("teach me how to play", "teach me to play", "teach me", "learn how to play", "learn to play", "learn", "lets learn"),
               !["it", "this", "that", "a song", "something", "piano", "the piano", "the song", "this song", "a new song", "something new", "the next part", "the next song", "how to play", "how to play piano", "more", "again", "a lesson", "the lesson", "music", "some music", "practice", "practise", "to practice", "practicing", "study", "work on it", "to play", "to play piano", "piano lesson"].contains(wanted),
               !h.has("lesson", "next", "more") {
                reply("I don't have \(wanted) in the library yet. Say song menu to hear what I do have."); return "no song"
            }
            chooseSong(songIdx); return "lesson"
        }

        // Something it has been taught before, by the AI or by a correction.
        if !secondPass, let known = learned[h.text] {
            secondPass = true
            defer { secondPass = false }
            let done = hear(known)
            if done != "ask" { return done }
        }
        // Not said in the expected words. Read it for its meaning and try once more.
        if !secondPass, let meant = loosely(h) {
            secondPass = true
            defer { secondPass = false }
            let done = hear(meant)
            if done != "ask" { return done }
        }
        // Conversation, sums, and music questions it can answer itself.
        // After a merely guessed name there is no small talk: only the weather, which is a request.
        if guessedName { if let answer = weatherTalk(h) { reply(answer); return "chat" } }
        else if let answer = chat(h) { reply(answer); return "chat" }
        if secondPass { return "ask" }
        // Words overheard just after it spoke, without its name, are only acted on when they are plainly a request.
        if casualHearing { return "ignored" }
        // With the AI awake, anything not understood goes to it: it can work out what was meant, or just talk.
        // Nothing of its own matched. If another app is in front and this is exactly one of its menu commands, that is what was meant.
        if h.words.count <= 7, !h.starts("what", "whats", "who", "why", "how", "when", "where", "is", "are", "do", "does", "did", "can", "tell", "play"),
           let t = targetApp(h), !t.named, t.name != "REAPER", let done = menuHear(h, app: t.name, explicit: false) { return done }
        if !aiRouting, !Opt.fast, AISession.shared.ready { noteMistake("rules did not understand", h.text); finishAsk(raw); return "ask" }
        // An opening word with a name that is not an app on this Mac.
        if h.words.count <= 6, let name = h.after("open", "launch", "fire up", "bring up", "pull up", "open up", "start up", "boot up"), !name.isEmpty {
            if ["it", "that", "this", "one", "them", "something"].contains(name) { reply("Open what? Tell me its name."); return "open what" }
            reply("I cannot find an app called \(name) on this Mac."); return "no app"
        }
        // Close to something it knows: offer the nearest thing, and do it on a yes.
        if let guess = closest(h) {
            pendingConfirm = { [unowned self] in _ = self.hear(guess.say) }
            pendingUntil = now() + 15
            run { g in self.say("Did you mean, \(guess.ask)?", g); self.resumeAfterHelp(g) }
            return "guess \(guess.say)"
        }
        // Anything else goes to the AI, which knows what is happening.
        if aiRouting { return "ask" }
        finishAsk(raw)
        return "ask"
    }

    // MARK: REAPER and Logic by voice

    static let effectWords: [(words: [String], fx: String)] = [
        (["reverb", "echo chamber", "room"], "ReaVerbate"), (["compressor", "compression", "compress"], "ReaComp"),
        (["eq", "equalizer", "equaliser"], "ReaEQ"), (["delay", "echo"], "ReaDelay"), (["limiter"], "ReaLimit"),
        (["gate", "noise gate"], "ReaGate"), (["tuner", "auto tune", "autotune", "pitch correction"], "ReaTune"),
    ]

    /// Turns a sentence into one command for the REAPER bridge, or nil if it is not about REAPER.
    /// `tracks` is the bridge's own list, such as "Track 2, Bass, armed, selected".
    func reaperPlan(_ h: Heard, tracks: [String]) -> [String]? {
        func track() -> String? {
            if let i = h.words.firstIndex(of: "track"), i + 1 < h.words.count, let n = Int(h.words[i + 1]) ?? numberWords[h.words[i + 1]], n >= 1, n <= max(1, tracks.count) { return String(n) }
            for (i, line) in tracks.enumerated() {
                let name = line.components(separatedBy: ", ").dropFirst().first?.lowercased() ?? ""
                if !name.isEmpty, name.split(separator: " ").allSatisfy({ h.words.contains(String($0)) }) { return String(i + 1) }
            }
            if let i = tracks.firstIndex(where: { $0.contains("selected") }) { return String(i + 1) }
            return tracks.isEmpty ? nil : String(tracks.count)
        }
        if h.has("new track", "add a track", "create a track", "another track", "make a track", "new instrument track", "new audio track", "new piano track", "add a piano track", "add an instrument track", "add an audio track") {
            let instrument = h.has("instrument", "piano", "synth", "keys", "midi", "keyboard")
            let name = (h.after("called", "named") ?? (instrument ? (h.has("piano") ? "piano" : "") : "")).capitalized
            return instrument ? ["track_new", "instrument", name, "ReaSynth"] : ["track_new", "audio", name]
        }
        if h.has("add", "put", "insert", "give", "use", "some", "more"), let fx = Engine.effectWords.first(where: { e in e.words.contains { h.has($0) } }), let t = track() {
            return ["fx_add", t, fx.fx]
        }
        if h.has("rename"), let t = track(), let name = h.after("to", "as") { return ["track_rename", t, name.capitalized] }
        if h.has("delete track", "remove track", "delete the track", "remove the track"), let t = track() { return ["track_delete", t] }
        if h.has("mute", "unmute"), let t = track() { return ["track_mute", t] }
        if h.has("solo", "unsolo"), let t = track() { return ["track_solo", t] }
        if h.has("arm", "disarm", "record enable"), let t = track() { return ["track_arm", t] }
        if h.has("track") && h.has("louder", "turn up", "up"), let t = track() { return ["track_vol", t, "3"] }
        if h.has("track") && h.has("quieter", "turn down", "down", "softer"), let t = track() { return ["track_vol", t, "-3"] }
        if h.has("tempo", "bpm", "beats per minute"), let n = h.number, n >= 20 { return ["tempo", "set", String(n)] }
        if h.has("tempo") { return ["tempo"] }
        if h.has("undo") { return ["undo"] }
        if h.has("redo") { return ["redo"] }
        if h.has("record", "recording") { return ["record"] }
        if h.has("playback", "play the project", "play it in reaper", "play reaper", "play the track", "play the tracks", "hit play", "press play", "play the session") { return ["play"] }
        if h.has("rewind", "go to the start", "go to the beginning", "back to the start", "back to the beginning") { return ["start"] }
        if h.has("where am i", "what bar", "which bar") { return ["position"] }
        if h.has("marker") { return [h.has("next") ? "marker_next" : h.has("previous", "last") ? "marker_prev" : "marker_add"] }
        if h.has("save the project", "save project", "save the session", "save reaper") { return ["save"] }
        if h.has("list the tracks", "list tracks", "what tracks", "which tracks", "how many tracks", "read the tracks") { return ["tracks"] }
        if h.has("project") && h.has("about", "info", "tell me", "what is") { return ["info"] }
        return nil
    }

    /// Returns what was done, or nil if the sentence is not for the DAW.
    func dawSay(_ text: String) {
        daw.lastSaid = text
        run { g in self.say(text, g); self.resumeAfterHelp(g) }
    }

    /// Runs a plan one step at a time, re-reading the project between steps, and stops at the first step that cannot be confirmed.
    func runPlan(_ steps: [PlanStep]) {
        run { g in
            var said: [String] = []
            for step in steps {
                guard self.alive(g) || Opt.fast else { break }
                guard let state = self.daw.adapter.state(), let op = step.op(state) else { said.append("I could not work out the \(step.what) step, so I stopped there."); break }
                let r = self.daw.perform(op)
                said.append(r.said)
                if !r.ok { said.append("I stopped there."); break }
            }
            let text = said.joined(separator: " ") + " Say undo to step back, or ask what I changed."
            self.daw.lastSaid = text
            self.say(text, g)
            self.resumeAfterHelp(g)
        }
    }

    /// Returns what was done, or nil if the sentence is not for the DAW.
    func dawHear(_ h: Heard) -> String? {
        if pretendReaper {
            return reaperPlan(h, tracks: ["Track 1, Piano, selected", "Track 2, Bass"]).map { "reaper " + $0.joined(separator: " ") }
        }
        if dawForced || (!Opt.fast && Reaper.running) {
            guard let state = daw.adapter.state() else {
                if h.has("track", "tracks", "plugin", "plugins", "mixer", "reaper", "master") { dawSay("REAPER is open but not answering me. Quit REAPER and open it again so it loads the link."); return "daw silent" }
                return nil
            }
            guard let ask = daw.understand(h, state) else { return nil }
            switch ask {
            case .say(let text):
                dawSay(text)
                return "daw say"
            case .question(let q):
                pendingSentence = h.text
                pendingUntil = now() + 25
                dawSay(q)
                return "daw question"
            case .op(let op, let confirm):
                var changes = true
                if case .select = op { changes = false }
                if case .transport = op { changes = false }
                let act = { [unowned self] in
                    self.run { g in
                        let r = self.daw.perform(op)
                        if !r.ok { self.noteMistake("a studio action failed", r.said) }
                        self.daw.lastSaid = r.said
                        self.say(r.said, g)
                        self.resumeAfterHelp(g)
                    }
                }
                if let question = confirm ?? (dawMode == "guided" && changes ? "I am about to change the project. Shall I go ahead?" : nil) {
                    pendingConfirm = act
                    pendingUntil = now() + 30
                    dawSay(question)
                    return "daw confirm"
                }
                act()
                return "daw op"
            case .plan(let explain, let steps):
                if dawMode == "autonomous" { runPlan(steps); return "daw plan" }
                pendingConfirm = { [unowned self] in self.runPlan(steps) }
                pendingUntil = now() + 40
                dawSay(explain + " Shall I go ahead?")
                return "daw plan?"
            }
        }
        if Opt.fast { return nil }
        guard runTool("/usr/bin/pgrep", ["-xq", "Logic Pro"], timeout: 3).ok else { return nil }
        // Logic is driven by its standard key commands.
        let keys: [(Bool, String, String, Int?, [String])] = [
            (h.has("record", "recording"), "Recording in Logic", "r", nil, []),
            (h.has("playback", "play the project", "play it in logic", "play logic", "hit play", "press play", "play the track"), "Play, or stop, in Logic", " ", 49, []),
            (h.has("undo"), "Undone in Logic", "z", nil, ["command"]),
            (h.has("new track", "add a track", "another track", "new instrument track", "new piano track"), "New software instrument track in Logic", "s", nil, ["command", "option"]),
            (h.has("new audio track", "add an audio track"), "New audio track in Logic", "a", nil, ["command", "option"]),
            (h.has("rewind", "go to the start", "go to the beginning", "back to the start"), "At the beginning", "", 36, []),
            (h.has("save the project", "save project", "save the session"), "Saved in Logic", "s", nil, ["command"]),
            (h.has("mute") && h.has("track"), "Mute toggled on the selected track", "m", nil, []),
            (h.has("solo") && h.has("track"), "Solo toggled on the selected track", "s", nil, []),
            (h.has("cycle", "loop") && h.has("logic", "on", "off"), "Cycle toggled", "c", nil, []),
            (h.has("mixer"), "Mixer", "x", nil, []),
        ]
        guard let k = keys.first(where: { $0.0 }) else { return nil }
        run { g in
            let r = LogicControl.key(k.2, code: k.3, mods: k.4)
            self.say(r.ok ? k.1 + "." : (LogicControl.denied(r.out) ? LogicControl.needPermission : "Logic did not respond."), g)
            self.resumeAfterHelp(g)
        }
        return "logic " + k.1
    }

    static var wakeReplies: [String] { ["Yes, \(You.name)?", "I'm listening.", "Go ahead.", "At your service.", "Yes, \(You.name)?", "How can I help?", "What do you need?", "I'm here, \(You.name).", "Right here.",
                              "Still here.", "Good morning, \(You.name).", "Good evening, \(You.name).", "Yes? I'm following your piece.", "Yes? The lesson can wait.", "Welcome back, \(You.name)."] }

    /// What to say when only the name is spoken.
    func wakeReply() -> String {
        let t = now()
        defer { lastWakeAt = t }
        // Called again straight away with nothing asked in between; the first call of the day; back after a long while.
        var options = wakeOptions(hour: Calendar.current.component(.hour, from: Date()), first: wakeCount == 0 && t - lastWakeAt >= 12, again: t - lastWakeAt < 12, longGap: t - lastWakeAt > 1200)
        if t - lastWakeAt < 12 || wakeCount == 0 || t - lastWakeAt > 1200 || Style.current == .brief {}
        else if mode == .compose, Int.random(in: 0..<4) == 0 { options = ["Yes? I'm following your piece."] }
        else if mode == .teach, Int.random(in: 0..<4) == 0 { options = ["Yes? The lesson can wait."] }
        wakeCount += 1
        let fresh = options.filter { $0 != lastWakeReply }
        lastWakeReply = (fresh.isEmpty ? options : fresh).randomElement() ?? "Yes?"
        return lastWakeReply
    }

    func voiceHelp() -> String {
        "You can say things like: play me something sad. Make it a lullaby. Play my album. Jam with me. Surprise me. New composition. Play it back with the band. What did I just play. Save that as, and a name. Teach me Ode to Joy. Jazz lesson three. Ear training. Metronome at ninety. Timer for ten minutes. Slower. Band louder. In REAPER: new piano track, add reverb to track two, tempo one hundred, record, undo. Right hand only. Large captions. Stop. Home. Remember that the recital is Friday. Add milk to my shopping list. Set an alarm for seven thirty. Brief me. Play a song on Spotify, or anything on YouTube. In any other app, tell me what you want done there, like: in Logic, new audio track. Or say click, and a button's name, read the window, or where am I. Or ask me any question."
    }

    // MARK: Small helpers the sentences map onto

    // Uses the same path as the single keys typed on the computer, so the behaviour is identical.
    func stdinKey(_ key: String) {
        switch key {
        case "[", "]":
            let before = sounds.level
            sounds.level += key == "]" ? 3 : -3
            ui("bandlevel \(sounds.level >= 0 ? "+" : "")\(Int(sounds.level)) dB")
            let edge = sounds.level == before ? " That is the limit." : ""
            run { g in self.say((key == "]" ? "Band louder." : "Band quieter.") + edge, g); self.resumeAfterHelp(g) }
        case ",", ".":
            Opt.voiceVolume = max(0.2, min(1.0, Opt.voiceVolume + (key == "." ? 0.15 : -0.15)))
            run { g in self.say(key == "." ? "Voice louder." : "Voice quieter.", g); self.resumeAfterHelp(g) }
        default:
            let name = Opt.fast ? "the next voice" : speaker.nextVoice()
            run { g in self.say("This is \(name).", g); self.resumeAfterHelp(g) }
        }
    }

    func stopEverything() {
        // If nothing of its own is going on, "stop" most likely means the music from Spotify.
        let idle = mode == .idle && metroBPM == 0 && !jamOn && !roundOn && now() - lastSpokenAt > 2
        if idle, !Opt.fast, spotifyPlaying() {
            midi.allOff()
            spotifyPausedAt = now()
            run { g in
                _ = self.spotifyScript("pause")
                usleep(500_000)
                self.say(self.spotifyNow()?.state == "playing" ? "I asked Spotify to stop, but it's still playing." : "Spotify is paused.", g)
            }
            return
        }
        metronome(nil)
        earTarget = nil
        jamOn = false
        roundOn = false
        accGen += 1
        midi.allOff()
        if mode == .teach, !paused { togglePause(); return }
        run { g in self.say(pick(["Okay, stopped.", "All quiet now.", "Stopping there."]), g) }
    }

    func setHands(_ which: String) {
        handsOnly = which
        if !Opt.fast { try? which.write(to: handsURL, atomically: true, encoding: .utf8) }
        ui("hands " + which)
        let text = which == "both" ? "Lessons will teach both hands again." : "Lessons will teach the \(which) hand only, from now on. Say both hands to change back."
        // A lesson in progress is rebuilt for the new choice.
        if mode == .teach, jazzIdx == nil, songs.indices.contains(songIdx) {
            progress[songs[songIdx].name] = 0
            run { g in self.say(text, g) }
            chooseSong(songIdx)
        } else {
            run { g in self.say(text, g); self.resumeAfterHelp(g) }
        }
    }

    // The best match for a song named in the sentence, if any word of a title was said.
    func songNamed(_ h: Heard) -> Int? {
        let skip: Set<String> = ["the", "a", "an", "of", "in", "to", "me", "and", "no", "op", "song", "piece", "complete", "opening", "only", "theme", "from", "you", "i", "on", "with", "it", "is", "like", "what", "feels", "last", "are", "can", "play", "make", "sound", "something", "have", "my", "your", "that", "this", "do", "for"]
        let said = Set(h.words.filter { !skip.contains($0) && $0.count > 1 })
        var best: (Int, Double) = (-1, 0)
        for (i, s) in songs.enumerated() {
            let title = Heard(s.name.replacingOccurrences(of: "-", with: " ")).words.filter { !skip.contains($0) && $0.count > 1 }
            guard !title.isEmpty else { continue }
            let hits = title.filter { said.contains($0) }
            // Rare words count for more than common ones such as "prelude" or "major".
            let weight = hits.reduce(0.0) { $0 + (["prelude", "major", "minor", "sonata", "theme", "life", "main", "flat", "state", "mind", "one", "night"].contains($1) ? 0.4 : 1) }
            let score = weight / Double(title.count) + weight * 0.3
            let named = hits.count >= 2 || title.count <= 2 || hits.contains { $0.count >= 6 && !["prelude", "sonata", "moonlight", "composition"].contains($0) }
            if weight >= 1, named, score > best.1 { best = (i, score) }
        }
        return best.0 >= 0 ? best.0 : nil
    }

    func saveNamed(_ name: String) {
        if !(mode == .compose && takeSaved) {
            var piece = mode == .compose ? tidyTake(notes(since: takeStart)) : []
            if piece.count < 3 { piece = lastStretch() }
            guard piece.count >= 3 else { run { g in self.say("There is nothing to save yet.", g) }; return }
            namingTake = piece
        } else {
            namingTake = []
        }
        typing = "name"
        nameBytes = Array(name.capitalized.utf8)
        finishNaming()
    }

    func heldChord() -> String {
        let held = openIdx.keys.sorted()
        guard !held.isEmpty else { return "Hold some keys down and ask again." }
        let names = flatNames
        if held.count == 1 { return "That is \(names[held[0] % 12])." }
        if let n = chordName(held, names: names) { return "\(n). The notes are \(held.map { names[$0 % 12] }.joined(separator: ", "))." }
        return "The notes are \(held.map { names[$0 % 12] }.joined(separator: ", ")). That is not one of the simple chords."
    }

    func describeLast() {
        let piece = lastStretch()
        guard piece.count >= 6 else { run { g in self.say("Play something first, then ask me.", g) }; return }
        let a = analyse(piece)
        let text = a.summary(noteCount: piece.count) + " " + insights(a, earlier: mem.pieces).joined(separator: " ")
        lastSummary = text
        run { g in self.say(text, g); self.resumeAfterHelp(g) }
    }

    func dawRecord() {
        run { g in
            if Opt.fast { self.say("Recording.", g); return }
            if Reaper.running, let r = Reaper.send("record") { self.say(r + ".", g); return }
            let r = LogicControl.key("r")
            self.say(r.ok ? "Recording in Logic." : (LogicControl.denied(r.out) ? LogicControl.needPermission : "I could not reach Logic or REAPER."), g)
        }
    }

    // MARK: Metronome and timers

    func metronome(_ bpm: Int?) {
        metroToken += 1
        guard let bpm = bpm else { return }
        metroBPM = bpm
        if Opt.fast { return }
        let token = metroToken
        let gap = 60.0 / Double(bpm)
        DispatchQueue.global(qos: .userInteractive).async {
            var beat = 0
            let start = now()
            while self.metroToken == token {
                let high = beat % 4 == 0
                self.midi.send([0x99, high ? 76 : 77, high ? 84 : 62])
                ui("beat \(beat % 4)")
                beat += 1
                let due = start + Double(beat) * gap
                while now() < due, self.metroToken == token { usleep(2000) }
                self.midi.send([0x89, high ? 76 : 77, 0])
            }
        }
    }

    func timer(_ seconds: Int, label: String = "") {
        if Opt.fast { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(seconds)) {
            self.chime([79, 84, 79, 84])
            ui("flash good")
            let amount = seconds >= 60 ? "\(seconds / 60) minute\(seconds / 60 == 1 ? "" : "s")" : "\(seconds) seconds"
            self.announce(label.isEmpty ? "Time. \(amount) are up." : "\(You.name), a reminder: \(label).")
        }
    }

    // MARK: Ear training: find the note I play

    func startEar() {
        goHomeQuietly()
        earRound = 0; earFirstTry = 0
        run { g in
            self.say("Ear training. I play a note, you find it on the piano. Five notes." + self.intro("ear", " A knock means not that one. The top key plays it again."), g)
            guard self.alive(g) else { return }
            self.lock.lock(); self.nextEar(); self.lock.unlock()
        }
    }

    func goHomeQuietly() {
        autosaveTake()
        mode = .idle
        paused = false; waiting = false; jazzIdx = nil; review = nil; drill = nil
        accGen += 1
        midi.allOff()
    }

    func nextEar() {
        earRound += 1
        earMisses = 0
        // Notes near the middle of the piano; the white keys first, then all twelve.
        let pool = earRound <= 2 ? [60, 62, 64, 65, 67, 69, 71, 72] : Array(55...76)
        var pick = pool.randomElement() ?? 60
        if pick == earTarget { pick = pool[(pool.firstIndex(of: pick)! + 3) % pool.count] }
        earTarget = pick
        playEar()
    }

    func playEar() {
        guard let p = earTarget, !Opt.fast else { return }
        midi.send([0x90, UInt8(p), 84])
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { self.midi.send([0x80, UInt8(p), 0]) }
    }

    // A note played during the game. Returns true if the game used it.
    func earNote(_ pitch: Int) -> Bool {
        guard let target = earTarget else { return false }
        if pitch == target {
            let name = flatNames[target % 12]
            if earMisses == 0 { earFirstTry += 1 }
            ui("flash good")
            let said = earMisses == 0 ? pick(["Yes, first try. \(name).", "\(name). Straight to it.", "Right away. \(name)."]) : "Yes. \(name)."
            if earRound >= 5 {
                earTarget = nil
                let score = earFirstTry
                run { g in self.say("\(said) That is five. \(score) on the first try. " + (score >= 4 ? "Your ear is sharp." : "Say ear training to go again."), g) }
            } else {
                run { g in
                    self.say(said + " Next.", g)
                    guard self.alive(g) else { return }
                    self.lock.lock(); self.nextEar(); self.lock.unlock()
                }
            }
        } else {
            earMisses += 1
            knock()
            ui("flash wrong")
            if earMisses % 3 == 0 {
                let way = (pitch - target) % 12 == 0 ? "Right note, wrong octave." : (pitch > target ? "Lower." : "Higher.")
                run { g in self.say(way, g); guard self.alive(g) else { return }; self.playEar() }
            }
        }
        return true
    }
}

func brainSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    // Each sentence must be understood as the thing on its right.
    let cases: [(String, String)] = [
        ("Hey \(Me.name), open composition mode", "compose"), ("\(Me.name) I have an idea", "compose"), ("jarvis", "wake"),
        ("\(Me.name), play it back with the band please", "band"), ("what did I just play?", "describe"), ("\(Me.name) what key was that in", "describe"),
        ("save that as Rainy Morning", "save as"), ("\(Me.name), keep that", "keep"), ("\(Me.name) stop", "stop"), ("be quiet", "stop"),
        ("go home", "home"), ("\(Me.name), what can you do?", "help"), ("metronome at 90", "metronome"), ("turn the metronome off", "metronome"),
        ("set a timer for ten minutes", "timer"), ("\(Me.name) slow down", "slower"), ("make the band louder", "band up"),
        ("open reaper", "app REAPER"), ("start recording", "record"), ("jazz lesson three", "jazz"), ("teach me to improvise", "jazz"),
        ("ear training", "ear"), ("quiz me", "ear"), ("right hand only", "hands right"), ("use both hands again", "hands both"),
        ("large captions", "large"), ("I am deaf", "deaf"), ("what time is it", "time"), ("what are the notes", "notes"),
        ("hear that again", "again"), ("skip ahead", "next"), ("give me a chord progression idea", "learn idea"),
        ("why does F minor sound sad in C major?", "ask"), ("audition the voices", "audition"), ("use Emma", "voice Emma"), ("what chord am I holding", "chord"),
    ]
    var wrong: [String] = []
    for (said, want) in cases {
        engine.goHomeQuietly(); engine.earTarget = nil
        let got = engine.hear(said)
        if got != want { wrong.append("\"\(said)\" was taken as \(got), not \(want)") }
    }
    engine.pretendReaper = true
    let daw: [(String, String)] = [
        ("\(Me.name), add a new piano track called Lead", "reaper track_new instrument Lead ReaSynth"), ("add reverb to track two", "reaper fx_add 2 ReaVerbate"),
        ("put a compressor on the bass", "reaper fx_add 2 ReaComp"), ("mute the piano track", "reaper track_mute 1"), ("set the tempo to 96", "reaper tempo set 96"),
        ("undo that", "reaper undo"), ("start recording", "reaper record"), ("rename track 2 to low end", "reaper track_rename 2 Low End"),
        ("where am I", "reaper position"), ("list the tracks", "reaper tracks"), ("turn track one down", "reaper track_vol 1 -3"), ("add an eq", "reaper fx_add 1 ReaEQ"),
    ]
    for (said, want) in daw {
        let got = engine.hear(said)
        if got != want { wrong.append("\"\(said)\" was taken as \(got), not \(want)") }
    }
    engine.pretendReaper = false
    engine.goHomeQuietly()
    check("brain: \(cases.count + daw.count) plain sentences are understood, including REAPER requests", wrong.isEmpty, wrong.isEmpty ? "all understood" : wrong.joined(separator: "; "))
    let clair = engine.hear("\(Me.name), teach me Clair de Lune")
    let fur = engine.hear("can you teach me fur elise")
    engine.goHomeQuietly()
    check("brain: songs are found by name", clair.contains("Clair de") && fur.lowercased().contains("fur elise"), clair + " / " + fur)
    engine.hear("ear training")
    let target = engine.earTarget ?? 0
    let playing = engine.earTarget != nil && engine.earNote(target + 1) && engine.earMisses == 1
    _ = engine.earNote(target)
    check("ear training: a wrong note is counted and the right one moves on", playing && engine.earRound == 2, "round \(engine.earRound)")
    engine.goHomeQuietly(); engine.earTarget = nil
    let saved = handsOnly
    handsOnly = "right"
    let one = Lesson(song: engine.songs.first { $0.name == "Ode to Joy" } ?? engine.songs[0])
    handsOnly = saved
    check("one-hand lessons: only the chosen hand is taught", !one.units.isEmpty && one.units.allSatisfy { $0.hand == 0 }, "\(one.units.count) steps, right hand only")
}
