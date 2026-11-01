// makebanner.swift — renders the README hero banner (1600×420) to argv[1].
// Diagonal gradient, the icon tile, wordmark, tagline and an original rack glyph.
// No third-party assets, no SF Symbols, no stock art.
import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "banner.png"
let W: CGFloat = 1600, H: CGFloat = 420

func drawRackGlyph(in rect: NSRect, color: NSColor, thickness: CGFloat) {
    color.setStroke()
    color.setFill()
    let body = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.14, yRadius: rect.width * 0.14)
    body.lineWidth = thickness
    body.stroke()
    let lines = NSBezierPath()
    for i in 1...2 {
        let y = rect.minY + rect.height * CGFloat(i) / 3.0
        lines.move(to: NSPoint(x: rect.minX + thickness / 2, y: y))
        lines.line(to: NSPoint(x: rect.maxX - thickness / 2, y: y))
    }
    lines.lineWidth = thickness
    lines.stroke()
    let dotR = thickness * 0.85
    for i in 0..<3 {
        let cy = rect.minY + rect.height * (CGFloat(i) + 0.5) / 3.0
        let cx = rect.maxX - rect.width * 0.17
        NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)).fill()
    }
}

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

// background gradient
NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.38, blue: 0.98, alpha: 1.0),
    NSColor(srgbRed: 0.38, green: 0.16, blue: 0.80, alpha: 1.0)
])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -32)

// soft radial highlights
if let ctx = NSGraphicsContext.current?.cgContext {
    let cols = [NSColor.white.withAlphaComponent(0.20).cgColor,
                NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 1]) {
        let c = CGPoint(x: W * 0.16, y: H * 0.86)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 8, endCenter: c, endRadius: 560, options: [])
    }
    let cols2 = [NSColor.black.withAlphaComponent(0.18).cgColor,
                 NSColor.black.withAlphaComponent(0.0).cgColor] as CFArray
    if let g2 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols2, locations: [0, 1]) {
        let c2 = CGPoint(x: W * 0.92, y: H * 0.06)
        ctx.drawRadialGradient(g2, startCenter: c2, startRadius: 8, endCenter: c2, endRadius: 620, options: [])
    }
}

// icon tile
let s: CGFloat = 236
let iconRect = NSRect(x: 84, y: (H - s) / 2, width: s, height: s)
let ipath = NSBezierPath(roundedRect: iconRect, xRadius: s * 0.2237, yRadius: s * 0.2237)
NSGraphicsContext.saveGraphicsState()
ipath.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0.05)])!
    .draw(in: iconRect, angle: -90)
NSGraphicsContext.restoreGraphicsState()

let gw = s * 0.46
let glyph = NSRect(x: iconRect.midX - gw / 2, y: iconRect.midY - gw * 0.41,
                   width: gw, height: gw * 0.82)
drawRackGlyph(in: glyph, color: .white, thickness: s * 0.030)

// faint watermark to balance the composition
let ww: CGFloat = 250
let watermark = NSRect(x: W - ww - 96, y: (H - ww * 0.82) / 2, width: ww, height: ww * 0.82)
drawRackGlyph(in: watermark, color: NSColor.white.withAlphaComponent(0.10), thickness: ww * 0.030)

func draw(_ t: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat) {
    let a: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha)
    ]
    (t as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: a)
}

draw("dev-stack", 384, 132, 116, .bold, 1.0)
draw("Local dev stack for macOS", 390, 274, 40, .medium, 0.90)
draw("nginx · Apache · MySQL · PostgreSQL · Redis · Mailpit · PHP 8.5/8.3/7.4", 392, 64, 26, .medium, 0.72)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("render failed\n".data(using: .utf8)!); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
