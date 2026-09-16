import AppKit
import Foundation

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let resources = root.appendingPathComponent("Resources", isDirectory: true)
private let iconset = resources.appendingPathComponent("PixyBar.iconset", isDirectory: true)
private let output = resources.appendingPathComponent("AppIcon.icns")

private struct IconFile {
    let name: String
    let pixels: Int
}

private let files = [
    IconFile(name: "icon_16x16.png", pixels: 16),
    IconFile(name: "icon_16x16@2x.png", pixels: 32),
    IconFile(name: "icon_32x32.png", pixels: 32),
    IconFile(name: "icon_32x32@2x.png", pixels: 64),
    IconFile(name: "icon_128x128.png", pixels: 128),
    IconFile(name: "icon_128x128@2x.png", pixels: 256),
    IconFile(name: "icon_256x256.png", pixels: 256),
    IconFile(name: "icon_256x256@2x.png", pixels: 512),
    IconFile(name: "icon_512x512.png", pixels: 512),
    IconFile(name: "icon_512x512@2x.png", pixels: 1024)
]

private let icnsChunks = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic10", "icon_512x512@2x.png")
]

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendBigEndianUInt32(_ value: Int) {
        var number = UInt32(value).bigEndian
        Swift.withUnsafeBytes(of: &number) { append(contentsOf: $0) }
    }
}

private func scaledRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, scale: CGFloat) -> NSRect {
    NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
}

private func drawPill(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

private func drawIcon(pixels: Int) throws -> Data {
    let size = CGFloat(pixels)
    let scale = size / 1024.0
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "PixyBarIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate bitmap"])
    }

    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let background = NSBezierPath(roundedRect: scaledRect(48, 48, 928, 928, scale: scale), xRadius: 214 * scale, yRadius: 214 * scale)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.13, alpha: 1.0),
        NSColor(calibratedRed: 0.10, green: 0.38, blue: 0.39, alpha: 1.0)
    ])?.draw(in: background, angle: -38)

    NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
    background.lineWidth = max(1.0, 6.0 * scale)
    background.stroke()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -18 * scale)
    shadow.shadowBlurRadius = 38 * scale

    let highlight = NSShadow()
    highlight.shadowColor = NSColor(calibratedWhite: 1.0, alpha: 0.18)
    highlight.shadowOffset = NSSize(width: 0, height: 4 * scale)
    highlight.shadowBlurRadius = 8 * scale

    shadow.set()
    let base = NSBezierPath(roundedRect: scaledRect(294, 180, 436, 116, scale: scale), xRadius: 58 * scale, yRadius: 58 * scale)
    NSColor(calibratedRed: 0.78, green: 0.84, blue: 0.85, alpha: 1.0).setFill()
    base.fill()

    let neck = NSBezierPath(roundedRect: scaledRect(454, 276, 116, 128, scale: scale), xRadius: 48 * scale, yRadius: 48 * scale)
    NSColor(calibratedRed: 0.82, green: 0.88, blue: 0.89, alpha: 1.0).setFill()
    neck.fill()

    shadow.set()
    let head = NSBezierPath(roundedRect: scaledRect(168, 366, 688, 360, scale: scale), xRadius: 136 * scale, yRadius: 136 * scale)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.95, green: 0.98, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.69, green: 0.77, blue: 0.78, alpha: 1.0)
    ])?.draw(in: head, angle: 90)

    highlight.set()
    NSColor(calibratedWhite: 1.0, alpha: 0.24).setStroke()
    head.lineWidth = max(1.0, 10.0 * scale)
    head.stroke()

    NSShadow().set()
    let mainLens = NSBezierPath(ovalIn: scaledRect(270, 448, 204, 204, scale: scale))
    NSGradient(colors: [
        NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.07, alpha: 1.0),
        NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.25, alpha: 1.0)
    ])?.draw(in: mainLens, angle: 45)

    NSColor(calibratedRed: 0.50, green: 0.88, blue: 0.90, alpha: 0.72).setFill()
    NSBezierPath(ovalIn: scaledRect(326, 544, 52, 52, scale: scale)).fill()

    let sideLens = NSBezierPath(ovalIn: scaledRect(558, 480, 142, 142, scale: scale))
    NSGradient(colors: [
        NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.08, alpha: 1.0),
        NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.22, alpha: 1.0)
    ])?.draw(in: sideLens, angle: 45)

    NSColor(calibratedRed: 0.52, green: 0.90, blue: 0.86, alpha: 1.0).setFill()
    NSBezierPath(ovalIn: scaledRect(730, 606, 42, 42, scale: scale)).fill()

    drawPill(scaledRect(390, 240, 244, 38, scale: scale), radius: 19 * scale, fill: NSColor(calibratedWhite: 1.0, alpha: 0.18))

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PixyBarIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    return data
}

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: iconset.path) {
    try FileManager.default.removeItem(at: iconset)
}
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for file in files {
    let data = try drawIcon(pixels: file.pixels)
    try data.write(to: iconset.appendingPathComponent(file.name))
}

var chunks = Data()
for (type, fileName) in icnsChunks {
    let png = try Data(contentsOf: iconset.appendingPathComponent(fileName))
    chunks.appendASCII(type)
    chunks.appendBigEndianUInt32(png.count + 8)
    chunks.append(png)
}

var icns = Data()
icns.appendASCII("icns")
icns.appendBigEndianUInt32(chunks.count + 8)
icns.append(chunks)
try icns.write(to: output)

print("Wrote \(output.path)")
