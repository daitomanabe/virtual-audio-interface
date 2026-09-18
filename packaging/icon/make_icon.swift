// Draws the app icon and builds AppIcon.icns next to this script:
//
//     swift packaging/icon/make_icon.swift
//
// A speaker dome seen from above, like the app's Top view of Examples/dome-24.sscene: ear-level,
// upper and top rings around the listener (facing front = up), two speakers lit in the level
// colors with their sounding lines, one of them selected. Every size is drawn from vectors;
// up to 64 px (32 pt @2x) get a simpler drawing (one ring, fewer and larger dots) so they stay readable.
// Needs only the macOS SDK (CoreGraphics, ImageIO, SwiftUI for the icon shape) and iconutil.
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// Same hues as Theme.swift.
let green = (0.22 as CGFloat, 0.82 as CGFloat, 0.38 as CGFloat)
let yellow = (1.00 as CGFloat, 0.80 as CGFloat, 0.12 as CGFloat)
let accent = rgb(0.25, 0.63, 1.00)

let center = CGPoint(x: 512, y: 512)

func point(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
    let a = degrees * .pi / 180
    return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
}

/// macOS icon body: 824 pt continuous-corner rounded square centered on the 1024 canvas. It must be
/// the system's own shape: macOS 26 puts an icon whose outline differs (e.g. a superellipse) on a
/// gray plate.
func bodyPath() -> CGPath {
    RoundedRectangle(cornerRadius: 824 * 0.225, style: .continuous)
        .path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath
}

func disc(_ cg: CGContext, _ p: CGPoint, _ r: CGFloat, _ color: CGColor) {
    cg.setFillColor(color)
    cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
}

func glow(_ cg: CGContext, _ p: CGPoint, _ r: CGFloat, _ c: (CGFloat, CGFloat, CGFloat), _ alpha: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [rgb(c.0, c.1, c.2, alpha), rgb(c.0, c.1, c.2, 0)] as CFArray,
                              locations: [0, 1])!
    cg.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
}

func draw(_ cg: CGContext, small: Bool) {
    let body = bodyPath()

    // Drop shadow, then the body: blue-black gradient with a soft light in the middle.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.45))
    cg.addPath(body)
    cg.setFillColor(rgb(0.06, 0.07, 0.10))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(body)
    cg.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)
    let fill = CGGradient(colorsSpace: space, colors: [rgb(0.13, 0.17, 0.27), rgb(0.035, 0.045, 0.07)] as CFArray,
                          locations: [0, 1])!
    cg.drawLinearGradient(fill, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    glow(cg, center, 420, (0.16, 0.30, 0.52), 0.55)

    // Rings: ear level, upper, top (full size); one ring when small.
    let rings: [CGFloat] = small ? [290] : [305, 205, 105]
    cg.setLineWidth(small ? 18 : 5)
    cg.setStrokeColor(rgb(1, 1, 1, small ? 0.16 : 0.11))
    for r in rings {
        cg.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    // Speakers (angle 90 = front). Lit ones are drawn afterwards, over their lines.
    let dim = rgb(0.30, 0.34, 0.42)
    /// `count` speakers of dot size `size` on a ring, the first at `start` degrees.
    func ring(_ radius: CGFloat, _ count: Int, _ start: CGFloat, _ size: CGFloat) -> [(CGFloat, CGFloat, CGFloat)] {
        (0..<count).map { (radius, start + CGFloat($0) * 360 / CGFloat(count), size) }
    }
    let speakers = small ? ring(290, 8, 90, 58) : ring(305, 8, 90, 27) + ring(205, 8, 112.5, 22) + ring(105, 4, 45, 18)
    let lit: [(radius: CGFloat, angle: CGFloat, size: CGFloat, color: (CGFloat, CGFloat, CGFloat))] = small
        ? [(290, 135, 78, yellow), (290, 45, 70, green)]
        : [(305, 135, 38, yellow), (205, 67.5, 30, green)]
    for (r, a, size) in speakers where !lit.contains(where: { $0.radius == r && $0.angle == a }) {
        disc(cg, point(r, a), size, dim)
    }

    // Sounding lines from the listener, glows, lit speakers.
    cg.setLineCap(.round)
    for s in lit {
        cg.setLineWidth(small ? 24 : 10)
        cg.setStrokeColor(rgb(s.color.0, s.color.1, s.color.2, 0.75))
        cg.move(to: center)
        cg.addLine(to: point(s.radius, s.angle))
        cg.strokePath()
    }
    for s in lit {
        let p = point(s.radius, s.angle)
        glow(cg, p, s.size * (small ? 2.6 : 3.4), s.color, 0.6)
        disc(cg, p, s.size, rgb(s.color.0, s.color.1, s.color.2))
    }
    if !small {                                     // the app's selection ring
        cg.setLineWidth(8)
        cg.setStrokeColor(accent)
        let p = point(lit[0].radius, lit[0].angle), r = lit[0].size + 16
        cg.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    // Listener: a disc with a front-pointing tip.
    glow(cg, center, small ? 150 : 110, (0.85, 0.90, 1.0), 0.25)
    disc(cg, center, small ? 64 : 40, rgb(0.93, 0.95, 1.0))
    if !small {
        cg.setFillColor(rgb(0.06, 0.07, 0.10))
        cg.move(to: CGPoint(x: 512, y: 540))
        cg.addLine(to: CGPoint(x: 496, y: 500))
        cg.addLine(to: CGPoint(x: 528, y: 500))
        cg.closePath()
        cg.fillPath()
    }

    // Faint top edge light for depth.
    cg.addPath(body)
    cg.setLineWidth(6)
    let edge = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray,
                          locations: [0, 0.5])!
    cg.replacePathWithStrokedPath()
    cg.clip()
    cg.drawLinearGradient(edge, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()
}

func png(_ px: Int, to url: URL) {
    let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(cg, small: px <= 64)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    png(size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    png(size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let icns = here.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(icns.path) (PNGs in \(iconset.path))")
