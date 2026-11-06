// Draws the app icon and writes Packaging/TidyMac.icns. Run it from the repository root after changing the design:
//   swift Packaging/make-icon.swift
//
// The sparkle is plain geometry on purpose: Apple's license does not allow SF Symbols in app icons.
import AppKit

func color(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// A four-pointed star whose sides curve in towards the centre.
func sparkle(center c: CGPoint, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let tips = [CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - r, y: c.y)]
    path.move(to: tips[0])
    for i in 0..<4 {
        let next = tips[(i + 1) % 4]
        let mid = CGPoint(x: (tips[i].x + next.x) / 2, y: (tips[i].y + next.y) / 2)
        // Pulling the control point most of the way to the centre gives the sharp, narrow points.
        path.addQuadCurve(to: next, control: CGPoint(x: c.x + (mid.x - c.x) * 0.16, y: c.y + (mid.y - c.y) * 0.16))
    }
    path.closeSubpath()
    return path
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
    ctx.setFillColor(color(0x5728CC))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0xE352D3), color(0x7A3BE0), color(0x2B1E8C)] as CFArray, locations: [0, 0.52, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 240, y: 924), end: CGPoint(x: 800, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // A soft light from the top, so the surface does not read as flat.
    let sheen = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 512, y: 960), startRadius: 0, endCenter: CGPoint(x: 512, y: 960), endRadius: 620, options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 30, color: CGColor(srgbRed: 0.12, green: 0.04, blue: 0.4, alpha: 0.55))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(sparkle(center: CGPoint(x: 470, y: 470), radius: 262))
    ctx.fillPath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
    ctx.addPath(sparkle(center: CGPoint(x: 712, y: 712), radius: 108))
    ctx.fillPath()
    ctx.addPath(sparkle(center: CGPoint(x: 738, y: 318), radius: 58))
    ctx.fillPath()
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
