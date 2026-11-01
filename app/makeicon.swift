// makeicon.swift — renders the app icon (1024²) to argv[1].
// Blue→indigo rounded square with an ORIGINAL vector "server rack" glyph.
// No third-party assets, no SF Symbols, no stock art.
import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let px: CGFloat = 1024
let inset: CGFloat = 44
let radius: CGFloat = (px - inset * 2) * 0.2237   // squircle-ish

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

let canvas = NSImage(size: NSSize(width: px, height: px))
canvas.lockFocus()

// subtle drop shadow
if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
}

// rounded-square gradient
let rect = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSGradient(colors: [
    NSColor(srgbRed: 0.23, green: 0.44, blue: 0.98, alpha: 1.0),   // blue
    NSColor(srgbRed: 0.36, green: 0.19, blue: 0.82, alpha: 1.0)    // indigo
])!.draw(in: path, angle: -90)

// top highlight
if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: NSRect(x: inset, y: px * 0.55, width: px - inset * 2, height: px * 0.45), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

// original glyph (centered, ~46% of the canvas)
let gw = (px - inset * 2) * 0.46
let glyph = NSRect(x: (px - gw) / 2, y: (px - gw * 0.82) / 2, width: gw, height: gw * 0.82)
drawRackGlyph(in: glyph, color: .white, thickness: px * 0.030)

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render icon\n".data(using: .utf8)!)
    exit(1)
}
do { try png.write(to: URL(fileURLWithPath: out)) }
catch { FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!); exit(1) }
print("wrote \(out)")
