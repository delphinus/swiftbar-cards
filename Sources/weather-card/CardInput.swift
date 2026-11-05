import Foundation

// weather.10m.sh が標準入力に渡す JSON の形。`Decodable` にすると、JSONDecoder が
// プロパティの名前と同じキーを読む。無いことがある値は Optional (`?`) にする。

struct CardInput: Decodable {
    let dark: Bool
    /// 今の時刻 (UNIX 時刻)
    let now: Double
    let obs: Observation?
    let graph: TemperatureGraph?
    /// 3 日分の予報の節の見出し (予報の区域の名前を含む)
    let daysTitle: String
    let days: [DayForecast]
    let week: [WeekForecast]
    /// カードの高さをこれ以上にする (下を空ける)。地点を切り替えたときに高さが
    /// 変わらないよう、設定した地点のカードの高さをそろえるのに使う。
    let minHeight: Double?
}

/// 今の観測値 (アメダス)
struct Observation: Decodable {
    /// 観測点の名前
    let point: String
    /// 観測した時刻。例: "17:30"
    let time: String
    let temp: Double?
    let tempColor: String?
    let humidity: Double?
    /// 降水量 (mm/h)
    let precip: Double?
    /// 風速 (m/s) と風向
    let wind: Double?
    let windDir: String?
}

/// 今後 24 時間の気温のグラフに使う値。JSON では値の組を配列で受け取るので、
/// 下の extension で名前の付いた組 (タプル) に読み替えて使う。
struct TemperatureGraph: Decodable {
    let current: Double?
    /// 過去の観測値。[時刻, 気温]
    let past: [[Double]]
    /// 予報。[時刻, 気温]
    let forecast: [[Double]]
    /// 3 時間ごとの天気。[時刻, アイコン, 色]
    let weather: [[String]]
    /// 6 時間ごとの降水確率。[時刻, 降水確率, 色]
    let pops: [[String]]
}

/// グラフの点。t は UNIX 時刻、value は気温
typealias TimedValue = (t: Double, value: Double)

extension TemperatureGraph {
    var pastPoints: [TimedValue] {
        past.filter { $0.count == 2 }.map { ($0[0], $0[1]) }
    }

    var forecastPoints: [TimedValue] {
        forecast.filter { $0.count == 2 }.map { ($0[0], $0[1]) }
    }

    var weatherIcons: [(t: Double, symbol: String, color: String)] {
        weather.compactMap { w in
            guard w.count == 3, let t = Double(w[0]) else { return nil }
            return (t, w[1], w[2])
        }
    }

    var precipitationChances: [(t: Double, percent: String, color: String)] {
        pops.compactMap { p in
            guard p.count == 3, let t = Double(p[0]), !p[1].isEmpty else { return nil }
            return (t, p[1], p[2])
        }
    }
}

/// 3 日分の予報の 1 日
struct DayForecast: Decodable {
    /// 11/5 の形
    let date: String
    /// 曜日 (0 が日曜)
    let dow: Int
    let text: String
    let icon: String
    let color: String
}

/// 週間予報の 1 日。値が無いところは空文字列
struct WeekForecast: Decodable {
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
