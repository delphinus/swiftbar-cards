import AppKit
#if canImport(Shared)
import Shared
#endif

/// メニューバーの画像。
///
///     [cpu] [直近 3 分の折れ線グラフ]  [memorychip] [横棒]  [電池] 1:25  48°C
///
/// 数字を減らして静かに見せるため、CPU とメモリは使用率の数字を出さず、グラフと棒
/// (と、その色) だけで表す。見出しも文字でなく SF Symbols のアイコンにしている。
/// 電池は本体のバッテリーがあるとき (MacBook) だけ出す。残量は電池の塗りで表し、
/// 数字では残り時間 (電池で動いているとき) か満充電までの時間 (充電中) を出す。
/// 時間が分からないとき (計算中・充電済み) は電池だけを出す。Bluetooth 機器の残量は
/// メニューのカードにだけ出し、20% を切ったときだけ警告のアイコンを足す。
///
/// 明るいメニューバー用と暗いメニューバー用の 2 枚を描く (SwiftBar.menuBarImageLine)。
/// 数字は等幅の数字で描くので、値が変わっても項目の幅が変わらない。
struct SystemMenuBar {
    let snapshot: Snapshot

    private let height: CGFloat = 22
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private let chartSize = CGSize(width: 40, height: 14)
    private let barSize = CGSize(width: 26, height: 6)
    /// 見出しとグラフ・値の間
    private let spacing: CGFloat = 4
    /// 見出しのアイコンの大きさ
    private let iconPointSize: CGFloat = 13
    /// 電池の本体 (出っ張りを除く)
    private let batterySize = CGSize(width: 22, height: 11)
    /// 電池の出っ張りの幅
    private let batteryNubWidth: CGFloat = 1.5
    /// CPU・メモリ・電池・温度の項目の間
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
        // アイコンが無い OS では文字に戻す
        let cpuIcon = NSImage.symbol("cpu", pointSize: iconPointSize, color: primary)
        let memoryIcon = NSImage.symbol("memorychip", pointSize: iconPointSize, color: primary)
        let cpuLabel = label("CPU", primary)
        let memoryLabel = label("MEM", primary)
        let cpuHeadWidth = cpuIcon?.size.width ?? cpuLabel.size().width
        let memoryHeadWidth = memoryIcon?.size.width ?? memoryLabel.size().width
        let tempValue = snapshot.cpu.temp.map { label(String(format: "%.0f°C", $0), level($0, warning: 70, critical: 85)) }
        let internalBattery = snapshot.battery.first { $0.isInternal }
        let batteryTime = internalBattery?.minutes.map {
            label(String(format: "%d:%02d", $0 / 60, $0 % 60), primary)
        }
        let bluetoothIsLow = snapshot.battery.contains { !$0.isInternal && $0.percent < 20 }

        var width = cpuHeadWidth + spacing + chartSize.width + itemGap
            + memoryHeadWidth + spacing + barSize.width
        if internalBattery != nil {
            width += itemGap + batterySize.width + batteryNubWidth
            if let batteryTime { width += spacing + batteryTime.size().width }
        }
        if let tempValue { width += itemGap + tempValue.size().width }
        if bluetoothIsLow { width += spacing + 16 }
        width = ceil(width) + 1

        return PNGImage.draw(width: width, height: height) { context in
            // 左から順に置いていく。x は次に置く位置
            var x: CGFloat = 0
            func put(_ text: NSAttributedString) {
                let size = text.size()
                text.draw(at: CGPoint(x: x, y: (height - size.height) / 2))
                x += size.width
            }
            func put(_ icon: NSImage?, or text: NSAttributedString) {
                guard let icon else { return put(text) }
                icon.drawUpright(in: CGRect(x: x, y: (height - icon.size.height) / 2,
                                            width: icon.size.width, height: icon.size.height))
                x += icon.size.width
            }

            put(cpuIcon, or: cpuLabel)
            x += spacing
            drawCPUChart(context, in: CGRect(x: x, y: (height - chartSize.height) / 2,
                                             width: chartSize.width, height: chartSize.height),
                         background: track.withAlphaComponent(dark ? 0.12 : 0.08),
                         color: level(cpuPercent, warning: 50, critical: 80))
            x += chartSize.width + itemGap

            put(memoryIcon, or: memoryLabel)
            x += spacing
            let bar = CGRect(x: x, y: (height - barSize.height) / 2, width: barSize.width, height: barSize.height)
            let radius = barSize.height / 2
            context.fillRoundedRect(bar, radius: radius, color: track)
            context.fillRoundedRect(CGRect(x: bar.minX, y: bar.minY,
                                           width: max(barSize.height, barSize.width * CGFloat(memoryPercent / 100)),
                                           height: barSize.height),
                                    radius: radius, color: level(memoryPercent, warning: 70, critical: 85))
            x += barSize.width

            if let internalBattery {
                x += itemGap
                drawBattery(context, internalBattery, at: x, outline: primary,
                            fill: internalBattery.percent < 20 ? red : internalBattery.percent < 40 ? yellow : green)
                x += batterySize.width + batteryNubWidth
                if let batteryTime {
                    x += spacing
                    put(batteryTime)
                }
            }
            if let tempValue {
                x += itemGap
                put(tempValue)
            }
            if bluetoothIsLow {
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

    /// 電池の形。枠の中を残量の割合だけ塗る。macOS の標準の表示に合わせて、充電中は
    /// 稲妻を、電源につながっているが充電していないとき (充電済み、バッテリー充電の
    /// 最適化や充電上限で止めているとき) はプラグを重ねる。
    private func drawBattery(_ context: CGContext, _ battery: Battery, at x: CGFloat, outline: NSColor, fill: NSColor) {
        let body = CGRect(x: x, y: (height - batterySize.height) / 2,
                          width: batterySize.width, height: batterySize.height)
        context.setStrokeColor(outline.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.strokePath()
        context.fillRoundedRect(CGRect(x: body.maxX, y: body.midY - 2, width: batteryNubWidth, height: 4),
                                radius: 0.75, color: outline.withAlphaComponent(0.5))

        let inner = body.insetBy(dx: 2, dy: 2)
        let level = CGFloat(min(max(battery.percent, 0), 100) / 100)
        if level > 0 {
            context.fillRoundedRect(CGRect(x: inner.minX, y: inner.minY,
                                           width: max(1.5, inner.width * level), height: inner.height),
                                    radius: 1.5, color: fill)
        }
        guard battery.external == true else { return }
        let mark = battery.charging == true ? "bolt.fill" : "powerplug.fill"
        if let icon = NSImage.symbol(mark, pointSize: 9, color: outline) {
            icon.drawUpright(centeredAt: CGPoint(x: body.midX, y: body.midY))
        }
    }
}
