// Renders Resources/AppIcon.icns: black rounded square with "OpenM600" in white.
// Usage: swift Scripts/make-icon.swift [stacked|single]   (default: stacked)
import AppKit

let layout = CommandLine.arguments.dropFirst().first ?? "stacked"
let outDir = "Resources"
let iconset = "\(NSTemporaryDirectory())AppIcon.iconset"

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~22.4% corner radius, centred.
    let body = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225).fill()

    let lines = layout == "single" ? ["OpenM600"] : ["Open", "M600"]
    let size = (layout == "single" ? 150 : 250) * s / 1024
    let font = NSFont.systemFont(ofSize: size, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: -size * 0.02]
    let lineH = size * 1.05
    var y = body.midY + lineH * CGFloat(lines.count) / 2 - lineH
    for l in lines {
        let str = NSAttributedString(string: l, attributes: attrs)
        let w = str.size().width
        str.draw(at: NSPoint(x: body.midX - w / 2, y: y + (lineH - font.ascender + font.descender) / 2 - font.descender * 0.0))
        y -= lineH
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "\(outDir)/AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
