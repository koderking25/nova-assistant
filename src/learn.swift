// Learning from mistakes.
//
// Three things are remembered between sessions:
//  - Phrases. When a sentence was not understood by the built-in rules and the AI worked out
//    what it meant, the pairing is kept, so the same sentence is understood at once next time.
//  - Corrections. "No, I meant ..." teaches that the last sentence means the corrected one.
//  - A plain list of what went wrong (mistakes.txt): sentences that were not understood,
//    corrections, and actions that could not be confirmed. It only ever holds sentences that
//    were addressed to the assistant. It is there so the faults can be found and fixed.

import Foundation

extension Engine {
    static let learnedURL = baseDir.appendingPathComponent("learned.json")
    static let mistakesURL = baseDir.appendingPathComponent("mistakes.txt")
    static let trustedURL = baseDir.appendingPathComponent("learned-from-you.txt")

    func loadLearned() {
        trustedLearned = ((try? String(contentsOf: Engine.trustedURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        learned = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Engine.learnedURL))) ?? [:]
        // Guesses learned before guesses had to make sense are let go: "do you wanna play emoji" is not "play me something sad".
        let sound = learned.filter { Engine.related($0.key, $0.value) || trustedLearned.contains($0.key) }
        if sound.count != learned.count {
            learned = sound
            if !Opt.fast, let d = try? JSONEncoder().encode(learned) { try? d.write(to: Engine.learnedURL) }
        }
    }

    /// Words that carry meaning in a request, without the ones every request shares ("play", "open", "me", "the").
    static func gist(_ s: String) -> Set<String> {
        let common: Set<String> = ["a", "an", "the", "me", "my", "i", "you", "your", "it", "its", "to", "of", "in", "on", "for", "and", "or", "is", "are", "be", "do", "can", "could", "would", "will",
                                   "please", "some", "something", "this", "that", "what", "whats", "now", "up", "go", "get", "make", "play", "open", "show", "put", "give", "want", "wanna", "let", "lets",
                                   "with", "just", "if", "so", "yeah", "ok", "okay", "hey", "jarvis", "start", "turn", "set", "say", "tell", "take", "have", "like", "need", "about", "at", "by", "from", "all", "one"]
        return Set(Ears.words(s).map { $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }.filter { !common.contains($0) && $0.count >= 2 })
    }
    /// True when an AI's reading of a sentence shares a meaningful word with it, or the sentence is just one word.
    static func related(_ said: String, _ means: String) -> Bool {
        let a = gist(said), b = gist(means)
        if a.isEmpty { return false }
        return !a.isDisjoint(with: b) || a.contains { w in b.contains { $0.count >= 4 && w.count >= 4 && ($0.hasPrefix(String(w.prefix(4))) || w.hasPrefix(String($0.prefix(4)))) } }
    }

    /// Remembers that a way of saying something means a request the app understands.
    /// `trusted`: the person said it themselves ("no, I meant..."), so it is kept even if no word is shared.
    func learn(_ said: String, means: String, trusted: Bool = false) {
        let key = Heard(said).text
        let value = means.lowercased().trimmingCharacters(in: .whitespaces)
        guard key.count >= 4, key.count <= 120, !value.isEmpty, key != Heard(value).text, trusted || Engine.related(said, value) else { return }
        learned[key] = value
        if trusted, !trustedLearned.contains(key) { trustedLearned.append(key); if !Opt.fast { try? trustedLearned.joined(separator: "\n").write(to: Engine.trustedURL, atomically: true, encoding: .utf8) } }
        if learned.count > 400, let drop = learned.keys.sorted().first { learned[drop] = nil }
        if !Opt.fast, let d = try? JSONEncoder().encode(learned) { try? d.write(to: Engine.learnedURL) }
    }

    func noteMistake(_ kind: String, _ text: String) {
        if Opt.fast { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let line = "\(f.string(from: Date()))  \(kind): \(text.prefix(200))\n"
        let path = Engine.mistakesURL.path
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 200_000 { try? "".write(toFile: path, atomically: true, encoding: .utf8) }
        if let h = try? FileHandle(forWritingTo: Engine.mistakesURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: Engine.mistakesURL, atomically: true, encoding: .utf8) }
    }

    /// "No, I meant new composition": do the right thing, and remember it for the sentence before.
    /// Returns what was done, or nil if this is not a correction.
    func correction(_ h: Heard) -> String? {
        let openers = ["no i meant", "i meant", "no i said", "i said", "not that i meant", "no i want", "no i wanted", "i wanted", "what i meant was", "i was asking for", "no no", "not that"]
        guard let opener = openers.first(where: { h.starts($0) }) else {
            // "That's wrong" on its own: ask, and take the next sentence as the correction.
            if ["thats wrong", "that is wrong", "wrong", "thats not what i meant", "thats not what i said", "thats not right", "no thats wrong", "not what i meant", "you got that wrong", "thats not it"].contains(h.text) {
                correcting = lastRequest
                noteMistake("told it was wrong", lastRequest)
                run { g in self.ears.expectAnswer(); self.say(pick(["Sorry about that. What did you mean?", "My mistake. What would you like?", "Sorry. Say it again and I'll get it right."]), g); self.ears.expectAnswer() }
                return "sorry"
            }
            return nil
        }
        let rest = String(h.text.dropFirst(opener.count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let wrong = correcting ?? lastRequest
        correcting = nil
        noteMistake("corrected", "\"\(wrong)\" should have been \"\(rest)\"")
        let done = hear(rest)
        if done != "ask", !wrong.isEmpty { learn(wrong, means: rest, trusted: true) }
        return done
    }
}

func learnSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let saved = engine.learned
    engine.learned = [:]
    engine.goHomeQuietly()
    engine.learn("fire up the writing thing", means: "new composition", trusted: true)
    let known = engine.hear("\(Me.name), fire up the writing thing")
    check("learning: a sentence the AI once explained is understood at once the next time", known == "compose", known)
    engine.goHomeQuietly()
    _ = engine.hear("do the scribble zone")          // not understood
    let fixed = engine.hear("no I meant new composition")
    engine.goHomeQuietly()
    let again = engine.hear("do the scribble zone")
    check("learning: \"no, I meant\" does the right thing and teaches it for next time", fixed == "compose" && again == "compose", "\(fixed), then \(again)")
    engine.goHomeQuietly()
    engine.learned = saved
}
