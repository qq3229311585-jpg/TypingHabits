import AppKit
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let g = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = g
let ctx = g.cgContext
func col(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
// 底板
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bp = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
let sh = NSShadow(); sh.shadowColor = col(0x000000, 0.35); sh.shadowOffset = NSSize(width: 0, height: -14); sh.shadowBlurRadius = 28; sh.set()
col(0x3B2F8F).setFill(); bp.fill()
ctx.restoreGState()
bp.addClip()
NSGradient(colors: [col(0x4F3FC0), col(0x1E3A8A), col(0x0F9D8F)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -55)
// 底部一排淡色小键
for i in 0..<5 {
    let w: CGFloat = 112, gap: CGFloat = 22
    let x = 512 - (5 * w + 4 * gap) / 2 + CGFloat(i) * (w + gap)
    col(0xFFFFFF, 0.16).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 190, width: w, height: 84), xRadius: 24, yRadius: 24).fill()
}
// 大键帽:底部厚边 + 面
let capShadow = NSRect(x: 292, y: 330, width: 440, height: 440)
col(0x0B1B4A, 0.55).setFill()
NSBezierPath(roundedRect: capShadow.offsetBy(dx: 0, dy: -22), xRadius: 96, yRadius: 96).fill()
col(0xC9D2F0).setFill()
NSBezierPath(roundedRect: capShadow.offsetBy(dx: 0, dy: -12), xRadius: 96, yRadius: 96).fill()
let face = NSBezierPath(roundedRect: capShadow, xRadius: 96, yRadius: 96)
NSGradient(colors: [col(0xFFFFFF), col(0xE8ECFA)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: face, angle: -90)
// 节奏波形(代表打字节奏)
let hs: [CGFloat] = [70, 150, 100, 250, 130, 190, 80]
let bw: CGFloat = 36, gp: CGFloat = 22
let total = CGFloat(hs.count) * bw + CGFloat(hs.count - 1) * gp
for (i, h) in hs.enumerated() {
    let x = 512 - total / 2 + CGFloat(i) * (bw + gp)
    let r = NSRect(x: x, y: 550 - h / 2, width: bw, height: h)
    let p = NSBezierPath(roundedRect: r, xRadius: bw / 2, yRadius: bw / 2)
    NSGradient(colors: [col(0x4F3FC0), col(0x14B8A6)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: p, angle: -90)
}
NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
