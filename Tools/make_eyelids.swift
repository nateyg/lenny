// Regenerates the closed-eyelids overlay for the blink, from the scene art.
//
//     swift Tools/make_eyelids.swift   →  eyelids.png
//
// Flood-fills each eye's white, then fills the enclosed holes so the dark pupils
// are covered too (the earlier version masked only white pixels, leaving the
// pupil dots poking through the closed lid). Dilates a touch to swallow the
// anti-aliased rim, then draws a lid line across each eye. Colour is sampled
// from Lenny's forehead so the lids blend in.

import AppKit

let proj = NSHomeDirectory() + "/Lenny/"
let src = NSBitmapImageRep(data: NSImage(contentsOfFile: proj + "Lenny_background.png")!
    .tiffRepresentation!)!
let W = src.pixelsWide, H = src.pixelsHigh

// eye-region bounds, and each eye's lid line, as fractions of the art
let region = (x0: 0.42, x1: 0.56, y0: 0.06, y1: 0.22)
let eyes = [(cx: 0.4750, w: 0.0477), (cx: 0.5172, w: 0.0367)]
let skin = (r: 237, g: 203, b: 35)

func whitish(_ x: Int, _ y: Int) -> Bool {
    guard x >= 0, y >= 0, x < W, y < H, let c = src.colorAt(x: x, y: y) else { return false }
    let mn = min(c.redComponent, min(c.greenComponent, c.blueComponent))
    let mx = max(c.redComponent, max(c.greenComponent, c.blueComponent))
    return mn > 0.62 && (mx - mn) < 0.18
}

let rx0 = Int(region.x0 * Double(W)), rx1 = Int(region.x1 * Double(W))
let ry0 = Int(region.y0 * Double(H)), ry1 = Int(region.y1 * Double(H))

var mask = [Bool](repeating: false, count: W * H)
for y in ry0..<ry1 { for x in rx0..<rx1 where whitish(x, y) { mask[y * W + x] = true } }

// Fill enclosed holes (the pupils): flood the background of the eye region from
// its border; any non-mask pixel the flood can't reach is enclosed, so mark it.
var reachable = [Bool](repeating: false, count: W * H)
var stack: [(Int, Int)] = []
for x in rx0..<rx1 { stack.append((x, ry0)); stack.append((x, ry1 - 1)) }
for y in ry0..<ry1 { stack.append((rx0, y)); stack.append((rx1 - 1, y)) }
while let (x, y) = stack.popLast() {
    let k = y * W + x
    guard x >= rx0, x < rx1, y >= ry0, y < ry1, !reachable[k], !mask[k] else { continue }
    reachable[k] = true
    stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
}
for y in ry0..<ry1 { for x in rx0..<rx1 where !mask[y*W+x] && !reachable[y*W+x] {
    mask[y * W + x] = true
} }

// dilate 1px
var grown = mask
for y in (ry0 - 1)..<(ry1 + 1) { for x in (rx0 - 1)..<(rx1 + 1) {
    guard x >= 0, y >= 0, x < W, y < H, !mask[y * W + x] else { continue }
    outer: for dy in -1...1 { for dx in -1...1 {
        let nx = x + dx, ny = y + dy
        if nx >= 0, ny >= 0, nx < W, ny < H, mask[ny * W + nx] { grown[y * W + x] = true; break outer }
    } }
} }

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
let buf = out.bitmapData!
for i in 0..<(W * H) {
    let o = i * 4
    if grown[i] { buf[o] = UInt8(skin.r); buf[o+1] = UInt8(skin.g); buf[o+2] = UInt8(skin.b); buf[o+3] = 255 }
    else { buf[o] = 0; buf[o+1] = 0; buf[o+2] = 0; buf[o+3] = 0 }
}

// a lid line across each eye, clipped to the filled region
for eye in eyes {
    let px = Int(eye.cx * Double(W))
    let half = Int(eye.w * Double(W) * 0.46), thick = max(1, Int(Double(H) * 0.0035))
    // centre the line on the eye's vertical middle
    var ys: [Int] = []
    for y in ry0..<ry1 where grown[y * W + px] { ys.append(y) }
    guard let top = ys.min(), let bot = ys.max() else { continue }
    let cy = (top + bot) / 2
    for dy in -thick...thick { for dx in -half...half {
        let x = px + dx, y = cy + dy
        guard x >= 0, y >= 0, x < W, y < H, grown[y * W + x] else { continue }
        let o = (y * W + x) * 4
        buf[o] = 0; buf[o+1] = 0; buf[o+2] = 0; buf[o+3] = 255
    } }
}

out.size = NSSize(width: W, height: H)
try! out.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: proj + "eyelids.png"))
print("eyelids.png regenerated with pupils filled")
