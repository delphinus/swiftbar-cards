// README とテスト用のアートワークを描く。実在の作品の画像を使わないよう、
// 図形の組み合わせだけで描く。
//   swift samples/artwork.swift <出力の PNG>
import AppKit

let size = 600
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
let s = CGFloat(size)
// 夜空のグラデーション
let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.05, green: 0.07, blue: 0.20, alpha: 1).cgColor,
    NSColor(red: 0.10, green: 0.32, blue: 0.45, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(sky, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
// オーロラの帯
for (i, c) in [NSColor(red: 0.3, green: 0.95, blue: 0.6, alpha: 0.35),
               NSColor(red: 0.5, green: 0.6, blue: 1.0, alpha: 0.30),
               NSColor(red: 0.8, green: 0.4, blue: 0.9, alpha: 0.22)].enumerated() {
    let p = CGMutablePath()
    let base = s * (0.62 - CGFloat(i) * 0.07)
    p.move(to: CGPoint(x: 0, y: base))
    p.addCurve(to: CGPoint(x: s, y: base + s * 0.08), control1: CGPoint(x: s * 0.3, y: base + s * 0.22),
               control2: CGPoint(x: s * 0.6, y: base - s * 0.16))
    cg.setStrokeColor(c.cgColor)
    cg.setLineWidth(s * 0.09)
    cg.setLineCap(.round)
    cg.addPath(p)
    cg.strokePath()
}
// 星
var seed: UInt64 = 7
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
cg.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor)
for _ in 0..<70 {
    let r = rnd() * 2.2 + 0.6
    cg.fillEllipse(in: CGRect(x: rnd() * s, y: s * 0.45 + rnd() * s * 0.55, width: r, height: r))
}
// 港の水面と桟橋
cg.setFillColor(NSColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1).cgColor)
cg.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.28))
cg.setFillColor(NSColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 1).cgColor)
cg.fill(CGRect(x: s * 0.08, y: s * 0.26, width: s * 0.5, height: s * 0.03))
for x in stride(from: s * 0.12, to: s * 0.58, by: s * 0.09) {
    cg.fill(CGRect(x: x, y: s * 0.12, width: s * 0.015, height: s * 0.15))
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
