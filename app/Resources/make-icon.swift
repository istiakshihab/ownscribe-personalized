// Draws the Earshot logo and writes AppIcon.icns plus a 1024 px Logo.png.
//
//   swift app/Resources/make-icon.swift [OUTPUT_DIR]     (default: app/Resources)
//
// The mark: a red recording dot with three sound arcs reaching out from it ("within earshot"),
// coloured like the app's sources: orange for the mic, blue for system audio, green for apps.
// Full-bleed artwork; macOS masks it to the app-icon shape.

import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().path)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the logo into a square context of side `s` (y up, CoreGraphics coordinates).
func drawLogo(_ ctx: CGContext, _ s: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Background: deep night blue, a little lighter at the top.
    let bg = CGGradient(colorsSpace: space, colors: [color(0x22355C), color(0x0C1426)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    // Soft light from the upper left.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x5B7BB8, 0.35), color(0x5B7BB8, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.25, y: s * 0.85), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.25, y: s * 0.85), endRadius: s * 0.75, options: [])

    let center = CGPoint(x: s * 0.345, y: s * 0.5)
    let span = CGFloat.pi * 0.31   // half-angle of each arc
    let width = s * 0.054
    let arcs: [(radius: CGFloat, color: UInt32)] = [
        (s * 0.152, 0xF27A36),   // mic: orange
        (s * 0.262, 0x3F8CFF),   // system audio: blue
        (s * 0.372, 0x22C08A),   // apps: green
    ]
    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    for arc in arcs {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.02, color: color(0x000000, 0.35))
        ctx.setStrokeColor(color(arc.color))
        ctx.addArc(center: center, radius: arc.radius, startAngle: -span, endAngle: span, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // The recording dot, with a soft red halo.
    let r = s * 0.07
    let halo = CGGradient(colorsSpace: space, colors: [color(0xFF4A3D, 0.45), color(0xFF4A3D, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: center, startRadius: r * 0.8, endCenter: center, endRadius: r * 2.2, options: [])
    let dot = CGGradient(colorsSpace: space, colors: [color(0xFF6B5E), color(0xE5352B)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    ctx.drawLinearGradient(dot, start: CGPoint(x: center.x, y: center.y + r), end: CGPoint(x: center.x, y: center.y - r), options: [])
    ctx.restoreGState()
}

func png(side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    drawLogo(ctx.cgContext, CGFloat(side))
    ctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(side: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(side: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
try png(side: 1024).write(to: outputDir.appendingPathComponent("Logo.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(outputDir.path)/AppIcon.icns and Logo.png" : "iconutil failed")
