import Foundation

// 気象庁のサイト (www.jma.go.jp/bosai/) が裏で読んでいる JSON の形。使う項目だけを
// 書く (Decodable は書いていないキーを読み飛ばす)。無いことがある値は Optional (`?`)。

// MARK: - 観測点と予報区の表 (めったに変わらない)

/// アメダスの観測点 (amedas/const/amedastable.json の 1 件)。キーは観測点の番号
struct AmedasStation: Decodable {
    /// 観測している要素。1 文字目が 1 なら気温を観測している
    let elems: String
    /// 緯度と経度。[度, 分] で配られる
    let lat: [Double]
    let lon: [Double]
    let kjName: String
    let enName: String

    var observesTemperature: Bool { elems.hasPrefix("1") }
    var latitude: Double { lat[0] + lat[1] / 60 }
    var longitude: Double { lon[0] + lon[1] / 60 }
}

/// 府県予報区の中の一次細分区域と、予報の気温の地点 (forecast/const/forecast_area.json の 1 件)
struct ForecastAreaEntry: Decodable {
    let class10: String
    /// 予報の気温の地点 (アメダスの観測点の番号)
    let amedas: [String]
}

/// 予報区の名前 (common/const/area.json)
struct AreaNames: Decodable {
    struct Name: Decodable {
        let name: String
        let enName: String
    }

    /// 府県予報区
    let offices: [String: Name]
    /// 一次細分区域
    let class10s: [String: Name]
}

// MARK: - 予報

/// 府県予報 (forecast/data/forecast/<府県予報区>.json)。配列の 1 つめが 3 日分の
/// 短期予報、2 つめが週間予報
struct ForecastReport: Decodable {
    let reportDatetime: String
    let timeSeries: [TimeSeries]

    /// 時刻の並びと、区域ごとの値
    struct TimeSeries: Decodable {
        let timeDefines: [String]
        let areas: [AreaValues]

        /// `code` の区域の値
        func area(_ code: String) -> AreaValues? {
            areas.first { $0.area.code == code }
        }
    }

    /// 1 つの区域の値。時系列によって入っている値が違う。値の無い時刻は空文字列
    struct AreaValues: Decodable {
        struct Area: Decodable {
            let name: String
            let code: String
        }

        let area: Area
        let weatherCodes: [String]?
        let weathers: [String]?
        let pops: [String]?
        let temps: [String]?
        let tempsMin: [String]?
        let tempsMax: [String]?
    }
}

/// 地域時系列予報 (jmatile/data/wdist/VPFD/<一次細分区域>.json)。3 時間ごとの天気と気温
struct TimeSeriesForecast: Decodable {
    let pointTimeSeries: OneOrMany<PointSeries>?
    let areaTimeSeries: OneOrMany<AreaSeries>?

    struct TimeDefine: Decodable {
        let dateTime: String
    }

    /// 予報の気温の地点の 3 時間ごとの気温
    struct PointSeries: Decodable {
        let pointNameJP: String?
        let timeDefines: [TimeDefine]?
        let temperature: [LooseNumber]?
    }

    /// 区域の 3 時間ごとの天気 (文字で配られる)
    struct AreaSeries: Decodable {
        let timeDefines: [TimeDefine]
        let weather: [String]
    }
}

// MARK: - 観測値

/// アメダスの観測値。全観測点の最新値 (amedas/data/map/<時刻>.json) では観測点ごとに、
/// 観測点の時系列 (amedas/data/point/<観測点>/<日付>_<時>.json) では時刻ごとに 1 件。
/// 値は [値, 品質] の組で配られるので、1 つめだけを使う。
struct AmedasObservation: Decodable {
    let temp: [Double?]?
    let humidity: [Double?]?
    let precipitation1h: [Double?]?
    let wind: [Double?]?
    let windDirection: [Double?]?

    var temperature: Double? { temp?.first ?? nil }
}

// MARK: - 形が一定しない値を読む

/// 数か、数を書いた文字列か、空文字列か null のどれかで配られる値。数でなければ nil
struct LooseNumber: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text)
        } else {
            value = nil
        }
    }
}

/// 1 つのオブジェクトのことも、その配列のこともある値
enum OneOrMany<Element: Decodable>: Decodable {
    case one(Element)
    case many([Element])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([Element].self) {
            self = .many(many)
        } else {
            self = .one(try container.decode(Element.self))
        }
    }
}
