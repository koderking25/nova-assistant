// The holographic console: an arc-reactor core that moves with the voice and the microphone,
// a quiet top bar, a small dock, and drawers for everything else. Plus the start-up sequence
// and the interface sounds, which are all made here from tones and noise: no recordings at all.

import AppKit
import AVFoundation
import SwiftUI

// MARK: - What the assistant is doing, in one word

extension Link {
    var activity: String {
        if state == "OFFLINE" { return "OFFLINE" }
        if state != "ONLINE" { return "STARTING" }
        if speaking { return "SPEAKING" }
        if thinking { return "THINKING" }
        if VoiceControl.shared.talking { return "LISTENING" }
        return VoiceControl.shared.on ? "STANDING BY" : "VOICE OFF"
    }
    /// The colour of that activity, as red, green and blue, so it can be blended smoothly.
    var tintRGB: (Double, Double, Double) {
        if Link.clock() - flashAt < 0.9, flash == "wrong" { return (1.0, 0.3, 0.32) }
        switch activity {
        case "THINKING": return (1.0, 0.72, 0.25)
        case "LISTENING": return (0.86, 0.98, 1.0)
        case "OFFLINE", "VOICE OFF": return (0.42, 0.52, 0.58)
        default: return (0.30, 0.86, 1.0)
        }
    }
    /// The colour of that activity.
    var tint: Color {
        if Link.clock() - flashAt < 0.9, flash == "wrong" { return Holo.red }
        switch activity {
        case "THINKING": return Holo.amber
        case "LISTENING": return Holo.white
        case "OFFLINE", "VOICE OFF": return Holo.grey
        default: return Hud.green
        }
    }
}

enum Holo {
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let red = Color(red: 1.0, green: 0.3, blue: 0.32)
    static let white = Color(red: 0.86, green: 0.98, blue: 1.0)
    static let grey = Color(red: 0.42, green: 0.52, blue: 0.58)
    static let deep = Color(red: 0.0, green: 0.03, blue: 0.06)
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

// MARK: - The core

struct HoloCore: View {
    @ObservedObject var link: Link
    @ObservedObject var voice = VoiceControl.shared
    let active: Bool
    /// How far the rings have turned and how loud it is, kept outside SwiftUI's state so that
    /// moving them does not ask the whole window to redraw.
    final class Motion {
        var spin = 0.0, at = 0.0, level = 0.0
        var rgb = (0.30, 0.86, 1.0)                     // the colour now, easing towards the activity's colour
        var lastActivity = "", pulses: [Double] = []     // a ring ripples out whenever the activity changes
        var flow = 0.0                                   // -1 streaming in (listening), +1 streaming out (speaking), 0 orbiting
        var comet = 0.0                                  // how bright the thinking comets are
        lazy var seeds: [(Double, Double, Double)] = (0..<70).map { _ in (Double.random(in: 0...1), Double.random(in: 0...(2 * .pi)), Double.random(in: 0.5...1.5)) }
    }
    @State private var m = Motion()

    var body: some View {
        TimelineView(.periodic(from: .now, by: active ? 1.0 / 60 : 0.5)) { _ in
            Canvas { g, size in
                let t = Link.clock()
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) * 0.46
                // The colour melts from one state to the next instead of switching.
                let want = link.tintRGB
                let dt0 = min(0.1, max(0, t - m.at))
                let k = 1 - exp(-dt0 * 5)
                m.rgb = (m.rgb.0 + (want.0 - m.rgb.0) * k, m.rgb.1 + (want.1 - m.rgb.1) * k, m.rgb.2 + (want.2 - m.rgb.2) * k)
                let tint = Color(red: m.rgb.0, green: m.rgb.1, blue: m.rgb.2)
                let activity = link.activity
                if activity != m.lastActivity { if !m.lastActivity.isEmpty { m.pulses.append(t) }; m.lastActivity = activity }
                m.pulses.removeAll { t - $0 > 1.2 }
                let flowWant = activity == "LISTENING" ? -1.0 : activity == "SPEAKING" ? 1.0 : 0.0
                m.flow += (flowWant - m.flow) * (1 - exp(-dt0 * 3))
                m.comet += ((activity == "THINKING" ? 1.0 : 0.0) - m.comet) * (1 - exp(-dt0 * 4))
                // How loud: the voice while speaking, the microphone while listening.
                let bands = link.voiceBands(at: t)
                let target = bands.map { $0.reduce(0, +) / Double($0.count) * 1.8 } ?? (voice.talking || voice.on ? voice.level * 1.4 : 0)
                let calm = Holo.reduceMotion ? 0.15 : 1.0
                let dt = dt0; m.at = t
                let speed = link.activity == "THINKING" ? 2.6 : link.speaking ? 1.3 : 0.45
                m.spin += dt * speed * calm
                m.level += (min(1, target) - m.level) * (1 - exp(-dt * (target > m.level ? 30 : 6)))
                let spin = m.spin, level = m.level
                func ring(_ r: CGFloat, _ width: CGFloat, _ color: Color, _ from: Double = 0, _ to: Double = 360) {
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                    g.stroke(p, with: .color(color), lineWidth: width)
                }
                // A soft halo behind everything.
                let halo = R * (0.62 + 0.18 * level)
                g.fill(Path(ellipseIn: CGRect(x: c.x - halo * 1.5, y: c.y - halo * 1.5, width: halo * 3, height: halo * 3)),
                       with: .radialGradient(Gradient(colors: [tint.opacity(0.22 + 0.25 * level), tint.opacity(0.05), .clear]), center: c, startRadius: 0, endRadius: halo * 1.5))
                // Outer scale: 120 ticks, every tenth one long, turning slowly.
                g.drawLayer { l in
                    l.translateBy(x: c.x, y: c.y); l.rotate(by: .degrees(spin * 6)); l.translateBy(x: -c.x, y: -c.y)
                    for i in 0..<120 {
                        let a = Double(i) / 120 * 2 * .pi
                        let long = i % 10 == 0
                        let r0 = R * (long ? 0.93 : 0.96), r1 = R
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                        l.stroke(p, with: .color(tint.opacity(long ? 0.7 : 0.25)), lineWidth: long ? 1.6 : 1)
                    }
                }
                // Three segmented rings turning at different speeds and directions.
                let rings: [(CGFloat, CGFloat, Double, Int, Double)] = [(0.86, 3, 20, 3, 0.55), (0.76, 6, -32, 6, 0.4), (0.66, 1.5, 48, 12, 0.7)]
                for (k, ringSpec) in rings.enumerated() {
                    let (rf, w, sp, segs, op) = ringSpec
                    let base = spin * sp + Double(k) * 17
                    for s in 0..<segs {
                        let start = base + Double(s) * 360 / Double(segs)
                        let len = 360 / Double(segs) * (k == 1 ? 0.55 : 0.78)
                        ring(R * rf, w, tint.opacity(op), start, start + len)
                    }
                }
                // The voice ring: 96 spokes that grow with the sound.
                let n = 96
                for i in 0..<n {
                    let a = Double(i) / Double(n) * 2 * .pi - .pi / 2
                    var v = level
                    if let b = bands {
                        let x = Double(i < n / 2 ? i : n - 1 - i) / Double(n / 2 - 1) * Double(b.count - 1)
                        v = b[min(b.count - 1, Int(x))] * 1.3
                    } else {
                        v = level * (0.55 + 0.45 * abs(sin(Double(i) * 0.7 + t * 3)))
                    }
                    let idle = 0.04 + 0.03 * sin(Double(i) * 0.5 + t * 1.4) * calm
                    let len = R * (0.05 + 0.2 * min(1.2, v + idle))
                    let r0 = R * 0.5
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * (r0 + len), y: c.y + sin(a) * (r0 + len)))
                    g.stroke(p, with: .color(tint.opacity(0.35 + 0.6 * min(1, v * 1.5))), lineWidth: 2)
                }
                // Ripples: a ring travelling outward each time the state changes.
                for p0 in m.pulses {
                    let a = (t - p0) / 1.2
                    let r = R * (0.3 + 0.85 * a)
                    ring(r, 2.5 * (1 - a), tint.opacity(0.7 * (1 - a)))
                }
                // A stream of particles: drawn in while listening, sent out while speaking, orbiting otherwise.
                if calm > 0.5 {
                    for (i, s) in m.seeds.enumerated() {
                        let speedP = 0.12 * s.2
                        var life = (s.0 + t * speedP).truncatingRemainder(dividingBy: 1)
                        if m.flow < 0 { life = 1 - life }
                        let reach = 0.32 + 0.72 * life
                        let swirl = s.1 + t * 0.25 * s.2 * (i % 2 == 0 ? 1 : -1) + life * 1.6 * m.flow
                        let r = R * (abs(m.flow) > 0.2 ? reach : 0.62 + 0.25 * sin(s.1 * 3 + t * 0.3))
                        let fade = abs(m.flow) > 0.2 ? sin(life * .pi) : 0.5
                        let pt = CGPoint(x: c.x + cos(swirl) * r, y: c.y + sin(swirl) * r)
                        let size = 1.2 + 1.6 * s.2 * (0.6 + level)
                        g.fill(Path(ellipseIn: CGRect(x: pt.x - size / 2, y: pt.y - size / 2, width: size, height: size)), with: .color(tint.opacity(0.18 + 0.55 * fade)))
                    }
                }
                // Thinking: two comets chase each other around the core.
                if m.comet > 0.02 {
                    for k in 0..<2 {
                        let head = t * 3.2 + Double(k) * .pi
                        for j in 0..<18 {
                            let a = head - Double(j) * 0.07
                            let r = R * 0.47
                            let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                            let sz = 5.0 * (1 - Double(j) / 18)
                            g.fill(Path(ellipseIn: CGRect(x: pt.x - sz / 2, y: pt.y - sz / 2, width: sz, height: sz)), with: .color(tint.opacity(m.comet * (1 - Double(j) / 18))))
                        }
                    }
                }
                // The reactor: a bright core, a triangle, and an inner ring that breathes.
                let breathe = 0.5 + 0.5 * sin(t * (link.activity == "THINKING" ? 5 : 1.6))
                let coreR = R * (0.26 + 0.05 * level + 0.012 * breathe * calm)
                g.drawLayer { l in
                    l.addFilter(.blur(radius: 14))
                    l.fill(Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)), with: .color(tint.opacity(0.55 + 0.3 * level)))
                }
                g.fill(Path(ellipseIn: CGRect(x: c.x - coreR * 0.62, y: c.y - coreR * 0.62, width: coreR * 1.24, height: coreR * 1.24)),
                       with: .radialGradient(Gradient(colors: [.white, tint.opacity(0.9), tint.opacity(0.1)]), center: c, startRadius: 0, endRadius: coreR * 0.62))
                ring(coreR * 1.25, 2, tint.opacity(0.8))
                ring(R * 0.44, 1, tint.opacity(0.3))
                g.drawLayer { l in
                    l.translateBy(x: c.x, y: c.y); l.rotate(by: .degrees(-spin * 10)); l.translateBy(x: -c.x, y: -c.y)
                    var tri = Path()
                    for k in 0..<3 {
                        let a = Double(k) / 3 * 2 * .pi - .pi / 2
                        let pt = CGPoint(x: c.x + cos(a) * coreR * 1.05, y: c.y + sin(a) * coreR * 1.05)
                        k == 0 ? tri.move(to: pt) : tri.addLine(to: pt)
                    }
                    tri.closeSubpath()
                    l.stroke(tri, with: .color(Color.white.opacity(0.55)), lineWidth: 1.5)
                }
                // Little lights in orbit.
                for k in 0..<6 {
                    let a = spin * (0.9 + Double(k) * 0.13) + Double(k) * 1.05
                    let r = R * (0.58 + 0.06 * Double(k % 3))
                    let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                    g.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(tint.opacity(0.9)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(link.assistant) is \(link.activity.lowercased())")
    }
}

/// The activity in one word, what it is busy with, and, while talking to it, the words as they are heard.
struct ActivityLine: View {
    @ObservedObject var link: Link
    @ObservedObject var voice = VoiceControl.shared
    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                let dots = String(repeating: ".", count: Int(ctx.date.timeIntervalSince1970 / 0.4) % 4)
                let busy = !link.activityText.isEmpty && !link.speaking
                Text(busy ? link.activityText.uppercased() + dots : link.activity)
                    .font(Hud.mono(link.large ? 14 : 11, .semibold)).tracking(6).foregroundColor(link.tint)
                    .shadow(color: link.tint, radius: 8)
                    .animation(.easeInOut(duration: 0.3), value: busy)
            }
            if voice.talking && !voice.liveText.isEmpty {
                Text(voice.liveText).font(Hud.mono(link.large ? 22 : 16)).foregroundColor(.white.opacity(0.9)).lineLimit(2)
                    .multilineTextAlignment(.center).transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: voice.talking)
        .accessibilityHidden(true)
    }
}

// MARK: - The room it sits in

struct HoloBackground: View {
    let active: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: active && !Holo.reduceMotion ? 1.0 / 30 : 2)) { _ in
            Canvas { g, size in
                let t = Link.clock()
                g.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(Gradient(colors: [Color(red: 0.0, green: 0.09, blue: 0.14), Holo.deep, .black]),
                       center: CGPoint(x: size.width / 2, y: size.height * 0.42), startRadius: 0, endRadius: max(size.width, size.height) * 0.75))
                // A floor grid running away into the distance.
                let horizon = size.height * 0.62
                for i in 0...24 {
                    let x = size.width / 2 + (Double(i) - 12) * size.width / 10
                    var p = Path(); p.move(to: CGPoint(x: size.width / 2 + (x - size.width / 2) * 0.08, y: horizon)); p.addLine(to: CGPoint(x: x, y: size.height))
                    g.stroke(p, with: .color(Hud.green.opacity(0.06)), lineWidth: 1)
                }
                let flow = (t * 0.12).truncatingRemainder(dividingBy: 1)
                for i in 0..<12 {
                    let z = (Double(i) + flow) / 12
                    let y = horizon + (size.height - horizon) * z * z
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    g.stroke(p, with: .color(Hud.green.opacity(0.07 * z)), lineWidth: 1)
                }
                // Dust drifting upward.
                for i in 0..<60 {
                    let s = Double(i) * 12.9898
                    let x = (sin(s) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let speed = 0.01 + 0.02 * abs(sin(s * 3.1))
                    let y = 1 - ((abs(cos(s)) + t * speed).truncatingRemainder(dividingBy: 1))
                    let a = 0.15 + 0.35 * abs(sin(t * 0.7 + s))
                    g.fill(Path(ellipseIn: CGRect(x: abs(x) * size.width, y: y * size.height, width: 1.6, height: 1.6)), with: .color(Hud.green.opacity(a)))
                }
                // A scan line passing now and then.
                let scan = (t * 0.08).truncatingRemainder(dividingBy: 1.4)
                if scan < 1 {
                    let y = scan * size.height
                    g.fill(Path(CGRect(x: 0, y: y - 40, width: size.width, height: 80)), with: .linearGradient(Gradient(colors: [.clear, Hud.green.opacity(0.035), .clear]), startPoint: CGPoint(x: 0, y: y - 40), endPoint: CGPoint(x: 0, y: y + 40)))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Glass

struct Glass: ViewModifier {
    var lit = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.02, green: 0.09, blue: 0.13).opacity(0.72)))
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinearGradient(colors: [Hud.green.opacity(lit ? 0.9 : 0.45), Hud.green.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: Hud.green.opacity(lit ? 0.35 : 0.12), radius: lit ? 14 : 8)
    }
}
extension View { func glass(lit: Bool = false) -> some View { modifier(Glass(lit: lit)) } }

/// A dock button: a symbol over a short word.
struct DockButton: View {
    let symbol: String
    let title: String
    let hint: String
    var lit = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(Hud.mono(9, .bold)).tracking(2)
            }
            .foregroundColor(lit ? .white : Hud.soft)
            .frame(width: 78, height: 54)
            .glass(lit: lit || hover)
            .scaleEffect(hover ? 1.04 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain).focusRing()
        .onHover { hover = $0 }
        .accessibilityLabel(hint)
    }
}

/// A small label and value, for the top bar.
struct Chip: View {
    let label: String
    let value: String
    var live = true
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(Hud.mono(9)).tracking(2).foregroundColor(Hud.dim)
            Text(value).font(Hud.mono(10, .semibold)).tracking(1).foregroundColor(live ? Hud.soft : Hud.dim).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glass()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The console

struct HoloConsole: View {
    @ObservedObject var link: Link
    @ObservedObject var voice = VoiceControl.shared
    let active: Bool
    @State private var showLog = false
    @State private var showMore = false
    @State private var time = ""
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    let groups: [(String, [Command])]

    /// The keyboard appears while the piano is in use, and tucks itself away after a quiet spell.
    var pianoBusy: Bool {
        ["compose", "teach", "jazz"].contains(link.mode) || Link.clock() - (link.ripples.last?.at ?? -100) < 12
    }

    var body: some View {
        ZStack {
            HoloBackground(active: active)
            VStack(spacing: 0) {
                topBar.scaleEffect(link.large ? 1.2 : 1, anchor: .top).padding(.horizontal, 22).padding(.top, 30)
                Spacer(minLength: 6)
                HoloCore(link: link, active: active).frame(maxWidth: 520, maxHeight: 520).padding(.horizontal, 40)
                VStack(spacing: 8) {
                    ActivityLine(link: link)
                    Caption(link: link, active: active).frame(maxWidth: 900)
                    if !link.heard.isEmpty && !link.speaking {
                        Text("\u{201C}" + link.heard + "\u{201D}").font(Hud.mono(12)).foregroundColor(Hud.dim).lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 30)
                Spacer(minLength: 6)
                if pianoBusy {
                    VStack(spacing: 6) { Legend(link: link); Keys(link: link, active: active).frame(height: 118) }
                        .padding(12).glass().padding(.horizontal, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                dock.scaleEffect(link.large ? 1.3 : 1).padding(.vertical, link.large ? 26 : 16)
            }
            .animation(.easeOut(duration: 0.35), value: pianoBusy)
            // Drawers.
            HStack {
                if showLog { logDrawer.transition(.move(edge: .leading).combined(with: .opacity)) }
                Spacer()
                if showMore { moreDrawer.transition(.move(edge: .trailing).combined(with: .opacity)) }
            }
            .padding(.top, 84).padding(.bottom, 96).padding(.horizontal, 18)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showLog)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showMore)
        }
        .overlay(FlashFrame(link: link).allowsHitTesting(false))
        .onReceive(tick) { _ in let f = DateFormatter(); f.dateFormat = "HH:mm"; time = f.string(from: Date()) }
    }

    var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(link.tint).frame(width: 8, height: 8).shadow(color: link.tint, radius: 6)
                Text(link.assistant.uppercased().map(String.init).joined(separator: " "))
                    .font(Hud.mono(18, .bold)).foregroundColor(.white).shadow(color: Hud.green, radius: 10)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Chip(label: "MODE", value: link.modeName)
            if !link.now.isEmpty { Chip(label: "NOW", value: link.now.uppercased()) }
            Chip(label: "VOICE", value: link.voice.isEmpty ? "…" : link.voice.uppercased())
            Chip(label: "PIANO", value: !link.pianoOn ? "IGNORED" : link.keyboards.isEmpty ? "NONE" : "CONNECTED", live: link.pianoOn && !link.keyboards.isEmpty)
            if link.daw { Chip(label: "DAW", value: "LINKED") }
            if !link.brain.isEmpty { Chip(label: "BRAIN", value: link.brain == "claude" ? "CLAUDE" : link.brain == "built-in" ? "BUILT-IN ONLY" : "OFF", live: link.brain == "claude") }
            if !link.chord.isEmpty { Chip(label: "CHORD", value: link.chord) }
            Text(time).font(Hud.mono(13, .semibold)).foregroundColor(Hud.soft).padding(.leading, 6).accessibilityHidden(true)
        }
    }

    var dock: some View {
        HStack(spacing: 12) {
            DockButton(symbol: "list.bullet.rectangle", title: "LOG", hint: showLog ? "Hide the conversation" : "Show the conversation", lit: showLog) { showLog.toggle() }
            DockButton(symbol: voice.on ? "ear.fill" : "ear", title: voice.on ? "LISTENING" : "EARS OFF",
                       hint: voice.on ? "Stop listening for \(link.assistant)'s name" : "Listen for \(link.assistant)'s name", lit: voice.on) { voice.toggle() }
            DockButton(symbol: voice.talking ? "waveform" : "mic.fill", title: voice.talking ? "SEND" : "TALK",
                       hint: voice.talking ? "Listening. Press again to send." : "Talk to \(link.assistant) without the name. Option Space works from any app.", lit: voice.talking) {
                voice.beginTalking(toggle: true)
            }
            .scaleEffect(1.12).padding(.horizontal, 6)
            DockButton(symbol: link.pianoOn ? "pianokeys" : "pianokeys.inverse", title: link.pianoOn ? "PIANO" : "PIANO OFF",
                       hint: link.pianoOn ? "The piano's keys work. Press to make \(link.assistant) ignore the piano." : "The piano is ignored. Press to listen to it again.", lit: link.pianoOn) {
                link.send(link.pianoOn ? "~piano 0\n" : "~piano 1\n")
            }
            DockButton(symbol: "square.grid.2x2", title: "MORE", hint: showMore ? "Hide the commands" : "Show every command, MIDI files and the visualiser", lit: showMore) { showMore.toggle() }
        }
    }

    var logDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONVERSATION").font(Hud.mono(11, .semibold)).tracking(4).foregroundColor(Hud.dim).accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(link.transcript) { line in
                            let mine = line.text.hasPrefix("\u{25B8}")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.time).font(Hud.mono(9)).foregroundColor(Hud.dim)
                                Text(line.text).font(Hud.mono(12, mine ? .semibold : .regular)).foregroundColor(mine ? .white : Hud.soft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Hud.green.opacity(mine ? 0.10 : 0.04)))
                            .id(line.id)
                        }
                    }
                }
                .onAppear { if let last = link.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: link.transcript.count) { _ in if let last = link.transcript.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
        }
        .padding(16).frame(width: 330).frame(maxHeight: .infinity).glass()
        .accessibilityLabel("Conversation: everything said")
    }

    var moreDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HudButton(title: "MIDI FILE", hint: "Choose a MIDI file and watch its notes fall onto the keys") { link.chooseFile() }
                HudButton(title: "BAND A MIDI", hint: "Choose a MIDI file and the band plays along with it") { link.chooseFile(band: true) }
                HudButton(title: "VISUALISER", hint: "Open the visualiser: your playing as rising light") { link.visual = true }
                HudButton(title: "SETTINGS", hint: "Open the settings") { link.settings = true }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(groups, id: \.0) { group in
                        Text(group.0).font(Hud.mono(10, .semibold)).tracking(3).foregroundColor(Hud.dim).padding(.top, 8).accessibilityAddTraits(.isHeader)
                        ForEach(group.1.filter { $0.only == nil || $0.only == link.mode }) { CommandButton(command: $0, composing: link.mode == "compose") }
                    }
                    if !link.jazz.isEmpty {
                        Text("JAZZ LESSONS").font(Hud.mono(10, .semibold)).tracking(3).foregroundColor(Hud.dim).padding(.top, 8).accessibilityAddTraits(.isHeader)
                        ForEach(Array(link.jazz.enumerated()), id: \.offset) { i, title in
                            CommandButton(command: Command("\(i + 1)", "~jazz \(i + 1)\n", title), composing: false)
                        }
                    }
                }
            }
        }
        .padding(16).frame(width: 370).frame(maxHeight: .infinity).glass()
    }
}

// MARK: - Start-up

struct BootSequence: View {
    let assistant: String
    let done: () -> Void
    @State private var started = 0.0
    private let lines = ["CORE SYSTEMS", "AUDIO ENGINE", "VOICE SYNTHESIS", "SPEECH RECOGNITION", "MIDI INTERFACE", "NEURAL LINK"]
    static let length = 3.4

    var body: some View {
        TimelineView(.animation) { _ in
            let t = started == 0 ? 0 : Link.clock() - started
            ZStack {
                Color.black.opacity(max(0, min(1, (BootSequence.length + 0.6 - t) / 0.6)))
                Canvas { g, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    // Rings drawing themselves in, one after another.
                    for k in 0..<4 {
                        let p0 = max(0, min(1, (t - 0.2 - Double(k) * 0.25) / 0.9))
                        guard p0 > 0 else { continue }
                        let r = CGFloat(70 + k * 44) * (t > 2.9 ? 1 + CGFloat(t - 2.9) * 1.6 : 1)
                        var p = Path()
                        p.addArc(center: c, radius: r, startAngle: .degrees(-90 + Double(k) * 40), endAngle: .degrees(-90 + Double(k) * 40 + 360 * p0), clockwise: false)
                        let fade = t > 2.9 ? max(0, 1 - (t - 2.9) * 2) : 1
                        g.stroke(p, with: .color(Hud.green.opacity(0.8 * fade)), lineWidth: k == 0 ? 3 : 1.5)
                    }
                    let flare = max(0, 1 - abs(t - 2.7) * 3)
                    if flare > 0 {
                        g.drawLayer { l in
                            l.addFilter(.blur(radius: 30))
                            l.fill(Path(ellipseIn: CGRect(x: c.x - 90, y: c.y - 90, width: 180, height: 180)), with: .color(Hud.green.opacity(flare)))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let at = 0.35 + Double(i) * 0.33
                        if t > at {
                            HStack {
                                Text(line).foregroundColor(Hud.soft)
                                Spacer()
                                Text(t > at + 0.22 ? "ONLINE" : "…").foregroundColor(t > at + 0.22 ? Hud.green : Hud.dim)
                            }
                            .font(Hud.mono(11)).tracking(2).frame(width: 300)
                        }
                    }
                    // A segmented progress bar.
                    HStack(spacing: 3) {
                        ForEach(0..<24, id: \.self) { i in
                            Rectangle().fill(Double(i) / 24 < min(1, t / 2.6) ? Hud.green : Hud.faint).frame(width: 9.5, height: 5)
                        }
                    }
                    .padding(.top, 6)
                    Text(t < 2.6 ? "INITIALISING" : "\(assistant.uppercased()) ONLINE").font(Hud.mono(12, .bold)).tracking(5).foregroundColor(.white).padding(.top, 2)
                }
                .padding(.bottom, 60)
                .opacity(max(0, min(1, (BootSequence.length - t) / 0.4)))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            started = Link.clock()
            Sfx.shared.play(.boot)
            DispatchQueue.main.asyncAfter(deadline: .now() + BootSequence.length + 0.6) { done() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(assistant) is starting")
    }
}

// MARK: - Sounds

/// The interface sounds, made from tones and noise when the app starts: nothing to download,
/// nothing to credit.
final class Sfx {
    static let shared = Sfx()
    enum Cue: CaseIterable { case boot, wake, listen, tool, done, error }
    static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "sfxOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "sfxOff") }
    }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let music = AVAudioPlayerNode()
    private let rate = 44100.0
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var ready = false
    private let queue = DispatchQueue(label: "nova.sfx")

    private func prepare() -> Bool {
        if ready { return engine.isRunning || (try? engine.start()) != nil }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return false }
        engine.attach(player); engine.attach(music)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(music, to: engine.mainMixerNode, format: nil)
        player.volume = 0.55
        music.volume = 0.32
        for cue in Cue.allCases { buffers[cue] = render(cue, format) }
        do { try engine.start() } catch { return false }
        ready = true
        return true
    }

    /// Saves a sound to a file, for listening to it outside the app. Returns the loudest sample.
    func save(_ cue: Cue, to path: String) -> Float {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2), let b = render(cue, format),
              let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings) else { return -1 }
        try? file.write(from: b)
        var peak: Float = 0
        if let ch = b.floatChannelData { for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[0][i]), abs(ch[1][i])) } }
        return peak
    }

    func play(_ cue: Cue) {
        guard Sfx.enabled else { return }
        queue.async {
            guard self.prepare(), let b = self.buffers[cue] else { return }
            self.player.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
            if !self.player.isPlaying { self.player.play() }
        }
    }

    // A tone with a quick attack and an exponential tail; a band of noise sweeping between two pitches.
    private func render(_ cue: Cue, _ format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let length: Double = cue == .boot ? 4.8 : 0.7
        let n = Int(length * rate)
        var out = [Float](repeating: 0, count: n)
        var pan = [Float](repeating: 0, count: n)          // -1 left, +1 right
        func blip(_ f: Double, at: Double = 0, dur: Double = 0.12, wave: Int = 0, gain: Double = 0.25, to: Double = 0, side: Float = 0) {
            var phase = 0.0
            let start = Int(at * rate), count = Int(dur * rate)
            for i in 0..<count where start + i < n {
                let x = Double(i) / Double(count)
                let freq = to > 0 ? f * pow(to / f, x) : f
                phase += 2 * .pi * freq / rate
                let s: Double
                switch wave {
                case 1: s = 2 * (phase / (2 * .pi) - floor(phase / (2 * .pi) + 0.5))       // saw
                case 2: s = sin(phase) >= 0 ? 1 : -1                                     // square
                default: s = sin(phase)
                }
                let attack = min(1, Double(i) / (0.008 * rate))
                let env = attack * gain * exp(-x * 5.5)
                out[start + i] += Float(s * env); pan[start + i] = side
            }
        }
        func noise(at: Double = 0, dur: Double = 0.4, gain: Double = 0.12, from: Double = 400, to: Double = 6000) {
            let start = Int(at * rate), count = Int(dur * rate)
            var y1 = 0.0, y2 = 0.0, x1 = 0.0, x2 = 0.0
            for i in 0..<count where start + i < n {
                let x = Double(i) / Double(count)
                let f = from * pow(to / from, x)
                let w0 = 2 * .pi * f / rate, q = 1.2, al = sin(w0) / (2 * q)
                let b0 = al, b2 = -al, a0 = 1 + al, a1 = -2 * cos(w0), a2 = 1 - al
                let input = Double.random(in: -1...1)
                let y = (b0 * input + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = input; y2 = y1; y1 = y
                let env = gain * (x < 0.25 ? x / 0.25 : exp(-(x - 0.25) * 4))
                out[start + i] += Float(y * env)
            }
        }
        // A chord of slightly detuned saw waves through a filter that slowly opens: a cinematic swell.
        func swell(_ freqs: [Double], at: Double, dur: Double, gain: Double, from: Double = 160, to: Double = 2800) {
            let start = Int(at * rate), count = Int(dur * rate)
            var phases = [Double](repeating: 0, count: freqs.count * 2)
            var lp = 0.0, lp2 = 0.0
            for i in 0..<count where start + i < n {
                let x = Double(i) / Double(count)
                var s = 0.0
                for (k, f) in freqs.enumerated() {
                    for d in 0..<2 {
                        let j = k * 2 + d
                        phases[j] += (f * (d == 0 ? 0.996 : 1.004)) / rate
                        s += 2 * (phases[j] - floor(phases[j] + 0.5))
                    }
                }
                s /= Double(freqs.count * 2)
                let cut = from * pow(to / from, min(1, x * 1.25))
                let a = 1 - exp(-2 * .pi * cut / rate)
                lp += a * (s - lp); lp2 += a * (lp - lp2)
                // Rises slowly, holds, then fades away.
                let rise = x < 0.6 ? pow(x / 0.6, 2.2) : 1
                let env = rise * (x > 0.62 ? exp(-(x - 0.62) * 6) : 1)
                out[start + i] += Float(lp2 * env * gain)
            }
        }
        func boom(at: Double, gain: Double) {
            let start = Int(at * rate), count = Int(1.6 * rate)
            var phase = 0.0
            for i in 0..<count where start + i < n {
                let x = Double(i) / rate
                phase += 2 * .pi * (46 + 30 * exp(-x * 9)) / rate
                out[start + i] += Float(sin(phase) * gain * exp(-x * 2.6) * min(1, x / 0.004))
            }
        }
        switch cue {
        case .boot:
            // Underneath it all: a D minor swell opening up, and a deep boom as it comes online.
            swell([73.4, 110, 146.8, 174.6, 220, 293.7], at: 0, dur: 4.4, gain: 0.55)
            boom(at: 2.55, gain: 0.35)
            // Power coming up: a low hum and a rising sweep under stacked fifths.
            noise(dur: 2.4, gain: 0.14, from: 120, to: 5200)
            blip(55, dur: 2.6, wave: 1, gain: 0.10, to: 110)
            blip(110, at: 0.05, dur: 2.4, wave: 1, gain: 0.08, to: 880)
            blip(220, at: 0.12, dur: 2.2, gain: 0.08, to: 1320)
            // Systems reporting in: quick digital chirps, left and right.
            for k in 0..<6 { blip([1760, 2093, 1568, 2349, 1975, 2637][k], at: 0.35 + Double(k) * 0.33 + 0.22, dur: 0.06, wave: 2, gain: 0.05, side: k % 2 == 0 ? -0.6 : 0.6) }
            // Online: a clean rising third, then a soft air release.
            blip(880, at: 2.55, dur: 0.35, gain: 0.2)
            blip(1320, at: 2.7, dur: 0.6, gain: 0.22)
            noise(at: 2.6, dur: 0.9, gain: 0.06, from: 6000, to: 900)
        case .wake:
            blip(1046, dur: 0.09, gain: 0.22); blip(1568, at: 0.07, dur: 0.14, gain: 0.2)
        case .listen:
            blip(660, dur: 0.1, gain: 0.14); blip(990, at: 0.06, dur: 0.12, gain: 0.1)
        case .tool:
            blip(2200, dur: 0.05, wave: 2, gain: 0.06); noise(dur: 0.1, gain: 0.05, from: 3000, to: 900)
        case .done:
            blip(1320, dur: 0.1, gain: 0.14); blip(880, at: 0.08, dur: 0.2, gain: 0.13)
        case .error:
            blip(320, dur: 0.18, wave: 2, gain: 0.12); blip(226, at: 0.13, dur: 0.3, wave: 2, gain: 0.1)
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let s = max(-1, min(1, out[i])), p = pan[i]
            ch[0][i] = s * (p > 0 ? 1 - p : 1); ch[1][i] = s * (p < 0 ? 1 + p : 1)
        }
        return buf
    }
}
