// For people who are blind or have low vision: reading what is on the screen (even text that is
// only a picture), describing a picture, reading documents aloud with a bookmark, naming what is
// under the pointer, and the battery and network in a sentence. Text recognition runs on the Mac
// (Apple's Vision); only "describe" sends a picture to the AI, and it says so first.

import Foundation
import ApplicationServices
import CoreGraphics
import Vision
import PDFKit
import AppKit

enum ScreenText {
    /// The front window of a process as a picture, or the whole screen if it has none. Needs Screen Recording.
    static func capture(pid: pid_t?) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nova-screen-\(getpid()).png")
        try? FileManager.default.removeItem(at: url)
        var args = ["-x", "-o"]
        if let pid = pid, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let id = w[kCGWindowNumber as String] as? Int {
            args += ["-l", String(id)]
        }
        args.append(url.path)
        guard runTool("/usr/sbin/screencapture", args, timeout: 10).ok, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The text in a picture, in reading order: top to bottom, left to right within a line.
    static func recognise(_ image: URL) -> [String] {
        guard let src = CGImageSourceCreateWithURL(image as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
        return recognise(cg)
    }
    static func recognise(_ cg: CGImage) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        let obs = (req.results ?? []).compactMap { o -> (CGRect, String)? in
            guard let t = o.topCandidates(1).first, t.confidence > 0.3 else { return nil }
            return (o.boundingBox, t.string)
        }
        // Vision measures from the bottom left; lines whose middles are close count as one line.
        let sorted = obs.sorted { a, b in abs(a.0.midY - b.0.midY) < 0.012 ? a.0.minX < b.0.minX : a.0.midY > b.0.midY }
        var lines: [String] = []
        var lastY = -1.0
        for (box, text) in sorted {
            if lastY >= 0, abs(Double(box.midY) - lastY) < 0.012, let l = lines.popLast() { lines.append(l + "  " + text) } else { lines.append(text) }
            lastY = Double(box.midY)
        }
        return lines
    }

    /// What is in a picture, from the Mac's own image recognition: a few likely labels.
    static func labels(_ image: URL) -> [String] {
        guard let src = CGImageSourceCreateWithURL(image as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
        let req = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return (req.results ?? []).filter { $0.confidence > 0.3 }.prefix(5).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }
}

/// A document being read aloud: its paragraphs, and where reading stopped.
final class Reading {
    static let shared = Reading()
    var title = ""
    var parts: [String] = []
    var at = 0

    /// The text of a PDF, Word, RTF, web page or plain text file. Scanned PDFs are read with text recognition.
    static func text(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let doc = PDFDocument(url: url) {
            var out = ""
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let t = page.string ?? ""
                if t.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { out += t + "\n\n"; continue }
                // A page that is only a picture of text.
                let img = page.thumbnail(of: NSSize(width: 1700, height: 2200), for: .mediaBox)
                if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { out += ScreenText.recognise(cg).joined(separator: "\n") + "\n\n" }
                if out.count > 400_000 { break }
            }
            return out
        }
        if ["png", "jpg", "jpeg", "heic", "tiff", "gif"].contains(ext) { return ScreenText.recognise(url).joined(separator: "\n") }
        if ["txt", "md", "text", "csv"].contains(ext) { return try? String(contentsOf: url, encoding: .utf8) }
        if ["docx", "doc", "rtf", "rtfd", "html", "htm", "odt", "pages", "webarchive"].contains(ext),
           let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { return a.string }
        return nil
    }

    func load(_ url: URL) -> Bool {
        guard let t = Reading.text(of: url) else { return false }
        // Paragraphs, with very long ones split at sentences so "stop" and "keep reading" land somewhere sensible.
        var out: [String] = []
        for para in t.components(separatedBy: "\n\n").map({ $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }) where !para.isEmpty {
            if para.count < 600 { out.append(para); continue }
            var chunk = ""
            for s in para.components(separatedBy: ". ") { chunk += s + ". "; if chunk.count > 400 { out.append(chunk); chunk = "" } }
            if !chunk.isEmpty { out.append(chunk) }
        }
        guard !out.isEmpty else { return false }
        title = url.deletingPathExtension().lastPathComponent
        parts = out
        at = 0
        return true
    }
}

extension Engine {
    /// The file selected in the Finder, if the Finder is in front and something is selected.
    func finderSelection() -> URL? {
        guard frontApp() == "Finder" else { return nil }
        let r = LogicControl.osa("tell application \"Finder\" to get POSIX path of (item 1 of (get selection) as alias)")
        let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !p.isEmpty && FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
    }

    /// The newest readable document in Downloads, Desktop or Documents.
    func newestDocument(images: Bool = false) -> URL? {
        let kinds = images ? ["png", "jpg", "jpeg", "heic"] : ["pdf", "docx", "doc", "rtf", "txt", "md", "pages", "html", "odt"]
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var best: (URL, Date)? = nil
        for d in ["Downloads", "Desktop", "Documents"] {
            for u in (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(d), includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
            where kinds.contains(u.pathExtension.lowercased()) {
                let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if date > (best?.1 ?? .distantPast) { best = (u, date) }
            }
        }
        return best?.0
    }

    /// Reads the document from where it stopped, a paragraph at a time, until the end or until told to stop.
    func continueReading() {
        let r = Reading.shared
        guard r.at < r.parts.count else { run { g in self.say(r.parts.isEmpty ? "There's nothing being read." : "That was the end of \(r.title).", g) }; return }
        run { g in
            while r.at < r.parts.count {
                self.say(r.parts[r.at], g)
                guard self.alive(g) else { return }          // stopped: the place is kept
                r.at += 1
            }
            self.say("That's the end of \(r.title).", g)
        }
    }

    func accessHear(_ h: Heard) -> String? {
        func reply(_ text: String) { run { g in self.say(text, g); self.resumeAfterHelp(g) } }

        // Documents, read aloud with a bookmark.
        if h.has("keep reading", "continue reading", "carry on reading", "resume reading", "read on", "go on reading", "where was i", "next paragraph") && !Reading.shared.parts.isEmpty {
            if h.has("next paragraph") { Reading.shared.at = min(Reading.shared.parts.count, Reading.shared.at + 1) }
            continueReading(); return "reading on"
        }
        if h.has("previous paragraph", "go back a paragraph", "read that paragraph again", "back a paragraph") && !Reading.shared.parts.isEmpty {
            Reading.shared.at = max(0, Reading.shared.at - (h.has("again") ? 0 : 1)); continueReading(); return "reading back"
        }
        if h.has("start reading from the beginning", "read it from the start", "start again from the top", "from the beginning") && !Reading.shared.parts.isEmpty {
            Reading.shared.at = 0; continueReading(); return "reading start"
        }
        if h.has("how much is left", "how far am i", "how long is it", "how many pages") && !Reading.shared.parts.isEmpty {
            let r = Reading.shared
            reply("You're \(Int(Double(r.at) / Double(max(1, r.parts.count)) * 100)) percent of the way through \(r.title). \(r.parts.count - r.at) paragraphs to go."); return "reading where"
        }
        let readDoc = h.has("read this document", "read the document", "read this file", "read the file", "read this pdf", "read the pdf", "read my latest download", "read the latest download",
                            "read the newest download", "read this to me", "read me this", "read this out", "read it out", "read the selected file", "read this page")
        if readDoc {
            if Opt.fast { return "read document" }
            run { g in
                guard let url = self.finderSelection() ?? self.newestDocument() else { self.say("I can't find a document. Select one in the Finder, then ask again.", g); return }
                guard Reading.shared.load(url) else { self.say("I can't read \(url.lastPathComponent). I can do PDFs, Word, RTF, text and web pages.", g); return }
                self.say("\(Reading.shared.title). \(Reading.shared.parts.count) paragraphs. Say stop to pause, and keep reading to carry on.", g)
                guard self.alive(g) else { return }
                self.continueReading()
            }
            return "read document"
        }

        // Text on the screen, read from the picture itself: for apps, images and videos that VoiceOver can't read.
        if h.has("read the text on the screen", "read all the text", "read everything on the screen", "read the words on the screen", "read the image", "read the picture", "read the text in the picture",
                 "read the text in the image", "read the subtitles", "read the captions on screen", "scan the screen", "ocr") {
            if Opt.fast { return "screen text" }
            run { g in
                let pid = self.frontApp().flatMap { AX.pid(of: $0) }
                guard let shot = ScreenText.capture(pid: pid) else { self.say(Engine.noScreen, g); return }
                let lines = ScreenText.recognise(shot)
                try? FileManager.default.removeItem(at: shot)
                guard !lines.isEmpty else { self.say("I can't find any text on the screen. If the screen isn't blank, \(Nova.name) may need Screen Recording permission.", g); return }
                let joined = lines.joined(separator: ". ")
                self.say(String(joined.prefix(1800)) + (joined.count > 1800 ? ". And there's more." : ""), g)
            }
            return "screen text"
        }

        // A picture, described: the AI looks at it; without the AI, the Mac's own recognition does its best.
        let describeScreen = h.has("describe the screen", "describe my screen", "describe what is on the screen", "describe whats on the screen", "what does the screen look like", "what am i looking at on the screen", "look at my screen", "look at the screen")
        let describeImage = h.has("describe this image", "describe the image", "describe this picture", "describe the picture", "what is in this picture", "whats in this picture", "what is in this image", "whats in this image", "what is this picture", "what is this image", "describe this photo", "whats in this photo")
        if describeScreen || describeImage {
            if Opt.fast { return describeScreen ? "describe screen" : "describe image" }
            run { g in
                var image: URL? = nil, temporary = false
                if describeImage { image = self.finderSelection().flatMap { ["png", "jpg", "jpeg", "heic", "gif", "tiff"].contains($0.pathExtension.lowercased()) ? $0 : nil } ?? self.newestDocument(images: true) }
                if image == nil { image = ScreenText.capture(pid: self.frontApp().flatMap { AX.pid(of: $0) }); temporary = true }
                guard let pic = image else { self.say(Engine.noScreen, g); return }
                defer { if temporary { try? FileManager.default.removeItem(at: pic) } }
                if AI.path != nil, !AISession.shared.signedOut {
                    self.say(pick(["Sending the picture to Claude to look at.", "Taking a look. The picture goes to Claude for this."]), g)
                    ui("think 1"); ui("status Looking at the picture")
                    let r = runTool(AI.path!, ["-p", "--model", "sonnet", "--allowedTools", "Read", "--disallowedTools", "Bash,Edit,Write,WebSearch,WebFetch,Agent",
                                               "Describe the image at \(pic.path) for someone who is blind, as you would say it out loud: what it is first, then the important details and any text that matters. Plain speech, no lists or symbols, at most five sentences."], timeout: 90)
                    ui("think 0"); ui("status ")
                    let said = AISession.tidy(r.out)
                    if r.ok, !said.isEmpty, !said.contains("401"), !said.lowercased().contains("authenticate") { self.say(said, g); return }
                }
                let labels = ScreenText.labels(pic), words = ScreenText.recognise(pic)
                self.say((labels.isEmpty ? "I can't tell what the picture shows." : "It looks like: \(spokenList(labels, limit: 5)).") + (words.isEmpty ? "" : " It says: \(String(words.joined(separator: ". ").prefix(600)))."), g)
            }
            return describeImage ? "describe image" : "describe screen"
        }

        // What the pointer is over.
        if h.has("whats under my mouse", "what is under my mouse", "whats under the mouse", "what is under the mouse", "whats under the pointer", "what is under the pointer",
                 "what am i pointing at", "where is my mouse", "where is the mouse", "where is my cursor", "whats under my cursor", "what is under my cursor") {
            if Opt.fast { return "under mouse" }
            guard AX.trusted else { reply(Engine.noAccess); return "no access" }
            let p = CGEvent(source: nil)?.location ?? .zero
            var el: AXUIElement?
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el)
            guard let e = el else { reply("Nothing I can name is under the pointer."); return "under mouse" }
            let name = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute].map { AX.text(e, $0) }.first { !$0.isEmpty } ?? ""
            let role = AX.text(e, kAXRoleDescriptionAttribute)
            var owner: pid_t = 0; AXUIElementGetPid(e, &owner)
            let app = NSRunningApplication(processIdentifier: owner)?.localizedName ?? ""
            let screen = CGDisplayBounds(CGMainDisplayID())
            let across = p.x < screen.width / 3 ? "left" : p.x > screen.width * 2 / 3 ? "right" : "middle"
            let down = p.y < screen.height / 3 ? "top" : p.y > screen.height * 2 / 3 ? "bottom" : "middle"
            let place = across == down ? "the middle of the screen" : "the \(down) \(across) of the screen"
            reply((name.isEmpty ? (role.isEmpty ? "Something without a name" : "A \(role)") : "\(name)\(role.isEmpty ? "" : ", a \(role)")") + (app.isEmpty ? "" : ", in \(app)") + ", at \(place).")
            return "under mouse"
        }

        // The Mac itself, in a sentence.
        if h.has("battery", "how much charge", "am i charging", "is it charging", "power left") {
            if Opt.fast { return "battery" }
            let out = runTool("/usr/bin/pmset", ["-g", "batt"], timeout: 4).out
            guard let r = out.range(of: #"(\d+)%"#, options: .regularExpression) else { reply("This Mac doesn't report a battery."); return "battery" }
            let pct = out[r].dropLast()
            let charging = out.contains("AC Power") ? (out.contains("charged") ? ", and it's full and plugged in" : ", and it's charging") : ""
            let left = out.range(of: #"(\d+):(\d+) remaining"#, options: .regularExpression).map { m -> String in
                let parts = out[m].split(separator: " ")[0].split(separator: ":").compactMap { Int($0) }
                return parts.count == 2 && (parts[0] > 0 || parts[1] > 0) ? ". About \(parts[0] > 0 ? "\(parts[0]) hour\(parts[0] == 1 ? "" : "s") " : "")\(parts[1]) minutes left" : ""
            } ?? ""
            reply("The battery is at \(pct) percent\(charging)\(left)."); return "battery"
        }
        if h.has("am i online", "am i connected", "is the internet working", "is my internet working", "do i have internet", "whats my wifi", "what is my wifi", "which wifi", "what wifi am i on", "internet connection") {
            if Opt.fast { return "online" }
            run { g in
                let online = runTool("/sbin/ping", ["-c", "1", "-t", "3", "1.1.1.1"], timeout: 5).ok
                let net = runTool("/usr/sbin/networksetup", ["-getairportnetwork", "en0"], timeout: 4).out
                let name = net.components(separatedBy: "Network: ").dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.say((online ? "Yes, you're online" : "No, the internet isn't reachable right now") + (name.isEmpty ? "." : ", on \(name)."), g)
            }
            return "online"
        }

        // Everything in the window bigger, not only the captions.
        if h.has("make everything bigger", "make the window bigger", "bigger buttons", "make it bigger", "zoom the window", "everything is too small", "i cant see the buttons") {
            ui("access large 1"); reply("Everything's bigger now. Say make everything smaller to undo it."); return "large"
        }
        if h.has("make everything smaller", "smaller buttons", "normal size", "make it smaller", "smaller captions", "small captions", "normal captions") {
            ui("access large 0"); reply("Back to normal size."); return "small"
        }
        return nil
    }

    static let noScreen = "I couldn't take a picture of the screen. Nova needs Screen Recording: open System Settings, Privacy and Security, Screen Recording, and switch on Nova."
}

/// The assistant's own name, for sentences outside the engine.
enum Nova { static var name: String { Me.name } }

func accessSelfTest(_ engine: Engine, _ check: (String, Bool, String) -> Void) {
    let cases: [(String, String?)] = [("read this document", "read document"), ("read the text on the screen", "screen text"), ("describe my screen", "describe screen"),
                                      ("what's in this picture", "describe image"), ("what's under my mouse", "under mouse"), ("how's my battery", "battery"),
                                      ("am I online", "online"), ("make everything bigger", "large"), ("open safari", nil), ("play it back with the band", nil)]
    let got = cases.map { engine.accessHear(Heard($0.0)) }
    let bad = zip(cases, got).filter { $0.0.1 != $0.1 }.map { "\($0.0.0) -> \($0.1 ?? "nil")" }
    // Text recognition, on a picture drawn here.
    let img = NSImage(size: NSSize(width: 700, height: 160))
    img.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 700, height: 160).fill()
    ("Practice scales for ten minutes" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
    img.unlockFocus()
    let lines = img.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ScreenText.recognise($0) } ?? []
    // A document read in paragraphs.
    let doc = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nova-reading-test.txt")
    try? "First paragraph.\n\nSecond paragraph, a little longer.\n\nThird.".write(to: doc, atomically: true, encoding: .utf8)
    let loaded = Reading.shared.load(doc) && Reading.shared.parts.count == 3
    try? FileManager.default.removeItem(at: doc)
    Reading.shared.parts = []
    check("access: reading, describing, the pointer, battery and size are understood, text is read from a picture, and documents load in paragraphs",
          bad.isEmpty && lines.joined(separator: " ").lowercased().contains("practice scales") && loaded, "\(bad) \(lines) \(loaded)")
}
