// More of an everyday assistant: things to remember, lists, alarms, focus time, a morning
// briefing, sums with units and dates, and a few facts about the Mac itself.
//
// Notes, lists and alarms are kept in the app's own folder on this Mac and go nowhere else.

import Foundation

struct Keepsakes: Codable {
    var notes: [String] = []
    var lists: [String: [String]] = [:]
    var alarms: [Double] = []            // times, as seconds since 1970

    static let file = baseDir.appendingPathComponent("keepsakes.json")
    static var all: Keepsakes = (try? JSONDecoder().decode(Keepsakes.self, from: Data(contentsOf: file))) ?? Keepsakes()
    static func save() {
        if Opt.fast { return }
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: file, options: .atomic) }
    }
}

let unitTable: [(names: [String], kind: String, toBase: Double)] = [
    (["mile", "miles"], "length", 1609.344), (["kilometre", "kilometres", "kilometer", "kilometers", "km", "k"], "length", 1000), (["metre", "metres", "meter", "meters"], "length", 1),
    (["foot", "feet", "ft"], "length", 0.3048), (["inch", "inches"], "length", 0.0254), (["centimetre", "centimetres", "centimeter", "centimeters", "cm"], "length", 0.01), (["yard", "yards"], "length", 0.9144),
    (["pound", "pounds", "lb", "lbs"], "weight", 0.45359237), (["kilogram", "kilograms", "kilo", "kilos", "kg"], "weight", 1), (["ounce", "ounces", "oz"], "weight", 0.028349523), (["gram", "grams"], "weight", 0.001),
    (["stone", "stones"], "weight", 6.35029318),
    (["litre", "litres", "liter", "liters"], "volume", 1), (["gallon", "gallons"], "volume", 3.785411784), (["cup", "cups"], "volume", 0.2365882365), (["millilitre", "millilitres", "milliliter", "milliliters", "ml"], "volume", 0.001),
    (["pint", "pints"], "volume", 0.473176473), (["tablespoon", "tablespoons"], "volume", 0.0147867648), (["teaspoon", "teaspoons"], "volume", 0.00492892159),
    (["hour", "hours"], "time", 3600), (["minute", "minutes"], "time", 60), (["second", "seconds"], "time", 1), (["day", "days"], "time", 86400), (["week", "weeks"], "time", 604800),
]

let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

func tidyNumber(_ v: Double) -> String {
    if abs(v - v.rounded()) < 0.005 { return String(Int(v.rounded())) }
    return String(format: abs(v) >= 100 ? "%.0f" : abs(v) >= 10 ? "%.1f" : "%.2f", v)
}

extension Engine {
    /// A time of day said aloud: "seven thirty pm", "7 30", "730 in the morning", "noon". The next time it comes round.
    func clockTime(in h: Heard) -> Date? {
        var hour = -1, minute = 0
        if h.has("noon", "midday") { hour = 12 } else if h.has("midnight") { hour = 0 }
        let nums = h.words.compactMap { w -> Int? in Int(w) ?? (["a", "an", "to", "for", "one"].contains(w) && w != "one" ? nil : numberWords[w]) }
        if hour < 0, let first = nums.first {
            if first >= 100, first <= 2359 { hour = first / 100; minute = first % 100 }
            else { hour = first; if nums.count > 1, nums[1] < 60 { minute = nums[1] } }
        }
        if h.has("half past"), let first = nums.first { hour = first; minute = 30 }
        if h.has("quarter past"), let first = nums.first { hour = first; minute = 15 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let pm = h.has("pm", "p m", "tonight", "evening", "afternoon"), am = h.has("am", "a m", "morning")
        if pm, hour < 12 { hour += 12 }
        if am, hour == 12 { hour = 0 }
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: Date())
        c.hour = hour; c.minute = minute; c.second = 0
        guard var when = cal.date(from: c) else { return nil }
        // With no "am" or "pm", it is the next time the clock shows that hour.
        if when <= Date(), !am, !pm, hour < 12, let later = cal.date(byAdding: .hour, value: 12, to: when), later > Date() { when = later }
        if when <= Date() { when = cal.date(byAdding: .day, value: 1, to: when) ?? when }
        return when
    }

    func spokenTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: d) + (Calendar.current.isDateInToday(d) ? "" : " tomorrow")
    }

    func armAlarm(_ at: Double) {
        if Opt.fast { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.5, at - Date().timeIntervalSince1970)) {
            guard Keepsakes.all.alarms.contains(at) else { return }           // cancelled in the meantime
            Keepsakes.all.alarms.removeAll { $0 == at }
            Keepsakes.save()
            for _ in 0..<3 { self.chime([79, 84, 88, 84]); usleep(700_000) }
            ui("flash good")
            self.announce("\(You.name), it's \(self.spokenTime(Date())). This is your alarm.")
        }
    }

    /// Alarms that were set before the app was last closed are picked up again.
    func restoreAlarms() {
        let nowT = Date().timeIntervalSince1970
        Keepsakes.all.alarms = Keepsakes.all.alarms.filter { $0 > nowT }
        for a in Keepsakes.all.alarms { armAlarm(a) }
    }

    func listName(_ h: Heard) -> String {
        for (said, name) in [("shopping", "shopping"), ("grocery", "shopping"), ("groceries", "shopping"), ("to do", "to do"), ("todo", "to do"), ("task", "to do"), ("tasks", "to do"), ("practice", "practice"),
                             ("homework", "homework"), ("packing", "packing"), ("wish", "wish")] where h.has(said) { return name }
        return "to do"
    }

    func extrasHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        // Things to remember.
        if let note = h.after("remember that", "remember to", "make a note that", "make a note", "note that", "take a note", "note to self", "dont let me forget to", "dont let me forget"), !h.has("spotify", "track") {
            Keepsakes.all.notes.append(note)
            Keepsakes.save()
            reply(pick(["I'll remember that.", "Noted.", "Got it, I've written that down."])); return "note"
        }
        if h.has("what did i ask you to remember", "what do you remember", "read my notes", "what are my notes", "my notes", "what did i tell you to remember", "what was i supposed to remember") && !h.has("open", "app") {
            let n = Keepsakes.all.notes
            reply(n.isEmpty ? "You haven't asked me to remember anything yet." : "You asked me to remember: " + n.suffix(6).joined(separator: ". Also: ") + "."); return "notes"
        }
        if h.has("forget my notes", "clear my notes", "delete my notes", "forget everything i told you", "forget what i told you") {
            guard !Keepsakes.all.notes.isEmpty else { reply("There's nothing to forget."); return "notes clear" }
            pendingConfirm = { [unowned self] in Keepsakes.all.notes = []; Keepsakes.save(); self.run { g in self.say("Forgotten.", g) } }
            pendingUntil = now() + 20
            reply("Forget all \(Keepsakes.all.notes.count) of your notes? Say yes or no."); return "notes clear?"
        }
        // Lists.
        if h.has("list"), !h.has("songs", "tracks", "menus", "buttons", "voices", "files", "plugins", "playlist") {
            let name = listName(h)
            if let item = h.after("add", "put"), h.has("to my", "to the", "on my", "on the") {
                let thing = item.components(separatedBy: " to my ")[0].components(separatedBy: " to the ")[0].components(separatedBy: " on my ")[0].components(separatedBy: " on the ")[0]
                guard !thing.isEmpty else { return nil }
                Keepsakes.all.lists[name, default: []].append(thing)
                Keepsakes.save()
                reply("Added \(thing) to your \(name) list."); return "list add \(name): \(thing)"
            }
            if let item = h.after("remove", "take", "cross off", "tick off", "delete") , h.has("from my", "from the", "off my", "off the") {
                let thing = item.components(separatedBy: " from ")[0].components(separatedBy: " off ")[0]
                let before = Keepsakes.all.lists[name]?.count ?? 0
                Keepsakes.all.lists[name]?.removeAll { $0 == thing || $0.contains(thing) }
                Keepsakes.save()
                reply((Keepsakes.all.lists[name]?.count ?? 0) < before ? "\(thing.capitalizedFirst) is off your \(name) list." : "I can't find \(thing) on your \(name) list."); return "list remove \(name): \(thing)"
            }
            if h.has("clear", "empty", "wipe") {
                guard !(Keepsakes.all.lists[name] ?? []).isEmpty else { reply("Your \(name) list is already empty."); return "list clear" }
                pendingConfirm = { [unowned self] in Keepsakes.all.lists[name] = []; Keepsakes.save(); self.run { g in self.say("Your \(name) list is empty.", g) } }
                pendingUntil = now() + 20
                reply("Clear your whole \(name) list? Say yes or no."); return "list clear?"
            }
            if h.has("whats", "what", "read", "tell", "anything", "show", "hear") {
                let items = Keepsakes.all.lists[name] ?? []
                reply(items.isEmpty ? "Your \(name) list is empty. Say, add milk to my \(name) list." : "On your \(name) list: \(spokenList(items, limit: 12))."); return "list read \(name)"
            }
        }
        // Alarms.
        if h.has("alarm", "alarms", "wake me") {
            if h.has("cancel", "delete", "remove", "turn off", "stop", "clear") {
                let n = Keepsakes.all.alarms.count
                Keepsakes.all.alarms = []; Keepsakes.save()
                reply(n == 0 ? "There are no alarms set." : n == 1 ? "Your alarm is cancelled." : "All \(n) alarms are cancelled."); return "alarm cancel"
            }
            if h.has("what", "whats", "any", "which", "do i have", "when") && !h.has("set", "for") {
                let a = Keepsakes.all.alarms.sorted().map { spokenTime(Date(timeIntervalSince1970: $0)) }
                reply(a.isEmpty ? "No alarms are set." : "You have an alarm for \(spokenList(a))."); return "alarm list"
            }
            guard let when = clockTime(in: h) else { reply("For what time? Say something like, set an alarm for seven thirty."); return "alarm?" }
            let at = when.timeIntervalSince1970
            Keepsakes.all.alarms.append(at); Keepsakes.save()
            armAlarm(at)
            reply("Alarm set for \(spokenTime(when)). I need to be left running for it to sound."); return "alarm set"
        }
        // Focus time.
        if h.has("focus session", "focus time", "focus mode", "pomodoro", "help me focus", "focus for", "study session", "practice session", "deep work") {
            let minutes = h.number ?? 25
            timer(minutes * 60, label: "your \(minutes) minutes of focus are up. Take a short break")
            reply("\(minutes) minutes of focus, starting now. I'll stay quiet and tell you when it's time for a break."); return "focus \(minutes)"
        }
        // A briefing.
        if h.has("brief me", "briefing", "whats my day", "catch me up", "whats happening today", "start my day", "morning update", "daily update", "whats new today") {
            run { g in
                let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"
                var text = "It's \(f.string(from: Date()))."
                if !Opt.fast { Weather.refresh(wait: 3) }
                if let w = Weather.fresh { text += " Outside it's \(Weather.sentence(w))." }
                let alarms = Keepsakes.all.alarms.sorted().map { self.spokenTime(Date(timeIntervalSince1970: $0)) }
                if !alarms.isEmpty { text += " You have an alarm for \(spokenList(alarms))." }
                let todo = Keepsakes.all.lists["to do"] ?? []
                if !todo.isEmpty { text += " On your to do list: \(spokenList(todo, limit: 5))." }
                if let last = Keepsakes.all.notes.last { text += " And you asked me to remember: \(last)." }
                if let s = self.mem.streak, s >= 3, Profile.current.plays { text += " That's \(s) days in a row at the piano." }
                self.say(text + " That's everything.", g)
            }
            return "briefing"
        }
        // Units: "convert 5 miles to kilometres", "how many cups in a litre", "what is 70 fahrenheit in celsius".
        if h.has("fahrenheit", "celsius", "centigrade"), let n = h.words.compactMap({ Double($0) ?? numberWords[$0].map(Double.init) }).first, h.has("in", "to", "convert", "whats", "what") {
            let fromF = h.words.firstIndex(where: { $0 == "fahrenheit" }) ?? 99 < (h.words.firstIndex(where: { $0 == "celsius" || $0 == "centigrade" }) ?? 99)
            let v = h.has("minus", "negative") ? -n : n
            reply(fromF ? "\(tidyNumber(v)) Fahrenheit is \(tidyNumber((v - 32) * 5 / 9)) Celsius." : "\(tidyNumber(v)) Celsius is \(tidyNumber(v * 9 / 5 + 32)) Fahrenheit."); return "convert"
        }
        if h.has("convert", "how many", "how much is", "in", "to"), !h.has("spotify", "youtube", "track", "list") {
            let found = h.words.enumerated().compactMap { i, w in unitTable.first { $0.names.contains(w) }.map { (i, w, $0) } }
            if found.count >= 2, found[0].2.kind == found[1].2.kind, found[0].2.names != found[1].2.names {
                let amount = h.words.compactMap { Double($0) ?? numberWords[$0].map(Double.init) }.first ?? 1
                // "how many cups in a litre" asks for the first unit; "5 miles in kilometres" for the second.
                let reverse = h.has("how many") && !h.words.prefix(found[0].0).contains(where: { Double($0) != nil || numberWords[$0] != nil })
                let from = reverse ? found[1] : found[0], to = reverse ? found[0] : found[1]
                let result = amount * from.2.toBase / to.2.toBase
                reply("\(tidyNumber(amount)) \(from.1) is \(tidyNumber(result)) \(to.1)."); return "convert"
            }
        }
        // Dates: "how many days until Christmas", "how long until the 25th of December".
        if h.has("days until", "days till", "days to", "how long until", "how long till", "how many sleeps", "days left until") {
            let cal = Calendar.current
            var month = -1, day = -1
            for (said, m, d) in [("christmas", 12, 25), ("new year", 1, 1), ("new years", 1, 1), ("halloween", 10, 31), ("valentines", 2, 14)] where h.has(said) { month = m; day = d }
            if month < 0, let mi = h.words.firstIndex(where: { monthNames.contains($0) }) {
                month = monthNames.firstIndex(of: h.words[mi])! + 1
                day = h.words.compactMap { w in Int(w.replacingOccurrences(of: "st", with: "").replacingOccurrences(of: "nd", with: "").replacingOccurrences(of: "rd", with: "").replacingOccurrences(of: "th", with: "")) ?? numberWords[w] }.first { (1...31).contains($0) } ?? 1
            }
            if h.has("weekend") {
                let wd = cal.component(.weekday, from: Date())
                reply(wd == 7 || wd == 1 ? "It is the weekend." : "\(7 - wd) day\(7 - wd == 1 ? "" : "s") until Saturday."); return "days until"
            }
            guard month > 0 else { return nil }
            var c = cal.dateComponents([.year], from: Date()); c.month = month; c.day = day
            guard var target = cal.date(from: c) else { return nil }
            let today = cal.startOfDay(for: Date())
            if target < today { c.year = (c.year ?? 0) + 1; target = cal.date(from: c) ?? target }
            let n = cal.dateComponents([.day], from: today, to: target).day ?? 0
            reply(n == 0 ? "That's today." : n == 1 ? "That's tomorrow." : "\(n) days."); return "days until"
        }
        // The Mac itself.
        if h.has("storage", "disk space", "space left", "space on my mac", "hard drive", "how full") && h.has("how", "much", "whats", "left", "free", "check") {
            run { g in
                let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
                guard !Opt.fast, let free = v?.volumeAvailableCapacityForImportantUsage, let total = v?.volumeTotalCapacity, total > 0 else { self.say("I couldn't read the disk just now.", g); return }
                let gb = Double(free) / 1e9
                self.say("You have about \(tidyNumber(gb)) gigabytes free, out of \(Int(Double(total) / 1e9))." + (gb < 10 ? " That's getting tight." : ""), g)
            }
            return "storage"
        }
        if h.has("wifi", "wi fi", "am i online", "am i connected", "internet working", "is the internet") {
            run { g in
                if Opt.fast { self.say("Online.", g); return }
                let online = runTool("/usr/bin/curl", ["-s", "-m", "4", "-o", "/dev/null", "-w", "%{http_code}", "https://www.apple.com/library/test/success.html"], timeout: 6).out.contains("200")
                self.say(online ? "Yes, you're online." : "I can't reach the internet right now.", g)
            }
            return "online"
        }
        // Choosing.
        if h.starts("choose between", "pick between", "decide between", "choose for me", "pick one", "should i have"), h.has("or") {
            let rest = h.after("choose between", "pick between", "decide between", "choose for me", "pick one", "should i have") ?? ""
            let options = rest.components(separatedBy: " or ").map { $0.replacingOccurrences(of: " and ", with: " ").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if options.count >= 2 { reply("\(Opt.fast ? options[0].capitalizedFirst : options.randomElement()!.capitalizedFirst)."); return "choose" }
        }
        return nil
    }
}

func extrasSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    engine.goHomeQuietly()
    let saved = Keepsakes.all
    Keepsakes.all = Keepsakes()
    let a = ["remember that the recital is on Friday", "what did I ask you to remember", "add milk to my shopping list", "add call grandma to my list", "what's on my shopping list",
             "remove milk from my shopping list", "set an alarm for seven thirty am", "what alarms do I have", "cancel the alarm", "start a focus session for 20 minutes", "brief me",
             "convert 5 miles to kilometres", "how many cups in a litre", "what is 70 fahrenheit in celsius", "how many days until christmas", "choose between pizza or pasta"].map { engine.hear($0) }
    let state = "\(Keepsakes.all.notes) \(Keepsakes.all.lists["shopping"] ?? []) \(Keepsakes.all.lists["to do"] ?? [])"
    Keepsakes.all = saved
    check("extras: notes, lists, alarms, focus time, a briefing, conversions, dates and choosing are understood",
          a == ["note", "notes", "list add shopping: milk", "list add to do: call grandma", "list read shopping", "list remove shopping: milk", "alarm set", "alarm list", "alarm cancel", "focus 20", "briefing",
                "convert", "convert", "convert", "days until", "choose"] && state == "[\"the recital is on friday\"] [] [\"call grandma\"]", a.joined(separator: " / ") + " :: " + state)
    let t = engine.clockTime(in: Heard("set an alarm for 7 30 pm")).map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
    let t2 = engine.clockTime(in: Heard("wake me at 645 in the morning")).map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
    check("extras: a spoken time of day is read correctly", t?.hour == 19 && t?.minute == 30 && t2?.hour == 6 && t2?.minute == 45, "\(String(describing: t)) \(String(describing: t2))")
    // The assistant's name, and the person's.
    let before = Profile.current
    let n = [engine.hear("what's your name"), engine.hear("change your name to Luna"), engine.hear("yes")]
    let renamed = Me.name
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let heardNew = Ears().partial("Luna new composition", final: true, engine: engine)
    let newOK = engine.mode == .compose
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let heardOld = Ears().partial("Jarvis new composition", final: true, engine: engine)
    let oldIgnored = engine.mode != .compose
    let bd = [engine.hear("my birthday is the third of March"), Profile.current.birthday, engine.hear("install the natural voice"), engine.hear("no")]
    let me = engine.hear("call me Sam")
    let named = You.name
    Profile.current = Profile(user: "", assistant: "Nova", city: "", fahrenheit: false, about: "", plays: true, done: true)
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let nova = [Ears().partial("Nova new composition", final: true, engine: engine), engine.mode == .compose ? "ok" : "no"]
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let split = [Ears().partial("hey no va new composition", final: true, engine: engine), engine.mode == .compose ? "ok" : "no"]
    engine.goHomeQuietly(); engine.lastSpokenAt = now() - 30; engine.lastSpoken = ""
    let talk = Ears().partial("there was a supernova in november over there", final: true, engine: engine)
    Profile.current = before
    check("profile: the assistant can be renamed, the new name wakes it and the old one no longer does, and the person can say their own name",
          n == ["name", "name? Luna", "confirmed"] && renamed == "Luna" && heardNew == "acted" && newOK && oldIgnored && me == "user Sam" && named == "Sam"
          && nova == ["acted", "ok"] && split == ["acted", "ok"] && talk == "not for me" && bd[0] == "birthday 03-03" && bd[1] == "03-03" && bd[2].hasPrefix("voice "),
          "\(bd) \(n) \(renamed) \(heardNew) \(newOK) \(heardOld) \(oldIgnored) \(me) \(named) \(nova) \(split) \(talk)")
    engine.goHomeQuietly()
}
