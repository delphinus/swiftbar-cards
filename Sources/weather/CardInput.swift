import Foundation

// カードに描く値。WeatherReport が気象庁のデータから組み立て、WeatherCard が描く。
// 色は外観 (ダーク / ライト) に合わせて選んだものを "#RRGGBB" の文字列で持つ
// (WeatherStyle.swift)。nil なら標準の文字色で描く。

struct CardInput {
    let dark: Bool
    /// 今の時刻 (UNIX 時刻)
    let now: Double
    let obs: Observation?
    let graph: TemperatureGraph?
    /// 3 日分の予報の節の見出し (予報の区域の名前を含む)
    let daysTitle: String
    let days: [DayForecast]
    /// 週間予報の節の見出し。気温が観測点とは別の地点の予報なら、その地点の名前を含む
    let weekTitle: String
    let week: [WeekForecast]
    /// 週間予報の期間の平年値。週間予報の気温の地点のもの
    let weekNormal: WeekNormal?
    /// カードの高さをこれ以上にする (下を空ける)。地点を切り替えたときに高さが
    /// 変わらないよう、設定した地点のカードの高さをそろえるのに使う。
    let minHeight: Double
}

/// 今の観測値 (アメダス)
struct Observation {
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

/// グラフの点。t は UNIX 時刻、value は気温
typealias TimedValue = (t: Double, value: Double)

/// 今後 24 時間の気温のグラフに使う値
struct TemperatureGraph {
    let current: Double?
    /// 過去の観測値
    let pastPoints: [TimedValue]
    /// 予報
    let forecastPoints: [TimedValue]
    /// 3 時間ごとの天気
    let weatherIcons: [(t: Double, symbol: String, color: String)]
    /// 6 時間ごとの降水確率
    let precipitationChances: [(t: Double, percent: String, color: String)]
    /// 3 時間ごとの風
    let winds: [WindForecast]
}

/// 3 時間ごとの風の予報
struct WindForecast {
    /// その時間帯の始まり (UNIX 時刻)
    let t: Double
    /// 風が吹いていく向き (北が 0 度で時計回り)。風向が分からなければ nil
    let heading: Double?
    /// 風速 (m/s)。気象庁の階級の範囲の真ん中を整数に丸めたもの。例: "4"
    let speed: String
    /// 強い風 (10 m/s 以上) か
    let strong: Bool
}

/// 週間予報の期間の平年値 (°C)。値は数を書いた文字列
struct WeekNormal {
    let max: String
    let maxColor: String?
    let min: String
    let minColor: String?
}

/// 3 日分の予報の 1 日
struct DayForecast {
    /// 11/5 の形
    let date: String
    /// 曜日 (0 が日曜)
    let dow: Int
    /// 祝日・休日か
    let holiday: Bool
    let text: String
    let icon: String
    let color: String
}

/// 週間予報の 1 日。値が無いところは空文字列
struct WeekForecast {
    let date: String
    let dow: Int
    /// 祝日・休日か
    let holiday: Bool
    let icon: String
    let color: String
    let max: String
    let maxColor: String?
    let min: String
    let minColor: String?
    let pop: String
    let popColor: String?
}
