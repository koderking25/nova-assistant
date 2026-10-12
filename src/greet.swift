// Hello: the weather, and a greeting that is different every time the app opens.

import Foundation

struct WeatherNow: Codable { var at: Double; var condition: String; var temp: Int; var feels: Int; var place: String }

enum Weather {
    static let cache = baseDir.appendingPathComponent("weather.json")
    static let cityFile = baseDir.appendingPathComponent("city.txt")
    static var latest: WeatherNow? = (try? JSONDecoder().decode(WeatherNow.self, from: Data(contentsOf: cache)))
    static var fetching = false

    static var city: String { ((try? String(contentsOf: cityFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var fresh: WeatherNow? { latest.flatMap { Date().timeIntervalSince1970 - $0.at < 1800 ? $0 : nil } }

    /// Asks a free weather service (wttr.in) for the weather here, or in the city the player has named.
    /// Only the city name, if one was given, is sent; otherwise the service goes by the network address.
    static func refresh(wait: Double = 0) {
        if Opt.fast || fresh != nil || fetching { return }
        fetching = true
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { fetching = false; done.signal() }
            let where_ = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            let r = runTool("/usr/bin/curl", ["-s", "-m", "4", "https://wttr.in/\(where_)?m&format=%C|%t|%f|%l"], timeout: 5)
            let f = r.out.components(separatedBy: "|")
            func degrees(_ s: String) -> Int? { Int(s.replacingOccurrences(of: "°C", with: "").replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)) }
            guard r.ok, f.count >= 4, let t = degrees(f[1]) else { return }
            let now = WeatherNow(at: Date().timeIntervalSince1970, condition: f[0].lowercased(), temp: t, feels: degrees(f[2]) ?? t,
                                 place: f[3].components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces).capitalized)
            latest = now
            if let d = try? JSONEncoder().encode(now) { try? d.write(to: cache) }
        }
        if wait > 0 { _ = done.wait(timeout: .now() + wait) }
    }

    /// A temperature as it is said aloud, in Celsius or Fahrenheit as the person prefers.
    static func shown(_ celsius: Int) -> String {
        let v = Profile.current.fahrenheit ? Int((Double(celsius) * 9 / 5 + 32).rounded()) : celsius
        return v < 0 ? "minus \(-v)" : "\(v)"
    }

    /// "14 degrees and raining in Springfield."
    static func sentence(_ w: WeatherNow) -> String {
        let c = w.condition
        let sky = c.contains("thunder") ? "stormy" : c.contains("snow") || c.contains("blizzard") ? "snowing" : c.contains("sleet") || c.contains("ice") ? "icy"
            : c.contains("drizzle") ? "drizzling" : c.contains("rain") || c.contains("shower") ? (c.contains("patchy") || c.contains("light") ? "a little rainy" : "raining")
            : c.contains("fog") || c.contains("mist") ? "foggy" : c.contains("overcast") ? "grey and overcast" : c.contains("partly") ? "partly cloudy"
            : c.contains("cloud") ? "cloudy" : c.contains("sunny") ? "sunny" : c.contains("clear") ? "clear" : c
        let temp = Weather.shown(w.temp)
        let chill = w.feels <= w.temp - 4 ? ", though it feels like \(Weather.shown(w.feels))" : ""
        return "\(temp) degrees and \(sky) in \(w.place)\(chill)"
    }

    /// A passing remark that fits the weather, or nothing.
    static func aside(_ w: WeatherNow) -> String {
        let c = w.condition
        if c.contains("thunder") { return pick(["Good night for something dramatic.", "Perfect weather for a minor key."]) }
        if c.contains("snow") { return pick(["Piano weather.", "A good day to stay in and write."]) }
        if c.contains("rain") || c.contains("drizzle") { return pick(["A good day to stay in and write.", "Rain on the window, piano inside. Not bad.", ""]) }
        if w.temp <= -8 { return pick(["Bundle up if you're heading out.", "Stay in. The piano's warmer."]) }
        if (c.contains("sunny") || c.contains("clear")) && w.temp >= 18 { return pick(["Lovely out. The piano will wait if you want some air.", ""]) }
        return ""
    }
}

extension Engine {
    /// The first thing said when the app opens. Built fresh each time from the hour, the day,
    /// the weather and what the player has been making, and never the same pieces twice running.
    func greeting() -> String { let p = greetingParts(); return p.rest.isEmpty ? p.hello : p.hello + " " + p.rest }

    static var hellos: [String] { ["Hello \(You.name). I'm \(Me.name).", "Still up, \(You.name)?", "Burning the midnight oil, \(You.name).", "Late one tonight, \(You.name).", "The small hours. Good time for music.",
        "Welcome back, \(You.name).", "Hello again, \(You.name).", "Good to hear you again, \(You.name).", "Good morning, \(You.name).", "Morning, \(You.name).", "Good morning, \(You.name).", "Rise and shine, \(You.name).",
        "Good afternoon, \(You.name).", "Afternoon, \(You.name).", "Good afternoon, \(You.name).", "Hello, \(You.name).", "Good evening, \(You.name).", "Evening, \(You.name).", "Good evening, \(You.name)."] }

    /// The hello on its own, then everything after it. The hello is one of a few known phrases,
    /// kept ready as sound, so it can be spoken the instant the app opens while the voice loads.
    func greetingParts() -> (hello: String, rest: String) {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let first = mem.sessions <= 1
        let away = first ? 0 : daysAgo(mem.lastOpened)
        let sameDay = !first && away == 0

        // Days in a row.
        let dayKey = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: now) }()
        if mem.lastDay != dayKey {
            mem.streak = (away == 1 ? (mem.streak ?? 1) + 1 : 1)
            mem.lastDay = dayKey
        }

        var hello: String
        if first { hello = "Hello \(You.name). I'm \(Me.name)." }
        else if hour < 5 { hello = pick(["Still up, \(You.name)?", "Burning the midnight oil, \(You.name).", "Late one tonight, \(You.name).", "The small hours. Good time for music."]) }
        else if sameDay && Int.random(in: 0..<2) == 0 { hello = pick(["Welcome back, \(You.name).", "Hello again, \(You.name).", "Good to hear you again, \(You.name)."]) }
        else if hour < 12 { hello = pick(["Good morning, \(You.name).", "Morning, \(You.name).", "Good morning, \(You.name).", "Rise and shine, \(You.name)."]) }
        else if hour < 18 { hello = pick(["Good afternoon, \(You.name).", "Afternoon, \(You.name).", "Good afternoon, \(You.name).", "Hello, \(You.name)."]) }
        else { hello = pick(["Good evening, \(You.name).", "Evening, \(You.name).", "Good evening, \(You.name).", "Hello, \(You.name)."]) }

        if Profile.isBirthday { hello = pick(["Happy birthday, \(You.name)!", "Happy birthday, \(You.name). Many happy returns.", "It's your birthday, \(You.name). Happy birthday!"]) }
        // One or two things worth saying, drawn from what is true today.
        var notes: [(kind: String, text: String)] = []
        Weather.refresh(wait: Opt.fast ? 0 : 1.5)
        if let w = Weather.fresh, !sameDay || Int.random(in: 0..<3) == 0 {
            let aside = Weather.aside(w)
            notes.append(("weather", pick(["It's \(Weather.sentence(w)).", "\(Weather.sentence(w).capitalizedFirst) right now.", "Outside it's \(Weather.sentence(w))."]) + (aside.isEmpty ? "" : " " + aside)))
        }
        let weekday = { () -> String in let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: now) }()
        if !sameDay {
            let weekend = ["Saturday", "Sunday"].contains(weekday)
            notes.append(("day", weekend ? pick(["Happy \(weekday).", "\(weekday), and nowhere to be.", "A whole \(weekday) ahead of you."])
                                         : weekday == "Monday" ? pick(["Monday. A fresh week.", "New week, new ideas."])
                                         : weekday == "Friday" ? pick(["Friday at last.", "It's Friday. You made it."]) : pick(["It's \(weekday).", "Happy \(weekday)."])))
        }
        if away >= 3 { notes.append(("away", pick(["It's been \(away) days. The piano missed you.", "\(away) days away. Good to have you back.", "It's been a little while."]))) }
        if let s = mem.streak, s >= 3 { notes.append(("streak", pick(["That's \(s) days in a row.", "\(s) days running now. It shows.", "Day \(s) of the streak."]))) }
        if mem.pieces.count >= 5, Int.random(in: 0..<2) == 0 {
            let n = mem.pieces.count
            var counts: [String: Int] = [:]
            for p in mem.pieces { counts[p.key, default: 0] += 1 }
            let fav = counts.max { $0.value < $1.value }?.key ?? ""
            notes.append(("pieces", pick(["You've written \(n) pieces now.", "\(n) pieces in your album so far.", fav.isEmpty ? "\(n) pieces and counting." : "You keep coming back to \(fav). It suits you."])))
        }
        if let p = mem.pieces.last, daysAgo(p.date) <= 1, Int.random(in: 0..<3) == 0 {
            notes.append(("last", pick(["That last piece in \(p.key) is still in my head.", "I've been thinking about the one in \(p.key)."])))
        }
        if Int.random(in: 0..<5) == 0, let fact = Engine.musicFacts.randomElement() { notes.append(("fact", pick(["Something for today: ", "Did you know? "]) + fact)) }

        // Leave out whatever was said last time, then take the weather if there is any and one other.
        let before = Set(mem.greeted ?? [])
        var chosen: [(kind: String, text: String)] = []
        let rest = notes.filter { $0.kind != "weather" }
        let unseen = rest.filter { !before.contains($0.kind) }
        if let extra = (unseen.isEmpty ? rest : unseen).randomElement() { chosen.append(extra) }
        if let w = notes.first(where: { $0.kind == "weather" }) { chosen.append(w) }
        mem.greeted = chosen.map { $0.kind }

        let offers = hour < 5 ? ["What are we making?", "I'm listening.", "Go on, play me something."]
            : ["What are we making today?", "Say the word when you're ready.", "I'm all ears.", "Shall we write something?", "Where would you like to start?", "Ready when you are.", "What's it going to be?"]
        let hint = mem.sessions <= 3 ? " Say \(Me.name) and tell me what you'd like. \(Me.name), what can you do, is a good place to start." : ""
        var text = ""
        for c in chosen where (hello + " " + text + " " + c.text).count < 200 { text += (text.isEmpty ? "" : " ") + c.text }
        text += (first ? "" : (text.isEmpty ? "" : " ") + pick(offers)) + hint
        return (hello, text.trimmingCharacters(in: .whitespaces))
    }

    /// Weather questions, and being told where he lives.
    func weatherTalk(_ h: Heard) -> String? {
        if let place = h.after("my city is", "i live in", "im in", "set my city to", "weather for", "i am in", "change my city to"), h.has("city", "live", "weather", "im in", "i am in"), !place.isEmpty, place.split(separator: " ").count <= 4 {
            let name = place.capitalized
            if !Opt.fast { try? name.write(to: Weather.cityFile, atomically: true, encoding: .utf8); Weather.latest = nil; Weather.refresh(wait: 3) }
            if let w = Weather.fresh { return "Got it, \(name). It's \(Weather.sentence(w)) right now." }
            return "Got it. I'll use \(name) for the weather."
        }
        guard h.has("weather", "raining", "rain", "snowing", "snow", "cold out", "hot out", "warm out", "temperature", "outside", "forecast", "need a jacket", "need a coat", "umbrella") else { return nil }
        if Opt.fast { return "It's 14 degrees and cloudy." }
        Weather.refresh(wait: 4)
        guard let w = Weather.fresh else { return "I couldn't reach the weather service just now." }
        if h.has("jacket", "coat") { return w.feels < 12 ? "Yes, take one. It's \(Weather.sentence(w))." : "You'll be fine without. It's \(Weather.sentence(w))." }
        if h.has("umbrella", "raining", "rain") { return (w.condition.contains("rain") || w.condition.contains("drizzle") || w.condition.contains("shower")) ? "Yes. It's \(Weather.sentence(w))." : "No rain. It's \(Weather.sentence(w))." }
        let aside = Weather.aside(w)
        return "It's \(Weather.sentence(w))." + (aside.isEmpty ? "" : " " + aside)
    }
}

func greetSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let w = WeatherNow(at: Date().timeIntervalSince1970, condition: "patchy rain nearby", temp: 14, feels: 13, place: "Springfield")
    let cold = WeatherNow(at: 0, condition: "light snow", temp: -6, feels: -12, place: "Toronto")
    check("weather: read out in plain words", Weather.sentence(w) == "14 degrees and a little rainy in Springfield" && Weather.sentence(cold) == "minus 6 degrees and snowing in Toronto, though it feels like minus 12", Weather.sentence(cold))
    let saved = engine.mem
    Weather.latest = w
    var seen = Set<String>()
    for _ in 0..<12 { seen.insert(engine.greeting()) }
    let sample = engine.greeting()
    Weather.latest = nil
    engine.mem = saved
    check("greeting: different each time, with the weather, and no lesson report", seen.count >= 8 && seen.allSatisfy { !$0.contains("You are on part") && $0.count < 330 } && seen.contains { $0.contains("Springfield") }, sample)
}
