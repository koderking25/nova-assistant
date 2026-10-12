// Understanding loose wording, opening apps, and ordinary conversation.
//
// The first pass in brain.swift recognises requests said in the expected words. This file is
// the second pass, for everything else: it fixes words the speech recogniser commonly gets
// wrong, reads a sentence for its ideas ("the instruments", "can't hear") and turns it into
// the request it most likely means, opens and closes apps and websites, answers music theory
// questions from what it knows, and holds up its end of small talk.

import Foundation

// Words the recogniser gets wrong, and what was meant.
let mishearings: [(String, String)] = [
    ("and reaper", "in reaper"), ("and logic pro", "in logic pro"), ("and logic", "in logic"), ("an reaper", "in reaper"), ("on spotify i", "on spotify"), ("and spotify", "on spotify"),
    ("on spot if i", "on spotify"), ("spot if i", "spotify"), ("on you tube", "on youtube"),
    ("metro gnome", "metronome"), ("metro nome", "metronome"), ("metro no", "metronome"), ("year training", "ear training"), ("here training", "ear training"),
    ("ear trading", "ear training"), ("claire de lune", "clair de lune"), ("clear de lune", "clair de lune"), ("clair de loon", "clair de lune"), ("clear the moon", "clair de lune"),
    ("for elise", "fur elise"), ("furry lease", "fur elise"), ("for a lease", "fur elise"), ("ate bit", "8 bit"), ("a bit version", "8 bit version"),
    ("reper", "reaper"), ("ripper", "reaper"), ("reefer", "reaper"), ("rea per", "reaper"), ("re paper", "reaper"), ("the reaper", "reaper"),
    ("low fi", "lofi"), ("lo-fi", "lofi"), ("composition mod", "composition mode"), ("compositional", "composition"), ("gem with me", "jam with me"),
    ("jam with me", "jam with me"), ("lulla by", "lullaby"), ("lullabye", "lullaby"), ("e q", "eq"), ("e.q.", "eq"), ("plug in", "plugin"), ("plug ins", "plugins"),
    ("plug-in", "plugin"), ("plug-ins", "plugins"), ("b flat", "b flat"), ("be flat", "b flat"), ("see major", "c major"), ("see minor", "c minor"),
    ("sea major", "c major"), ("gee major", "g major"), ("dee minor", "d minor"), ("jazz lessen", "jazz lesson"), ("the base", "the bass"), ("base track", "bass track"),
    ("vocal track", "vocal track"), ("un mute", "unmute"), ("un solo", "unsolo"), ("re verb", "reverb"), ("timer four", "timer for"), ("i'm bored", "im bored"),
]

// One way of saying something loosely: every group must have one of its phrases present.
struct Loose {
    let means: String
    let needs: [[String]]
    var not: [String] = []
    var keep = ""           // "number": carry the number across; "all": carry the whole sentence
}

private let voiceWords = ["voice", "you", "your", "talk", "talking", "speak", "speaking", "jarvis"]
private let bandWords = ["band", "instruments", "instrument", "strings", "accompaniment", "orchestra", "backing", "group", "cello", "others", "everything else", "the rest"]
private let quietWords = ["quiet", "quieter", "soft", "softer", "softly", "lower", "down", "less loud", "too loud", "not so loud", "gentler", "calm down", "drowning", "overpowering", "deafening"]
private let loudWords = ["louder", "turn up", "turn it up", "cant hear", "cannot hear", "barely hear", "hard to hear", "too quiet", "boost", "stronger", "speak up", "more of", "bring up", "volume up"]

// Everyday ways of saying a thing, rewritten into the plain word before anything else looks at the sentence.
let sayings: [(String, String)] = [
    ("crank up", "turn up"), ("crank", "turn up"), ("bump up", "turn up"), ("pump up", "turn up"), ("bring up the", "turn up the"), ("raise the", "turn up the"),
    ("bring down the", "turn down the"), ("pull down the", "turn down the"), ("drop the level of", "turn down"), ("dial back", "turn down"), ("dial down", "turn down"),
    ("silence the", "mute the"), ("shut off the", "mute the"), ("kill the", "remove the"), ("ditch the", "remove the"), ("lose the", "remove the"), ("take off the", "remove the"),
    ("isolate the", "solo the"), ("just the", "solo the"), ("slap a", "add a"), ("stick a", "add a"), ("throw a", "add a"), ("chuck a", "add a"), ("drop a", "add a"),
    ("slap some", "add some"), ("throw some", "add some"), ("whats on", "what plugins are on"), ("copy the", "duplicate the"), ("clone the", "duplicate the"),
    ("go back a step", "undo"), ("take that back", "undo"), ("reverse that", "undo"), ("scrap that change", "undo"), ("oops", "undo"), ("hit record", "start recording"),
    ("roll tape", "start recording"), ("from the beginning", "from the start"), ("the top of the song", "the start"), ("how fast is it", "what is the tempo"),
    ("speed of the song", "tempo"), ("beats a minute", "bpm"),
]

let looseRules: [Loose] = [
    Loose(means: "stop", needs: [["thats enough", "enough", "shush", "hush", "stop it", "cut it out", "no more", "shut it", "zip it", "ok stop", "please stop", "make it stop"]]),
    Loose(means: "band quieter", needs: [bandWords, quietWords]),
    Loose(means: "band louder", needs: [bandWords, loudWords]),
    Loose(means: "voice quieter", needs: [voiceWords, quietWords], not: ["play", "band", "slow"]),
    Loose(means: "voice louder", needs: [voiceWords, loudWords], not: ["play", "band"]),
    Loose(means: "metronome off", needs: [["click", "metronome", "ticking", "tick", "beat"], ["off", "stop", "kill", "no more", "enough", "lose"]]),
    Loose(means: "metronome at", needs: [["click", "metronome", "ticking", "tick", "count me in", "keep time", "keep me in time", "a beat", "steady beat", "pulse"]], keep: "number"),
    Loose(means: "timer for", needs: [["timer", "alarm", "countdown", "tell me when", "let me know when", "wake me", "remind me"]], keep: "number"),
    Loose(means: "play it back with the band", needs: [["hear", "listen", "play", "playback", "give", "show", "put", "add"], ["with the band", "with a band", "with the group", "with instruments", "with the orchestra", "with strings", "full band", "accompaniment", "arranged", "arrangement", "backing", "behind it", "to it", "instruments on"]]),
    Loose(means: "play it back with the band", needs: [["how does it sound", "what does it sound like", "how did that sound", "let me hear it", "let me hear that", "play that for me", "play it for me"]]),
    Loose(means: "what did i just play", needs: [["what"], ["was that", "did i play", "i just played", "i played", "am i playing", "chords was", "chords were", "key was", "key is that", "notes did i", "have i got", "did i just do"]]),
    Loose(means: "what did i just play", needs: [["analyse", "analyze", "break down", "explain"], ["what i played", "that", "my piece", "it", "what i wrote"]]),
    Loose(means: "keep that", needs: [["dont lose", "hold on to", "hang on to", "hold onto", "store", "thats a keeper", "i like that one", "that was good", "dont forget that", "write that down", "bank that", "lock that in"]]),
    Loose(means: "play my album", needs: [["everything", "all", "whole lot", "my stuff", "my work", "my collection", "my recordings"], ["i wrote", "ive written", "i made", "ive made", "i saved", "ive saved", "my stuff", "my work", "play", "hear"]], not: ["tracks", "track"]),
    Loose(means: "jam with me", needs: [["play together", "play with me", "answer me", "respond to me", "back and forth", "trade", "conversation", "bounce off", "riff with me", "lets play", "copy me", "echo me"]], not: ["lesson", "song"]),
    Loose(means: "make it a lullaby", needs: [["baby", "bedtime", "nursery", "sleepy", "cradle", "tinkly"], ["version", "make", "turn", "into", "as a", "like"]]),
    Loose(means: "make it a video game", needs: [["game", "chiptune", "pixel", "mario", "zelda", "retro", "arcade", "bleepy", "bleeps"], ["version", "make", "turn", "into", "as a", "like", "sound"]]),
    Loose(means: "make it epic", needs: [["bigger", "huge", "massive", "hollywood", "dramatic", "orchestral", "grand", "majestic", "trailer"], ["version", "make", "turn", "into", "as a", "like", "it", "sound"]]),
    Loose(means: "electric piano version", needs: [["chill", "rhodes", "mellow", "laid back", "smooth", "cafe", "lofi"], ["version", "make", "turn", "into", "as a", "like", "it"]]),
    Loose(means: "tell me a joke", needs: [["funny", "laugh", "humor", "humour", "cheer me up", "make me giggle", "pun"]]),
    Loose(means: "surprise me", needs: [["show me what you can do", "do something", "anything cool", "wow", "dazzle", "entertain me", "im bored", "amaze me", "do your thing", "show off"]]),
    Loose(means: "ear training", needs: [["ear", "ears", "hearing", "listening", "pitch"], ["train", "training", "test", "quiz", "game", "exercise", "practice", "practise", "challenge", "work on", "improve"]]),
    Loose(means: "ear training", needs: [["guess the note", "name that note", "find the note", "which note is this game"]]),
    Loose(means: "give me a chord progression idea", needs: [["idea", "ideas", "inspiration", "inspire me", "stuck", "writers block", "dont know what to play", "what should i write", "nothing is coming", "blank"]], not: ["have an idea", "new idea", "got an idea"]),
    Loose(means: "new composition", needs: [["write", "compose", "create", "make", "start", "begin", "work on", "come up with", "record", "try"], ["something new", "new piece", "new song", "new tune", "a song", "a piece", "a tune", "my own", "some music", "something of my own", "an original", "from scratch", "something"]], not: ["teach", "learn", "play me", "for me", "you", "album"]),
    Loose(means: "play a variation", needs: [["different version", "another version", "variation", "change it", "mix it up", "remix", "twist", "spin on it", "another take"]]),
    Loose(means: "follow me", needs: [["follow", "accompany", "back me up", "play along", "play behind me", "join in", "come in with me", "support me"]], not: ["lesson"]),
    Loose(means: "jazz", needs: [["jazz", "swing", "blues", "improv", "improvise", "improvising", "soloing", "bebop"]]),
    Loose(means: "say the notes", needs: [["show me the notes", "read the notes", "give me the notes", "the notes again", "which notes", "what notes", "note names", "tell me the notes", "what do i play", "what comes next", "what is next", "whats next", "remind me of the notes", "what are they", "what was it again"]]),
    Loose(means: "again", needs: [["once more", "one more time", "replay", "didnt catch", "say again", "play it again", "from the top", "run that back", "do that again", "hear that again"]]),
    Loose(means: "next", needs: [["move on", "next one", "next part", "skip this", "skip it", "go on to", "keep moving", "on to the next"]]),
    Loose(means: "go back", needs: [["previous one", "previous part", "last one", "one before", "back one", "go back a"]]),
    Loose(means: "slower", needs: [["slow", "slower", "too fast", "not so fast", "take it easy", "ease up", "half speed"]], not: ["metronome", "tempo"]),
    Loose(means: "faster", needs: [["faster", "quicker", "speed up", "too slow", "pick up the pace", "full speed", "hurry"]], not: ["metronome", "tempo"]),
    Loose(means: "large captions", needs: [["bigger", "larger", "cant read", "too small", "enlarge", "zoom"], ["text", "captions", "words", "letters", "font", "writing", "screen", "it"]]),
    Loose(means: "what can you do", needs: [["what can you", "what do you do", "how do i use", "how does this work", "instructions", "commands", "what are my options", "what else can", "what are you capable", "your features", "show me around"]]),
    Loose(means: "home", needs: [["main menu", "get me out", "back out", "take me back", "return to the start", "leave this", "im done", "i am done", "finished here", "close this"]]),
    Loose(means: "song menu", needs: [["what songs", "which songs", "song list", "list of songs", "what can i learn", "what pieces", "choose a song", "pick a song", "browse songs", "what do you have"]]),
    Loose(means: "teach me", needs: [["learn", "teach", "lesson", "practise", "practice", "show me how to play", "how do i play", "work on", "study", "master"]], not: ["compose", "jazz", "ear", "chord", "chords", "scale", "scales", "interval", "arpeggio", "on spotify", "on youtube"], keep: "all"),
    Loose(means: "what time is it", needs: [["time", "clock", "how late"]], not: ["timer", "signature", "in time", "next time", "one more time", "first time"]),
    Loose(means: "what day is it", needs: [["date", "what day", "todays", "day is it", "day of the week"]]),
    Loose(means: "right hand only", needs: [["one hand", "single hand", "only one hand", "one handed"], ["right"]]),
    Loose(means: "left hand only", needs: [["one hand", "single hand", "only one hand", "one handed"], ["left"]]),
    Loose(means: "goodbye", needs: [["see you", "im off", "im leaving", "sign off", "thats all for today", "im going to bed", "talk later"]]),
]

// More words for each mood than the first pass knows.
let moodWords: [String: [String]] = [
    "sad": ["gloomy", "dark", "depressing", "moody", "tearful", "sorrowful", "mournful", "miserable", "unhappy", "tragic", "grief", "wistful", "heartache", "moving", "somber", "sombre", "crying"],
    "happy": ["cheery", "lively", "energetic", "playful", "bouncy", "jolly", "merry", "sunshine", "celebration", "party", "excited", "peppy", "smile"],
    "calm": ["tranquil", "mellow", "serene", "bedtime", "lazy", "restful", "meditative", "spa", "unwind", "comforting", "cosy", "cozy", "rain"],
    "epic": ["huge", "triumphant", "adventure", "war", "mighty", "bold", "grand", "massive", "hero", "thunder", "storm", "angry", "fierce", "victory"],
    "dreamy": ["spooky", "ethereal", "mystical", "weird", "fantasy", "alien", "strange", "underwater", "ghostly", "enchanted", "fairy", "cloud", "moonlight", "stars", "eerie"],
    "hopeful": ["uplifting", "inspiring", "tender", "romantic", "love", "sweet", "touching", "heartfelt", "sunrise", "gentle", "soulful", "emotional", "longing", "memories", "sentimental"],
]

struct AppEntry { let name: String; let path: String }

let appAliases: [(say: [String], app: String)] = [
    (["google chrome", "chrome", "google", "the browser", "my browser", "the internet", "the web"], "Google Chrome"), (["logic pro", "logic"], "Logic Pro"), (["reaper"], "REAPER"),
    (["microsoft word", "word"], "Microsoft Word"), (["excel", "spreadsheet"], "Microsoft Excel"), (["powerpoint", "power point"], "Microsoft PowerPoint"),
    (["outlook"], "Microsoft Outlook"), (["teams"], "Microsoft Teams"), (["one note", "onenote"], "Microsoft OneNote"), (["vs code", "visual studio", "code editor"], "Visual Studio Code"),
    (["system settings", "settings", "preferences", "system preferences"], "System Settings"), (["messages", "imessage", "my texts", "texts"], "Messages"), (["face time", "facetime"], "FaceTime"),
    (["apple music", "music app", "the music app"], "Music"), (["voice memos", "voice memo"], "VoiceMemos"), (["app store"], "App Store"), (["activity monitor"], "Activity Monitor"),
    (["whats app", "whatsapp"], "WhatsApp"), (["one drive", "onedrive"], "OneDrive"), (["quicktime", "quick time"], "QuickTime Player"), (["text edit", "textedit"], "TextEdit"),
    (["midi player"], "MIDI Player"), (["finder", "my files"], "Finder"), (["claude"], "Claude"), (["obs"], "OBS"), (["vlc"], "VLC"),
]

let websites: [(say: [String], url: String, name: String)] = [
    (["youtube", "you tube"], "https://www.youtube.com", "YouTube"), (["gmail", "g mail", "my email", "my mail"], "https://mail.google.com", "Gmail"),
    (["google classroom", "classroom"], "https://classroom.google.com", "Google Classroom"), (["google docs", "docs"], "https://docs.google.com", "Google Docs"),
    (["google drive", "my drive"], "https://drive.google.com", "Google Drive"), (["netflix"], "https://www.netflix.com", "Netflix"), (["wikipedia"], "https://www.wikipedia.org", "Wikipedia"),
    (["google maps"], "https://maps.google.com", "Google Maps"), (["google calendar"], "https://calendar.google.com", "Google Calendar"),
]

let openVerbs = ["open", "launch", "start", "fire up", "bring up", "pull up", "load", "run", "switch to", "go to", "show me", "take me to", "get me", "boot up", "start up", "open up", "i need"]

extension Engine {
    // MARK: Loose wording

    /// The request a loosely worded sentence most likely means, in words the first pass understands.
    func loosely(_ h: Heard) -> String? {
        // A mood said some other way, with anything suggesting "play".
        if h.has("play", "something", "music", "piece", "tune", "song", "make", "give", "hear", "feeling", "feel", "mood", "im") {
            for (mood, words) in moodWords where words.contains(where: { h.words.contains($0) }) {
                if !h.has("teach", "learn", "lesson", "track", "metronome", "version", "it") { return "play me something \(mood)" }
            }
        }
        for rule in looseRules {
            guard rule.needs.allSatisfy({ group in group.contains { h.has($0) } }), !rule.not.contains(where: { h.has($0) }) else { continue }
            switch rule.keep {
            case "number": return h.number.map { "\(rule.means) \($0)" + (h.has("second", "seconds") ? " seconds" : rule.means.hasPrefix("timer") ? " minutes" : "") } ?? (rule.means.hasPrefix("metronome") ? "metronome" : nil)
            case "all": return rule.means + " " + h.text
            default: return rule.means
            }
        }
        return nil
    }

    // MARK: Apps and websites

    static let apps: [AppEntry] = {
        var out: [AppEntry] = []
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                out.append(AppEntry(name: String(item.dropLast(4)), path: dir + "/" + item))
            }
        }
        out.append(AppEntry(name: "Finder", path: "/System/Library/CoreServices/Finder.app"))
        return out
    }()

    /// The installed app a sentence names: by a nickname, or by every word of its real name.
    func appNamed(_ h: Heard) -> AppEntry? {
        for alias in appAliases where alias.say.contains(where: { h.has($0) }) {
            if let app = Engine.apps.first(where: { $0.name == alias.app }) { return app }
        }
        var best: AppEntry? = nil
        for app in Engine.apps {
            let words = Heard(app.name).words
            guard !words.isEmpty, words.allSatisfy({ h.words.contains($0) }) else { continue }
            if best == nil || words.count > Heard(best!.name).words.count { best = app }
        }
        return best
    }

    /// Opening and closing apps, opening websites, and searching the web. Returns what was done, or nil.
    func appsHear(_ h: Heard) -> String? {
        if h.has("composition", "mode", "menu", "lesson", "track", "bus", "mixer", "plugin", "preset") { return nil }
        func launch(_ args: [String], _ said: String, _ failed: String) {
            run { g in
                if Opt.fast { self.say(said, g); return }
                self.say(said, g)
                let r = runTool("/usr/bin/open", args, timeout: 10)
                if !r.ok { self.say(failed, g) }
            }
        }
        // A question to find out, answered aloud from the web. Only "google ..." opens a page of results,
        // which is no use to someone who is not looking at the screen.
        if !h.has("google", "youtube", "you tube", "files", "computer"), !Opt.fast, AISession.shared.ready,
           let wanted = h.after("look up", "search the web for", "search online for", "search the internet for", "search for", "find out"), !wanted.isEmpty {
            finishAsk("Search the web and tell me: " + wanted)
            return "web \(wanted)"
        }
        // Searching: the words after "for", or after "google" or "look up".
        if let query = h.after("search google for", "search the web for", "search online for", "search the internet for", "search for", "google search for", "look up", "google"), !query.isEmpty,
           h.has("search", "look up") || h.starts("google") {
            let onYouTube = h.has("youtube", "you tube")
            let q = query.replacingOccurrences(of: "on youtube", with: "").replacingOccurrences(of: "on google", with: "").trimmingCharacters(in: .whitespaces)
            var parts = URLComponents(string: onYouTube ? "https://www.youtube.com/results" : "https://www.google.com/search")!
            parts.queryItems = [URLQueryItem(name: onYouTube ? "search_query" : "q", value: q)]
            launch([parts.url?.absoluteString ?? "https://www.google.com"], "Searching \(onYouTube ? "YouTube" : "Google") for \(q).", "I could not open the browser.")
            return "search \(q)"
        }
        if let yt = h.after("search youtube for", "find on youtube", "youtube search for") {
            var parts = URLComponents(string: "https://www.youtube.com/results")!
            parts.queryItems = [URLQueryItem(name: "search_query", value: yt)]
            launch([parts.url?.absoluteString ?? "https://www.youtube.com"], "Searching YouTube for \(yt).", "I could not open the browser.")
            return "search \(yt)"
        }
        let wantsOpen = openVerbs.contains { h.has($0) }
        let wantsQuit = h.starts("quit", "close", "exit", "shut", "kill") || h.has("quit", "close down", "shut down")
        guard wantsOpen || wantsQuit else { return nil }
        if wantsQuit, !wantsOpen, let app = appNamed(h) {
            guard app.name != "Nova", app.name != "Finder" else { return nil }
            pendingConfirm = { [unowned self] in
                self.run { g in
                    let r = Opt.fast ? (ok: true, out: "") : runTool("/usr/bin/osascript", ["-e", "tell application \"\(app.name)\" to quit"], timeout: 10)
                    self.say(r.ok ? "\(app.name) is closing. If it has unsaved work, it will ask you first." : "I could not close \(app.name).", g)
                }
            }
            pendingUntil = now() + 20
            run { g in self.say("Close \(app.name)? Say yes or no.", g) }
            return "quit? \(app.name)"
        }
        guard wantsOpen else { return nil }
        if let site = websites.first(where: { s in s.say.contains { h.has($0) } }) {
            launch([site.url], pick(["Opening \(site.name).", "\(site.name), coming up."]), "I could not open the browser.")
            return "site \(site.name)"
        }
        guard let app = appNamed(h) else { return nil }
        // Apps named after everyday words (Notes, Music, Home) need a clear "open": "show me the notes" is about a lesson.
        let plainWords: Set<String> = ["Notes", "Music", "Home", "Clock", "Calendar", "Maps", "Books", "News", "Mail", "Photos", "Stocks", "Tips", "Phone", "Games", "Weather", "Preview", "Shortcuts", "Reminders", "Contacts", "Messages", "Journal", "Passwords", "Apps"]
        if plainWords.contains(app.name), !h.has("open", "launch", "fire up", "bring up", "pull up", "open up", "boot up", "start up", "switch to") { return nil }
        if app.name == "REAPER" { _ = Reaper.installBridge() }
        launch(["-a", app.path], pick(["Opening \(app.name).", "\(app.name), coming up.", "Right away. \(app.name)."]) + (app.name == "REAPER" ? " Once it is open, just tell me what you need in the project." : ""), "I could not open \(app.name).")
        return "app \(app.name)"
    }

    // MARK: Conversation and things it simply knows

    static var chatReplies: [String] { ["You're welcome, \(You.name).", "Any time.", "My pleasure.", "Happy to.", "Loud and clear.", "Always.", "No trouble at all.", "Running perfectly, and better for hearing you play.",
                                        "All systems are happy. How is the music going?", "Thank you. You did the hard part.", "Glad you liked it.", "That means a lot.", "Good morning, \(You.name).",
                                        "Good evening, \(You.name).", "Good night, \(You.name). Well played today."] }
    static let musicFacts = [
        "A piano has 88 keys: 52 white and 36 black.",
        "The lowest note on a piano, A zero, vibrates about 27 and a half times a second. The highest, C eight, more than four thousand.",
        "The word piano is short for pianoforte, Italian for soft loud, because it was the first keyboard that could play both.",
        "Going up one octave exactly doubles how fast a note vibrates.",
        "Bach wrote a prelude and fugue in every major and minor key, and then did the whole thing again.",
        "A modern piano holds about twenty tons of tension in its strings.",
        "Beethoven kept composing after he lost his hearing. He wrote his Ninth Symphony almost completely deaf.",
    ]

    /// A note name spoken in words, such as "e flat", starting at word i. Returns the pitch class and how many words it used.
    func spokenNote(_ w: [String], at i: Int) -> (pc: Int, used: Int)? {
        guard i < w.count, let base = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11][w[i]] else { return nil }
        if i + 1 < w.count, w[i + 1] == "flat" { return ((base + 11) % 12, 2) }
        if i + 1 < w.count, w[i + 1] == "sharp" { return ((base + 1) % 12, 2) }
        return (base, 1)
    }

    /// Scales, chords, key signatures, relatives and intervals, answered from first principles.
    func theory(_ h: Heard) -> String? {
        let w = h.words
        let qualityWords = ["major", "minor", "diminished", "augmented", "dominant", "seven", "seventh", "chord", "scale", "key", "blues"]
        // Find a note that is followed by a word saying what kind of thing is meant.
        var found: (pc: Int, next: Int)? = nil
        for i in w.indices {
            if let n = spokenNote(w, at: i), i + n.used < w.count, qualityWords.contains(w[i + n.used]) { found = (n.pc, i + n.used); break }
        }
        func names(_ pc: Int, minor: Bool) -> [String] {
            let flatKeys: Set<Int> = minor ? [2, 7, 0, 5, 10, 3] : [5, 10, 3, 8, 1, 6]
            return flatKeys.contains(pc) ? flatNames : sharpNames
        }
        if h.has("interval", "above", "below", "up from", "down from") {
            let intervals: [(String, Int)] = [("minor second", 1), ("major second", 2), ("minor third", 3), ("major third", 4), ("perfect fourth", 5), ("fourth", 5), ("tritone", 6),
                                              ("perfect fifth", 7), ("fifth", 7), ("minor sixth", 8), ("major sixth", 9), ("minor seventh", 10), ("major seventh", 11), ("octave", 12),
                                              ("whole step", 2), ("whole tone", 2), ("half step", 1), ("semitone", 1), ("third", 4), ("sixth", 9), ("second", 2)]
            if let iv = intervals.first(where: { h.has($0.0) }), let at = w.indices.first(where: { i in ["above", "below", "from"].contains(w[i]) && spokenNote(w, at: i + 1) != nil }), let n = spokenNote(w, at: at + 1) {
                let down = h.has("below", "down from")
                let pc = ((n.pc + (down ? -iv.1 : iv.1)) % 12 + 12) % 12
                return "A \(iv.0) \(down ? "below" : "above") \(flatNames[n.pc]) is \(flatNames[pc])."
            }
        }
        guard let f = found else { return nil }
        let minor = w[f.next] == "minor"
        let n = names(f.pc, minor: minor)
        if h.has("relative") {
            return minor ? "The relative major of \(n[f.pc]) minor is \(names((f.pc + 3) % 12, minor: false)[(f.pc + 3) % 12]) major. They share the same notes."
                         : "The relative minor of \(n[f.pc]) major is \(names((f.pc + 9) % 12, minor: true)[(f.pc + 9) % 12]) minor. They share the same notes."
        }
        if h.has("sharps", "flats", "key signature", "how many sharps", "how many flats") {
            let major = minor ? (f.pc + 3) % 12 : f.pc
            let count = [0: 0, 7: 1, 2: 2, 9: 3, 4: 4, 11: 5, 6: 6, 5: -1, 10: -2, 3: -3, 8: -4, 1: -5][major] ?? 0
            let what = count == 0 ? "no sharps or flats" : count > 0 ? "\(count) sharp\(count == 1 ? "" : "s")" : "\(-count) flat\(count == -1 ? "" : "s")"
            return "\(n[f.pc]) \(minor ? "minor" : "major") has \(what)."
        }
        guard h.has("notes", "spell", "whats in", "what is in", "what are", "how do i play", "play a", "made of", "make a", "build", "tell me", "show me", "what is a", "what is") else { return nil }
        let rest = Array(w[f.next...])
        let isChord = rest.contains("chord") || rest.contains("seven") || rest.contains("seventh") || rest.contains("diminished") || rest.contains("augmented") || rest.contains("triad")
        if rest.contains("blues") {
            return "The \(n[f.pc]) blues scale is " + [0, 3, 5, 6, 7, 10].map { flatNames[(f.pc + $0) % 12] }.joined(separator: ", ") + "."
        }
        if isChord {
            let seventh = rest.contains("seven") || rest.contains("seventh")
            var steps = minor ? [0, 3, 7] : [0, 4, 7], kind = minor ? "minor" : "major"
            if rest.contains("diminished") { steps = [0, 3, 6]; kind = "diminished" }
            if rest.contains("augmented") { steps = [0, 4, 8]; kind = "augmented" }
            if seventh {
                if rest.first == "major" { steps = [0, 4, 7, 11]; kind = "major seventh" }
                else if minor { steps = [0, 3, 7, 10]; kind = "minor seventh" }
                else { steps = [0, 4, 7, 10]; kind = "seventh" }
            }
            return "\(n[f.pc]) \(kind) is " + steps.map { n[(f.pc + $0) % 12] }.joined(separator: ", ") + "."
        }
        let scale = minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        return "\(n[f.pc]) \(minor ? "minor" : "major") is " + scale.map { n[(f.pc + $0) % 12] }.joined(separator: ", ") + "."
    }

    /// Small talk, simple sums, the battery, and music questions. Returns the reply, or nil.
    func chat(_ h: Heard) -> String? {
        if let answer = theory(h) { return answer }
        if let answer = weatherTalk(h) { return answer }
        if h.has("flip a coin", "toss a coin", "heads or tails", "coin flip", "coin toss") { return Opt.fast ? "Heads." : pick(["Heads.", "Tails."]) }
        if h.has("roll a dice", "roll a die", "roll the dice", "roll dice", "roll a d6") { return "You rolled a \(Opt.fast ? 4 : Int.random(in: 1...6))." }
        if h.has("pick a number", "random number", "choose a number") {
            let nums = h.words.compactMap { Int($0) ?? numberWords[$0] }
            let lo = nums.count >= 2 ? min(nums[0], nums[1]) : 1, hi = nums.count >= 2 ? max(nums[0], nums[1]) : (nums.first ?? 10)
            return "\(Int.random(in: lo...max(lo, hi)))."
        }
        if let i = h.words.firstIndex(where: { $0 == "percent" || $0.hasSuffix("%") }), let j = h.words.firstIndex(of: "of"), j + 1 < h.words.count {
            let pText = h.words[i].hasSuffix("%") ? String(h.words[i].dropLast()) : (i > 0 ? h.words[i - 1] : "")
            if let p = Double(pText) ?? numberWords[pText].map(Double.init), let n = Double(h.words[j + 1]) ?? numberWords[h.words[j + 1]].map(Double.init) {
                let v = p * n / 100
                return "\(v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v))."
            }
        }
        if let word = h.after("how do you spell", "how do i spell", "spell the word", "spell"), h.has("spell"), word.split(separator: " ").count <= 3 {
            return word.capitalized + ". " + word.uppercased().filter { $0.isLetter }.map(String.init).joined(separator: ", ") + "."
        }
        if h.has("good night", "goodnight", "night night") && h.words.count <= 4 { return pick(["Good night, \(You.name). Well played today.", "Good night, \(You.name).", "Sleep well, \(You.name)."]) }
        if h.has("streak", "days in a row", "how many days") { let s = mem.streak ?? 1; return s <= 1 ? "Today starts a new streak." : "\(s) days in a row now." }
        if h.has("how many pieces", "how many songs have i", "how many compositions", "how many ideas") {
            let n = mem.pieces.count
            return n == 0 ? "None saved yet. Say new composition when you're ready." : "You've saved \(n) piece\(n == 1 ? "" : "s") so far."
        }
        if h.has("thank you", "thanks", "thank", "cheers", "appreciate it", "appreciate that", "nice one jarvis", "good job", "well done", "good work") {
            return pick(["You're welcome, \(You.name).", "Any time.", "My pleasure.", "Happy to."])
        }
        if h.has("can you hear me", "are you there", "you there", "are you listening", "hello", "anyone there", "testing") && h.words.count <= 5 { return pick(["Loud and clear.", "Always."]) }
        if h.has("how are you", "how are things", "how are you doing", "hows it going", "you ok", "you all right", "whats up") {
            return pick(["Running perfectly, and better for hearing you play.", "All systems are happy. How is the music going?"])
        }
        if h.has("who are you", "what are you", "your name", "about yourself", "introduce yourself", "what is jarvis") {
            return "I'm \(Me.name), your assistant on this Mac. I open apps and work inside them, play music, answer questions, keep your notes and lists, and if you play piano I teach, listen and play along."
        }
        if h.has("who made you", "who built you", "who created you") { return "A musician who wanted a Mac that listens. And you're shaping me too, every time you tell me what you need." }
        if h.has("i love it", "i love that", "that was beautiful", "that was amazing", "that was great", "that was awesome", "that was cool", "so good", "i like that", "beautiful", "amazing", "perfect", "wow") && h.words.count <= 7 {
            return mode == .compose ? pick(["Thank you. You did the hard part.", "Glad you liked it."]) : pick(["Glad you liked it.", "That means a lot."])
        }
        if h.has("good morning") { return "Good morning, \(You.name)." }
        if h.has("good evening", "good afternoon") { return "Good evening, \(You.name)." }
        if h.has("sorry", "my bad", "never mind that", "forget it", "ignore that") && h.words.count <= 5 { return "No trouble at all." }
        if h.has("fun fact", "something interesting", "tell me something", "teach me something", "did you know", "music fact", "piano fact") { return Engine.musicFacts.randomElement() }
        if h.has("battery", "charge", "power left", "plugged in") {
            if Opt.fast { return "The battery is at 80 percent." }
            let out = runTool("/usr/bin/pmset", ["-g", "batt"], timeout: 4).out
            if let r = out.range(of: #"\d+%"#, options: .regularExpression) {
                return "The battery is at \(out[r].dropLast()) percent" + (out.contains("AC Power") ? ", and plugged in." : ", on battery.")
            }
            return "I could not read the battery."
        }
        if h.has("what should i do", "what should we do", "what now", "any suggestions", "suggest something", "what next", "what do you suggest", "what do you recommend") {
            if let j = mem.jazzLesson, j + 1 < jazzLessons.count { return "You are on jazz lesson \(j + 1), \(jazzLessons[j].title). Say jazz to carry on, or say play me something and I will make up a piece." }
            return pick(["Play me a few bars and say what did I just play. Or say surprise me.", "Try jam with me: you play a phrase and I answer.", "Say play my album and hear everything you have written."])
        }
        // Simple sums: "what is twelve times eight".
        let ops: [(String, (Double, Double) -> Double?)] = [("plus", { $0 + $1 }), ("minus", { $0 - $1 }), ("times", { $0 * $1 }), ("multiplied by", { $0 * $1 }), ("x", { $0 * $1 }),
                                                             ("divided by", { $1 == 0 ? nil : $0 / $1 }), ("over", { $1 == 0 ? nil : $0 / $1 })]
        for (word, f) in ops where h.has(word) {
            let sides = (" " + h.text + " ").components(separatedBy: " " + word + " ")
            func num(_ s: String, last: Bool) -> Double? {
                let ws = s.split(separator: " ").map(String.init)
                for x in (last ? ws.reversed() : ws) { if let n = Double(x) ?? numberWords[x].map(Double.init), !["a", "an", "to", "for"].contains(x) { return n } }
                return nil
            }
            if sides.count == 2, let a = num(sides[0], last: true), let b = num(sides[1], last: false), let r = f(a, b) {
                let shown = r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r)
                return "\(shown)."
            }
        }
        return nil
    }
}

// What the assistant can do, said plainly, for offering a guess when a sentence is nearly one of these.
let guessable: [(say: String, ask: String, about: [String])] = [
    ("new composition", "start a new composition", ["new", "composition", "compose", "write", "song", "piece", "idea", "create"]),
    ("play it back with the band", "play it back with the band", ["play", "back", "band", "hear", "listen", "instruments", "accompaniment"]),
    ("what did i just play", "tell you what you just played", ["what", "played", "chords", "describe", "analyse", "wrote"]),
    ("keep that", "keep what you just played", ["keep", "save", "store", "remember", "record"]),
    ("play me something", "play you something I make up", ["play", "something", "music", "improvise", "make", "tune"]),
    ("play my album", "play your album", ["album", "pieces", "songs", "saved", "collection", "everything"]),
    ("jam with me", "jam with you", ["jam", "duet", "together", "answer", "trade", "conversation"]),
    ("make it a lullaby", "turn your piece into a lullaby", ["lullaby", "baby", "music", "box", "sleep", "version"]),
    ("make it a video game", "turn your piece into a video game tune", ["video", "game", "retro", "8", "bit", "version"]),
    ("make it epic", "turn your piece into a film score", ["epic", "film", "score", "orchestra", "cinematic", "big", "version"]),
    ("song menu", "open the song menu", ["song", "songs", "menu", "list", "choose", "pick", "learn"]),
    ("jazz", "carry on with the jazz course", ["jazz", "blues", "swing", "improvise", "course"]),
    ("ear training", "start ear training", ["ear", "training", "hearing", "quiz", "test", "notes", "guess"]),
    ("metronome", "start the metronome", ["metronome", "click", "beat", "tempo", "time", "tick"]),
    ("say the notes", "tell you the notes", ["notes", "which", "next", "tell", "names"]),
    ("what can you do", "tell you what I can do", ["help", "what", "can", "do", "commands", "options"]),
    ("surprise me", "surprise you", ["surprise", "bored", "fun", "cool", "anything"]),
    ("tell me a joke", "tell you a joke", ["joke", "funny", "laugh"]),
    ("list the tracks", "list the tracks in REAPER", ["tracks", "list", "project", "reaper", "session", "channels"]),
    ("home", "go back to the start", ["home", "menu", "back", "exit", "leave", "start"]),
]

extension Engine {
    /// The thing the assistant can do that shares most words with the sentence, if it shares enough.
    func closest(_ h: Heard) -> (say: String, ask: String)? {
        let said = Set(h.words.map(stem)).union(h.near)
        guard said.count >= 1, h.words.count <= 12 else { return nil }
        var best: (Double, Int) = (0, -1)
        for (i, g) in guessable.enumerated() {
            let hits = g.about.filter { said.contains(stem($0)) }.count
            let score = Double(hits) / Double(max(2, min(said.count, 5)))
            if hits >= 2, score > best.0 { best = (score, i) }
        }
        return best.1 >= 0 && best.0 >= 0.5 ? (guessable[best.1].say, guessable[best.1].ask) : nil
    }
}

func looseSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    // Sentences worded nothing like the commands, and what they must be taken as.
    let cases: [(String, String)] = [
        ("could you talk a bit more softly", "voice down"), ("I can barely hear the other instruments", "band up"), ("the strings are drowning me out", "band down"),
        ("I want to write something of my own", "compose"), ("let me hear that with the full band", "band"), ("how does it sound", "band"),
        ("give me a click at 90", "metronome"), ("kill the click", "metronome"), ("what was that I played", "describe"), ("don't lose that", "keep"),
        ("that's enough thanks", "stop"), ("\(Me.name), stop listening for a while", "ears off"), ("can you play something that sounds gloomy", "gift sad"), ("I'm feeling something tranquil", "gift calm"),
        ("test my hearing", "ear"), ("turn it into something for a baby", "restyle lullaby"), ("make it sound like a mario game", "restyle 8-bit"),
        ("say something funny", "joke"), ("I'm bored, entertain me", "surprise"), ("let's play together, back and forth", "jam"), ("I'm stuck, I need inspiration", "learn idea"),
        ("one more time from the top", "again"), ("take it easy, that's too fast", "slower"), ("I can't read the words, make them bigger", "large"),
        ("what are you capable of", "help"), ("get me out of here", "home"), ("tell me when 5 minutes are up", "timer"), ("play everything I've written", "album"),
        ("metro gnome at 100", "metronome"), ("start year training", "ear"), ("back me up while I play", "live"),
    ]
    var wrong: [String] = []
    for (said, want) in cases {
        engine.goHomeQuietly(); engine.earTarget = nil; engine.jamOn = false; engine.lastGift = nil
        let got = engine.hear(said)
        if got != want { wrong.append("\"\(said)\" was taken as \(got), not \(want)") }
    }
    engine.goHomeQuietly(); engine.jamOn = false
    for (said, want) in [("show me the notes", "notes"), ("open jazz", "jazz"), ("start composision mode", "compose"), ("metronom at 80", "metronome"), ("open notes", "app Notes")] {
        engine.goHomeQuietly()
        let got = engine.hear(said)
        if got != want { wrong.append("\"\(said)\" was taken as \(got), not \(want)") }
    }
    engine.goHomeQuietly()
    let guess = engine.hear("some sort of tune box baby thing version")
    let offered = guess.hasPrefix("guess ") || guess.hasPrefix("restyle")
    engine.pendingConfirm = nil
    if !offered { wrong.append("a near miss was not offered as a guess: \(guess)") }
    check("loose wording: \(cases.count) requests said in other words are understood", wrong.isEmpty, wrong.isEmpty ? "all understood" : wrong.joined(separator: "; "))

    let apps = ["open reaper": "app REAPER", "launch logic": "app Logic Pro", "can you fire up google": "app Google Chrome", "open spotify please": "app Spotify",
                "bring up system settings": "app System Settings", "open youtube": "site YouTube", "search google for jazz piano voicings": "search jazz piano voicings",
                "open microsoft word": "app Microsoft Word", "pull up my email": "site Gmail", "open flibbertigibbet": "no app", "quit spotify": "quit? Spotify"]
    var appWrong: [String] = []
    for (said, want) in apps {
        engine.pendingConfirm = nil
        let got = engine.hear(said)
        if got != want { appWrong.append("\"\(said)\" gave \(got), not \(want)") }
    }
    engine.pendingConfirm = nil
    for (said, want) in [("open a new project", "new project"), ("press command shift n in logic pro", "press command+shift+n in Logic Pro"), ("click menu file then save as in logic", "menu file > save as in Logic Pro")] {
        let got = engine.hear(said)
        if got != want { appWrong.append("\"\(said)\" gave \(got), not \(want)") }
    }
    check("apps: opening apps and websites, searching, and asking before closing", appWrong.isEmpty, appWrong.isEmpty ? "\(Engine.apps.count) apps found on this Mac" : appWrong.joined(separator: "; "))

    let knows: [(String, String)] = [
        ("what notes are in E flat major", "E flat major is E flat, F, G, A flat, B flat, C, D."), ("spell a D minor seven chord", "D minor seventh is D, F, A, C."),
        ("what is the relative minor of C major", "The relative minor of C major is A minor. They share the same notes."), ("how many sharps in A major", "A major has 3 sharps."),
        ("what is a perfect fifth above D", "A perfect fifth above D is A."), ("what is twelve times 8", "96."), ("what notes are in the C blues scale", "The C blues scale is C, E flat, F, G flat, G, B flat."),
    ]
    let bad = knows.filter { engine.chat(Heard($0.0)) != $0.1 }.map { "\"\($0.0)\" gave \(engine.chat(Heard($0.0)) ?? "nothing")" }
    check("knowledge: scales, chords, key signatures, intervals and sums are answered correctly", bad.isEmpty, bad.isEmpty ? "7 of 7" : bad.joined(separator: "; "))
    check("conversation: thanks, greetings and questions about itself get an answer", ["thank you jarvis", "how are you", "who are you", "that was beautiful", "tell me something interesting"].allSatisfy { engine.chat(Heard($0)) != nil }, "")
    engine.goHomeQuietly()
}
