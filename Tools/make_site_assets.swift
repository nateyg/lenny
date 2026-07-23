// Renders the images the landing page uses, from the app's own art and geometry.
//
//     swift Tools/make_site_assets.swift   →  docs/hero.png, docs/icon.png

import AppKit

let proj = NSHomeDirectory() + "/Lenny/"
let docs = proj + "docs/"

// Scene geometry, kept in step with `enum Art` in Main.swift.
let aspect: CGFloat = 1280.0 / 960.0
let beamScale: CGFloat = 1.044, beamRatio: CGFloat = 1404.0 / 1041.0
let spotX: CGFloat = 0.228, spotY: CGFloat = 0.902, spotFloorY: CGFloat = 0.711
let spotStart: CGFloat = 0.84, spotLine: CGFloat = 0.52

let W: CGFloat = 1280
let artH = W / aspect
let barH: CGFloat = 76
let titleH: CGFloat = 74
let H = artH + barH + titleH

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: Int(W)*4, bitsPerPixel: 32)!
out.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)

// window body
// Square corners: the page clips them with border-radius, and dropping the
// alpha channel lets this ship as a JPEG a tenth the size.
NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// scene (AppKit origin is bottom-left)
let artRect = NSRect(x: 0, y: barH, width: W, height: artH)
NSGraphicsContext.current?.saveGraphicsState()
NSBezierPath(rect: artRect).setClip()
NSImage(contentsOfFile: proj + "Lenny_background.png")!.draw(in: artRect)

let progress: CGFloat = 0.86                      // the ⌘D moment: light almost on the line
let bw = W * beamScale, bh = bw * beamRatio
let cx = spotStart + (spotLine - spotStart) * progress
NSImage(contentsOfFile: proj + "Lenny_beam.png")!.draw(
    in: NSRect(x: W * cx - bw * spotX,
               y: artRect.maxY - artH * spotFloorY - bh * (1 - spotY),
               width: bw, height: bh),
    from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.current?.restoreGraphicsState()

// status bar
NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: barH).fill()
// the locked-out state, which is what ⌘D shows off
let red = NSColor(calibratedRed: 1.0, green: 0.37, blue: 0.35, alpha: 1)
red.setFill()
NSBezierPath(ovalIn: NSRect(x: 26, y: barH/2 - 9, width: 18, height: 18)).fill()
let mono = NSFont.monospacedSystemFont(ofSize: 25, weight: .regular)
("Resets in 0:11:36" as NSString).draw(
    at: NSPoint(x: 58, y: barH/2 - 15),
    withAttributes: [.font: mono, .foregroundColor: red])
let grey = NSColor(calibratedWhite: 0.92, alpha: 0.82)
let right = "Screensaver  |  Sound ON" as NSString
let rw = right.size(withAttributes: [.font: mono]).width
right.draw(at: NSPoint(x: W - rw - 26, y: barH/2 - 15),
           withAttributes: [.font: mono, .foregroundColor: grey])

// title bar
NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
NSRect(x: 0, y: H - titleH, width: W, height: titleH).fill()
for (i, c) in [NSColor(calibratedRed: 1, green: 0.37, blue: 0.35, alpha: 1),
               NSColor(calibratedRed: 1, green: 0.74, blue: 0.18, alpha: 1),
               NSColor(calibratedRed: 0.16, green: 0.80, blue: 0.25, alpha: 1)].enumerated() {
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: 26 + CGFloat(i)*30, y: H - titleH/2 - 8, width: 16, height: 16)).fill()
}
let title = "Lenny" as NSString
let tf = NSFont.systemFont(ofSize: 24, weight: .semibold)
title.draw(at: NSPoint(x: 132, y: H - titleH/2 - 14),
           withAttributes: [.font: tf, .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)])

NSGraphicsContext.restoreGraphicsState()
let jpeg = out.representation(using: .jpeg, properties: [.compressionFactor: 0.82])!
try! jpeg.write(to: URL(fileURLWithPath: docs + "hero.jpg"))
print("docs/hero.jpg  \(Int(W))x\(Int(H))  \(jpeg.count/1024)KB")

// icon for the page + favicon
let icon = NSImage(contentsOfFile: proj + "Lenny_Icon_right of claude.png")!
let side = 512
let ir = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: side*4, bitsPerPixel: 32)!
ir.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: ir)
icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
NSGraphicsContext.restoreGraphicsState()
try! ir.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: docs + "icon.png"))
print("docs/icon.png  \(side)x\(side)")
