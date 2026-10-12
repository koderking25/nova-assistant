// Who is using the app, and what they call their assistant.
//
// Asked once, in the welcome screens, and kept in profile.json in the app's own folder on this
// Mac. Nothing here is sent anywhere: the city alone is used, as a place name, to ask for the weather.

import Foundation

struct Profile: Codable {
    var user = ""                 // what to call the person; empty until they say
    var assistant = "Nova"        // the wake word, and the assistant's name
    var city = ""                 // for the weather; empty means "work it out from the network"
    var fahrenheit = false
    var about = ""                // anything that changes how to help: "uses a screen reader", "plays piano"
    var plays = true              // false hides nothing, but the greeting stops assuming a piano
    var done = false              // the welcome has been finished
    var birthday = ""             // "MM-DD", or empty. No year is ever asked for or kept.

    init() {}
    init(user: String, assistant: String, city: String, fahrenheit: Bool, about: String, plays: Bool, done: Bool) {
        self.user = user; self.assistant = assistant; self.city = city; self.fahrenheit = fahrenheit; self.about = about; self.plays = plays; self.done = done
    }
    /// A profile saved by an earlier version may lack the newer answers. Whatever is there is kept.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        assistant = (try? c.decode(String.self, forKey: .assistant)) ?? "Nova"
        city = (try? c.decode(String.self, forKey: .city)) ?? ""
        fahrenheit = (try? c.decode(Bool.self, forKey: .fahrenheit)) ?? false
        about = (try? c.decode(String.self, forKey: .about)) ?? ""
        plays = (try? c.decode(Bool.self, forKey: .plays)) ?? true
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        birthday = (try? c.decode(String.self, forKey: .birthday)) ?? ""
    }

    static var isBirthday: Bool {
        let f = DateFormatter(); f.dateFormat = "MM-dd"
        return !current.birthday.isEmpty && f.string(from: Date()) == current.birthday
    }

    static let file = baseDir.appendingPathComponent("profile.json")
    static var current: Profile = (try? JSONDecoder().decode(Profile.self, from: Data(contentsOf: file))) ?? Profile()

    static func save() {
        if Opt.fast { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(current) { try? d.write(to: file, options: .atomic) }
        if !current.city.isEmpty { try? current.city.write(to: Weather.cityFile, atomically: true, encoding: .utf8) }
    }

    /// Names offered in the welcome, each with the ways the Mac's speech recogniser tends to
    /// write it. `strict` spellings count anywhere; `loose` ones are real words too, so they
    /// only count at the very start of a sentence that turns out to be a request.
    static let known: [String: (strict: [String], pairs: [[String]], loose: [String])] = [
        // Every list below comes from measurement: the Mac's own voices said each name 72 ways, and
        // these are the things the recogniser wrote when it got the name wrong.
        "nova": (["nova", "novah", "novas", "novo", "noba", "nava", "nofa", "mova", "nover"], [["no", "va"], ["know", "va"], ["no", "vah"]], ["noah", "nola"]),
        "apollo": (["apollo", "apollos", "appolo", "apolo", "appollo"], [["a", "polo"], ["a", "pollo"], ["uh", "polo"]], ["hello", "paulo", "pablo", "polo", "follow"]),
        "harmony": (["harmony", "harmonie", "harmonies"], [["har", "money"], ["harm", "any"]], ["amity", "omni", "rely", "armani", "hominy", "army"]),
        "phoenix": (["phoenix", "phenix", "fenix", "pheonix"], [["fee", "nix"], ["fee", "nicks"]], ["felix", "next", "minutes", "phonics", "finish"]),
        "luna": (["luna", "lunah", "loona", "lunas"], [["lou", "na"], ["loo", "na"]], ["lunar", "lena", "luma", "bruno", "lu", "lou"]),
        "aria": (["aria", "arya", "ariah", "arias", "ariya"], [["ah", "ria"], ["a", "ria"], ["are", "ya"]], ["area", "areas", "oreo", "ariel", "arm"]),
        "melody": (["melody", "melodie", "melodies"], [["mel", "lady"], ["mel", "o", "d"]], ["melanie", "mel", "memory", "memories", "mail"]),
        "galaxy": (["galaxy", "galaxie", "galaxies"], [["gal", "axy"]], ["alex", "danny", "gallery"]),
        "atlas": (["atlas", "atlus", "atlass"], [["at", "las"], ["at", "less"], ["add", "list"], ["at", "least"]], ["atmos", "alice"]),
        "orion": (["orion", "oryan", "orions", "oreon"], [["o", "ryan"], ["oh", "ryan"], ["o", "ryon"]], ["ryan", "rhyme", "onion"]),
        "jarvis": (["jarvis", "jarvus", "jervis", "jarvas", "javis", "charvis", "jarvice", "jarves", "garvis", "darvis", "jarvi", "travis"], [], []),
    ]

    /// Words the recogniser sometimes writes when the name was said on its own, but which are
    /// also said all the time ("no"). On their own they are not answered aloud: the assistant
    /// gives a soft chime and listens for a moment, and only a plain request is then acted on.
    static let uncertainAlone: [String: Set<String>] = ["nova": ["no", "lower", "noah", "know"], "apollo": ["hello"], "luna": ["lu", "lou"], "harmony": ["rely"], "melody": ["mail", "memory"],
                                                        "aria": ["oreo", "area"], "phoenix": ["next", "minutes"], "galaxy": ["alex"]]

    /// How reliably the Mac's recogniser wrote each offered name in that measurement, out of 72.
    static let measured: [String: Int] = ["jarvis": 70, "apollo": 69, "galaxy": 68, "harmony": 67, "phoenix": 65, "luna": 63, "melody": 62, "aria": 61, "nova": 57]

    /// A name someone has typed or said, made fit to be a wake word: one word, letters only. Nil if it cannot be one.
    static func cleanName(_ raw: String) -> String? {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ").last ?? ""
        let letters = word.filter { $0.isLetter }
        guard (3...12).contains(letters.count) else { return nil }
        return letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
    }
}

/// The person.
enum You {
    static var name: String { Profile.current.user.isEmpty ? "friend" : Profile.current.user }
}

/// The assistant.
enum Me {
    static var name: String { Profile.current.assistant }
    static var key: String { Profile.current.assistant.lowercased().filter { $0.isLetter } }
}

extension Engine {
    /// "Call me Sam", "change your name to Luna", "I live in Leeds": the profile, changed by asking.
    func profileHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        if let wanted = h.after("change your name to", "change your wake word to", "your new name is", "your name is now", "i will call you", "ill call you", "i want to call you", "can i call you",
                                "rename yourself to", "rename yourself", "call yourself", "change the wake word to", "set the wake word to", "set your name to", "wake word to") {
            guard let name = Profile.cleanName(wanted.capitalized) else { reply("A name for me needs to be one word, three to twelve letters long."); return "name bad" }
            let old = Me.name
            if name.lowercased() == Me.key { reply("That's already my name."); return "name same" }
            pendingConfirm = { [unowned self] in
                Profile.current.assistant = name
                Profile.save()
                ui("name \(Me.name)|\(You.name)")
                self.sendVocabulary()
                AISession.shared.shutDown()
                self.run { g in self.say("Done. From now on, call me \(name). \(old) won't work any more.", g) }
            }
            pendingUntil = now() + 25
            reply("Change my name from \(old) to \(name)? Say yes or no.")
            return "name? \(name)"
        }
        if h.has("change your name", "change your wake word", "change the wake word", "different name for you", "rename you") {
            reply("Tell me the new one like this: change your name to Luna. One word, easy to say, works best."); return "name how"
        }
        if h.has("whats your name", "what is your name", "what are you called", "what do i call you", "whats your wake word", "what is your wake word") {
            reply("I'm \(Me.name). Say \(Me.name), then what you'd like. You can change it by saying, change your name to, and a new one."); return "name"
        }
        if let wanted = h.after("my name is", "call me", "you can call me", "change my name to", "im called", "i am called"), !h.has("spotify", "youtube", "taxi", "uber", "back"), wanted.split(separator: " ").count <= 2 {
            let name = wanted.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            Profile.current.user = name
            Profile.save()
            ui("name \(Me.name)|\(You.name)")
            reply(pick(["Good to meet you, \(name).", "\(name) it is.", "Got it, \(name)."])); return "user \(name)"
        }
        if let said = h.after("my birthday is on the", "my birthday is on", "my birthday is the", "my birthday is", "i was born on the", "i was born on"), let mi = said.split(separator: " ").firstIndex(where: { monthNames.contains(String($0)) }) {
            let words = said.split(separator: " ").map(String.init)
            let day = words.compactMap { w in Int(w.replacingOccurrences(of: "st", with: "").replacingOccurrences(of: "nd", with: "").replacingOccurrences(of: "rd", with: "").replacingOccurrences(of: "th", with: "")) ?? numberWords[w] }.first { (1...31).contains($0) }
            guard let d = day, let m = monthNames.firstIndex(of: words[mi]) else { reply("Tell me the day and the month, like: my birthday is the third of March."); return "birthday?" }
            Profile.current.birthday = String(format: "%02d-%02d", m + 1, d)
            Profile.save()
            reply("\(monthNames[m].capitalized) \(d). I'll remember, and I won't ask the year."); return "birthday \(Profile.current.birthday)"
        }
        if h.has("forget my birthday", "delete my birthday", "remove my birthday") { Profile.current.birthday = ""; Profile.save(); reply("Forgotten."); return "birthday forget" }
        if h.has("when is my birthday", "whens my birthday", "do you know my birthday") {
            let p = Profile.current.birthday.split(separator: "-").compactMap { Int($0) }
            reply(p.count == 2 ? "\(monthNames[p[0] - 1].capitalized) \(p[1])." : "You haven't told me. Say, my birthday is, and the day and month. No year needed."); return "birthday"
        }
        if h.has("whats my name", "what is my name", "who am i", "do you know my name") {
            reply(Profile.current.user.isEmpty ? "You haven't told me yet. Say, call me, and your name." : "You're \(You.name)."); return "user"
        }
        if h.number == nil, h.has("use fahrenheit", "switch to fahrenheit", "temperatures in fahrenheit", "weather in fahrenheit") || h.has("use celsius", "switch to celsius", "temperatures in celsius", "weather in celsius") {
            Profile.current.fahrenheit = h.has("fahrenheit")
            Profile.save(); Weather.latest = nil
            reply("Temperatures in \(Profile.current.fahrenheit ? "Fahrenheit" : "Celsius") from now on."); return "units"
        }
        return nil
    }

    /// The names the Mac's speech recogniser should expect to hear.
    func sendVocabulary() {
        var vocab = [Me.name, "Hey \(Me.name)", "composition", "metronome", "REAPER", "Logic Pro", "ear training", "jazz lesson", "lullaby", "reverb", "compressor", "threshold",
                     "equalizer", "preset", "plugin", "band louder", "band quieter", "play my album", "jam with me", "play it back", "what did I just play"]
        vocab += songs.filter { $0.level >= 2 }.map { $0.name.components(separatedBy: ",")[0] }
        vocab += ["Spotify", "on Spotify", "on YouTube", "Google Chrome", "YouTube", "Microsoft Word", "System Settings", "Safari", "OneDrive", "Downloads", "the weather", "look up"]
        ui("vocab " + Array(Set(vocab)).prefix(90).joined(separator: "|"))
    }
}
