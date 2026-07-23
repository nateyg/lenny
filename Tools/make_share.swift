// Builds the 1200x630 social share card.  swift Tools/make_share.swift → docs/share.png
import AppKit

let docs = NSHomeDirectory() + "/Lenny/docs/"

func blank(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    r.size = NSSize(width: w, height: h)
    return r
}

let out = blank(1200, 630)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)

NSColor(calibratedRed: 0.239, green: 0.239, blue: 0.239, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1200, height: 630).fill()

let shot = NSImage(contentsOfFile: docs + "hero.jpg")!
let sw: CGFloat = 640, sh = sw * (shot.size.height / shot.size.width)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.shadowBlurRadius = 46
shadow.set()
let tf = NSAffineTransform()
tf.translateX(by: 840, yBy: 315)
tf.rotate(byDegrees: 3.6)
tf.concat()
shot.draw(in: NSRect(x: -sw/2, y: -sh/2, width: sw, height: sh), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.current?.restoreGraphicsState()

if let font = NSFont(name: "BomberBalloon", size: 132) {
    ("LENNY" as NSString).draw(at: NSPoint(x: 68, y: 336),
        withAttributes: [.font: font, .foregroundColor: NSColor.white])
}
("Your countdown to Coding Time." as NSString).draw(at: NSPoint(x: 74, y: 292),
    withAttributes: [.font: NSFont.systemFont(ofSize: 29, weight: .medium),
                     .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1)])

NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: docs + "share.png"))
print("docs/share.png written")
