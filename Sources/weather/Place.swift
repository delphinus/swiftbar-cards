import Foundation
#if canImport(Shared)
import Shared
#endif

/// 設定ファイルに書いた地点と、それに当たる観測点
struct Place {
    /// 設定ファイルに書かれた文字列 (観測点の名前か番号、現在地)
    let query: String
    let match: Match

    enum Match {
        case found(Station)
        case notFound
        /// 同じ名前の観測点が複数ある
        case ambiguous([Station])
    }

    var isHere: Bool { Configuration.isHere(query) }
    var station: Station? {
        if case .found(let station) = match { return station }
        return nil
    }

    /// 観測点と、その天気を出すのに使う予報区
    struct Station {
        /// 観測点の番号
        let code: String
        /// 現在地として選んだ観測点か
        let isHere: Bool
        let name: String
        let enName: String
        /// 府県予報区と、その名前
        let office: String
        let officeName: String
        let officeEnName: String
        /// 一次細分区域と、その英語名
        let class10: String
        let class10EnName: String
        /// 予報の気温の地点 (観測点の番号) と、その名前
        let temperaturePoint: String
        let temperaturePointName: String

        /// 表示の言語での観測点の名前
        var localizedName: String { L(name, enName) }
    }
}

/// 地点の文字列から観測点を引き、天気を出すのに使う予報区のコード (府県予報区・
/// 一次細分区域・予報の気温の地点) を決める。
struct PlaceResolver {
    let tables: StationTables
    let here: CurrentLocation

    /// 現在地が分からないときに出す観測点 (東京)
    static let tokyo = "44132"

    func resolve(_ query: String) -> Place {
        let isHere = Configuration.isHere(query)
        let stations = candidates(for: query, isHere: isHere).map { station(for: $0, isHere: isHere) }
        let match: Place.Match = switch stations.count {
        case 0: .notFound
        case 1: .found(stations[0])
        default: .ambiguous(stations)
        }
        return Place(query: query, match: match)
    }

    /// 地点の文字列に当たる観測点の番号。現在地なら、いちばん近い観測点のうち気温を
    /// 観測しているもの (現在地が分からなければ東京)。数字だけなら観測点の番号、
    /// それ以外は観測点の名前として探す。
    private func candidates(for query: String, isHere: Bool) -> [String] {
        if isHere {
            guard let here = here.coordinate else { return [Self.tokyo] }
            let nearest = tables.stations.filter { $0.value.observesTemperature }.min { a, b in
                distanceSquared(fromLatitude: here.latitude, longitude: here.longitude,
                                toLatitude: a.value.latitude, longitude: a.value.longitude)
                    < distanceSquared(fromLatitude: here.latitude, longitude: here.longitude,
                                      toLatitude: b.value.latitude, longitude: b.value.longitude)
            }
            return nearest.map { [$0.key] } ?? [Self.tokyo]
        }
        if query.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return tables.stations[query] == nil ? [] : [query]
        }
        return tables.stations.filter { $0.value.kjName == query }.keys.sorted()
    }

    /// 観測点の天気を出すのに使う予報区を決める。予報の気温の地点のうち、観測点と
    /// 同じ地域でいちばん近いものの区域を使う。
    ///
    /// 番号の上 2 桁は地域 (おおむね府県予報区) を表すので、同じ地域の地点から選ぶ。
    /// 近さだけで選ぶと、県境の近くで隣の県の地点を拾う (東京都の府中は、東京と
    /// さいたまからほぼ同じ距離にある)。
    private func station(for code: String, isHere: Bool) -> Place.Station {
        let station = tables.stations[code]!
        let region = code.prefix(2)
        let sameRegion = tables.forecastPoints.filter { $0.station.hasPrefix(region) }
        let points = sameRegion.isEmpty ? tables.forecastPoints : sameRegion
        let best = points.min { a, b in
            distanceSquared(fromLatitude: station.latitude, longitude: station.longitude,
                            toLatitude: a.latitude, longitude: a.longitude)
                < distanceSquared(fromLatitude: station.latitude, longitude: station.longitude,
                                  toLatitude: b.latitude, longitude: b.longitude)
        }!
        let office = tables.areaNames.offices[best.office]
        return Place.Station(
            code: code, isHere: isHere, name: station.kjName, enName: station.enName,
            office: best.office, officeName: office?.name ?? "", officeEnName: office?.enName ?? "",
            class10: best.class10, class10EnName: tables.areaNames.class10s[best.class10]?.enName ?? "",
            temperaturePoint: best.station, temperaturePointName: tables.stations[best.station]?.kjName ?? "")
    }

    /// 選んでいる地点の位置。覚えている文字列 (`selected`) と、書かれた文字列・観測点の
    /// 名前・番号のどれかが一致する地点を選ぶ。無ければ先頭にする。
    ///
    /// 同名の観測点が複数あって「山口」を選んだあと、設定を place=81286 に書き換えても、
    /// 山口を選んだままにするため。書かれた文字列と一致する地点を先に探し、観測点の
    /// 名前・番号では現在地を拾わない。東京にいると現在地の観測点も東京なので、
    /// 東京を選んでも現在地を選んだことになる。
    static func selectedIndex(in places: [Place], selected: String) -> Int {
        if let index = places.firstIndex(where: { $0.query == selected }) { return index }
        let index = places.firstIndex { place in
            let stations: [Place.Station] = switch place.match {
            case .found(let station): [station]
            case .ambiguous(let stations): stations
            case .notFound: []
            }
            return stations.contains { !$0.isHere && ($0.name == selected || $0.code == selected) }
        }
        return index ?? 0
    }
}
