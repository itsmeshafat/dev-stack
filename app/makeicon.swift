// makeicon.swift — renders the app icon (1024²) to a PNG path given as argv[1].
// Blue→indigo rounded square + white "server.rack" SF Symbol. No external assets.
import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let px: CGFloat = 1024
let inset: CGFloat = 44
let radius: CGFloat = (px - inset * 2) * 0.2237   // squircle-ish

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
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.23, green: 0.44, blue: 0.98, alpha: 1.0),   // blue
    NSColor(srgbRed: 0.36, green: 0.19, blue: 0.82, alpha: 1.0)    // indigo
])!
grad.draw(in: path, angle: -90)

// top highlight
if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let hi = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)])!
    hi.draw(in: NSRect(x: inset, y: px * 0.55, width: px - inset * 2, height: px * 0.45), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

// white glyph
if let sym = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.40, weight: .regular)
    if let sized = sym.withSymbolConfiguration(cfg) {
        let white = NSImage(size: sized.size, flipped: false) { r in
            sized.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let w = sized.size.width, h = sized.size.height
        let dst = NSRect(x: (px - w) / 2, y: (px - h) / 2 - px * 0.01, width: w, height: h)
        white.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}

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
