// sysmon.sh が起動する、システムの状態をメニューバーに出す常駐型のプログラム。
//
// SwiftBar の常駐型 (streamable) プラグインとして動き、10 秒ごとに値を集めて
// 描き、メニューの中身を標準出力に書く。中身の後ろに「~~~」の行を書くと、
// SwiftBar がメニューを差し替える (sysmon.sh の useTrailingStreamSeparator)。
//
// 以前は 10 秒ごとにシェルのスクリプトを起動し、iostat・ps・vm_stat・jq・描画の
// プログラムなどを毎回起動していた。その起動の積み重ねで、平均して 1 コアの
// 2.5% ほどを使っていたので、常駐して値を API から直接取るようにした。
// - CPU の使用率: host_processor_info のティックの差分
// - メモリ: host_statistics64 (Activity Monitor の「使用済みメモリ」と同じく、
//   アプリ (internal から purgeable を除く) + wired + 圧縮で数える)
// - 負荷: getloadavg
// - プロセスごとの CPU とメモリ: ps (20 秒ごと)。root で動くプロセスは権限の無い
//   プログラムからは libproc で読めないので、setuid root の ps に頼る。
// - 温度と E / P コアの稼働率: macmon (30 秒ごと)
// - Bluetooth 機器のバッテリー: ioreg (60 秒ごと)。名前は system_profiler (1 時間ごと)
//
// カード: 上から CPU (使用率・過去 10 分の推移・E / P コア・温度)、メモリ、
// CPU とメモリの上位 5 件のプロセス、Bluetooth 機器のバッテリー。
// メニューバー: CPU の直近 3 分の推移・使用率、メモリ、温度。
//
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。sysmon.sh が初回 (とソースを変えたとき) にコンパイルする。

import AppKit
import Darwin

struct CPU {
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

struct Mem {
    let used: Double
    let total: Double
    let compressed: Double
    let swap: String
    let pressure: Int
}

struct Proc {
    let name: String
    let value: Double
    // com.apple.WebKit.WebContent のような名前は先頭が同じで、切り詰めると区別が
    // 付かなくなるので com.apple. を省く
    var shown: String { name.hasPrefix("com.apple.") ? String(name.dropFirst("com.apple.".count)) : name }
}

struct Battery {
    let name: String
    let percent: Double
}

struct Input {
    let dark: Bool
    let interval: Double // 履歴の 1 回分の秒数
    let cpu: CPU
    let mem: Mem
    let procCpu: [Proc]
    let procMem: [Proc] // KB
    let battery: [Battery]
}

// 描画: カードとメニューバーの画像を描き、[カードの大きさ, カード, メニューバーの大きさ, 明るい用, 暗い用] を返す
func renderAll(_ input: Input) -> [String] {
    var out: [String] = []
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
        let unit = text("%", x: pad + big.width + 1, y: y0 + 8, size: 16, color: col, weight: .light)
        let breakdown = text("ユーザ \(fmt(c.user))%  システム \(fmt(c.sys))%", x: pad, y: y0 + 38, size: 10, color: sub)

        // 推移の折れ線グラフ (塗りつぶし付き)。縦軸は 0〜100%。
        // 推移の折れ線グラフは、大きな数字と内訳の文字の右から描く (左端を固定すると、
        // 内訳の文字が長いときに重なる)
        let gx = ceil(max(118, pad + big.width + 1 + unit.width, pad + breakdown.width) + 12)
        let g = CGRect(x: gx, y: y0 + 2, width: width - gx - pad, height: 46)
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
    out.append("\(Int(width)) \(Int(ceil(height)))")
    out.append(png.base64EncodedString())

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
    out.append("\(Int(barSize.width)) \(Int(barSize.height))")
    out.append(lightBar.base64EncodedString())
    out.append(darkBar.base64EncodedString())
    return out
}

// ---- 値の収集 ----

func sysctlValue<T>(_ name: String, _ initial: T) -> T? {
    var v = initial
    var size = MemoryLayout<T>.size
    return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
}

// 外部のコマンドを起動して、標準出力を文字列で返す
func run(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

// CPU のティック (全コアの合計)。使用率は前回との差分で求める。
struct Ticks { var user: UInt64 = 0, sys: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0 }
func cpuTicks() -> Ticks {
    var count: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    var t = Ticks()
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
          let info else { return t }
    for c in 0..<Int(count) {
        let b = Int(CPU_STATE_MAX) * c
        t.user += UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]))
        t.sys += UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]))
        t.idle += UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))
        t.nice += UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
    }
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    return t
}

func memory() -> Mem {
    var vm = vm_statistics64()
    var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt) }
    }
    let page = Double(vm_kernel_page_size)
    let compressed = Double(vm.compressor_page_count) * page
    let used = (Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count)) * page + compressed
    let total = Double(sysctlValue("hw.memsize", UInt64(0)) ?? 0)
    let swapUsed = sysctlValue("vm.swapusage", xsw_usage()).map { Double($0.xsu_used) } ?? 0
    let swap = swapUsed >= 1_073_741_824 ? String(format: "%.1f GB", swapUsed / 1_073_741_824) : String(format: "%.0f MB", swapUsed / 1_048_576)
    let pressure = Int(sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0)) ?? 0)
    return Mem(used: used, total: total, compressed: compressed, swap: swap, pressure: pressure)
}

// ps の %CPU は直近の平均なので、全体の使用率と合計は一致しない
func processes() -> ([Proc], [Proc]) {
    guard let s = run("/bin/ps", ["-Aceo", "pcpu=,rss=,comm="]) else { return ([], []) }
    var all: [(Double, Double, String)] = []
    for line in s.split(separator: "\n") {
        let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard f.count == 3, let c = Double(f[0]), let r = Double(f[1]) else { continue }
        all.append((c, r, String(f[2])))
    }
    let byCpu = all.sorted { $0.0 > $1.0 }.prefix(5).map { Proc(name: $0.2, value: $0.0) }
    let byMem = all.sorted { $0.1 > $1.1 }.prefix(5).map { Proc(name: $0.2, value: $0.1) }
    return (byCpu, byMem)
}

// macmon の cpu_usage_pct はコアが起きていた時間の割合で、Activity Monitor の
// 使用率より大きく出る。macmon は温度と E / P コアの稼働率だけに使う。
func macmon() -> (temp: Double?, gpu: Double?, e: Double?, p: Double?) {
    for path in ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"] where FileManager.default.isExecutableFile(atPath: path) {
        guard let s = run(path, ["pipe", "-s", "1", "-i", "500"]),
              let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return (nil, nil, nil, nil) }
        let t = j["temp"] as? [String: Any]
        func pct(_ k: String) -> Double? { (j[k] as? Double).map { ($0 * 100).rounded() } }
        return ((t?["cpu_temp_avg"] as? Double)?.rounded(), (t?["gpu_temp_avg"] as? Double)?.rounded(),
                pct("ecpu_active_ratio"), pct("pcpu_active_ratio"))
    }
    return (nil, nil, nil, nil)
}

// Bluetooth 機器の名前 (アドレス → 名前)。ioreg の Product は空になる機器があるので
// system_profiler から取る。
func bluetoothNames() -> [String: String] {
    guard let s = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
          let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
          let bt = (j["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [:] }
    var names: [String: String] = [:]
    for key in ["device_connected", "device_not_connected"] {
        for entry in bt[key] as? [[String: Any]] ?? [] {
            for (name, v) in entry {
                if let addr = (v as? [String: Any])?["device_address"] as? String { names[addr.uppercased()] = name }
            }
        }
    }
    return names
}

func batteries(_ names: [String: String]) -> [Battery] {
    guard let s = run("/usr/sbin/ioreg", ["-r", "-k", "BatteryPercent", "-l"]) else { return [] }
    var out: [Battery] = []
    var addr = ""
    for line in s.split(separator: "\n") {
        if line.contains("\"DeviceAddress\" = ") {
            addr = line.components(separatedBy: " = ").last?.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "-", with: ":").uppercased() ?? ""
        } else if line.contains("\"BatteryPercent\" = "), let v = Double(line.components(separatedBy: " = ").last ?? "") {
            out.append(Battery(name: names[addr] ?? addr, percent: v))
            addr = ""
        }
    }
    return out
}

func isDark() -> Bool {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
}

// ---- 常駐のループ ----

setvbuf(stdout, nil, _IOLBF, 0)
let interval: TimeInterval = 10
let historyFile = NSString(string: "~/Library/Caches/swiftbar-sysmon-cpu-history.txt").expandingTildeInPath
var history: [Double] = ((try? String(contentsOfFile: historyFile, encoding: .utf8)) ?? "")
    .split(separator: "\n").compactMap { Double($0) }.suffix(60).map { $0 }
var prev = cpuTicks()
var procCpu: [Proc] = [], procMem: [Proc] = []
var temps: (temp: Double?, gpu: Double?, e: Double?, p: Double?) = (nil, nil, nil, nil)
var bats: [Battery] = []
var btNames: [String: String] = [:]
var lastPs = 0.0, lastMacmon = 0.0, lastBattery = 0.0, lastNames = 0.0
Thread.sleep(forTimeInterval: 1) // 最初の使用率を出すため、ティックの差分を取る間を置く

while true {
    let now = Date().timeIntervalSince1970
    let t = cpuTicks()
    let du = Double((t.user &- prev.user) &+ (t.nice &- prev.nice)), ds = Double(t.sys &- prev.sys)
    let di = Double(t.idle &- prev.idle)
    let total = du + ds + di
    let user = total > 0 ? (du / total * 100).rounded() : 0, sys = total > 0 ? (ds / total * 100).rounded() : 0
    prev = t
    history.append(user + sys)
    if history.count > 60 { history.removeFirst(history.count - 60) }
    try? history.map { String(Int($0)) }.joined(separator: "\n").write(toFile: historyFile, atomically: true, encoding: .utf8)

    var la = [Double](repeating: 0, count: 3)
    getloadavg(&la, 3)
    if now - lastPs >= 20 { (procCpu, procMem) = processes(); lastPs = now }
    if now - lastMacmon >= 30 { temps = macmon(); lastMacmon = now }
    if now - lastNames >= 3600 { btNames = bluetoothNames(); lastNames = now }
    if now - lastBattery >= 60 { bats = batteries(btNames); lastBattery = now }

    let input = Input(dark: isDark(), interval: interval,
                      cpu: CPU(total: user + sys, user: user, sys: sys, e: temps.e, p: temps.p,
                               load: String(format: "%.2f / %.2f / %.2f", la[0], la[1], la[2]),
                               temp: temps.temp, gpu: temps.gpu, hist: history),
                      mem: memory(), procCpu: procCpu, procMem: procMem, battery: bats)
    let o = renderAll(input)
    var lines: [String] = []
    if o.count == 5 {
        lines.append(" | image=\(o[3]),\(o[4]) width=\(o[2].replacingOccurrences(of: " ", with: " height="))")
        lines.append("---")
        // カードの行には動作を付けない (無効な項目にする)。動作を付けると、マウスを
        // 載せたときにカード全体が選択の色で塗られる。画像は無効な項目でも薄くならない。
        lines.append(" | image=\(o[1]) width=\(o[0].replacingOccurrences(of: " ", with: " height="))")
    } else {
        lines.append("CPU \(Int(user + sys))%")
    }
    lines.append("---")
    lines.append("アクティビティモニタを開く | sfimage=arrow.up.forward.circle bash=/usr/bin/open param1=-a param2=\"Activity Monitor\" terminal=false")
    // 中身の後ろに区切りを出す (sysmon.sh の useTrailingStreamSeparator)
    print(lines.joined(separator: "\n") + "\n~~~")
    fflush(stdout)

    // 次の 10 秒の区切りまで寝る
    let next = (floor(Date().timeIntervalSince1970 / interval) + 1) * interval
    Thread.sleep(forTimeInterval: max(1, next - Date().timeIntervalSince1970))
}
