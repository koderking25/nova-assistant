// Draws the picture behind the icons in the download's window: Nova's dark green, with a
// large arrow from the app to the Applications folder and one line saying what to do.
import AppKit

let w = 660.0, h = 420.0, scale = 2.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let g = NSGraphicsContext.current!.cgContext
let green = CGColor(red: 0.30, green: 0.86, blue: 1.0, alpha: 1)

g.setFillColor(CGColor(red: 0.008, green: 0.03, blue: 0.018, alpha: 1)); g.fill(CGRect(x: 0, y: 0, width: w, height: h))
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.04, green: 0.22, blue: 0.12, alpha: 1), CGColor(red: 0.008, green: 0.03, blue: 0.018, alpha: 1)] as CFArray, locations: [0, 1])!
g.drawRadialGradient(glow, startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0, endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: 380, options: [])
g.setStrokeColor(green.copy(alpha: 0.06)!); g.setLineWidth(1)
var p = 0.0
while p < w { g.move(to: CGPoint(x: p, y: 0)); g.addLine(to: CGPoint(x: p, y: h)); p += 44 }
p = 0
while p < h { g.move(to: CGPoint(x: 0, y: p)); g.addLine(to: CGPoint(x: w, y: p)); p += 44 }
g.strokePath()

// The arrow, between where the two icons sit.
g.setShadow(offset: .zero, blur: 18, color: green.copy(alpha: 0.8)!)
g.setStrokeColor(green); g.setLineWidth(9); g.setLineCap(.round); g.setLineJoin(.round)
let y = 210.0
g.move(to: CGPoint(x: 262, y: y)); g.addLine(to: CGPoint(x: 392, y: y))
g.move(to: CGPoint(x: 362, y: y + 30)); g.addLine(to: CGPoint(x: 394, y: y)); g.addLine(to: CGPoint(x: 362, y: y - 30))
g.strokePath()
g.setShadow(offset: .zero, blur: 0, color: nil)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, tracking: CGFloat = 0) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style, .kern: tracking]
    NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 0, y: y, width: w, height: size * 1.5))
}
text("DRAG NOVA INTO APPLICATIONS", size: 24, weight: .bold, color: .white, y: 340, tracking: 3)
text("then open it from your Applications folder", size: 14, weight: .regular, color: NSColor(red: 0.55, green: 1, blue: 0.78, alpha: 1), y: 312)
text("N O V A", size: 12, weight: .bold, color: NSColor(red: 0.30, green: 0.86, blue: 1.0, alpha: 0.7), y: 26, tracking: 4)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
