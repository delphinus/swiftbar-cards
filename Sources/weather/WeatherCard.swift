import AppKit
#if canImport(Shared)
import Shared
#endif

/// 天気のカード。上から次の 4 つの節を積む (無い節は飛ばす)。
/// 1. 今の観測値 (アメダス): 気温を大きく、湿度・降水量・風を横に
/// 2. 今後 24 時間の気温のグラフ (WeatherCard+Graph.swift)。下に天気・降水確率・風
/// 3. 3 日分の予報の文
/// 4. 週間予報: 7 日を横に並べる。見出しの右に平年の最高・最低気温
struct WeatherCard {
    let input: CardInput
    let colors: CardColors

    init(input: CardInput) {
        self.input = input
        self.colors = CardColors(dark: input.dark)
    }

    // 大きさ (pt)。PNG はこの 2 倍の画素で描く。
    let width: CGFloat = 340
    /// 左右の余白
    let pad: CGFloat = 2
    /// 節の間 (区切り線を含む)
    let gap: CGFloat = 13
    /// 節の見出しの高さ
    let headerHeight: CGFloat = 20

    /// 描いた画像と、下を空ける前の本来の高さ
    func render() -> (image: PNGImage, naturalHeight: CGFloat) {
        var sections: [CardSection] = []
        if input.obs != nil {
            sections.append(CardSection(height: 52, draw: drawObservation(in:top:)))
        }
        if let graph = input.graph {
            sections.append(CardSection(height: graph.winds.isEmpty ? 178 : 194, draw: drawGraph(in:top:)))
        }
        if !input.days.isEmpty {
            sections.append(CardSection(height: headerHeight + dayRowHeights.reduce(0, +), draw: drawDays(in:top:)))
        }
        if !input.week.isEmpty {
            sections.append(CardSection(height: headerHeight + 98, draw: drawWeek(in:top:)))
        }

        let naturalHeight = sections.totalHeight(gap: gap)
        let height = max(naturalHeight, CGFloat(input.minHeight))
        let image = PNGImage.drawCard(width: width, height: height, dark: input.dark) { context in
            sections.drawStacked(in: context, gap: gap) { y in
                WeatherPen(context: context, colors: colors).horizontalLine(y: y, from: pad, to: width - pad, color: colors.rule)
            }
        }
        return (image, naturalHeight)
    }

    // MARK: - 1. 今の観測値

    private func drawObservation(in context: CGContext, top: CGFloat) {
        guard let obs = input.obs else { return }
        let pen = WeatherPen(context: context, colors: colors)

        // 左: 気温を大きく、その下に観測点と時刻
        let tempColor = colors.color(obs.tempColor)
        let big = pen.text(obs.temp.map { formatted($0, digits: 1) } ?? "-", x: pad, y: top - 2, size: 32,
                           color: tempColor, weight: .light)
        pen.text("°C", x: pad + big.width + 1, y: top + 4, size: 16, color: tempColor, weight: .light)
        pen.text(L("\(obs.point)  \(obs.time) の観測", "\(obs.point), observed at \(obs.time)"),
                 x: pad, y: top + 36, size: 11, color: colors.secondary)

        // 右: 湿度・降水量・風を 1 行ずつ
        let labels = (humidity: L("湿度", "Humidity"), precip: L("降水量", "Precip."), wind: L("風", "Wind"))
        // 値の書き出し位置は、いちばん長いラベルの後ろにそろえる (言語でラベルの長さが変わる)
        let labelWidth = [labels.humidity, labels.precip, labels.wind]
            .map { textWidth($0, font: NSFont.card(size: 12)) }.max() ?? 0
        let labelX: CGFloat = 176
        let valueX = labelX + max(48, ceil(labelWidth) + 12)
        var y = top + 2
        func row(_ label: String, _ value: String, color: NSColor? = nil) {
            pen.text(label, x: labelX, y: y, size: 12, color: colors.secondary)
            pen.text(value, x: valueX, y: y, size: 12, color: color, weight: .medium)
            y += 16
        }
        if let humidity = obs.humidity {
            row(labels.humidity, "\(formatted(humidity))%")
        }
        if let precip = obs.precip {
            row(labels.precip, "\(formatted(precip, digits: 1)) mm/h", color: precip > 0 ? colors.blue : nil)
        }
        if let wind = obs.wind {
            row(labels.wind, "\(obs.windDir ?? "") \(formatted(wind, digits: 1)) m/s")
        }
    }

    // MARK: - 3. 3 日分の予報の文

    /// 予報の文を描き始める x と、その幅
    private var dayTextX: CGFloat { pad + 104 }
    private var dayTextWidth: CGFloat { width - pad - dayTextX }

    /// 行の高さ。予報の文は、幅に収まらなければ折り返し、その行だけ高くする
    private var dayRowHeights: [CGFloat] {
        input.days.map { day in
            let textHeight = WeatherPen.wrappedTextHeight(Typesetting.forecastPhrases(day.text), width: dayTextWidth, size: 13)
            return max(21, ceil(textHeight) + 5)
        }
    }

    private func drawDays(in context: CGContext, top: CGFloat) {
        let pen = WeatherPen(context: context, colors: colors)
        pen.text(input.daysTitle, x: pad, y: top, size: 11, color: colors.secondary)
        var y = top + headerHeight
        for (day, rowHeight) in zip(input.days, dayRowHeights) {
            pen.symbol(day.icon, color: colors.color(day.color), cx: pad + 9, cy: y + 8, size: 14)
            // 週間予報と同じく、曜日だけを土曜は青、日曜と祝日は赤にする。
            // 日付は縦に並ぶので、等幅の数字で桁をそろえる
            let weekday = weekdayName(day.dow)
            let pieces = isJapanese
                ? [(day.date, colors.secondary), ("（\(weekday)）", colors.weekday(day.dow, holiday: day.holiday))]
                : [(weekday, colors.weekday(day.dow, holiday: day.holiday)), (" \(day.date)", colors.secondary)]
            pen.text(pieces, x: pad + 26, y: y, size: 13, digits: .tabular)
            pen.wrappedText(Typesetting.forecastPhrases(day.text), x: dayTextX, y: y, width: dayTextWidth, size: 13)
            y += rowHeight
        }
    }

    // MARK: - 4. 週間予報

    private func drawWeek(in context: CGContext, top: CGFloat) {
        let pen = WeatherPen(context: context, colors: colors)
        pen.text(input.weekTitle, x: pad, y: top, size: 11, color: colors.secondary)
        drawWeekNormal(pen, top: top)
        let columnWidth = (width - pad * 2) / CGFloat(input.week.count)
        let y = top + headerHeight
        for (i, day) in input.week.enumerated() {
            let cx = pad + columnWidth * (CGFloat(i) + 0.5)
            let weekday = weekdayName(day.dow)
            pen.text(day.date, x: cx, y: y, size: 11, color: colors.secondary, align: .center)
            pen.text(L("（\(weekday)）", weekday), x: cx, y: y + 13, size: 10, color: colors.weekday(day.dow, holiday: day.holiday),
                     align: .center)
            pen.symbol(day.icon, color: colors.color(day.color), cx: cx, cy: y + 41, size: 17)
            pen.text(day.max.isEmpty ? "-" : "\(day.max)°", x: cx, y: y + 56, size: 13,
                     color: colors.color(day.maxColor), weight: .semibold, align: .center)
            // 色が無い (13〜24°C) ときは、最高気温と同じく標準の文字色にする
            pen.text(day.min.isEmpty ? "-" : "\(day.min)°", x: cx, y: y + 71, size: 13,
                     color: colors.color(day.minColor), align: .center)
            pen.text(day.pop.isEmpty ? "-" : "\(day.pop)%", x: cx, y: y + 86, size: 11,
                     color: day.popColor == nil ? colors.secondary : colors.color(day.popColor),
                     weight: .semibold, align: .center)
        }
    }

    /// 見出しの右端に、週間予報の期間の平年の最高気温と最低気温を出す。週間予報の
    /// 期間で 1 組だけ配られる値なので、日ごとの列には入れない
    private func drawWeekNormal(_ pen: WeatherPen, top: CGFloat) {
        guard let normal = input.weekNormal else { return }
        let pieces: [(String, NSColor)] = [
            (L("平年  最高 ", "Normal  high "), colors.secondary), ("\(normal.max)°", colors.color(normal.maxColor)),
            (L("  最低 ", "  low "), colors.secondary), ("\(normal.min)°", colors.color(normal.minColor)),
        ]
        let font = NSFont.card(size: 11)
        let width = pieces.map { textWidth($0.0, font: font) }.reduce(0, +)
        pen.text(pieces, x: self.width - pad - ceil(width), y: top, size: 11)
    }
}
