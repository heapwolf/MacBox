// Renders the app icon: the Apple logo on a standard macOS icon tile.
// Usage: swiftc App/icon.swift -o icon && ./icon <output.iconset>

import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    // Apple's macOS icon grid: an 824pt rounded square centered on a 1024pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSGradient(starting: .white, ending: NSColor(white: 0.86, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185), angle: -90)

    let symbol = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 440, weight: .regular).applying(.init(paletteColors: [.black])))!
    let size = symbol.size
    // Nudged up slightly: the leaf makes the logo look low when centered by its bounds.
    symbol.draw(in: NSRect(x: 512 - size.width / 2, y: 512 - size.height / 2 + 12, width: size.width, height: size.height))

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
