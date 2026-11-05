import AppKit
#if canImport(Shared)
import Shared
#endif

/// メニューバーの画像。
///
///     CPU [直近 3 分の折れ線グラフ] 28%  MEM [横棒] 58%  48°C
///
/// 明るいメニューバー用と暗いメニューバー用の 2 枚を描く (SwiftBar.menuBarImageLine)。
/// 数字は等幅の数字で描くので、値が変わっても項目の幅が変わらない。
struct SystemMenuBar {
    let snapshot: Snapshot

    private let height: CGFloat = 22
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private let chartSize = CGSize(width: 40, height: 14)
    private let barSize = CGSize(width: 26, height: 6)
    /// ラベルとグラフ・値の間
    private let spacing: CGFloat = 4
    /// CPU・MEM・温度の項目の間
    private let itemGap: CGFloat = 10
    /// グラフに描く回数 (18 回 = 3 分)
    private let chartSamples = 18

    func render(dark: Bool) -> PNGImage {
        // メニューバーの色は、カードの色 (CardColors) より明るい
        let primary = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
        let track = dark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.18)
        let green = NSColor(rgb: dark ? 0x30D158 : 0x248A3D)
        let yellow = NSColor(rgb: dark ? 0xFFD60A : 0xB07800)
        let red = NSColor(rgb: dark ? 0xFF453A : 0xD70015)
        func level(_ value: Double, warning: Double, critical: Double) -> NSColor {
            value >= critical ? red : value >= warning ? yellow : green
        }
        func label(_ string: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        }

        // 描く前に、項目を並べたときの幅を求める
        let cpuPercent = snapshot.cpu.total
        let memoryPercent = snapshot.memoryPercent
        let cpuLabel = label("CPU", primary)
        let memoryLabel = label("MEM", primary)
        let cpuValue = label(threeDigits(cpuPercent) + "%", primary)
        let memoryValue = label(threeDigits(memoryPercent) + "%", level(memoryPercent, warning: 70, critical: 85))
        let tempValue = snapshot.cpu.temp.map { label(String(format: "%.0f°C", $0), level($0, warning: 70, critical: 85)) }
        let batteryIsLow = snapshot.battery.contains { $0.percent < 20 }

        var width = cpuLabel.size().width + spacing + chartSize.width + spacing + cpuValue.size().width + itemGap
            + memoryLabel.size().width + spacing + barSize.width + spacing + memoryValue.size().width
        if let tempValue { width += itemGap + tempValue.size().width }
        if batteryIsLow { width += spacing + 16 }
        width = ceil(width) + 1

        return PNGImage.draw(width: width, height: height) { context in
            // 左から順に置いていく。x は次に置く位置
            var x: CGFloat = 0
            func put(_ text: NSAttributedString) {
                let size = text.size()
                text.draw(at: CGPoint(x: x, y: (height - size.height) / 2))
                x += size.width
            }

            put(cpuLabel)
            x += spacing
            drawCPUChart(context, in: CGRect(x: x, y: (height - chartSize.height) / 2,
                                             width: chartSize.width, height: chartSize.height),
                         background: track.withAlphaComponent(dark ? 0.12 : 0.08),
                         color: level(cpuPercent, warning: 50, critical: 80))
            x += chartSize.width + spacing
            put(cpuValue)
            x += itemGap

            put(memoryLabel)
            x += spacing
            let bar = CGRect(x: x, y: (height - barSize.height) / 2, width: barSize.width, height: barSize.height)
            let radius = barSize.height / 2
            context.fillRoundedRect(bar, radius: radius, color: track)
            context.fillRoundedRect(CGRect(x: bar.minX, y: bar.minY,
                                           width: max(barSize.height, barSize.width * CGFloat(memoryPercent / 100)),
                                           height: barSize.height),
                                    radius: radius, color: level(memoryPercent, warning: 70, critical: 85))
            x += barSize.width + spacing
            put(memoryValue)

            if let tempValue {
                x += itemGap
                put(tempValue)
            }
            if batteryIsLow {
                x += spacing
                if let icon = NSImage.symbol("exclamationmark.triangle.fill", pointSize: 12, color: red) {
                    icon.drawUpright(in: CGRect(x: x, y: (height - icon.size.height) / 2,
                                                width: icon.size.width, height: icon.size.height))
                }
            }
        }
    }

    /// CPU の使用率の直近の推移。縦軸は 0〜100%、色は今の使用率の色。
    private func drawCPUChart(_ context: CGContext, in box: CGRect, background: NSColor, color: NSColor) {
        context.fillRoundedRect(box, radius: 2, color: background)
        let history = Array(snapshot.cpu.hist.suffix(chartSamples))
        guard history.count > 1 else { return }
        let points = history.indices.map { i in
            CGPoint(x: box.maxX - box.width * CGFloat(history.count - 1 - i) / CGFloat(chartSamples - 1),
                    y: box.maxY - (box.height - 1) * CGFloat(min(history[i], 100) / 100) - 0.5)
        }
        context.drawFilledLine(through: points, bottom: box.maxY, color: color, fillAlpha: 0.35, lineWidth: 1.25)
    }

    /// 3 桁の幅にそろえた数。桁が少ないときは、数字 1 文字分の空白 (U+2007 figure space)
    /// で前を埋める。
    private func threeDigits(_ value: Double) -> String {
        String(format: "%3.0f", value).replacingOccurrences(of: " ", with: "\u{2007}")
    }
}
