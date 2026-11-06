import AppKit
#if canImport(Shared)
import Shared
#endif

/// メニューを開いたときに出すカード。上から CPU (使用率・過去 10 分の推移・E / P コア・
/// 温度)、メモリ、CPU とメモリの上位 5 件のプロセス、バッテリー。
struct SystemCard {
    let snapshot: Snapshot
    let dark: Bool
    let colors: CardColors

    init(snapshot: Snapshot, dark: Bool) {
        self.snapshot = snapshot
        self.dark = dark
        self.colors = CardColors(dark: dark)
    }

    // 大きさ (pt)
    private let width: CGFloat = 360
    /// 左右の余白
    private let pad: CGFloat = 2
    /// 節の間 (区切り線を含む)
    private let gap: CGFloat = 13
    /// 節の見出しの高さ
    private let headerHeight: CGFloat = 20
    /// メーターなどの 1 行の高さ
    private let rowHeight: CGFloat = 18

    func render() -> PNGImage {
        // 節ごとに高さと描き方を決め、上から積む。無い節は飛ばす。
        var sections = [
            CardSection(height: cpuHeight, draw: drawCPU(in:top:)),
            CardSection(height: headerHeight + 52 + rowHeight, draw: drawMemory(in:top:)),
        ]
        if processRows > 0 {
            sections.append(CardSection(height: headerHeight + rowHeight * CGFloat(processRows), draw: drawProcesses(in:top:)))
        }
        if !snapshot.battery.isEmpty {
            sections.append(CardSection(height: headerHeight + batteryRowHeights.reduce(0, +), draw: drawBatteries(in:top:)))
        }

        return PNGImage.drawCard(width: width, height: sections.totalHeight(gap: gap), dark: dark) { context in
            sections.drawStacked(in: context, gap: gap) { y in
                Pen(context: context, colors: colors).horizontalRule(y: y, from: pad, to: width - pad)
            }
        }
    }

    // MARK: - 1. CPU

    private var cpuHeight: CGFloat {
        let cpu = snapshot.cpu
        let meterRows = (cpu.e != nil ? 2 : 0) + (cpu.temp != nil ? 2 : 0)
        return headerHeight + 52 + 14 + rowHeight * CGFloat(meterRows)
    }

    private func drawCPU(in context: CGContext, top: CGFloat) {
        let pen = Pen(context: context, colors: colors)
        let cpu = snapshot.cpu
        pen.text("CPU", x: pad, y: top, size: 11, color: colors.secondary)
        pen.text(L("負荷 \(cpu.load)", "Load \(cpu.load)"), x: width - pad, y: top, size: 11,
                 color: colors.secondary, digits: .tabular, align: .right)

        // 大きな数字と、ユーザ・システムの内訳
        let y0 = top + headerHeight
        let color = colors.level(cpu.total, warning: 50, critical: 80)
        let big = pen.text(formatted(cpu.total), x: pad, y: y0 - 4, size: 34, color: color, weight: .light,
                           digits: .tabular)
        let unit = pen.text("%", x: pad + big.width + 1, y: y0 + 8, size: 16, color: color, weight: .light)
        let breakdown = pen.text(L("ユーザ \(formatted(cpu.user))%  システム \(formatted(cpu.sys))%",
                                   "User \(formatted(cpu.user))%  System \(formatted(cpu.sys))%"),
                                 x: pad, y: y0 + 38, size: 10, color: colors.secondary, digits: .tabular)

        // 推移のグラフは、大きな数字と内訳の文字の右から描く (左端を固定すると、
        // 内訳の文字が長いときに重なる)
        let graphX = ceil(max(118, pad + big.width + 1 + unit.width, pad + breakdown.width) + 12)
        let graph = CGRect(x: graphX, y: y0 + 2, width: width - graphX - pad, height: 46)
        drawHistoryGraph(pen, in: graph, color: color)

        // E / P コアと温度のメーター
        var y = y0 + 52 + 14 // グラフの下の「10 分前」「今」の分を空ける
        if let e = cpu.e, let p = cpu.p {
            meterRow(pen, L("E コア", "E-cores"), value: e, shown: "\(formatted(e))%",
                     color: colors.level(e, warning: 70, critical: 90), y: y)
            y += rowHeight
            meterRow(pen, L("P コア", "P-cores"), value: p, shown: "\(formatted(p))%",
                     color: colors.level(p, warning: 50, critical: 80), y: y)
            y += rowHeight
        }
        if let temp = cpu.temp {
            temperatureRow(pen, L("CPU 温度", "CPU temp"), temp, y: y)
            y += rowHeight
            // GPU がほとんど動いていないとき、室温より低い値が出ることがある (macmon で温度を取っていたころに見た)
            if let gpu = cpu.gpu, gpu >= 20 {
                temperatureRow(pen, L("GPU 温度", "GPU temp"), gpu, y: y)
            } else {
                meterRow(pen, L("GPU 温度", "GPU temp"), value: 0, shown: "-", color: colors.green, y: y)
            }
        }
    }

    /// 使用率の推移の折れ線グラフ (塗りつぶし付き)。縦軸は 0〜100%。
    private func drawHistoryGraph(_ pen: Pen, in graph: CGRect, color: NSColor) {
        let context = pen.context
        // 目盛り: 0・50・100%
        context.setStrokeColor(colors.track.cgColor)
        context.setLineWidth(1)
        for fraction in [0.0, 0.5, 1.0] {
            let y = graph.maxY - graph.height * CGFloat(fraction)
            context.move(to: CGPoint(x: graph.minX, y: y))
            context.addLine(to: CGPoint(x: graph.maxX, y: y))
        }
        context.strokePath()

        let history = snapshot.cpu.hist
        // 右端が今。60 回分に満たないうちは右に寄せて描く。
        let slots = max(59, history.count - 1)
        if history.count > 1 {
            let last = CGFloat(history.count - 1)
            let points = history.indices.map { i in
                CGPoint(x: graph.maxX - graph.width * (last - CGFloat(i)) / CGFloat(slots),
                        y: graph.maxY - graph.height * CGFloat(min(history[i], 100) / 100))
            }
            context.drawFilledLine(through: points, bottom: graph.maxY, color: color, fillAlpha: 0.22, lineWidth: 1.5)
        }

        let minutes = Int((Double(slots) * snapshot.interval / 60).rounded())
        pen.text(L("\(minutes) 分前", "\(minutes) min ago"), x: graph.minX, y: graph.maxY + 2, size: 9,
                 color: colors.secondary)
        pen.text(L("今", "now"), x: graph.maxX, y: graph.maxY + 2, size: 9, color: colors.secondary, align: .right)
    }

    /// 温度のメーターの行。メーターは 30〜100°C を 0〜100% として描く
    private func temperatureRow(_ pen: Pen, _ label: String, _ temp: Double, y: CGFloat) {
        meterRow(pen, label, value: (temp - 30) / 70 * 100, shown: "\(formatted(temp))°C",
                 color: colors.level(temp, warning: 70, critical: 85), y: y)
    }

    /// ラベル・メーター・値の 1 行
    private func meterRow(_ pen: Pen, _ label: String, value: Double, shown: String, color: NSColor, y: CGFloat) {
        pen.text(label, x: pad, y: y, size: 12, color: colors.secondary)
        pen.meter(x: 74, y: y + 5, width: 200, value: value, color: color)
        pen.text(shown, x: width - pad, y: y, size: 12, weight: .medium, digits: .tabular, align: .right)
    }

    // MARK: - 2. メモリ

    private func drawMemory(in context: CGContext, top: CGFloat) {
        let pen = Pen(context: context, colors: colors)
        let mem = snapshot.mem
        let percent = snapshot.memoryPercent
        pen.text(L("メモリ", "Memory"), x: pad, y: top, size: 11, color: colors.secondary)
        // 右上にメモリプレッシャー
        let pressure: (label: String, color: NSColor) = switch mem.pressure {
        case 1: (L("正常", "Normal"), colors.green)
        case 2: (L("警告", "Warning"), colors.yellow)
        case 4: (L("危険", "Critical"), colors.red)
        default: (L("不明", "Unknown"), colors.secondary)
        }
        let pressureSize = pen.text(pressure.label, x: width - pad, y: top, size: 11, color: pressure.color,
                                    weight: .semibold, align: .right)
        pen.text(L("メモリプレッシャー", "Memory Pressure"), x: width - pad - pressureSize.width - 4, y: top,
                 size: 11, color: colors.secondary, align: .right)

        let y0 = top + headerHeight
        let color = colors.level(percent, warning: 70, critical: 85)
        let big = pen.text(formatted(percent), x: pad, y: y0 - 4, size: 34, color: color, weight: .light,
                           digits: .tabular)
        pen.text("%", x: pad + big.width + 1, y: y0 + 8, size: 16, color: color, weight: .light)
        let barX: CGFloat = 118
        pen.meter(x: barX, y: y0 + 8, width: width - barX - pad, height: 10, value: percent, color: color)
        pen.text("\(gigabytes(mem.used)) / \(gigabytes(mem.total))", x: barX, y: y0 + 24, size: 12, weight: .medium,
                 digits: .tabular)
        pen.text(L("圧縮 \(gigabytes(mem.compressed))   スワップ \(mem.swap)",
                   "Compressed \(gigabytes(mem.compressed))   Swap \(mem.swap)"),
                 x: barX, y: y0 + 40, size: 11, color: colors.secondary, digits: .tabular)
    }

    private func gigabytes(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }

    // MARK: - 3. プロセス

    private var processRows: Int { max(snapshot.procCpu.count, snapshot.procMem.count) }

    /// 左に CPU、右にメモリを使っているプロセスの上位
    private func drawProcesses(in context: CGContext, top: CGFloat) {
        let pen = Pen(context: context, colors: colors)
        let columnWidth = (width - pad * 2 - 12) / 2
        let leftX = pad
        let rightX = pad + columnWidth + 12
        pen.text(L("CPU を使っているプロセス", "Top CPU"), x: leftX, y: top, size: 11, color: colors.secondary)
        pen.text(L("メモリを使っているプロセス", "Top Memory"), x: rightX, y: top, size: 11, color: colors.secondary)

        for (i, process) in snapshot.procCpu.enumerated() {
            let y = top + headerHeight + rowHeight * CGFloat(i)
            // ps の %CPU は 1 コアを使い切ると 100%。メーターは 100% で頭打ちにする。
            pen.meter(x: leftX, y: y + 5, width: 18, value: process.value,
                      color: colors.level(process.value, warning: 50, critical: 90))
            pen.text(formatted(process.value, digits: 1), x: leftX + 56, y: y, size: 11, weight: .medium,
                     digits: .tabular, align: .right)
            pen.text(process.shownName, x: leftX + 62, y: y, size: 11, maxWidth: columnWidth - 62)
        }
        for (i, process) in snapshot.procMem.enumerated() {
            let y = top + headerHeight + rowHeight * CGFloat(i)
            // メモリのメーターは 4 GB を 100% として描く
            let kilobytes = process.value
            let percent = kilobytes / 4_194_304 * 100
            pen.meter(x: rightX, y: y + 5, width: 18, value: percent,
                      color: colors.level(percent, warning: 50, critical: 90))
            let size = kilobytes >= 1_048_576
                ? String(format: "%.1f GB", kilobytes / 1_048_576)
                : String(format: "%d MB", Int(kilobytes / 1024))
            pen.text(size, x: rightX + 68, y: y, size: 11, weight: .medium, digits: .tabular, align: .right)
            pen.text(process.shownName, x: rightX + 74, y: y, size: 11, maxWidth: columnWidth - 74)
        }
    }

    // MARK: - 4. バッテリー

    /// 行の高さ。本体のバッテリーは、状態の文の行のぶん高い
    private var batteryRowHeights: [CGFloat] {
        snapshot.battery.map { $0.statusText == nil ? rowHeight : 33 }
    }

    private func drawBatteries(in context: CGContext, top: CGFloat) {
        let pen = Pen(context: context, colors: colors)
        pen.text(L("バッテリー", "Battery"), x: pad, y: top, size: 11, color: colors.secondary)
        var y = top + headerHeight
        for (battery, height) in zip(snapshot.battery, batteryRowHeights) {
            // 残量は少ないほど危ないので、少ないときに黄・赤にする
            let color = battery.percent < 20 ? colors.red : battery.percent < 40 ? colors.yellow : colors.green
            pen.text(battery.isInternal ? L("この Mac", "This Mac") : battery.name, x: pad, y: y, size: 12, maxWidth: 150)
            pen.meter(x: 160, y: y + 5, width: 130, value: battery.percent, color: color)
            pen.text("\(formatted(battery.percent))%", x: width - pad, y: y, size: 12, weight: .medium,
                     digits: .tabular, align: .right)
            if let status = battery.statusText {
                pen.text(status, x: pad, y: y + 16, size: 11, color: colors.secondary, digits: .tabular)
            }
            y += height
        }
    }
}
