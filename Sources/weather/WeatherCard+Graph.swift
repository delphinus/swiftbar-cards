import AppKit
#if canImport(Shared)
import Shared
#endif

// 2. 今後 24 時間の気温のグラフ。実線は今の観測値から予報をつなぎ、破線は同じ時刻の
// 前日の観測値 (= 過去 24 時間)。下に時刻・天気のアイコン・降水確率・風。
// Weathernews のウィジェットの気温のグラフにならった。
//
// `extension` で、WeatherCard の続きを別のファイルに書いている。

private let hour: Double = 3600

/// 気象庁のデータは日本時間なので、時刻の目盛りも日本時間で描く (Mac の
/// タイムゾーンが日本でなくても、観測の時刻とずれないように)
private let japanCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar
}()

/// グラフの範囲と、時刻・気温から座標への変換
private struct GraphScale {
    let plot: CGRect
    /// 横軸の左端と右端 (UNIX 時刻)
    let start: Double
    let end: Double
    /// 縦軸の下端と上端 (°C)
    let low: Double
    let high: Double

    func x(_ t: Double) -> CGFloat { plot.minX + CGFloat((t - start) / (end - start)) * plot.width }
    func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat((value - low) / (high - low)) * plot.height }
    func point(_ p: TimedValue) -> CGPoint { CGPoint(x: x(p.t), y: y(p.value)) }
}

extension WeatherCard {
    func drawGraph(in context: CGContext, top: CGFloat) {
        guard let graph = input.graph else { return }
        let pen = WeatherPen(context: context, colors: colors)
        pen.text(L("今後 24 時間", "Next 24 hours"), x: pad, y: top, size: 11, color: colors.secondary)

        // 線: 実線は今の観測値と、今より後の予報。破線は前日の観測値を 24 時間ずらしたもの
        var solid: [TimedValue] = []
        if let current = graph.current { solid.append((input.now, current)) }
        solid += graph.forecastPoints.filter { $0.t > input.now }
        let dotted = graph.pastPoints.map { (t: $0.t + 24 * hour, value: $0.value) }

        let plot = CGRect(x: 14, y: top + 26, width: width - 14 - 30, height: 78)
        let start = floor(input.now / hour) * hour
        let scale = makeScale(plot: plot, start: start, end: start + 24 * hour, lines: solid + dotted)

        drawGrid(pen, scale)
        drawLines(context, scale, solid: solid, dotted: dotted)
        drawMarks(pen, scale, solid: solid, hasCurrent: graph.current != nil)

        // 下に時刻・天気のアイコン・降水確率・風
        let hourY = plot.maxY + 8
        drawHours(pen, scale, y: hourY)
        let iconCY = hourY + 32
        // 天気のアイコン: 3 時間ごとの予報を、その時間帯の真ん中に置く
        for icon in graph.weatherIcons {
            let middle = icon.t + 1.5 * hour
            guard middle > scale.start, middle < scale.end else { continue }
            pen.symbol(icon.symbol, color: colors.color(icon.color), cx: scale.x(middle), cy: iconCY, size: 15)
        }
        // 降水確率: 6 時間ごとの値を、その時間帯 (アイコン 2 つ分) の真ん中に置く
        for chance in graph.precipitationChances {
            let middle = chance.t + 3 * hour
            guard middle > scale.start, middle < scale.end else { continue }
            pen.text("\(chance.percent)%", x: scale.x(middle), y: iconCY + 14, size: 10,
                     color: colors.color(chance.color), weight: .semibold, align: .center)
        }
        drawWinds(pen, scale, winds: graph.winds, y: iconCY + 32)
    }

    /// 風: 3 時間ごとの予報を、天気のアイコンの下に置く。風が吹いていく向きの矢印と、
    /// 風速 (気象庁の階級の範囲の真ん中)。単位は右の余白に 1 つだけ書く
    private func drawWinds(_ pen: WeatherPen, _ scale: GraphScale, winds: [WindForecast], y: CGFloat) {
        guard !winds.isEmpty else { return }
        let arrowSize: CGFloat = 8, spacing: CGFloat = 2
        var drewAny = false
        for wind in winds {
            let middle = wind.t + 1.5 * hour
            guard middle > scale.start, middle < scale.end else { continue }
            let color = wind.strong ? colors.primary : colors.secondary
            let weight: NSFont.Weight = wind.strong ? .semibold : .medium
            let speedWidth = ceil(textWidth(wind.speed, font: .card(size: 10, weight: weight)))
            let arrowWidth = wind.heading == nil ? 0 : arrowSize + spacing
            let left = scale.x(middle) - (arrowWidth + speedWidth) / 2
            if let heading = wind.heading {
                drawArrow(pen.context, heading: heading, center: CGPoint(x: left + arrowSize / 2, y: y + 7),
                          length: arrowSize, color: color)
            }
            pen.text(wind.speed, x: left + arrowWidth, y: y, size: 10, color: color, weight: weight)
            drewAny = true
        }
        if drewAny {
            pen.text("m/s", x: scale.plot.maxX + 4, y: y + 1, size: 9, color: colors.secondary)
        }
    }

    /// `heading` (北が 0 度で時計回り) を向いた矢印。描画先は y が下向き
    private func drawArrow(_ context: CGContext, heading: Double, center: CGPoint, length: CGFloat, color: NSColor) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        // y が下向きなので、正の角度で回すと画面では時計回りになる
        context.rotate(by: CGFloat(heading * .pi / 180))
        let half = length / 2
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(1.3)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [])
        context.move(to: CGPoint(x: 0, y: half))
        context.addLine(to: CGPoint(x: 0, y: -half + 2))
        context.strokePath()
        context.move(to: CGPoint(x: 0, y: -half))
        context.addLine(to: CGPoint(x: 3, y: -half + 3.5))
        context.addLine(to: CGPoint(x: -3, y: -half + 3.5))
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    /// 縦軸の範囲を決める。描く値すべてが入るよう、2°C 刻みに広げる。狭すぎると
    /// わずかな変化が大きく見えるので、6°C 以上にする。
    private func makeScale(plot: CGRect, start: Double, end: Double, lines: [TimedValue]) -> GraphScale {
        let visible = lines.filter { $0.t >= start - 3 * hour && $0.t <= end + 3 * hour }.map(\.value)
        var low = floor(((visible.min() ?? 0) - 0.5) / 2) * 2
        var high = ceil(((visible.max() ?? 10) + 0.5) / 2) * 2
        if high - low < 6 {
            low = floor(((high + low) / 2 - 3) / 2) * 2
            high = low + 6
        }
        return GraphScale(plot: plot, start: start, end: end, low: low, high: high)
    }

    /// 2°C ごとの目盛りの線と、上端・下端の値
    private func drawGrid(_ pen: WeatherPen, _ scale: GraphScale) {
        let plot = scale.plot
        for value in stride(from: scale.low, through: scale.high + 0.01, by: 2) {
            pen.horizontalLine(y: scale.y(value), from: plot.minX, to: plot.maxX, color: colors.grid)
        }
        pen.text(formatted(scale.high), x: plot.maxX + 4, y: scale.y(scale.high) - 7, size: 10, color: colors.secondary)
        pen.text(formatted(scale.low), x: plot.maxX + 4, y: scale.y(scale.low) - 7, size: 10, color: colors.secondary)
    }

    private func drawLines(_ context: CGContext, _ scale: GraphScale, solid: [TimedValue], dotted: [TimedValue]) {
        context.saveGState()
        // 横はグラフの範囲ちょうどで切る。予報は 3 時間ごとなので、右端 (24 時間後) を
        // 過ぎた次の点まで線を引き、範囲の境目で切り落とす。外側に余白を取ると、線が
        // 範囲の外まで伸びかけて途中で切れたように見える。
        let plot = scale.plot
        context.clip(to: CGRect(x: plot.minX, y: plot.minY - 20, width: plot.width, height: plot.height + 40))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if dotted.count > 1 {
            context.setStrokeColor(colors.secondary.cgColor)
            context.setLineWidth(2)
            // 長さがほぼ 0 の線分を、丸い端で点にして並べる
            context.setLineDash(phase: 0, lengths: [0.1, 4])
            context.addLines(between: dotted.map(scale.point))
            context.strokePath()
        }
        if solid.count > 1 {
            context.setStrokeColor(colors.primary.cgColor)
            context.setLineWidth(2.5)
            context.setLineDash(phase: 0, lengths: [])
            // 予報は 3 時間ごとにしか配られないので、点の間は滑らかな曲線で結ぶ
            context.addPath(monotoneCurve(through: solid.map(scale.point)))
            context.strokePath()
        }
        context.restoreGState()
    }

    /// 今の気温と、予報の最高気温に点と値を添える (最低気温は今の気温の近くに来やすく、値が重なる)
    private func drawMarks(_ pen: WeatherPen, _ scale: GraphScale, solid: [TimedValue], hasCurrent: Bool) {
        func mark(_ p: TimedValue) {
            let q = scale.point(p)
            pen.context.setFillColor(colors.primary.cgColor)
            pen.context.fillEllipse(in: CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7))
            pen.text(formatted(p.value.rounded()), x: min(max(q.x, scale.plot.minX + 8), scale.plot.maxX - 8), y: q.y - 19,
                     size: 11, weight: .semibold, align: .center)
        }

        let now = hasCurrent ? solid.first : nil
        if let now { mark(now) }

        // 予報の最高気温は、今より高いときだけ出す (この先は下がるだけなら、出しても
        // 意味が無い)。今の点のすぐ近くにあると値が重なるので、そのときも省く。
        let future = solid.filter { $0.t >= scale.start && $0.t <= scale.end }.dropFirst(now != nil ? 1 : 0)
        guard let highest = future.max(by: { $0.value < $1.value }) else { return }
        if let now {
            let isHigher = highest.value.rounded() > now.value.rounded()
            let isApart = abs(scale.x(highest.t) - scale.x(now.t)) >= 26 || abs(scale.y(highest.value) - scale.y(now.value)) >= 16
            guard isHigher && isApart else { return }
        }
        mark(highest)
    }

    /// 時刻: 3 時間ごとに数字、その間は点
    private func drawHours(_ pen: WeatherPen, _ scale: GraphScale, y: CGFloat) {
        for t in stride(from: scale.start, through: scale.end, by: hour) {
            let hourOfDay = japanCalendar.component(.hour, from: Date(timeIntervalSince1970: t))
            if hourOfDay % 3 == 0 {
                pen.text("\(hourOfDay)", x: scale.x(t), y: y, size: 10, color: colors.secondary, align: .center)
            } else {
                pen.context.setFillColor(colors.secondary.cgColor)
                pen.context.fillEllipse(in: CGRect(x: scale.x(t) - 1, y: y + 6, width: 2, height: 2))
            }
        }
    }
}
