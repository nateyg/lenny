// Regenerates Lenny's icons from the source art on the Desktop.
//
//     swift Tools/make_icons.swift
//
// Reads  ~/Desktop/Lenny/Lenny_Icon_{left,right} of claude.png  (full-bleed art)
// Writes ~/Lenny/Lenny_Icon_{left,right} of claude.png          (dock-styled)
//        ~/Lenny/Assets.xcassets/AppIcon.appiconset/*
//
// Always run it against the Desktop originals — running it on its own output
// would inset an already-inset icon.

import AppKit

let desk = NSHomeDirectory() + "/Desktop/Lenny/"
let proj = NSHomeDirectory() + "/Lenny/"

/// macOS draws app icons inside a safe area rather than edge-to-edge: an 824pt
/// body on a 1024pt canvas. Drawing full-bleed is why Lenny loomed larger than
/// his neighbours. The rim approximates the specular edge the system gives the
/// stock icons — brightest along the top.
func dockStyled(_ src: NSImage) -> NSBitmapImageRep {
    let canvas: CGFloat = 1024, body: CGFloat = 824
    let inset = (canvas - body) / 2
    let radius = 215.0 * body / canvas          // source radius, scaled with the body

    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: Int(canvas)*4, bitsPerPixel: 32)!
    out.size = NSSize(width: canvas, height: canvas)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)

    // sits slightly high so the shadow has room, matching the stock tiles
    let rect = NSRect(x: inset, y: inset + 12, width: body, height: body)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 26
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

    // rim: the specular edge, brightest along the top. Painted through a
    // gradient mask so there's no seam where the highlight falls off.
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: radius, yRadius: radius)
    rim.lineWidth = 6

    let layer = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: Int(canvas)*4, bitsPerPixel: 32)!
    layer.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layer)
    NSColor.white.setStroke()
    rim.stroke()
    let fade = NSGradient(colors: [NSColor.white.withAlphaComponent(0.10),
                                   NSColor.white.withAlphaComponent(0.46)])!
    NSGraphicsContext.current?.compositingOperation = .sourceIn
    fade.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { r in
        layer.draw(in: r); return true
    }.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas),
           from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return out
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// runtime tiles
for name in ["Lenny_Icon_left of claude", "Lenny_Icon_right of claude"] {
    let src = NSImage(contentsOfFile: desk + name + ".png")!
    save(dockStyled(src), proj + name + ".png")
}
print("dock tiles styled")

// app icon set, from the same styled art
let styled = NSImage(contentsOf: URL(fileURLWithPath: proj + "Lenny_Icon_right of claude.png"))!
let dir = proj + "Assets.xcassets/AppIcon.appiconset/"
for (size, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let px = size*scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: px*4, bitsPerPixel: 32)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    styled.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    save(rep, dir + "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png")
}
print("app icon set regenerated")
