// makebanner.swift — renders the README hero banner (1600×420) to argv[1].
// Diagonal blue→indigo gradient, the app icon, wordmark and stack tagline.
import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "banner.png"
let W: CGFloat = 1600, H: CGFloat = 420

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

// background gradient
NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.38, blue: 0.98, alpha: 1.0),
    NSColor(srgbRed: 0.38, green: 0.16, blue: 0.80, alpha: 1.0)
])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -32)

// soft radial highlight
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

// app icon (glassy rounded square + glyph)
let s: CGFloat = 236
let iconRect = NSRect(x: 84, y: (H - s) / 2, width: s, height: s)
let ipath = NSBezierPath(roundedRect: iconRect, xRadius: s * 0.2237, yRadius: s * 0.2237)
NSGraphicsContext.saveGraphicsState()
ipath.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0.05)])!
    .draw(in: iconRect, angle: -90)
NSGraphicsContext.restoreGraphicsState()
if let sym = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil),
   let sized = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .regular)) {
    let white = NSImage(size: sized.size, flipped: false) { r in
        sized.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
    }
    let w = sized.size.width, h = sized.size.height
    white.draw(in: NSRect(x: iconRect.midX - w / 2, y: iconRect.midY - h / 2, width: w, height: h))
}

func draw(_ t: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat) {
    let a: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha)
    ]
    (t as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: a)
}

// faint server-rack watermark on the right to balance the composition
if let sym = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil),
   let sized = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 380, weight: .regular)) {
    let faint = NSImage(size: sized.size, flipped: false) { r in
        sized.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
    }
    let w = sized.size.width, h = sized.size.height
    faint.draw(in: NSRect(x: W - w - 70, y: (H - h) / 2, width: w, height: h),
               from: .zero, operation: .sourceOver, fraction: 0.09)
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
