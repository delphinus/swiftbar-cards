import Foundation

/// 観測点の表と、予報区と観測点の対応表。めったに変わらないので、週に 1 回取り直す。
struct StationTables {
    /// 観測点の番号 → 観測点
    let stations: [String: AmedasStation]
    /// 予報の気温の地点 (forecast_area.json に一次細分区域ごとに 1 つある)
    let forecastPoints: [ForecastPoint]
    let areaNames: AreaNames

    /// 予報の気温の地点と、それが属する府県予報区・一次細分区域
    struct ForecastPoint {
        let office: String
        let class10: String
        /// 観測点の番号
        let station: String
        let latitude: Double
        let longitude: Double
    }

    private static let files = [
        "amedas/const/amedastable.json",
        "forecast/const/forecast_area.json",
        "common/const/area.json",
    ]

    /// 古ければ取り直してから読む。読めなければ nil
    static func load(cache: CacheFolder, client: JMAClient) async -> StationTables? {
        for path in files {
            let file = cache.constant(URL(fileURLWithPath: path).lastPathComponent)
            if !CacheFolder.isFresh(file, maxAge: 7 * 86400) {
                await client.download(path, to: file)
            }
        }

        let decoder = JSONDecoder()
        guard let stationData = try? Data(contentsOf: cache.constant("amedastable.json")),
              let stations = try? decoder.decode([String: AmedasStation].self, from: stationData),
              let areaData = try? Data(contentsOf: cache.constant("forecast_area.json")),
              let forecastAreas = try? decoder.decode([String: [ForecastAreaEntry]].self, from: areaData),
              let namesData = try? Data(contentsOf: cache.constant("area.json")),
              let areaNames = try? decoder.decode(AreaNames.self, from: namesData) else { return nil }

        // 府県予報区の番号の順に並べる (近さが同じ地点があったときに、選ぶものを決めておく)
        var points: [ForecastPoint] = []
        for office in forecastAreas.keys.sorted() {
            for entry in forecastAreas[office] ?? [] {
                for code in entry.amedas {
                    guard let station = stations[code] else { continue }
                    points.append(ForecastPoint(office: office, class10: entry.class10, station: code,
                                                latitude: station.latitude, longitude: station.longitude))
                }
            }
        }
        return StationTables(stations: stations, forecastPoints: points, areaNames: areaNames)
    }
}

/// 2 点の近さを比べるための値 (距離の 2 乗)。緯度の差と、経度の差に cos(緯度) を
/// 掛けたものから求める。近さを比べるだけなので、地球の丸みまでは考えない。
func distanceSquared(fromLatitude la: Double, longitude lo: Double, toLatitude lat: Double, longitude lon: Double) -> Double {
    let dLat = lat - la
    let dLon = (lon - lo) * cos(la * .pi / 180)
    return dLat * dLat + dLon * dLon
}
