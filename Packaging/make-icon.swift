// Draws the app icon and writes Packaging/TidyMac.icns. Run it from the repository root after changing the design:
//   swift Packaging/make-icon.swift
//
// The "T" and the dot are plain geometry on purpose: Apple's license does not allow SF Symbols in app icons.
import AppKit

func color(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Drawn on a 1024-point canvas and scaled, with the margins and corner radius of Apple's macOS icon grid.
func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1B5BE0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x5CC0FF), color(0x2E8BFF), color(0x1B5BE0)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 240, y: 924), end: CGPoint(x: 800, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // A soft light from the top, so the surface does not read as flat.
    let sheen = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 512, y: 960), startRadius: 0, endCenter: CGPoint(x: 512, y: 960), endRadius: 620, options: [])
    ctx.restoreGState()

    // A bold glassy "T" (white fading to ice blue) with a round dot low in its stem.
    let t = CGMutablePath()
    t.addRoundedRect(in: CGRect(x: 236, y: 596, width: 552, height: 176), cornerWidth: 70, cornerHeight: 70)
    t.addRoundedRect(in: CGRect(x: 424, y: 228, width: 176, height: 470), cornerWidth: 70, cornerHeight: 70)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: CGColor(srgbRed: 0.03, green: 0.14, blue: 0.5, alpha: 0.45))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(t)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(t)
    ctx.clip()
    let glass = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xDCEEFF), color(0xA9D2FF)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(glass, start: CGPoint(x: 512, y: 772), end: CGPoint(x: 512, y: 228), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setFillColor(color(0x2F7BF0))
    ctx.fillEllipse(in: CGRect(x: 512 - 58, y: 318 - 58, width: 116, height: 116))
    ctx.restoreGState()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TidyMac-\(UUID().uuidString).iconset")
try fm.createDirectory(at: set, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: set) }
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: set.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: set.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", "Packaging/TidyMac.icns"]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
