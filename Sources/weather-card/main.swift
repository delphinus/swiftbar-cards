// weather.10m.sh が使う、天気のカードを描くプログラム。
//
// 標準入力に JSON を受け取り、PNG を Base64 にして標準出力に書く。
// 1 行目に画像の大きさ (pt) を「幅 高さ」で書き、2 行目に Base64 を書く。
//
// カードは上から次の 4 つ。
// 1. 今の観測値 (アメダス): 気温を大きく、湿度・降水量・風を横に
// 2. 今後 24 時間の気温のグラフ: 実線は今の観測値から予報をつなぎ、破線は同じ
//    時刻の前日の観測値 (= 過去 24 時間)。下に時刻・天気のアイコン・降水確率。
//    Weathernews のウィジェットの気温のグラフにならった。
// 3. 3 日分の予報の文
// 4. 週間予報: 7 日を横に並べる
//
// 色は weather.10m.sh が外観 (ダーク / ライト) に合わせて選んで渡す。
// メニューの文字と違い、画像の中の色は指定どおりに描かれる。
//
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。weather.10m.sh が初回にコンパイルする。

import AppKit
#if canImport(Shared)
import Shared
#endif

struct Obs: Decodable {
    let point: String
    let time: String
    let temp: Double?
    let tempColor: String?
    let humidity: Double?
    let precip: Double?
    let wind: Double?
    let windDir: String?
}

struct Graph: Decodable {
    let current: Double?
    let past: [[Double]]
    let forecast: [[Double]]
    let weather: [[String]] // [時刻, アイコン, 色]
    let pops: [[String]]    // [時刻, 降水確率, 色]
}

struct Day: Decodable {
    let date: String // 11/5 の形
    let dow: Int     // 曜日 (0 が日曜)
    let text: String
    let icon: String
    let color: String
}

struct WeekDay: Decodable {
    let date: String
    let dow: Int
    let icon: String
    let color: String
    let max: String
    let maxColor: String?
    let min: String
    let minColor: String?
    let pop: String
    let popColor: String?
}

struct Input: Decodable {
    let dark: Bool
    let now: Double
    let obs: Obs?
    let graph: Graph?
    let daysTitle: String
    let days: [Day]
    let week: [WeekDay]
    // カードの高さをこれ以上にする (下を空ける)。地点を切り替えたときに高さが
    // 変わらないよう、設定した地点のカードの高さをそろえるのに使う。
    let minHeight: Double?
}

// 曜日の名前 (0 が日曜)
func weekday(_ dow: Int) -> String {
    let i = (dow % 7 + 7) % 7
    return L(["日", "月", "火", "水", "木", "金", "土"][i], ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][i])
}

let data = FileHandle.standardInput.readDataToEndOfFile()
let input: Input
do {
    input = try JSONDecoder().decode(Input.self, from: data)
} catch {
    FileHandle.standardError.write("weather-card: JSON を読めない: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// 明るい外観の色は、背後が透けて灰色に見えるポップアップでも読めるように濃くする
// (sysmon.swift の renderAll に経緯を書いた)
let fg = input.dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.05, alpha: 1)
let sub = input.dark ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.2, alpha: 1)
let grid = input.dark ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.16)
let rule = input.dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.22)

func hex(_ s: String?) -> NSColor {
    guard let s, !s.isEmpty else { return fg }
    var v: UInt64 = 0
    Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}


// 和文の中の括弧は、全角の括弧にしてヒラギノ角ゴシックの palt (プロポーショナル
// メトリクス) で描く。半角の括弧は欧文の字形で、基準線の下まで伸びる位置にある
// ので、和文の中に置くと括弧が下にずれて見える。日本語の組版では、括弧を全角に
// するか半角にするかは中身ではなく置かれた文で決める (JIS X 4051、日本語組版処理の
// 要件)。そこで、括弧の直前が和字か、括弧の中に和字を含むなら全角にし、前の空白は
// 消す (全角の括弧は字形に空きを含む)。前後も中身も英数字だけなら半角のままにする。
func hiragino(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let w = weight == .light ? "W2" : weight == .medium ? "W5" : weight == .semibold ? "W6" : weight == .bold ? "W7" : "W3"
    let feature: [NSFontDescriptor.FeatureKey: Any] = [
        NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureTag as String): "palt",
        NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureValue as String): 1,
    ]
    let d = NSFontDescriptor(name: "HiraginoSans-\(w)", size: size).addingAttributes([.featureSettings: [feature]])
    return NSFont(descriptor: d, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}
func isWaji(_ c: Character) -> Bool {
    c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
}
let parenPair = try! NSRegularExpression(pattern: "( ?)\\(([^()]*)\\)")
func styled(_ s: String, font: NSFont, color: NSColor, size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
    let ns = s as NSString
    let out = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    let paren = hiragino(size, weight)
    for m in parenPair.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
        let inner = ns.substring(with: m.range(at: 2))
        // 括弧 (と前の空白) の直前の文字
        let before = m.range.location > 0 ? ns.substring(with: NSRange(location: m.range.location - 1, length: 1)) : ""
        guard inner.contains(where: isWaji) || before.contains(where: isWaji) else { continue }
        let rep = NSMutableAttributedString(string: "（", attributes: [.font: paren, .foregroundColor: color])
        rep.append(NSAttributedString(string: inner, attributes: [.font: font, .foregroundColor: color]))
        rep.append(NSAttributedString(string: "）", attributes: [.font: paren, .foregroundColor: color]))
        // 前の空白も含めて置き換える (m.range は空白から閉じ括弧まで)
        out.replaceCharacters(in: m.range, with: rep)
    }
    return out
}

// 気象庁の予報の文は「晴れ　明け方　まで　くもり」のように全角の空白で語を
// 区切って配られる。空白は詰めて描き、折り返しは語の間でだけ起きるようにする
// (語の中の字の間に U+2060 WORD JOINER、語の間に U+200B ZERO WIDTH SPACE を
// 置く)。字の間のどこでも折り返すと、「雷を伴」と「う」に分かれたりする。
// 助詞で始まる語 (まで・で・から・を など) は前の語につなげ、手前で折らない。
// 英語の天気の名前のように全角の空白を含まない文は、そのまま返す (普通に語の間で折り返す)。
func phrased(_ s: String) -> String {
    guard s.contains("　") else { return s }
    let particles = ["まで", "では", "で", "から", "を", "に", "の", "より"]
    var words: [String] = []
    for w in s.split(separator: "　").map(String.init) {
        if let last = words.last, particles.contains(where: { w.hasPrefix($0) }) {
            words[words.count - 1] = last + w
        } else {
            words.append(w)
        }
    }
    return words.map { $0.map(String.init).joined(separator: "\u{2060}") }.joined(separator: "\u{200B}")
}

// 幅を決めて折り返して描く文。高さを測る関数と描く関数を対にする。
func boxString(_ s: String, size: CGFloat, color: NSColor = fg, weight: NSFont.Weight = .regular) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    let str = NSMutableAttributedString(attributedString: styled(s, font: font, color: color, size: size, weight: weight))
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    str.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: str.length))
    return str
}
func boxHeight(_ s: String, width w: CGFloat, size: CGFloat) -> CGFloat {
    boxString(s, size: size).boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin]).height
}
func textBox(_ s: String, x: CGFloat, y: CGFloat, width w: CGFloat, size: CGFloat, color: NSColor = fg) {
    boxString(s, size: size, color: color).draw(with: CGRect(x: x, y: y, width: w, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin])
}

// 大きさ (pt)。上から順に積む。PNG はこの 2 倍の画素で描く。
let width: CGFloat = 340
let pad: CGFloat = 2
let obsH: CGFloat = input.obs != nil ? 52 : 0
let graphH: CGFloat = input.graph != nil ? 178 : 0
// 予報の文は、幅に収まらなければ折り返し、その行だけ高くする
let dayTextX = pad + 104, dayTextW = width - pad - dayTextX
let dayRowHs: [CGFloat] = input.days.map { max(21, ceil(boxHeight(phrased($0.text), width: dayTextW, size: 13)) + 5) }
let daysH: CGFloat = input.days.isEmpty ? 0 : 20 + dayRowHs.reduce(0, +)
let weekH: CGFloat = input.week.isEmpty ? 0 : 20 + 98
let gap: CGFloat = 13 // 節の間 (区切り線を含む)
let sections = [obsH, graphH, daysH, weekH].filter { $0 > 0 }
let naturalHeight = sections.reduce(0, +) + gap * CGFloat(max(sections.count - 1, 0))
let height = max(naturalHeight, CGFloat(input.minHeight ?? 0))
let scale: CGFloat = 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
let base = NSGraphicsContext(bitmapImageRep: rep)!
let ctx = base.cgContext
// 上から下へ座標を取る (y は上端からの距離)
ctx.translateBy(x: 0, y: height)
ctx.scaleBy(x: 1, y: -1)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

// 文字は y を上端として描く。数字は等幅の数字 (tabular figures) にする。
@discardableResult
func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor = fg,
          weight: NSFont.Weight = .regular, align: NSTextAlignment = .left) -> CGSize {
    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    let str = styled(s, font: font, color: color, size: size, weight: weight)
    let sz = str.size()
    let dx: CGFloat = align == .center ? -sz.width / 2 : (align == .right ? -sz.width : 0)
    str.draw(at: CGPoint(x: x + dx, y: y))
    return sz
}

// SF Symbols のアイコンを、中心が (cx, cy) に来るよう描く
func symbol(_ name: String, color: NSColor, cx: CGFloat, cy: CGFloat, size: CGFloat) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    let s = img.size
    img.draw(in: CGRect(x: cx - s.width / 2, y: cy - s.height / 2, width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func hline(_ y: CGFloat, color: NSColor, from x0: CGFloat = pad, to x1: CGFloat = width - pad) {
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(1)
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.move(to: CGPoint(x: x0, y: y))
    ctx.addLine(to: CGPoint(x: x1, y: y))
    ctx.strokePath()
}

func fmt(_ v: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", v) }

var top: CGFloat = 0
func nextSection(_ h: CGFloat) {
    top += h
    if top < height - 1 {
        hline(top + gap / 2, color: rule)
        top += gap
    }
}

// 1. 今の観測値
if let o = input.obs {
    let tempStr = o.temp.map { fmt($0, 1) } ?? "-"
    let big = text(tempStr, x: pad, y: top - 2, size: 32, color: hex(o.tempColor), weight: .light)
    text("°C", x: pad + big.width + 1, y: top + 4, size: 16, color: hex(o.tempColor), weight: .light)
    text(L("\(o.point)  \(o.time) の観測", "\(o.point), observed at \(o.time)"), x: pad, y: top + 36, size: 11, color: sub)
    let rx: CGFloat = 176
    var ry = top + 2
    // 値の書き出し位置は、いちばん長いラベルの後ろにそろえる (言語でラベルの長さが変わる)
    let labels = (humidity: L("湿度", "Humidity"), precip: L("降水量", "Precip."), wind: L("風", "Wind"))
    let labelW = [labels.humidity, labels.precip, labels.wind]
        .map { NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 12)]).size().width }.max() ?? 0
    func row(_ label: String, _ value: String, _ color: NSColor = fg) {
        text(label, x: rx, y: ry, size: 12, color: sub)
        text(value, x: rx + max(48, ceil(labelW) + 12), y: ry, size: 12, color: color, weight: .medium)
        ry += 16
    }
    if let h = o.humidity { row(labels.humidity, "\(fmt(h))%") }
    if let p = o.precip { row(labels.precip, "\(fmt(p, 1)) mm/h", p > 0 ? hex(input.dark ? "#64B5FF" : "#0047B3") : fg) }
    if let w = o.wind { row(labels.wind, "\(o.windDir ?? "") \(fmt(w, 1)) m/s") }
    nextSection(obsH)
}

// 気象庁のデータは日本時間なので、時刻の目盛りも日本時間で描く (Mac の
// タイムゾーンが日本でなくても、観測の時刻とずれないように)
let jst: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return c
}()

// 2. 今後 24 時間の気温のグラフ
if let g = input.graph {
    text(L("今後 24 時間", "Next 24 hours"), x: pad, y: top, size: 11, color: sub)
    let plot = CGRect(x: 14, y: top + 26, width: width - 14 - 30, height: 78)
    let hourY = plot.maxY + 8
    let iconCY = hourY + 32
    let popY = iconCY + 14

    let t0 = floor(input.now / 3600) * 3600
    let t1 = t0 + 24 * 3600
    var solid: [(Double, Double)] = []
    if let c = g.current { solid.append((input.now, c)) }
    for p in g.forecast where p.count == 2 && p[0] > input.now { solid.append((p[0], p[1])) }
    let dotted = g.past.filter { $0.count == 2 }.map { ($0[0] + 24 * 3600, $0[1]) }

    // 縦軸: 描く値すべてが入るよう、2°C 刻みに広げる
    let visible = (solid + dotted).filter { $0.0 >= t0 - 3 * 3600 && $0.0 <= t1 + 3 * 3600 }.map { $0.1 }
    var lo = floor(((visible.min() ?? 0) - 0.5) / 2) * 2
    var hi = ceil(((visible.max() ?? 10) + 0.5) / 2) * 2
    if hi - lo < 6 { lo = floor(((hi + lo) / 2 - 3) / 2) * 2; hi = lo + 6 }
    func x(_ t: Double) -> CGFloat { plot.minX + CGFloat((t - t0) / (t1 - t0)) * plot.width }
    func y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - lo) / (hi - lo)) * plot.height }

    var v = lo
    while v <= hi + 0.01 { hline(y(v), color: grid, from: plot.minX, to: plot.maxX); v += 2 }
    text(fmt(hi), x: plot.maxX + 4, y: y(hi) - 7, size: 10, color: sub)
    text(fmt(lo), x: plot.maxX + 4, y: y(lo) - 7, size: 10, color: sub)

    ctx.saveGState()
    ctx.clip(to: CGRect(x: plot.minX - 4, y: plot.minY - 20, width: plot.width + 8, height: plot.height + 40))
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
    func mark(_ p: (Double, Double)) {
        let q = CGPoint(x: x(p.0), y: y(p.1))
        ctx.setFillColor(fg.cgColor)
        ctx.fillEllipse(in: CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7))
        text(fmt(p.1.rounded()), x: min(max(q.x, plot.minX + 8), plot.maxX - 8), y: q.y - 19, size: 11,
             weight: .semibold, align: .center)
    }
    let now = g.current != nil ? solid.first : nil
    if let now { mark(now) }
    let future = solid.filter { $0.0 >= t0 && $0.0 <= t1 }.dropFirst(now != nil ? 1 : 0)
    // 予報の最高気温は、今より高いときだけ出す (この先は下がるだけなら、出しても
    // 意味が無い)。今の点のすぐ近くにあると値が重なるので、そのときも省く。
    if let mx = future.max(by: { $0.1 < $1.1 }),
       now.map({ mx.1.rounded() > $0.1.rounded()
                 && (abs(x(mx.0) - x($0.0)) >= 26 || abs(y(mx.1) - y($0.1)) >= 16) }) ?? true {
        mark(mx)
    }

    // 時刻: 3 時間ごとに数字、その間は点
    var t = t0
    while t <= t1 {
        let hour = jst.component(.hour, from: Date(timeIntervalSince1970: t))
        if hour % 3 == 0 {
            text("\(hour)", x: x(t), y: hourY, size: 10, color: sub, align: .center)
        } else {
            ctx.setFillColor(sub.cgColor)
            ctx.fillEllipse(in: CGRect(x: x(t) - 1, y: hourY + 6, width: 2, height: 2))
        }
        t += 3600
    }
    // 天気のアイコン: 3 時間ごとの予報を、その時間帯の真ん中に置く
    for w in g.weather where w.count == 3 {
        guard let ts = Double(w[0]) else { continue }
        let mid = ts + 1.5 * 3600
        guard mid > t0, mid < t1 else { continue }
        symbol(w[1], color: hex(w[2]), cx: x(mid), cy: iconCY, size: 15)
    }
    // 降水確率: 6 時間ごとの値を、その時間帯 (アイコン 2 つ分) の真ん中に置く
    for p in g.pops where p.count == 3 {
        guard let ts = Double(p[0]), !p[1].isEmpty else { continue }
        let mid = ts + 3 * 3600
        guard mid > t0, mid < t1 else { continue }
        text("\(p[1])%", x: x(mid), y: popY, size: 10, color: hex(p[2]), weight: .semibold, align: .center)
    }
    nextSection(graphH)
}

// 3. 3 日分の予報の文
if !input.days.isEmpty {
    text(input.daysTitle, x: pad, y: top, size: 11, color: sub)
    var ry = top + 20
    for (d, h) in zip(input.days, dayRowHs) {
        symbol(d.icon, color: hex(d.color), cx: pad + 9, cy: ry + 8, size: 14)
        text(L("\(d.date)(\(weekday(d.dow)))", "\(weekday(d.dow)) \(d.date)"), x: pad + 26, y: ry, size: 13, color: sub)
        textBox(phrased(d.text), x: dayTextX, y: ry, width: dayTextW, size: 13)
        ry += h
    }
    nextSection(daysH)
}

// 4. 週間予報: 7 日を横に並べる
if !input.week.isEmpty {
    text(L("週間予報", "Weekly forecast"), x: pad, y: top, size: 11, color: sub)
    let colW = (width - pad * 2) / CGFloat(input.week.count)
    let y0 = top + 20
    for (i, d) in input.week.enumerated() {
        let cx = pad + colW * (CGFloat(i) + 0.5)
        // 土曜は青、日曜は赤
        let wcolor: NSColor = d.dow == 6 ? hex(input.dark ? "#64B5FF" : "#0047B3")
            : d.dow == 0 ? hex(input.dark ? "#FF6961" : "#A3000F") : sub
        text(d.date, x: cx, y: y0, size: 11, color: sub, align: .center)
        text(L("(\(weekday(d.dow)))", weekday(d.dow)), x: cx, y: y0 + 13, size: 10, color: wcolor, align: .center)
        symbol(d.icon, color: hex(d.color), cx: cx, cy: y0 + 41, size: 17)
        text(d.max.isEmpty ? "-" : "\(d.max)°", x: cx, y: y0 + 56, size: 13, color: hex(d.maxColor),
             weight: .semibold, align: .center)
        // 色が無い (13〜24°C) ときは、最高気温と同じく標準の文字色にする
        text(d.min.isEmpty ? "-" : "\(d.min)°", x: cx, y: y0 + 71, size: 13, color: hex(d.minColor), align: .center)
        text(d.pop.isEmpty ? "-" : "\(d.pop)%", x: cx, y: y0 + 86, size: 11,
             color: d.popColor == nil ? sub : hex(d.popColor), weight: .semibold, align: .center)
    }
    top += weekH
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
// 幅、高さ、本来の高さ (下を空ける前)
print("\(Int(width)) \(Int(ceil(height))) \(Int(ceil(naturalHeight)))")
print(png.base64EncodedString())
