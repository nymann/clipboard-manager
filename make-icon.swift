// Generates a macOS .iconset (10 PNGs at the standard sizes) for the
// clipboard-manager app icon — the `doc.on.clipboard.fill` SF Symbol
// on an indigo rounded square. Build the .icns from the output with:
//
//   iconutil -c icns <iconset-dir> -o AppIcon.icns
//
// Re-run only when tweaking the colour/glyph (`just icon`); the .icns
// is assembled into the bundle at build time.

import AppKit
import Foundation

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <iconset-output-dir>\n".utf8))
    exit(2)
}
let outDir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let background = NSColor(srgbRed: 0.35, green: 0.36, blue: 0.86, alpha: 1.0)

func render(pixels: Int) -> Data {
    // Draw into a 1:1 NSBitmapImageRep so the PNG has exactly the
    // requested pixel dimensions (NSImage.lockFocus() would pick up
    // the screen backing scale and emit 2x-too-big PNGs).
    let p = pixels
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: p,
        pixelsHigh: p,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!

    let prior = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.current = prior }

    let s = CGFloat(p)
    let inset = s * 0.08
    let cornerRadius = s * 0.22
    let bgRect = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: inset, dy: inset)
    background.setFill()
    NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let m = glyph.size
        glyph.draw(in: NSRect(
            x: (s - m.width) / 2,
            y: (s - m.height) / 2,
            width: m.width,
            height: m.height
        ))
    }

    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in sizes {
    let png = render(pixels: pixels)
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
