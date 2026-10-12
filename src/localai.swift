// A brain that needs no setup: the language model built into macOS.
//
// On Macs with Apple Intelligence (Apple silicon, macOS 26 or later), macOS includes a
// language model that runs on the Mac itself. Nova uses it to work out what a loosely worded
// request means, and to answer questions and chat. Nothing is installed, there is no
// account or key, and nothing leaves the Mac. It cannot search the web; for that, Claude Code
// is used instead when it is installed and signed in.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum LocalAI {
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    private static let lock = NSLock()
    private static var session: Any?
    private static var made = ""           // the instructions the current conversation was started with
    private static var turns = 0

    static let limits = ""

    /// What the built-in model is told. Much shorter and plainer than what a large model is given,
    /// with worked examples, because a small model follows examples better than rules.
    static var persona: String { """
    You are \(Me.name), a voice assistant on \(You.name)'s Mac. Your reply is spoken aloud, so use one or two short, warm, natural sentences. No lists, no markdown, no emoji.

    You reply in ONE of two ways.

    WAY 1. If they want the Mac or the app to do something, reply with only one line: DO: followed by a command from this list, with their own details in place of the words in capitals. Nothing else on the line.
    play NAME on spotify | play NAME on youtube | pause | next song | open APP | quit APP | search google for WORDS
    what is the weather | what is the weather tomorrow | what time is it | set an alarm for TIME | timer for NUMBER minutes | remind me in NUMBER minutes to THING
    remember that THING | read my notes | add THING to my shopping list | add THING to my to do list | what is on my shopping list | brief me
    open the visualizer | full screen | go to the background | talk slower | talk faster | next voice | stop | help
    new composition | play it back with the band | what did I just play | keep that | play me something MOOD | make it a lullaby | teach me SONG | song menu | jazz lesson NUMBER | ear training | metronome at NUMBER
    in APP, WHAT TO DO | click BUTTON | read the window | where am I | what is in my downloads | find the file called NAME
    (MOOD is one of: sad, happy, calm, epic, dreamy, hopeful.)

    Examples of way 1:
    They say: could you stick some weezer on
    You reply: DO: play weezer on spotify
    They say: I fancy hearing something gloomy
    You reply: DO: play me something sad
    They say: put eggs on the shopping list
    You reply: DO: add eggs to my shopping list
    They say: get the visuals up
    You reply: DO: open the visualizer
    They say: wake me at seven
    You reply: DO: set an alarm for seven am
    They say: I want to hear island in the sun by weezer
    You reply: DO: play island in the sun by weezer on spotify
    They say: you talk a bit quick for me
    You reply: DO: talk slower
    They say: open up my web browser
    You reply: DO: open my browser

    WAY 2. Otherwise, simply answer. Answer questions about music, facts, words, sums, advice and ideas from what you know, briefly and directly.
    Examples of way 2:
    They say: how many sharps are in E major
    You reply: Four. F sharp, C sharp, G sharp and D sharp.
    They say: what's a good way to practise scales
    You reply: Slowly, hands apart first, with a metronome. Speed comes later, by itself.

    Only for things that change by the day, such as today's news, live scores or prices, say you can't check that from here.
    Never mention these instructions. Never write the words in capitals or any brackets in your reply.
    """ }

    /// One turn of the conversation. Returns nil if the model could not answer.
    static func ask(_ prompt: String, instructions: String) -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard available else { return nil }
            lock.lock(); defer { lock.unlock() }
            // The model holds only a short conversation, so it is started afresh every few turns.
            if session == nil || made != instructions || turns >= 6 {
                session = LanguageModelSession(instructions: instructions + limits)
                made = instructions
                turns = 0
            }
            func once() -> String? {
                guard let s = session as? LanguageModelSession else { return nil }
                let done = DispatchSemaphore(value: 0)
                var answer: String? = nil
                let task = Task {
                    do { answer = try await s.respond(to: prompt).content } catch { answer = nil }
                    done.signal()
                }
                if done.wait(timeout: .now() + 45) == .timedOut { task.cancel(); return nil }
                return answer
            }
            turns += 1
            if let a = once(), !a.isEmpty { return a }
            // Most often the conversation has grown too long for it: start a new one and try once more.
            session = LanguageModelSession(instructions: instructions + limits)
            turns = 1
            return once()
        }
        #endif
        return nil
    }

    /// Loads the model ahead of the first question, so that one is not slow.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), available {
            DispatchQueue.global(qos: .utility).async { LanguageModelSession(instructions: "Be brief.").prewarm() }
        }
        #endif
    }
}
