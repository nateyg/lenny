// Strips the baked-in checkerboard from the welcome-screen hero.
//
//     swift Tools/make_hero.swift
//
// Reads  ~/Desktop/Lenny/lenny_hero.jpg
// Writes ~/Lenny/lenny_hero.png
//
// A flood fill inward from the border gets the bulk of it while protecting
// interior whites (eyes, teeth). That leaves pockets the border can't reach —
// the gaps between his arms and body, and between his hands and legs. Those are
// cleared too, but only when they contain a real run of the checkerboard's grey
// square (tone 221), which appears nowhere in the character art. Merely "darker
// than white" is not enough: JPEG ringing inside the eye whites hits that, and
// erases his eyes.

import AppKit

let src = NSBitmapImageRep(data: NSImage(contentsOfFile:
    NSHomeDirectory() + "/Desktop/Lenny/lenny_hero.jpg")!.tiffRepresentation!)!
let W = src.pixelsWide, H = src.pixelsHigh

func isChecker(_ x: Int, _ y: Int) -> Bool {
    guard let c = src.colorAt(x: x, y: y) else { return false }
    let mx = max(c.redComponent, max(c.greenComponent, c.blueComponent))
    let mn = min(c.redComponent, min(c.greenComponent, c.blueComponent))
    return mx > 0.74 && (mx - mn) < 0.06
}

var bg = [Bool](repeating: false, count: W*H)

func flood(from seeds: [(Int, Int)]) -> [(Int, Int)] {
    var stack = seeds, filled: [(Int, Int)] = []
    while let (x, y) = stack.popLast() {
        guard x >= 0, y >= 0, x < W, y < H, !bg[y*W + x], isChecker(x, y) else { continue }
        bg[y*W + x] = true
        filled.append((x, y))
        stack += [(x+1, y), (x-1, y), (x, y+1), (x, y-1)]
    }
    return filled
}

var border: [(Int, Int)] = []
for x in 0..<W { border += [(x, 0), (x, H-1)] }
for y in 0..<H { border += [(0, y), (W-1, y)] }
_ = flood(from: border)

/// A solid pixel of the checkerboard's grey square, not just an off-white one.
func isCheckerGrey(_ x: Int, _ y: Int) -> Bool {
    guard let c = src.colorAt(x: x, y: y) else { return false }
    let v = c.redComponent * 255
    let mx = max(c.redComponent, max(c.greenComponent, c.blueComponent))
    let mn = min(c.redComponent, min(c.greenComponent, c.blueComponent))
    return v >= 214 && v <= 230 && (mx - mn) < 0.03
}

// enclosed pockets: clear them only when they really are checkerboard
var pockets = 0
for y in 0..<H {
    for x in 0..<W where !bg[y*W + x] && isChecker(x, y) {
        var probe = bg
        swap(&bg, &probe)                       // flood on a scratch copy first
        let blob = flood(from: [(x, y)])
        let grey = blob.filter { isCheckerGrey($0.0, $0.1) }.count
        if grey >= max(12, blob.count / 12) { pockets += 1 }
        else { swap(&bg, &probe) }              // character art — put it back
    }
}

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: W*4, bitsPerPixel: 32)!
let buf = out.bitmapData!
var cleared = 0
for y in 0..<H {
    for x in 0..<W {
        let o = (y*W + x)*4
        if bg[y*W + x] {
            buf[o] = 0; buf[o+1] = 0; buf[o+2] = 0; buf[o+3] = 0
            cleared += 1
        } else {
            let c = src.colorAt(x: x, y: y)!
            buf[o]   = UInt8(c.redComponent * 255)
            buf[o+1] = UInt8(c.greenComponent * 255)
            buf[o+2] = UInt8(c.blueComponent * 255)
            buf[o+3] = 255
        }
    }
}
out.size = NSSize(width: W, height: H)
try! out.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: NSHomeDirectory() + "/Lenny/lenny_hero.png"))
print("hero \(W)x\(H): \(cleared) px cleared, including \(pockets) enclosed pockets")
