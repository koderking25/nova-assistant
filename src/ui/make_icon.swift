// Draws the Talking Piano icon (black and green, a ring of sound around three piano keys)
// and writes it as a 1024-pixel PNG. build_app.sh turns that into the app's icon file.
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let g = NSGraphicsContext.current!.cgContext
func green(_ a: Double, _ soft: Bool = false) -> CGColor {
    soft ? CGColor(red: 0.62, green: 0.92, blue: 1.0, alpha: a) : CGColor(red: 0.30, green: 0.86, blue: 1.0, alpha: a)
}
let c = CGPoint(x: size / 2, y: size / 2)

// The tile: macOS's rounded square, nearly black with a green glow in the middle.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
g.saveGState()
g.addPath(shape); g.clip()
g.setFillColor(CGColor(red: 0.008, green: 0.022, blue: 0.014, alpha: 1)); g.fill(tile)
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [CGColor(red: 0.05, green: 0.30, blue: 0.17, alpha: 1), CGColor(red: 0.008, green: 0.022, blue: 0.014, alpha: 1)] as CFArray,
                      locations: [0, 1])!
g.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 470, options: [])
// A faint grid.
g.setStrokeColor(green(0.05)); g.setLineWidth(2)
var p = 100.0
while p < 924 { g.move(to: CGPoint(x: p, y: 100)); g.addLine(to: CGPoint(x: p, y: 924)); g.move(to: CGPoint(x: 100, y: p)); g.addLine(to: CGPoint(x: 924, y: p)); p += 68.7 }
g.strokePath()
g.restoreGState()
g.addPath(shape); g.setStrokeColor(green(0.55)); g.setLineWidth(5); g.strokePath()

// Outer rings: one thin full circle, and thick broken arcs.
g.setStrokeColor(green(0.25)); g.setLineWidth(3)
g.addEllipse(in: CGRect(x: c.x - 345, y: c.y - 345, width: 690, height: 690)); g.strokePath()
g.setShadow(offset: .zero, blur: 26, color: green(0.9))
g.setStrokeColor(green(1)); g.setLineWidth(17); g.setLineCap(.butt)
for (a0, a1) in [(0.35, 1.75), (2.25, 3.05), (3.75, 5.45)] {
    g.addArc(center: c, radius: 318, startAngle: a0, endAngle: a1, clockwise: false); g.strokePath()
}
g.setLineWidth(6); g.setStrokeColor(green(0.8))
for (a0, a1) in [(1.2, 2.6), (4.3, 6.0)] {
    g.addArc(center: c, radius: 283, startAngle: a0, endAngle: a1, clockwise: false); g.strokePath()
}

// The waveform: bars around a circle, taller on two sides like a voice.
g.setStrokeColor(green(1, true)); g.setLineWidth(8); g.setLineCap(.round)
g.setShadow(offset: .zero, blur: 14, color: green(0.9))
let bars = 72
for i in 0..<bars {
    let a = Double(i) / Double(bars) * 2 * .pi
    let voice = pow(abs(cos(a)), 1.6)
    let len = 14 + 62 * voice * (0.55 + 0.45 * abs(sin(Double(i) * 1.7)))
    g.move(to: CGPoint(x: c.x + cos(a) * 178, y: c.y + sin(a) * 178))
    g.addLine(to: CGPoint(x: c.x + cos(a) * (178 + len), y: c.y + sin(a) * (178 + len)))
}
g.strokePath()

// The heart: a dark disc holding three white keys and two black ones.
g.setShadow(offset: .zero, blur: 0, color: nil)
g.setFillColor(CGColor(red: 0.01, green: 0.05, blue: 0.03, alpha: 1))
g.fillEllipse(in: CGRect(x: c.x - 160, y: c.y - 160, width: 320, height: 320))
g.setStrokeColor(green(0.9)); g.setLineWidth(5)
g.strokeEllipse(in: CGRect(x: c.x - 160, y: c.y - 160, width: 320, height: 320))
let keyW = 58.0, keyH = 170.0, gap = 8.0
let left = c.x - (3 * keyW + 2 * gap) / 2, bottom = c.y - keyH / 2
g.setShadow(offset: .zero, blur: 18, color: green(0.8))
for i in 0..<3 {
    let r = CGRect(x: left + Double(i) * (keyW + gap), y: bottom, width: keyW, height: keyH)
    g.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
    g.setFillColor(i == 1 ? green(1, true) : green(0.9)); g.fillPath()
}
g.setShadow(offset: .zero, blur: 0, color: nil)
g.setFillColor(CGColor(red: 0.01, green: 0.05, blue: 0.03, alpha: 1))
for i in 0..<2 {
    let x = left + Double(i + 1) * (keyW + gap) - gap / 2 - 19
    g.fill(CGRect(x: x, y: bottom + keyH * 0.42, width: 38, height: keyH * 0.6))
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
