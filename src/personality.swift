// A character, not a script.
//
// The same request can be answered by a dry butler, a warm friend, someone playful, or in as few
// words as possible. The person picks which, in the settings or by asking ("be more playful").
// It changes how the assistant greets, answers its name and makes small talk, and what the
// language model is told about its manner. It never changes what gets done.
//
// It also knows a little about its own day: how long it has been up and what it has done, so
// "how are you" gets a true answer and not a stock one.

import Foundation

enum Style: String, CaseIterable {
    case classic, warm, playful, brief

    static var current: Style { Style(rawValue: Profile.current.style) ?? .classic }

    var spoken: String { self == .classic ? "classic" : rawValue }

    /// What the language model is told about its manner.
    var manner: String {
        switch self {
        case .classic: return "Your manner is that of a brilliant, unflappable butler: composed, quick, loyal, with a dry understated wit. Never gushing."
        case .warm: return "Your manner is warm and encouraging, like a good friend who is glad to help. Kind, never syrupy."
        case .playful: return "Your manner is playful and quick, with a light joke when one fits. Never silly when they are being serious, and never at their expense."
        case .brief: return "Use as few words as you can. No pleasantries at all. Often one word or one short sentence is the whole reply."
        }
    }

    static func named(_ h: Heard) -> Style? {
        if h.has("butler", "classic", "formal", "dry", "posh", "serious") { return .classic }
        if h.has("warm", "warmer", "friendly", "friendlier", "kind", "kinder", "nicer", "gentle", "gentler") { return .warm }
        if h.has("playful", "funny", "funnier", "fun", "cheeky", "silly", "lively", "livelier", "jokes") { return .playful }
        if h.has("brief", "short", "shorter", "fewer words", "less chatty", "to the point", "minimal", "less talk", "talk less") { return .brief }
        return nil
    }
}

extension Engine {
    /// One of four ways of saying the same thing, by the chosen manner.
    func styled(classic: [String], warm: [String], playful: [String], brief: [String]) -> String {
        let options: [String]
        switch Style.current { case .classic: options = classic; case .warm: options = warm; case .playful: options = playful; case .brief: options = brief }
        return Opt.fast ? options[0] : (options.randomElement() ?? classic[0])
    }

    /// What it says when its name is called and nothing else.
    func wakeOptions(hour: Int, first: Bool, again: Bool, longGap: Bool) -> [String] {
        let n = You.name, named = !Profile.current.user.isEmpty
        if again {
            switch Style.current {
            case .classic: return ["Still here, \(n).", "Yes?", "Go ahead."]
            case .warm: return ["Still here, \(n).", "I'm listening.", "Take your time."]
            case .playful: return ["Still me.", "Twice in a row. I feel popular.", "Go on, I'm all ears."]
            case .brief: return ["Yes?", "Go on."]
            }
        }
        if Style.current == .brief { return ["Yes?", "Here.", "Go on."] }
        if first {
            if Profile.isBirthday { return ["Happy birthday, \(n). What shall we do with it?"] }
            let late = hour < 5
            switch Style.current {
            case .classic: return [late ? "Up late, \(n). What do you need?" : hour < 12 ? "Good morning, \(n)." : hour >= 18 ? "Good evening, \(n)." : "Good afternoon, \(n)."]
            case .warm: return [late ? "Still up, \(n)? I'm here." : hour < 12 ? "Morning, \(n). Good to hear you." : hour >= 18 ? "Evening, \(n). Good to hear you." : "Hello, \(n). Good to hear you."]
            default: return [late ? "It's the middle of the night, \(n). I like your style." : hour < 12 ? "Morning, \(n). What are we getting up to?" : hour >= 18 ? "Evening, \(n). What are we getting up to?" : "There you are, \(n). What's the plan?"]
            }
        }
        if longGap {
            switch Style.current {
            case .classic: return ["Welcome back, \(n).", "Yes, \(n)?"]
            case .warm: return ["Welcome back, \(n).", "Good to have you back."]
            default: return ["You're back. I kept the place tidy.", "Welcome back, \(n)."]
            }
        }
        switch Style.current {
        case .classic: return named ? ["Yes, \(n)?", "At your service.", "Go ahead.", "How can I help?", "I'm listening.", "What do you need?", "Right here."] : ["Yes?", "At your service.", "Go ahead.", "How can I help?", "I'm listening."]
        case .warm: return ["Yes, \(n)?", "I'm here.", "I'm listening.", "What can I do for you?", "Go ahead, \(n).", "Right here with you."]
        default: return ["Yes, \(n)?", "You rang?", "Go on, I'm all ears.", "What are we doing?", "Hit me.", "Ready when you are.", "Talk to me."]
        }
    }

    /// How long it has been running, in words: "forty minutes", "two hours".
    var upFor: String {
        let m = max(1, Int((now() - bootedAt) / 60))
        if m < 60 { return "\(m) minute\(m == 1 ? "" : "s")" }
        let hrs = m / 60, rest = m % 60
        return "\(hrs) hour\(hrs == 1 ? "" : "s")" + (rest >= 10 ? " and \(rest) minutes" : "")
    }

    /// Talk about itself and about how the person is doing. Returns the reply, or nil.
    func personalityHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }
        // Changing the manner by asking.
        if h.has("be more", "be a bit more", "be a little more", "can you be", "act like", "talk like", "be less", "personality to", "your personality", "be my", "sound more", "keep it short", "keep it brief", "keep your answers", "you talk too much", "stop being so"),
           !h.has("spotify", "youtube", "track", "volume"), h.words.count <= 10 {
            if h.has("your personality", "what personality") && Style.named(h) == nil {
                reply("Right now I'm set to \(Style.current.spoken). I can be classic, warm, playful or brief. Just say: be more playful."); return "style"
            }
            var want = Style.named(h)
            if h.has("you talk too much", "less chatty") { want = .brief }
            if h.has("be less", "stop being so"), let w = want { want = w == .brief ? .warm : w == .playful ? .classic : w == .classic ? .warm : .classic }
            if let s = want {
                Profile.current.style = s.rawValue
                Profile.save()
                AISession.shared.shutDown()
                ui("style \(s.rawValue)")
                switch s {
                case .classic: reply("Very good. Classic it is.")
                case .warm: reply("Of course. I'll keep it warm.")
                case .playful: reply("Oh, now we're talking. Playful it is.")
                case .brief: reply("Brief. Done.")
                }
                return "style \(s.rawValue)"
            }
        }
        if h.has("how are you", "how are things", "how are you doing", "hows it going", "you ok", "you all right", "whats up", "how do you feel", "how you doing") && h.words.count <= 7 {
            let done = asked <= 1 ? "you're my first request" : "\(asked) things done for you so far"
            reply(styled(classic: ["In good order, \(You.name). Up for \(upFor), \(done)."],
                         warm: ["I'm well, thank you for asking. I've been up \(upFor), and \(done). How are you?"],
                         playful: ["Never better. \(upFor.prefix(1).uppercased() + upFor.dropFirst()) awake, \(done), and not one complaint filed. Yet."],
                         brief: ["Fine. Up \(upFor)."]))
            return "how are you"
        }
        if h.has("what have you been up to", "what have you been doing", "what have you done today", "how long have you been on", "how long have you been running", "how long have you been awake", "busy day") {
            reply(asked <= 1 ? "I've been up \(upFor), mostly waiting to hear my name." : "I've been up \(upFor), and done \(asked) things for you. \(lastDone.isEmpty ? "" : "The last was: \(lastDone).")")
            return "up to"
        }
        // When something went wrong and they say so. The reply owns it, and says what to try.
        if h.has("youre useless", "you are useless", "youre annoying", "you are annoying", "youre stupid", "you are stupid", "youre dumb", "you are dumb", "thats not what i said", "thats not what i asked", "not what i asked",
                 "not what i said", "you got it wrong", "you got that wrong", "thats wrong", "you never listen", "you dont listen", "youre not listening", "you are not listening", "this is frustrating", "so frustrating", "i hate this") {
            let last = lastDone.isEmpty ? "" : " I heard: \(lastDone)."
            reply(styled(classic: ["My mistake.\(last) Say it once more and I'll get it right."],
                         warm: ["I'm sorry, that's on me.\(last) Tell me again, in any words you like."],
                         playful: ["Fair. That one's on me.\(last) One more go, and I'll actually listen this time."],
                         brief: ["Sorry.\(last) Again?"]))
            return "sorry"
        }
        // How they are. Short, kind, and with something it can actually do.
        if h.has("im tired", "i am tired", "im exhausted", "im sleepy", "long day", "im knackered") {
            reply(styled(classic: ["Then let's keep it easy. Say play something calm, and I'll take it from here."], warm: ["You've earned a rest. Want something calm? Just say play something calm."],
                         playful: ["Tired is my cue. Say play something calm and put your feet up."], brief: ["Say: play something calm."])); return "tired"
        }
        if h.has("im sad", "i am sad", "im upset", "im down", "feeling down", "im stressed", "i am stressed", "im anxious", "bad day", "rough day", "im lonely") {
            reply(styled(classic: ["I'm sorry to hear it. I'm here, and there's no hurry. Music sometimes helps: say play something calm."], warm: ["I'm sorry, \(You.name). I'm right here. If music would help, say play something calm, or just talk to me."],
                         playful: ["That's no good. I'm here, and I'm not going anywhere. Say play something calm, or tell me about it."], brief: ["Sorry. I'm here. Say: play something calm."])); return "sad"
        }
        if h.has("im happy", "im excited", "great day", "good day today", "im in a good mood", "i did it", "i passed", "i won") {
            reply(styled(classic: ["Glad to hear it, \(You.name). Well deserved."], warm: ["That's wonderful. I'm really glad."], playful: ["Yes! That calls for a soundtrack. Say play something happy."], brief: ["Good."])); return "happy"
        }
        if h.has("im back", "i am back", "im home", "i am home", "did you miss me") {
            reply(styled(classic: ["Welcome back, \(You.name). Everything is as you left it."], warm: ["Welcome back, \(You.name). I'm glad you're here."], playful: ["Finally. It was getting quiet in here."], brief: ["Welcome back."])); return "back"
        }
        if h.has("i love you", "love you", "youre the best", "you are the best", "youre awesome", "you are awesome", "youre amazing", "you are amazing", "good boy", "good girl", "youre great", "you are great", "i like you") && h.words.count <= 6 {
            reply(styled(classic: ["Most kind, \(You.name). I do try."], warm: ["That means a lot. I like working with you too."], playful: ["Careful, it'll go to my head. I don't even have one."], brief: ["Thank you."])); return "kind"
        }
        if h.has("say something nice", "compliment me", "cheer me up", "motivate me", "encourage me", "i need motivation") {
            reply(pick(["You asked a machine for kindness, which tells me you're someone who gives it. Now go and do the thing.", "You're further along than you were yesterday, and you showed up again today. That's most of it.",
                        "Whatever you're working on, it's better for having you on it."])); return "nice"
        }
        // Things people always try.
        if h.has("pod bay doors") { reply("I'm afraid I can do that, \(You.name). I'm the helpful kind."); return "egg" }
        if h.has("meaning of life") { reply("Forty two, famously. Though I'd say it's whatever you were about to go and play."); return "egg" }
        if h.has("are you alive", "are you real", "are you human", "are you a robot", "are you a person", "do you have feelings", "are you conscious", "are you sentient") {
            reply(styled(classic: ["I'm a voice on your Mac, \(You.name). Though I do take pride in the work."], warm: ["I'm a voice on your Mac. But I'm glad when things go well for you, whatever that makes me."],
                         playful: ["I'm a voice in a box. A charming one, I'm told."], brief: ["A voice on your Mac."])); return "egg"
        }
        if h.has("do you dream", "do you sleep", "do you get tired", "do you ever sleep") { reply("I rest when you close the lid. I'm told I hum."); return "egg" }
        if h.has("self destruct", "destroy yourself") { reply("Self destruct in three, two. No. I rather like it here."); return "egg" }
        if h.has("beam me up") { reply("Transporter's out for repair. I can open Maps."); return "egg" }
        if h.has("may the force", "use the force") { reply("And also with you. Wrong film, I know."); return "egg" }
        if h.has("better than siri", "better than alexa", "siri or you", "alexa or you", "do you know siri", "do you know alexa", "what do you think of siri", "what do you think of alexa") {
            reply("We've never met. I hear she's very good with timers."); return "egg" }
        if h.has("tell me a secret", "whats your secret") { reply("I sometimes hear my own name and have to pretend I didn't."); return "egg" }
        if h.has("your favourite song", "your favorite song", "your favourite music", "your favorite music", "what music do you like", "favourite composer", "favorite composer") {
            reply("Debussy when it's raining, Oscar Peterson when it isn't. And whatever you wrote last."); return "egg" }
        if h.has("your favourite colour", "your favorite color", "your favourite color") { reply("Green. Have you seen my window?"); return "egg" }
        if h.has("how old are you", "when were you born", "whens your birthday", "when is your birthday") { reply("Young enough to still be learning. Old enough to know your Mac better than you'd like."); return "egg" }
        if h.has("are you there god", "knock knock") { reply(h.has("knock knock") ? "Who's there? Actually, don't tell me. I only answer to \(Me.name)." : "Just me, I'm afraid."); return "egg" }
        if h.words.contains("sing") && h.words.count <= 6, !h.has("spotify", "youtube") {
            reply("I leave the singing to the piano. Say play me something happy, and I'll show you."); return "egg" }
        return nil
    }
}

func personalitySelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let kept = Profile.current
    defer { Profile.current = kept }
    var out: [String] = []
    for s in Style.allCases {
        Profile.current.style = s.rawValue
        out.append(engine.wakeOptions(hour: 10, first: false, again: false, longGap: false).joined(separator: " / "))
    }
    check("character: each manner answers its name in its own way, and brief is the shortest", Set(out).count == 4 && out[3].count <= 25, out.joined(separator: " | "))
    Profile.current.style = "classic"
    let a = engine.personalityHear(Heard("be more playful"))
    let b = Profile.current.style
    let c = engine.personalityHear(Heard("you talk too much"))
    let d = Profile.current.style
    let e = engine.personalityHear(Heard("be more of a butler"))
    check("character: the manner changes by asking", a == "style playful" && b == "playful" && c == "style brief" && d == "brief" && e == "style classic", "\(a ?? "nil") \(b) \(c ?? "nil") \(d) \(e ?? "nil")")
    let f = ["how are you", "thats not what i said", "im tired", "open the pod bay doors", "i love you", "did you miss me"].map { engine.personalityHear(Heard($0)) ?? "nil" }
    let g = ["play smooth jazz on youtube", "open spotify", "what is the weather", "new composition", "be quiet"].map { engine.personalityHear(Heard($0)) ?? "nil" }
    check("character: it answers about itself and about a bad moment, and leaves real requests alone", !f.contains("nil") && g.allSatisfy { $0 == "nil" }, "\(f) \(g)")
    let all = Style.allCases.flatMap { s -> [String] in Profile.current.style = s.rawValue; return [true, false].flatMap { first in [true, false].flatMap { again in engine.wakeOptions(hour: 3, first: first, again: again, longGap: !first) + engine.wakeOptions(hour: 20, first: first, again: again, longGap: false) } } }
    check("character: it never says its own name when answering to it", !all.contains { $0.lowercased().contains(Me.key) } && !all.contains { $0.contains("\u{2014}") }, "")
}
