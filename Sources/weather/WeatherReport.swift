import Foundation
#if canImport(Shared)
import Shared
#endif

/// 取得した気象庁のデータから、1 つの地点のメニューバーの行とカードに描く値を組み立てる。
///
/// カードに使うデータ:
/// - 今の観測値: アメダスの全観測点の最新値
/// - 気温のグラフ: 地域時系列予報 (3 時間ごとの気温と天気) と、アメダスの観測点の
///   時系列 (3 時間ごとのファイルに 10 分ごとの値)
/// - 3 日分の予報の文・週間予報・降水確率: 府県予報
struct WeatherReport {
    let station: Place.Station
    /// 府県予報。1 つめが短期予報、2 つめ (無いこともある) が週間予報
    let forecast: [ForecastReport]
    let timeSeries: TimeSeriesForecast?
    /// 全観測点の最新値 (観測点の番号 → 値) と、その時刻 ("2026-11-04T20:30:00+09:00")
    let latest: [String: AmedasObservation]
    let latestTime: String
    /// 観測点の時系列 (時刻 "20261104210000" → 値)
    let series: [String: AmedasObservation]
    /// 天気コード → 英語名 (data/jma-telops.json)
    let telops: [String: Telop]
    /// 観測点の番号 → 観測点 (週間予報の気温の地点の英語名を引く)
    let stations: [String: AmedasStation]
    /// 祝日・休日 (曜日を日曜と同じ赤にする)
    let holidays: Holidays
    /// 取得に失敗して、前に取れたデータを出しているか
    let stale: Bool
    let now: Double
    let dark: Bool
    let minHeight: Double

    // MARK: - 予報の時系列

    private var short: ForecastReport { forecast[0] }
    /// 3 日分の天気 (一次細分区域ごと)
    private var weatherSeries: ForecastReport.TimeSeries? { short.timeSeries.first }
    private var weatherArea: ForecastReport.AreaValues? { weatherSeries?.area(station.class10) }
    /// 6 時間ごとの降水確率 (一次細分区域ごと)
    private var popSeries: ForecastReport.TimeSeries? { short.timeSeries.count > 1 ? short.timeSeries[1] : nil }
    private var popArea: ForecastReport.AreaValues? { popSeries?.area(station.class10) }
    /// 今日・明日の最低気温と最高気温 (予報の気温の地点ごと)
    private var temperatureSeries: ForecastReport.TimeSeries? { short.timeSeries.count > 2 ? short.timeSeries[2] : nil }
    private var temperatureArea: ForecastReport.AreaValues? { temperatureSeries?.area(station.temperaturePoint) }

    private var currentTemperature: Double? { latest[station.code]?.temperature }

    // MARK: - メニューバーの行

    /// メニューバーの行: 今日の天気のアイコン、現在の気温、いまの時間帯の降水確率。
    ///
    /// アイコンは :name: の形で文中に書く (SwiftBar の symbolize)。sfimage と違って
    /// 1 行に複数置けて、どれも同じ大きさで描かれる。sfcolor と sfcolor2 が 1 個目と
    /// 2 個目のアイコンの色になる。
    var menuBarLine: String { summary(colors: \.menuBar) }

    /// 地点の切り替えの項目に添える行。中身はメニューバーの行と同じ。項目はメニュー
    /// (背後の壁紙を透かす) の上に描かれるので、色はメニューバー用ではなく、明るい
    /// 外観ではカードと同じ濃い色を使う (メニューバー用の色では読みにくかった)。
    var menuItemSummary: String { summary(colors: \.menuItem) }

    private func summary(colors: KeyPath<ColorSet, String>) -> String {
        let icon = weatherIcon(weatherArea?.weatherCodes?.first ?? "")
        let pop = currentPrecipitationChance
        var text = ":\(icon): " + (currentTemperature.map { "\(Int($0.rounded()))°" } ?? "")
        var parameters = " | sfcolor=\(WeatherStyle.colors(forIcon: icon)[keyPath: colors])"
        var iconCount = 1
        if !pop.isEmpty {
            text += " :umbrella.fill: \(pop)%"
            iconCount += 1
            parameters += " sfcolor\(iconCount)=\(WeatherStyle.colors(forPrecipitationChance: pop)[keyPath: colors])"
        }
        if stale {
            text += " :exclamationmark.triangle:"
            iconCount += 1
            parameters += " sfcolor\(iconCount)=\(WeatherStyle.staleColors)"
        }
        return text + parameters
    }

    /// いまの時間帯の降水確率。今より前に始まった時間帯のうち最後のもの (無ければ最初のもの)
    private var currentPrecipitationChance: String {
        guard let series = popSeries, let pops = popArea?.pops else { return "" }
        let started = series.timeDefines.indices.filter { i in
            i == 0 || (JapanTime.epoch(series.timeDefines[i]) ?? .infinity) <= now
        }
        guard let index = started.last, pops.indices.contains(index) else { return "" }
        return pops[index]
    }

    // MARK: - カード

    var card: CardInput {
        CardInput(dark: dark, now: now, obs: observation, graph: graph, daysTitle: daysTitle,
                  days: days, weekTitle: weekTitle, week: week, minHeight: minHeight)
    }

    private var observation: Observation? {
        guard let temperature = currentTemperature, let values = latest[station.code] else { return nil }
        return Observation(
            point: station.localizedName,
            time: latestTime.slice(11, 16),
            temp: temperature,
            tempColor: WeatherStyle.color(forTemperature: temperature, dark: dark),
            humidity: values.humidity?.first ?? nil,
            precip: values.precipitation1h?.first ?? nil,
            wind: values.wind?.first ?? nil,
            windDir: (values.windDirection?.first ?? nil).flatMap { WeatherStyle.windDirection(Int($0)) })
    }

    /// 気温のグラフ。地域時系列予報が無ければ描かない (観測点の時系列が無ければ破線を省く)
    private var graph: TemperatureGraph? {
        guard let point = temperaturePointSeries, let area = areaWeatherSeries else { return nil }

        // 観測点の時系列は 10 分ごとの値なので、正時の値だけを使う
        let past = series.compactMap { key, values -> TimedValue? in
            guard key.hasSuffix("0000"), let t = JapanTime.epoch(compact: key), let temperature = values.temperature
            else { return nil }
            return (t, temperature)
        }.sorted { $0.t < $1.t }
        // 今の値は、上の観測値と同じ全観測点の最新値を使う。時系列の正時の値は最大で
        // 59 分古く、時系列のファイルが取れなかったときはさらに古くなる
        let current = currentTemperature ?? past.last?.value

        let pointTimes = point.timeDefines ?? topLevelPointTimes
        let forecastPoints = (point.temperature ?? []).enumerated().compactMap { i, temperature -> TimedValue? in
            guard let value = temperature.value, i < pointTimes.count,
                  let t = JapanTime.epoch(pointTimes[i].dateTime) else { return nil }
            return (t, value)
        }

        let weatherIcons = zip(area.timeDefines, area.weather).compactMap { time, weather -> (t: Double, symbol: String, color: String)? in
            guard let t = JapanTime.epoch(time.dateTime) else { return nil }
            let icon = WeatherStyle.icon(forText: weather)
            return (t, icon, WeatherStyle.colors(forIcon: icon).card(dark: dark))
        }

        // 降水確率は府県予報の 6 時間ごとの値 (一次細分区域ごと)
        var chances: [(t: Double, percent: String, color: String)] = []
        if let series = popSeries, let pops = popArea?.pops {
            for (time, pop) in zip(series.timeDefines, pops) where !pop.isEmpty {
                guard let t = JapanTime.epoch(time) else { continue }
                chances.append((t, pop, WeatherStyle.colors(forPrecipitationChance: pop).card(dark: dark)))
            }
        }

        return TemperatureGraph(current: current,
                                pastPoints: past.filter { $0.t >= now - 25 * 3600 },
                                forecastPoints: forecastPoints,
                                weatherIcons: weatherIcons,
                                precipitationChances: chances)
    }

    /// 予報の気温の地点の時系列。地点が複数あれば、予報の気温の地点の名前で選ぶ
    private var temperaturePointSeries: TimeSeriesForecast.PointSeries? {
        switch timeSeries?.pointTimeSeries {
        case .one(let point): point
        case .many(let points): points.first { $0.pointNameJP == station.temperaturePointName } ?? points.first
        case nil: nil
        }
    }

    /// 地点の時系列に時刻が無いときに使う、全体の時刻
    private var topLevelPointTimes: [TimeSeriesForecast.TimeDefine] {
        if case .one(let point) = timeSeries?.pointTimeSeries { return point.timeDefines ?? [] }
        return []
    }

    private var areaWeatherSeries: TimeSeriesForecast.AreaSeries? {
        switch timeSeries?.areaTimeSeries {
        case .one(let area): area
        case .many(let areas): areas.first
        case nil: nil
        }
    }

    // MARK: 3 日分の予報

    private var daysTitle: String {
        let issued = short.reportDatetime.slice(11, 16)
        let areaName = weatherArea?.area.name ?? ""
        if isJapanese { return "\(areaName)の予報（\(issued) 発表）" }
        let englishName = station.class10EnName.isEmpty && station.officeEnName.isEmpty
            ? areaName : "\(station.class10EnName), \(station.officeEnName)"
        return "Forecast for \(englishName) (issued \(issued))"
    }

    /// 予報は 5・11・17 時に発表されるので、日付が変わってから次の発表までは先頭が
    /// 昨日の分になる。今日より前の日は出さない。
    private var days: [DayForecast] {
        guard let series = weatherSeries, let area = weatherArea else { return [] }
        let today = JapanTime.string(now, "yyyy-MM-dd")
        return series.timeDefines.enumerated().compactMap { i, time in
            guard time.slice(0, 10) >= today else { return nil }
            let code = area.weatherCodes?[safe: i] ?? ""
            let icon = weatherIcon(code)
            // 「今日」「明日」は日付をまたぐと指す日が変わって分かりにくいので、日付で出す
            let (date, weekday) = JapanTime.monthDay(time)
            // 全角の空白 (語の区切り) は残し、カードの側で折り返しの位置に使う
            return DayForecast(date: date, dow: weekday, holiday: holidays.contains(time.slice(0, 10)), text: forecastText(area.weathers?[safe: i] ?? "", code: code),
                               icon: icon, color: WeatherStyle.colors(forIcon: icon).card(dark: dark))
        }
    }

    /// 天気コードのアイコン
    private func weatherIcon(_ code: String) -> String {
        WeatherStyle.icon(forCode: code, telop: telops[code])
    }

    /// 予報の文。英語のときは、日本語でしか配られない文の代わりに天気コードの英語名を使う
    private func forecastText(_ text: String, code: String) -> String {
        isJapanese ? text : (telops[code]?.en ?? text)
    }

    // MARK: 週間予報

    /// 週間予報の気温の地点と、それが観測点の予報の気温の地点か。週間予報の気温の地点は
    /// 府県に 1 つだけのことがある (山口県なら下関だけ、神奈川県なら横浜だけ)。予報の
    /// 気温の地点が無ければ先頭の地点を使う。
    private var weekTemperature: (area: ForecastReport.AreaValues, isOwnPoint: Bool)? {
        guard forecast.count > 1, forecast[1].timeSeries.count > 1 else { return nil }
        let areas = forecast[1].timeSeries[1].areas
        if let own = areas.first(where: { $0.area.code == station.temperaturePoint }) { return (own, true) }
        return areas.first.map { ($0, false) }
    }

    /// 週間予報の節の見出し。気温が別の地点の予報なら、「週間予報（下関）」のように
    /// その地点の名前を添える (山口の観測値の下に下関の気温が出ると、内陸と海沿いで
    /// 朝の気温が 7°C 違うことがあった)。
    private var weekTitle: String {
        guard let weekTemperature, !weekTemperature.isOwnPoint else { return L("週間予報", "Weekly forecast") }
        let area = weekTemperature.area.area
        let enName = stations[area.code]?.enName ?? area.name
        return L("週間予報（\(area.name)）", "Weekly forecast (\(enName))")
    }

    /// 週間予報。初日は気温と降水確率が空欄で配られる (短期予報で発表されるため)。
    /// 初日は、5 時の発表までは前の日の 17 時に出た週間予報の初日 (今日)、11 時の
    /// 発表からは明日。空欄なら短期予報の値で埋める。
    ///
    /// 週間予報の気温が別の地点の予報なら、短期予報 (観測点の予報の気温の地点の値) が
    /// ある日はそちらを使う。グラフの気温と食い違わないようにするため。
    private var week: [WeekForecast] {
        guard forecast.count > 1 else { return [] }
        let weekly = forecast[1]
        guard let weatherSeries = weekly.timeSeries.first else { return [] }
        // 週間予報の天気は、一次細分区域ごとのことも府県でまとめてのこともある
        let weatherArea = weatherSeries.area(station.class10) ?? weatherSeries.area(station.office) ?? weatherSeries.areas.first
        let temperatureArea = weekTemperature?.area
        let prefersShortRange = weekTemperature?.isOwnPoint == false

        return weatherSeries.timeDefines.enumerated().map { i, time in
            let date = time.slice(0, 10)
            func temperature(_ weeklyValue: String?, minimum: Bool) -> String {
                let weeklyValue = weeklyValue ?? ""
                return prefersShortRange
                    ? filled(shortRangeTemperature(on: date, minimum: minimum)) { weeklyValue }
                    : filled(weeklyValue) { shortRangeTemperature(on: date, minimum: minimum) }
            }
            let max = temperature(temperatureArea?.tempsMax?[safe: i], minimum: false)
            let min = temperature(temperatureArea?.tempsMin?[safe: i], minimum: true)
            let pop = filled(weatherArea?.pops?[safe: i] ?? "") { highestPrecipitationChance(on: date) }
            let icon = weatherIcon(weatherArea?.weatherCodes?[safe: i] ?? "")
            let (label, weekday) = JapanTime.monthDay(time)
            return WeekForecast(
                date: label, dow: weekday, holiday: holidays.contains(date), icon: icon, color: WeatherStyle.colors(forIcon: icon).card(dark: dark),
                max: max, maxColor: WeatherStyle.color(forTemperature: max, dark: dark),
                min: min, minColor: WeatherStyle.color(forTemperature: min, dark: dark),
                pop: pop, popColor: pop.isEmpty ? nil : WeatherStyle.colors(forPrecipitationChance: pop).card(dark: dark))
        }
    }

    /// 空欄なら `fallback` で埋める
    private func filled(_ value: String, _ fallback: () -> String) -> String {
        value.isEmpty ? fallback() : value
    }

    /// 短期予報の、その日の最低気温 (0 時の値) か最高気温 (9 時の値)。
    ///
    /// ただし短期予報は発表した日の最低気温を予報せず、その日の 0 時の欄にも最高気温を
    /// 入れて配る (11/6 11 時の発表の東京なら、11/6 の 9 時と 0 時がどちらも 25)。
    /// 発表した日の最低気温は埋めずに空欄のままにする。
    private func shortRangeTemperature(on date: String, minimum: Bool) -> String {
        guard let series = temperatureSeries, let temps = temperatureArea?.temps else { return "" }
        if minimum && date == short.reportDatetime.slice(0, 10) { return "" }
        let index = series.timeDefines.indices.first { i in
            let time = series.timeDefines[i]
            return time.slice(0, 10) == date && (time.slice(11, 13) == "00") == minimum
        }
        return index.flatMap { temps[safe: $0] } ?? ""
    }

    /// 短期予報の、その日の 6 時間ごとの降水確率のうちいちばん高いもの
    private func highestPrecipitationChance(on date: String) -> String {
        guard let series = popSeries, let pops = popArea?.pops else { return "" }
        let values = zip(series.timeDefines, pops).compactMap { time, pop in
            time.slice(0, 10) == date ? Int(pop) : nil
        }
        return values.max().map(String.init) ?? ""
    }
}

extension Array {
    /// 範囲の外なら nil を返す添字
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
