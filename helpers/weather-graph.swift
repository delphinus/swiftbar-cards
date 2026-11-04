// weather.10m.sh が使う、気温のグラフを描くプログラム。
//
// 標準入力に JSON を受け取り、PNG を Base64 にして標準出力に書く。
//   {
//     "now": 1793800000,              // 今 (UNIX 時刻)
//     "current": 11.9,                // 今の観測値 (無ければ null)
//     "past": [[1793710000, 12.3], …], // 過去の観測値 [時刻, 気温]
//     "forecast": [[1793810800, 11], …], // 予報 [時刻, 気温]
//     "weather": [[1793810800, "cloud.rain", "#64B5FF"], …], // 3 時間ごとの天気のアイコンと色
//     "pops": [[1793804400, "90", "#64B5FF"], …], // 6 時間ごとの降水確率と色
//     "dark": true                    // ダークモードか
//   }
//
// 横軸は今から 24 時間後まで。実線は今の観測値から予報をつなぎ、破線は
// 同じ時刻の前日の観測値 (= 過去 24 時間) を描く。Weathernews のウィジェットの
// 気温のグラフにならった。
//
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。weather.10m.sh が初回にコンパイルする。

import AppKit

struct Input: Decodable {
    let now: Double
    let current: Double?
    let past: [[Double]]
    let forecast: [[Double]]
    let weather: [[String]]
    let pops: [[String]]?
    let dark: Bool
}

let data = FileHandle.standardInput.readDataToEndOfFile()
guard let input = try? JSONDecoder().decode(Input.self, from: data) else {
    FileHandle.standardError.write("weather-graph: JSON を読めない\n".data(using: .utf8)!)
    exit(1)
}

// 大きさ (pt)。PNG はこの 2 倍の画素で描く。
let width: CGFloat = 320, height: CGFloat = 166
let scale: CGFloat = 2
let plot = CGRect(x: 14, y: 70, width: width - 14 - 30, height: 82) // 下からの座標
let hourY: CGFloat = 54   // 時刻の行
let iconY: CGFloat = 20   // 天気のアイコンの行 (下端)
let popY: CGFloat = 4     // 降水確率の行

let fg = input.dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)
let sub = input.dark ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.4, alpha: 1)
let grid = input.dark ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.12)

func hex(_ s: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

// 横軸: 今の時刻を正時に切り下げたところから 24 時間
let t0 = floor(input.now / 3600) * 3600
let t1 = t0 + 24 * 3600

// 予報の線: 今の観測値から始め、今より後の予報をつなぐ
var solid: [(Double, Double)] = []
if let c = input.current { solid.append((input.now, c)) }
for p in input.forecast where p.count == 2 && p[0] > input.now {
    solid.append((p[0], p[1]))
}
// 破線: 前日の同じ時刻の観測値を 24 時間ずらして重ねる
let dotted: [(Double, Double)] = input.past.filter { $0.count == 2 }.map { ($0[0] + 24 * 3600, $0[1]) }

// 縦軸: 描く値すべてが入るよう、2°C 刻みに広げる
let visible = (solid + dotted).filter { $0.0 >= t0 - 3 * 3600 && $0.0 <= t1 + 3 * 3600 }.map { $0.1 }
var lo = floor(((visible.min() ?? 0) - 0.5) / 2) * 2
var hi = ceil(((visible.max() ?? 10) + 0.5) / 2) * 2
if hi - lo < 6 { let mid = (hi + lo) / 2; lo = floor((mid - 3) / 2) * 2; hi = lo + 6 }

func x(_ t: Double) -> CGFloat { plot.minX + CGFloat((t - t0) / (t1 - t0)) * plot.width }
func y(_ v: Double) -> CGFloat { plot.minY + CGFloat((v - lo) / (hi - lo)) * plot.height }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor, align: NSTextAlignment = .center, bold: Bool = false) {
    let font = bold ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
                    : NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    let w = str.size().width
    let dx: CGFloat = align == .center ? -w / 2 : (align == .right ? -w : 0)
    str.draw(at: CGPoint(x: p.x + dx, y: p.y))
}

// 目盛りの横線と、上下の値
ctx.setLineWidth(1)
ctx.setStrokeColor(grid.cgColor)
var v = lo
while v <= hi + 0.01 {
    ctx.move(to: CGPoint(x: plot.minX, y: y(v)))
    ctx.addLine(to: CGPoint(x: plot.maxX, y: y(v)))
    v += 2
}
ctx.strokePath()
text(String(format: "%.0f", hi), at: CGPoint(x: plot.maxX + 4, y: y(hi) - 6), size: 10, color: sub, align: .left)
text(String(format: "%.0f", lo), at: CGPoint(x: plot.maxX + 4, y: y(lo) - 6), size: 10, color: sub, align: .left)

// 線を描く。範囲の外にはみ出した分は切り取る。
ctx.saveGState()
ctx.clip(to: CGRect(x: plot.minX - 4, y: 0, width: plot.width + 8, height: height))
func path(_ pts: [(Double, Double)]) {
    for (i, p) in pts.enumerated() {
        let q = CGPoint(x: x(p.0), y: y(p.1))
        if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
    }
}
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
if dotted.count > 1 {
    ctx.setStrokeColor(sub.cgColor)
    ctx.setLineWidth(2)
    ctx.setLineDash(phase: 0, lengths: [0.1, 4])
    path(dotted)
    ctx.strokePath()
}
if solid.count > 1 {
    ctx.setStrokeColor(fg.cgColor)
    ctx.setLineWidth(2.5)
    ctx.setLineDash(phase: 0, lengths: [])
    path(solid)
    ctx.strokePath()
}
ctx.restoreGState()

// 今の気温と、予報の最高気温に点と値を添える (最低気温は今の気温の近くに来やすく、値が重なる)
func mark(_ p: (Double, Double), above: Bool) {
    let q = CGPoint(x: x(p.0), y: y(p.1))
    ctx.setFillColor(fg.cgColor)
    ctx.fillEllipse(in: CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7))
    let label = String(format: "%.0f", p.1.rounded())
    let ty = above ? q.y + 5 : q.y - 17
    text(label, at: CGPoint(x: min(max(q.x, plot.minX + 8), plot.maxX - 8), y: ty), size: 11, color: fg, bold: true)
}
let inWindow = solid.filter { $0.0 >= t0 && $0.0 <= t1 }
if let first = solid.first, input.current != nil { mark(first, above: true) }
let future = inWindow.dropFirst(input.current != nil ? 1 : 0)
if let mx = future.max(by: { $0.1 < $1.1 }) { mark(mx, above: true) }

// 時刻: 3 時間ごとに数字、その間は点
var t = t0
while t <= t1 {
    let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: t))
    if hour % 3 == 0 {
        text("\(hour)", at: CGPoint(x: x(t), y: hourY), size: 10, color: sub)
    } else {
        ctx.setFillColor(sub.cgColor)
        ctx.fillEllipse(in: CGRect(x: x(t) - 1, y: hourY + 5, width: 2, height: 2))
    }
    t += 3600
}

// 天気のアイコン: 3 時間ごとの予報を、その時間帯の真ん中に置く
for w in input.weather where w.count == 3 {
    guard let ts = Double(w[0]) else { continue }
    let mid = ts + 1.5 * 3600
    guard mid > t0, mid < t1 else { continue }
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [hex(w[2])]))
    guard let img = NSImage(systemSymbolName: w[1], accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { continue }
    let s = img.size
    img.draw(in: CGRect(x: x(mid) - s.width / 2, y: iconY + (26 - s.height) / 2, width: s.width, height: s.height))
}

// 降水確率: 6 時間ごとの値を、その時間帯 (アイコン 2 つ分) の真ん中に置く
for p in input.pops ?? [] where p.count == 3 {
    guard let ts = Double(p[0]), !p[1].isEmpty else { continue }
    let mid = ts + 3 * 3600
    guard mid > t0, mid < t1 else { continue }
    text("\(p[1])%", at: CGPoint(x: x(mid), y: popY), size: 10, color: hex(p[2]), bold: true)
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
print(png.base64EncodedString())
