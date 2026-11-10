import Foundation
#if canImport(Shared)
import Shared
#endif

// MARK: - 警報・注意報のデータ

/// 警報・注意報 (warning/data/r8/<府県予報区>.json)。2026 年 5 月末の防災気象情報の
/// 見直しで、それまでの warning/data/warning/<府県予報区>.json は更新されなくなった
/// (2026-05-28 の発表のまま止まっている)。
///
/// 配列の 1 件が 1 つの電文 (dataTypeCode が VPWW55〜61) で、大雨・土砂災害・高潮・
/// 風・波・大雪・その他の注意報、と種類ごとに分かれている。どの電文にも、府県予報区の
/// 全部の市町村 (class20Items) が並ぶ。
struct WarningReport: Decodable {
    let warning: Body

    struct Body: Decodable {
        let class20Items: [Item]?
    }

    struct Item: Decodable {
        let areaCode: String
        let kinds: [Kind]
    }

    /// 1 つの警報・注意報。発表されていない市町村では code が無く、status が
    /// 「発表警報・注意報はなし」になる
    struct Kind: Decodable {
        let code: String?
        let status: String
    }

    /// 市町村 (`class20`) に出ている警報・注意報。段階の高い順
    static func warnings(in reports: [WarningReport], class20: String) -> [WeatherWarning] {
        var codes: [String] = []
        for report in reports {
            for item in report.warning.class20Items ?? [] where item.areaCode == class20 {
                for kind in item.kinds where kind.status != "解除" {
                    if let code = kind.code, !codes.contains(code) { codes.append(code) }
                }
            }
        }
        return codes.compactMap(WeatherWarning.init(code:)).sorted()
    }
}

/// 警報・注意報の 1 つ。
///
/// コードの表は、気象庁の警報・注意報のページのスクリプトにあるもの (2026-11-10 に
/// 読んだ)。氾濫 (コード 20〜53) は別の表で、濃霧・乾燥・なだれ (20〜22) とコードが
/// 重なる。全国 58 の府県予報区のファイルを取って、氾濫が入っていないことを確かめたので、
/// 氾濫の表は持たない。
struct WeatherWarning: Comparable {
    let code: String
    let element: Element
    /// 2 が注意報、3 が警報、4 が危険警報、5 が特別警報。気象庁の「警戒レベル」の
    /// 数字と同じ (大雨・土砂災害・高潮だけが名前に「レベル」を付ける)
    let level: Int

    /// 気象庁のページの並び順
    enum Element: Int, CaseIterable {
        case rain, landslide, tide, wind, windSnow, snow, wave, thunder, snowMelting,
             fog, dry, avalanche, cold, frost, iceAccretion, snowAccretion
    }

    private static let table: [String: (Element, Int)] = [
        "10": (.rain, 2), "03": (.rain, 3), "43": (.rain, 4), "33": (.rain, 5),
        "29": (.landslide, 2), "09": (.landslide, 3), "49": (.landslide, 4), "39": (.landslide, 5),
        "19": (.tide, 2), "08": (.tide, 3), "48": (.tide, 4), "38": (.tide, 5),
        "15": (.wind, 2), "05": (.wind, 3), "35": (.wind, 5),
        "13": (.windSnow, 2), "02": (.windSnow, 3), "32": (.windSnow, 5),
        "12": (.snow, 2), "06": (.snow, 3), "36": (.snow, 5),
        "16": (.wave, 2), "07": (.wave, 3), "37": (.wave, 5),
        "14": (.thunder, 2), "17": (.snowMelting, 2), "20": (.fog, 2), "21": (.dry, 2),
        "22": (.avalanche, 2), "23": (.cold, 2), "24": (.frost, 2), "25": (.iceAccretion, 2),
        "26": (.snowAccretion, 2),
    ]

    /// 知らないコードなら nil
    init?(code: String) {
        guard let (element, level) = Self.table[code] else { return nil }
        self.code = code
        self.element = element
        self.level = level
    }

    /// 段階の高いほうが先。同じ段階なら気象庁のページの並び順
    static func < (a: WeatherWarning, b: WeatherWarning) -> Bool {
        a.level != b.level ? a.level > b.level : a.element.rawValue < b.element.rawValue
    }

    /// 気象庁の呼び方。「レベル４大雨危険警報」「暴風警報」「雷注意報」など
    var name: String {
        let (ja, en) = elementName
        let kind: (String, String) = switch level {
        case 2: ("注意報", "Advisory")
        case 3: ("警報", "Warning")
        case 4: ("危険警報", "Urgent Warning")
        default: ("特別警報", "Emergency Warning")
        }
        let leveled = [.rain, .landslide, .tide].contains(element)
        let digits = ["", "", "２", "３", "４", "５"]
        return L((leveled ? "レベル\(digits[level])" : "") + ja + kind.0,
                 (leveled ? "Level \(level) " : "") + en + " " + kind.1)
    }

    /// 現象の名前。風は注意報 (強風・風雪) と警報 (暴風・暴風雪) で名前が変わる
    private var elementName: (String, String) {
        switch element {
        case .rain: ("大雨", "Heavy Rain")
        case .landslide: ("土砂災害", "Landslide")
        case .tide: ("高潮", "Storm Surge")
        case .wind: level == 2 ? ("強風", "Gale") : ("暴風", "Storm")
        case .windSnow: level == 2 ? ("風雪", "Gale and Snow") : ("暴風雪", "Snowstorm")
        case .snow: ("大雪", "Heavy Snow")
        case .wave: ("波浪", "High Wave")
        case .thunder: ("雷", "Thunderstorm")
        case .snowMelting: ("融雪", "Snow Melting")
        case .fog: ("濃霧", "Dense Fog")
        case .dry: ("乾燥", "Dry Air")
        case .avalanche: ("なだれ", "Avalanche")
        case .cold: ("低温", "Low Temperature")
        case .frost: ("霜", "Frost")
        case .iceAccretion: ("着氷", "Ice Accretion")
        case .snowAccretion: ("着雪", "Snow Accretion")
        }
    }
}

/// 観測点 (現在地なら現在地) のある市町村と、そこに出ている警報・注意報
struct WarningArea {
    /// 市町村の番号 (class20)
    let code: String
    let name: String
    let enName: String
    let warnings: [WeatherWarning]

    var localizedName: String { L(name, enName) }

    /// 気象庁の警報・注意報のページを、この市町村で開く
    var url: String { "https://www.jma.go.jp/bosai/warning/#area_type=class20s&area_code=\(code)" }
}

// MARK: - 座標から市町村を決める

/// 緯度と経度から、警報・注意報を発表する市町村 (class20) を決める。気象庁の
/// サイトと同じく、市町村ごとの外接矩形 (common/const/class20relm.json) で候補を
/// 絞り、候補の境界 (common/const/geojson/class20s/<番号>.json) の内外で決める。
/// どの境界にも入らなければ (海岸の観測点など)、外接矩形の中心がいちばん近い市町村。
///
/// 境界のファイルは市町村ごとに数百バイト〜数十 KB で、取ったらキャッシュに置いて
/// 使い回す。
struct Class20Locator {
    let cache: CacheFolder
    let client: JMAClient

    private struct Bounds: Decodable {
        /// [緯度, 経度]
        let ne: [Double]
        let sw: [Double]

        func contains(latitude: Double, longitude: Double) -> Bool {
            sw[0] <= latitude && latitude <= ne[0] && sw[1] <= longitude && longitude <= ne[1]
        }

        var center: (Double, Double) { ((ne[0] + sw[0]) / 2, (ne[1] + sw[1]) / 2) }
    }

    /// 市町村の番号。外接矩形の表が無いか、候補の境界を取れなければ nil
    func locate(latitude: Double, longitude: Double) async -> String? {
        guard let data = try? Data(contentsOf: cache.constant("class20relm.json")),
              let bounds = try? JSONDecoder().decode([String: Bounds].self, from: data), !bounds.isEmpty
        else { return nil }

        let candidates = bounds.filter { $0.value.contains(latitude: latitude, longitude: longitude) }.keys.sorted()
        for code in candidates {
            guard let rings = await boundary(code) else { return nil }
            if Self.contains(rings, latitude: latitude, longitude: longitude) { return code }
        }
        return bounds.min { a, b in
            distanceSquared(fromLatitude: latitude, longitude: longitude, toLatitude: a.value.center.0, longitude: a.value.center.1)
                < distanceSquared(fromLatitude: latitude, longitude: longitude, toLatitude: b.value.center.0, longitude: b.value.center.1)
        }?.key
    }

    /// 市町村の境界。多角形の輪 (外周とくり抜き) を [経度, 緯度] の列で並べたもの。
    /// キャッシュに無いか 30 日より古ければ取り直す
    private func boundary(_ code: String) async -> [[[Double]]]? {
        let file = cache.constant("class20s/\(code).json")
        if !CacheFolder.isFresh(file, maxAge: 30 * 86400) {
            await client.download("common/const/geojson/class20s/\(code).json", to: file)
        }
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return nil }
        var rings: [[[Double]]] = []
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any] else { continue }
            switch geometry["type"] as? String {
            case "Polygon": rings += geometry["coordinates"] as? [[[Double]]] ?? []
            case "MultiPolygon": rings += (geometry["coordinates"] as? [[[[Double]]]] ?? []).flatMap { $0 }
            default: break
            }
        }
        return rings
    }

    /// 点が多角形の中にあるか。輪をまたぐ回数の偶奇で決める (くり抜いた部分は外になる)
    static func contains(_ rings: [[[Double]]], latitude y: Double, longitude x: Double) -> Bool {
        var inside = false
        for ring in rings where ring.count >= 3 {
            var j = ring.count - 1
            for i in ring.indices {
                let (xi, yi) = (ring[i][0], ring[i][1])
                let (xj, yj) = (ring[j][0], ring[j][1])
                if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
        }
        return inside
    }
}
