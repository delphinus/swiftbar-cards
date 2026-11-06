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
/// 見出しのアイコンは白か黒で、電池の枠・数字は使用率や残量の色で描く。
/// SwiftBar は明るい用と暗い用の 2 枚 (SwiftBar.menuBarImageLine) から、メインの
/// モニタのメニューバーに合うほうを選び、その 1 枚をほかのモニタにも出す。モニタごとに
/// 壁紙が違うと、明るいメニューバーに暗い用の画像が載る (白いアイコンが消えて見えた)。
/// 見出しのアイコン以外は、どちらの 1 枚もどちらの地で読めるよう、色は中くらいの
/// 明るさの鮮やかな色にし、2 枚の違いは明るさを少し寄せるだけにする。地の灰色も、
/// 白や黒でなく中間の灰色にする。
/// 数字は等幅の数字で描くので、値が変わっても項目の幅が変わらない。
struct SystemMenuBar {
    let snapshot: Snapshot

    private let height: CGFloat = 22
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private let chartSize = CGSize(width: 40, height: 14)
    private let barSize = CGSize(width: 26, height: 6)
    /// 見出しとグラフ・値の間
    private let spacing: CGFloat = 4
    /// 文字を真ん中から持ち上げる量。画像の真ん中に置くと、メニューバーのほかの文字
    /// (天気や時計) より 1pt 下に見えた (メニューバーを撮った画像で数字の上下端を測った)。
    /// アイコンは真ん中のままで、ほかのアプリのアイコンと高さがそろっている。
    private let textRaise: CGFloat = 1
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
        // 黄色は明るい地で見えなくなるので、注意の色は橙にする
        let green = NSColor(rgb: dark ? 0x34C759 : 0x28A745)
        let yellow = NSColor(rgb: dark ? 0xFF9500 : 0xE08000)
        let red = NSColor(rgb: dark ? 0xFF3B30 : 0xE0352B)
        let track = NSColor(white: 0.55, alpha: 0.4)
        // CPU とメモリの見出しのアイコンは、グラフや棒と見分けられるよう白か黒で描く。
        // ほかのモニタのメニューバーの明るさが違うと、そこではアイコンだけ見えなくなる
        // (グラフや棒は色付きなので残る)。それでも、青や灰色より白黒のほうがメニュー
        // バーのほかの項目となじむので、こちらを選んだ。
        let heading = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
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
        let cpuColor = level(cpuPercent, warning: 50, critical: 80)
        let memoryColor = level(memoryPercent, warning: 70, critical: 85)
        let cpuIcon = NSImage.symbol("cpu", pointSize: iconPointSize, color: heading)
        let memoryIcon = NSImage.symbol("memorychip", pointSize: iconPointSize, color: heading)
        let cpuLabel = label("CPU", heading)
        let memoryLabel = label("MEM", heading)
        let cpuHeadWidth = cpuIcon?.size.width ?? cpuLabel.size().width
        let memoryHeadWidth = memoryIcon?.size.width ?? memoryLabel.size().width
        let tempValue = snapshot.cpu.temp.map { label(String(format: "%.0f°C", $0), level($0, warning: 70, critical: 85)) }
        let internalBattery = snapshot.battery.first { $0.isInternal }
        let batteryColor = internalBattery.map { $0.percent < 20 ? red : $0.percent < 40 ? yellow : green } ?? green
        let batteryTime = internalBattery?.minutes.map {
            label(String(format: "%d:%02d", $0 / 60, $0 % 60), batteryColor)
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
                text.draw(at: CGPoint(x: x, y: (height - size.height) / 2 - textRaise))
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
                         background: track.withAlphaComponent(0.2), color: cpuColor)
            x += chartSize.width + itemGap

            put(memoryIcon, or: memoryLabel)
            x += spacing
            let bar = CGRect(x: x, y: (height - barSize.height) / 2, width: barSize.width, height: barSize.height)
            let radius = barSize.height / 2
            context.fillRoundedRect(bar, radius: radius, color: track)
            context.fillRoundedRect(CGRect(x: bar.minX, y: bar.minY,
                                           width: max(barSize.height, barSize.width * CGFloat(memoryPercent / 100)),
                                           height: barSize.height),
                                    radius: radius, color: memoryColor)
            x += barSize.width

            if let internalBattery {
                x += itemGap
                drawBattery(context, internalBattery, at: x, color: batteryColor)
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
        context.drawFilledLine(through: points, bottom: box.maxY, color: color, fillAlpha: 0.45, lineWidth: 1.5)
    }

    /// 電池の形。枠の中を残量の割合だけ塗る。macOS の標準の表示に合わせて、充電中は
    /// 稲妻を、電源につながっているが充電していないとき (充電済み、バッテリー充電の
    /// 最適化や充電上限で止めているとき) はプラグを重ねる。枠も塗りも残量の色で描く。
    private func drawBattery(_ context: CGContext, _ battery: Battery, at x: CGFloat, color: NSColor) {
        let body = CGRect(x: x, y: (height - batterySize.height) / 2,
                          width: batterySize.width, height: batterySize.height)
        context.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.strokePath()
        context.fillRoundedRect(CGRect(x: body.maxX, y: body.midY - 2, width: batteryNubWidth, height: 4),
                                radius: 0.75, color: color.withAlphaComponent(0.7))

        let inner = body.insetBy(dx: 2, dy: 2)
        let level = CGFloat(min(max(battery.percent, 0), 100) / 100)
        if level > 0 {
            context.fillRoundedRect(CGRect(x: inner.minX, y: inner.minY,
                                           width: max(1.5, inner.width * level), height: inner.height),
                                    radius: 1.5, color: color)
        }
        guard battery.external == true else { return }
        // 印も同じ色なので、塗りの上でも見えるよう、周りを 1pt くり抜いてから描く
        // (くり抜いたところはメニューバーの地が透ける)
        let mark = battery.charging == true ? "bolt.fill" : "powerplug.fill"
        guard let icon = NSImage.symbol(mark, pointSize: 9, color: color) else { return }
        let center = CGPoint(x: body.midX, y: body.midY)
        for dx in [-1, 0, 1] as [CGFloat] {
            for dy in [-1, 0, 1] as [CGFloat] where dx != 0 || dy != 0 {
                icon.draw(in: CGRect(x: center.x + dx - icon.size.width / 2, y: center.y + dy - icon.size.height / 2,
                                     width: icon.size.width, height: icon.size.height),
                          from: .zero, operation: .destinationOut, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        icon.drawUpright(centeredAt: center)
    }
}
