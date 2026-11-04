// sysmon.10s.sh が使う、システムの状態のカードを描くプログラム。
//
// 標準入力に JSON を受け取り、次の 5 行を書く。
//   1. カードの大きさ (pt) を「幅 高さ」で   2. カードの PNG の Base64
//   3. メニューバーの画像の大きさ             4・5. 明るい / 暗いメニューバー用の PNG の Base64
//
// カードは上から次の 4 つ。
// 1. CPU: 使用率を大きく、その横に推移の折れ線グラフ。下に E / P コアの稼働率と温度
// 2. メモリ: 使用率を大きく、使用量のバー、圧縮・スワップ・メモリプレッシャー
// 3. プロセス: CPU とメモリの上位 5 件を左右に並べる
// 4. バッテリー: Bluetooth 機器ごとの残量
//
// 10 秒ごとに起動されるので、1 回の描画は 0.05 秒ほどに収まるようにしてある。
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。sysmon.10s.sh が初回にコンパイルする。

import AppKit

struct CPU: Decodable {
    let total: Double
    let user: Double
    let sys: Double
    let e: Double?
    let p: Double?
    let load: String
    let temp: Double?
    let gpu: Double?
    let hist: [Double]
}

struct Mem: Decodable {
    let used: Double
    let total: Double
    let compressed: Double
    let swap: String
    let pressure: Int
}

struct Proc: Decodable {
    let name: String
    let value: Double
    // com.apple.WebKit.WebContent のような名前は先頭が同じで、切り詰めると区別が
    // 付かなくなるので com.apple. を省く
    var shown: String { name.hasPrefix("com.apple.") ? String(name.dropFirst("com.apple.".count)) : name }
}

struct Battery: Decodable {
    let name: String
    let percent: Double
}

struct Input: Decodable {
    let dark: Bool
    let interval: Double // 履歴の 1 回分の秒数
    let cpu: CPU
    let mem: Mem
    let procCpu: [Proc]
    let procMem: [Proc] // KB
    let battery: [Battery]
}

let data = FileHandle.standardInput.readDataToEndOfFile()
let input: Input
do {
    input = try JSONDecoder().decode(Input.self, from: data)
} catch {
    FileHandle.standardError.write("sysmon-card: JSON を読めない: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let dark = input.dark
let fg = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.1, alpha: 1)
let sub = dark ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.42, alpha: 1)
let track = dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)
let rule = dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.15)
func rgb(_ light: UInt32, _ darkv: UInt32) -> NSColor {
    let v = dark ? darkv : light
    return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let green = rgb(0x248A3D, 0x30D158), yellow = rgb(0xB07800, 0xFFD60A), red = rgb(0xD70015, 0xFF453A)
let blue = rgb(0x0A6FD8, 0x64B5FF)
// 値に応じた色。warn 以上で黄、crit 以上で赤。
func level(_ v: Double, _ warn: Double, _ crit: Double) -> NSColor { v >= crit ? red : v >= warn ? yellow : green }

// 大きさ (pt)。上から順に積む。
let width: CGFloat = 360
let pad: CGFloat = 2
let gap: CGFloat = 13
let cpuH: CGFloat = 20 + 52 + 14 + 18 * CGFloat((input.cpu.e != nil ? 2 : 0) + (input.cpu.temp != nil ? 2 : 0))
let memH: CGFloat = 20 + 52 + 18
let procRows = max(input.procCpu.count, input.procMem.count)
let procH: CGFloat = procRows > 0 ? 20 + 18 * CGFloat(procRows) : 0
let batH: CGFloat = input.battery.isEmpty ? 0 : 20 + 18 * CGFloat(input.battery.count)
let sections = [cpuH, memH, procH, batH].filter { $0 > 0 }
let height = sections.reduce(0, +) + gap * CGFloat(max(sections.count - 1, 0))
let scale: CGFloat = 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
// 上から下へ座標を取る (y は上端からの距離)
ctx.translateBy(x: 0, y: height)
ctx.scaleBy(x: 1, y: -1)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

@discardableResult
func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor = fg,
          weight: NSFont.Weight = .regular, align: NSTextAlignment = .left, maxWidth: CGFloat? = nil) -> CGSize {
    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    var sz = str.size()
    if let mw = maxWidth { sz.width = min(sz.width, mw) }
    let dx: CGFloat = align == .center ? -sz.width / 2 : (align == .right ? -sz.width : 0)
    str.draw(with: CGRect(x: x + dx, y: y, width: sz.width, height: sz.height + 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    return sz
}

func symbol(_ name: String, x: CGFloat, cy: CGFloat, size: CGFloat, color: NSColor) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    let s = img.size
    img.draw(in: CGRect(x: x, y: cy - s.height / 2, width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

// 横棒のメーター。0〜100 の値を、角の丸い溝の上に色の棒で描く。
func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 6, value: Double, color: NSColor) {
    let r = h / 2
    ctx.setFillColor(track.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()
    let fw = max(h, w * CGFloat(min(max(value, 0), 100) / 100))
    if value > 0 {
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: fw, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
    }
}

func hline(_ y: CGFloat) {
    ctx.setStrokeColor(rule.cgColor)
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: pad, y: y))
    ctx.addLine(to: CGPoint(x: width - pad, y: y))
    ctx.strokePath()
}

func fmt(_ v: Double, _ d: Int = 0) -> String { String(format: "%.\(d)f", v) }
func gb(_ b: Double) -> String { String(format: "%.1f GB", b / 1_073_741_824) }

var top: CGFloat = 0
func nextSection(_ h: CGFloat) {
    top += h
    if top < height - 1 { hline(top + gap / 2); top += gap }
}

// ラベル・メーター・値の 1 行
func meterRow(_ label: String, value: Double, shown: String, color: NSColor, y: CGFloat) {
    text(label, x: pad, y: y, size: 12, color: sub)
    bar(x: 74, y: y + 5, w: 200, value: value, color: color)
    text(shown, x: width - pad, y: y, size: 12, color: fg, weight: .medium, align: .right)
}

// 1. CPU
do {
    let c = input.cpu
    text("CPU", x: pad, y: top, size: 11, color: sub)
    text("負荷 \(c.load)", x: width - pad, y: top, size: 11, color: sub, align: .right)
    let y0 = top + 20
    let col = level(c.total, 50, 80)
    let big = text(fmt(c.total), x: pad, y: y0 - 4, size: 34, color: col, weight: .light)
    text("%", x: pad + big.width + 1, y: y0 + 8, size: 16, color: col, weight: .light)
    text("ユーザ \(fmt(c.user))%  システム \(fmt(c.sys))%", x: pad, y: y0 + 38, size: 10, color: sub)

    // 推移の折れ線グラフ (塗りつぶし付き)。縦軸は 0〜100%。
    let g = CGRect(x: 118, y: y0 + 2, width: width - 118 - pad, height: 46)
    ctx.setStrokeColor(track.cgColor)
    ctx.setLineWidth(1)
    for f in [0.0, 0.5, 1.0] {
        let yy = g.maxY - g.height * CGFloat(f)
        ctx.move(to: CGPoint(x: g.minX, y: yy)); ctx.addLine(to: CGPoint(x: g.maxX, y: yy))
    }
    ctx.strokePath()
    let h = c.hist
    if h.count > 1 {
        let n = CGFloat(max(h.count - 1, 1))
        // 右端が今。60 回分に満たないうちは右に寄せて描く。
        let slots = CGFloat(max(59, h.count - 1))
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: g.maxX - g.width * (n - CGFloat(i)) / slots, y: g.maxY - g.height * CGFloat(min(h[i], 100) / 100))
        }
        let line = CGMutablePath()
        line.move(to: pt(0))
        for i in 1..<h.count { line.addLine(to: pt(i)) }
        let area = CGMutablePath()
        area.addPath(line)
        area.addLine(to: CGPoint(x: pt(h.count - 1).x, y: g.maxY))
        area.addLine(to: CGPoint(x: pt(0).x, y: g.maxY))
        area.closeSubpath()
        ctx.addPath(area)
        ctx.setFillColor(col.withAlphaComponent(0.22).cgColor)
        ctx.fillPath()
        ctx.addPath(line)
        ctx.setStrokeColor(col.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }
    let minutes = Int((Double(max(59, h.count - 1)) * input.interval / 60).rounded())
    text("\(minutes) 分前", x: g.minX, y: g.maxY + 2, size: 9, color: sub)
    text("今", x: g.maxX, y: g.maxY + 2, size: 9, color: sub, align: .right)

    var ry = y0 + 52 + 14 // グラフの下の「10 分前」「今」の分を空ける
    if let e = c.e, let p = c.p {
        meterRow("E コア", value: e, shown: "\(fmt(e))%", color: level(e, 70, 90), y: ry); ry += 18
        meterRow("P コア", value: p, shown: "\(fmt(p))%", color: level(p, 50, 80), y: ry); ry += 18
    }
    if let t = c.temp {
        // 温度のメーターは 30〜100°C を 0〜100% として描く
        meterRow("CPU 温度", value: (t - 30) / 70 * 100, shown: "\(fmt(t))°C", color: level(t, 70, 85), y: ry); ry += 18
        // GPU がほとんど動いていないとき、macmon は室温より低い値を返すことがある
        if let gt = c.gpu, gt >= 20 {
            meterRow("GPU 温度", value: (gt - 30) / 70 * 100, shown: "\(fmt(gt))°C", color: level(gt, 70, 85), y: ry)
        } else {
            meterRow("GPU 温度", value: 0, shown: "-", color: green, y: ry)
        }
    }
    nextSection(cpuH)
}

// 2. メモリ
do {
    let m = input.mem
    let pct = m.used / m.total * 100
    text("メモリ", x: pad, y: top, size: 11, color: sub)
    let pressure = m.pressure == 1 ? ("正常", green) : m.pressure == 2 ? ("警告", yellow) : m.pressure == 4 ? ("危険", red) : ("不明", sub)
    let ps = text(pressure.0, x: width - pad, y: top, size: 11, color: pressure.1, weight: .semibold, align: .right)
    text("メモリプレッシャー", x: width - pad - ps.width - 4, y: top, size: 11, color: sub, align: .right)
    let y0 = top + 20
    let col = level(pct, 70, 85)
    let big = text(fmt(pct), x: pad, y: y0 - 4, size: 34, color: col, weight: .light)
    text("%", x: pad + big.width + 1, y: y0 + 8, size: 16, color: col, weight: .light)
    let bx: CGFloat = 118
    bar(x: bx, y: y0 + 8, w: width - bx - pad, h: 10, value: pct, color: col)
    text("\(gb(m.used)) / \(gb(m.total))", x: bx, y: y0 + 24, size: 12, weight: .medium)
    text("圧縮 \(gb(m.compressed))   スワップ \(m.swap)", x: bx, y: y0 + 40, size: 11, color: sub)
    nextSection(memH)
}

// 3. プロセス: 左に CPU、右にメモリの上位
if procRows > 0 {
    let colW = (width - pad * 2 - 12) / 2
    let lx = pad, rx = pad + colW + 12
    text("CPU を使っているプロセス", x: lx, y: top, size: 11, color: sub)
    text("メモリを使っているプロセス", x: rx, y: top, size: 11, color: sub)
    var ry = top + 20
    for i in 0..<procRows {
        if i < input.procCpu.count {
            let p = input.procCpu[i]
            // ps の %CPU は 1 コアを使い切ると 100%。バーは 100% で頭打ちにする。
            bar(x: lx, y: ry + 5, w: 18, value: p.value, color: level(p.value, 50, 90))
            text(fmt(p.value, 1), x: lx + 56, y: ry, size: 11, weight: .medium, align: .right)
            text(p.shown, x: lx + 62, y: ry, size: 11, maxWidth: colW - 62)
        }
        if i < input.procMem.count {
            let p = input.procMem[i]
            // メモリのバーは 4 GB を 100% として描く
            let kb = p.value
            let pct = kb / 4_194_304 * 100
            bar(x: rx, y: ry + 5, w: 18, value: pct, color: level(pct, 50, 90))
            let s = kb >= 1_048_576 ? String(format: "%.1f GB", kb / 1_048_576) : String(format: "%d MB", Int(kb / 1024))
            text(s, x: rx + 68, y: ry, size: 11, weight: .medium, align: .right)
            text(p.shown, x: rx + 74, y: ry, size: 11, maxWidth: colW - 74)
        }
        ry += 18
    }
    nextSection(procH)
}

// 4. バッテリー
if !input.battery.isEmpty {
    text("バッテリー", x: pad, y: top, size: 11, color: sub)
    var ry = top + 20
    for b in input.battery {
        // 残量は少ないほど危ないので、少ないときに黄・赤にする
        let col = b.percent < 20 ? red : b.percent < 40 ? yellow : green
        text(b.name, x: pad, y: ry, size: 12, maxWidth: 150)
        bar(x: 160, y: ry + 5, w: 130, value: b.percent, color: col)
        text("\(fmt(b.percent))%", x: width - pad, y: ry, size: 12, weight: .medium, align: .right)
        ry += 18
    }
    top += batH
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
print("\(Int(width)) \(Int(ceil(height)))")
print(png.base64EncodedString())

// メニューバーの画像
// CPU [直近 3 分の折れ線グラフ] 28%  MEM [横棒] 58%  48°C
// 明るいメニューバー用と暗いメニューバー用の 2 枚を描く。SwiftBar は
// image=明るい用,暗い用 の 2 枚から、メニューバーの見た目に合うほうを選ぶ。
// 数字は等幅の数字で描くので、値が変わっても項目の幅が変わらない。
func menuBarImage(dark d: Bool) -> (Data, CGSize) {
    func c(_ light: UInt32, _ darkv: UInt32) -> NSColor {
        let v = d ? darkv : light
        return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    let bfg = d ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
    let btrack = d ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.18)
    let bgreen = c(0x248A3D, 0x30D158), byellow = c(0xB07800, 0xFFD60A), bred = c(0xD70015, 0xFF453A)
    func lv(_ v: Double, _ w: Double, _ cr: Double) -> NSColor { v >= cr ? bred : v >= w ? byellow : bgreen }

    let h: CGFloat = 22
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    func attr(_ s: String, _ col: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: col])
    }
    let cpu = input.cpu.total
    let pct = input.mem.used / input.mem.total * 100
    let chartW: CGFloat = 40, chartH: CGFloat = 14, barW: CGFloat = 26, barH: CGFloat = 6
    let cpuLabel = attr("CPU", bfg), memLabel = attr("MEM", bfg)
    // 桁が少ないときは、数字 1 文字分の空白 (U+2007 figure space) で前を埋めて幅を揃える
    func pad3(_ v: Double) -> String { String(format: "%3.0f", v).replacingOccurrences(of: " ", with: "\u{2007}") }
    let cpuVal = attr(pad3(cpu) + "%", bfg)
    let memVal = attr(pad3(pct) + "%", lv(pct, 70, 85))
    let tempVal = input.cpu.temp.map { attr(String(format: "%.0f°C", $0), lv($0, 70, 85)) }
    let low = input.battery.contains { $0.percent < 20 }
    let sp: CGFloat = 4, gapW: CGFloat = 10
    var w = cpuLabel.size().width + sp + chartW + sp + cpuVal.size().width + gapW
        + memLabel.size().width + sp + barW + sp + memVal.size().width
    if let t = tempVal { w += gapW + t.size().width }
    if low { w += sp + 16 }
    w = ceil(w) + 1

    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    r.size = NSSize(width: w, height: h)
    let g = NSGraphicsContext(bitmapImageRep: r)!
    let cg = g.cgContext
    cg.translateBy(x: 0, y: h)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    var x: CGFloat = 0
    func put(_ a: NSAttributedString) {
        let sz = a.size()
        a.draw(at: CGPoint(x: x, y: (h - sz.height) / 2))
        x += sz.width
    }
    put(cpuLabel); x += sp
    // 折れ線グラフ: 直近 18 回分 (3 分)。縦軸は 0〜100%、色は今の使用率の色。
    let hist = Array(input.cpu.hist.suffix(18))
    let box = CGRect(x: x, y: (h - chartH) / 2, width: chartW, height: chartH)
    cg.setFillColor(btrack.withAlphaComponent(d ? 0.12 : 0.08).cgColor)
    cg.addPath(CGPath(roundedRect: box, cornerWidth: 2, cornerHeight: 2, transform: nil))
    cg.fillPath()
    if hist.count > 1 {
        let col = lv(cpu, 50, 80)
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: box.maxX - chartW * CGFloat(hist.count - 1 - i) / 17,
                    y: box.maxY - (chartH - 1) * CGFloat(min(hist[i], 100) / 100) - 0.5)
        }
        let line = CGMutablePath()
        line.move(to: pt(0))
        for i in 1..<hist.count { line.addLine(to: pt(i)) }
        let area = CGMutablePath()
        area.addPath(line)
        area.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        area.addLine(to: CGPoint(x: pt(0).x, y: box.maxY))
        area.closeSubpath()
        cg.addPath(area)
        cg.setFillColor(col.withAlphaComponent(0.35).cgColor)
        cg.fillPath()
        cg.addPath(line)
        cg.setStrokeColor(col.cgColor)
        cg.setLineWidth(1.25)
        cg.setLineJoin(.round)
        cg.strokePath()
    }
    x += chartW + sp
    put(cpuVal); x += gapW
    put(memLabel); x += sp
    // メモリの横棒
    let mb = CGRect(x: x, y: (h - barH) / 2, width: barW, height: barH)
    cg.setFillColor(btrack.cgColor)
    cg.addPath(CGPath(roundedRect: mb, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
    cg.fillPath()
    cg.setFillColor(lv(pct, 70, 85).cgColor)
    cg.addPath(CGPath(roundedRect: CGRect(x: mb.minX, y: mb.minY, width: max(barH, barW * CGFloat(pct / 100)), height: barH),
                      cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
    cg.fillPath()
    x += barW + sp
    put(memVal)
    if let t = tempVal { x += gapW; put(t) }
    if low {
        x += sp
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [bred]))
        if let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = img.size
            img.draw(in: CGRect(x: x, y: (h - s.height) / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return (r.representation(using: .png, properties: [:])!, CGSize(width: w, height: h))
}
let (lightBar, barSize) = menuBarImage(dark: false)
let (darkBar, _) = menuBarImage(dark: true)
print("\(Int(barSize.width)) \(Int(barSize.height))")
print(lightBar.base64EncodedString())
print(darkBar.base64EncodedString())
