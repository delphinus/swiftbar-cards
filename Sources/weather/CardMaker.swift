import Foundation
#if canImport(Shared)
import Shared
#endif

/// 1 つの地点のデータを取り直し、カードを描いてキャッシュに置く。
///
/// 取り直しと描き直しを分けてある。外観 (ダーク / ライト) が変わったときは、取り
/// 直さずにキャッシュのデータから描き直す。
final class CardMaker {
    let cache: CacheFolder
    let client = JMAClient()
    /// 天気コード → 英語名 (data/jma-telops.json)
    let telops: [String: String]
    /// 観測点の番号 → 観測点。週間予報の気温の地点の英語名を引くのに使う。観測点の表を
    /// 読んだら WeatherPlugin が入れる
    var stations: [String: AmedasStation] = [:]
    /// 前回の取り直しで取得に失敗した観測点 (描き直すときも古いデータの印を付ける)
    private var staleStations: Set<String> = []

    init(cache: CacheFolder, telops: [String: String]) {
        self.cache = cache
        self.telops = telops
    }

    /// 地点のデータを取り直す
    func fetch(_ station: Place.Station, now: Double) async {
        var stale = false
        let office = JMAClient.forecastOffice(for: station.office)
        if !(await client.download("forecast/data/forecast/\(office).json", to: cache.forecast(office: office))) {
            stale = true
        }
        if !(await fetchLatestObservations()) { stale = true }
        await client.download("jmatile/data/wdist/VPFD/\(station.class10).json",
                              to: cache.timeSeriesForecast(class10: station.class10))
        await fetchObservationSeries(station: station.code, now: now)

        if stale { staleStations.insert(station.code) } else { staleStations.remove(station.code) }
        cache.deleteOldFiles(days: 2) { $0.hasPrefix("forecast-") || $0.hasPrefix("vpfd-") }
        cache.deleteOldFiles(in: "amedas", days: 2) { $0.hasSuffix(".json") }
    }

    /// 全観測点の最新値。最新の時刻を問い合わせてから、その時刻のファイルを取る
    private func fetchLatestObservations() async -> Bool {
        guard let data = await client.data("amedas/data/latest_time.txt"),
              let latest = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !latest.isEmpty else { return false }
        // 2026-11-04T20:30:00+09:00 → 20261104203000
        let stamp = latest.slice(0, 19).filter(\.isNumber)
        guard await client.download("amedas/data/map/\(stamp).json", to: cache.latestObservations) else { return false }
        CacheFolder.writeText(latest, to: cache.latestObservationsTime)
        return true
    }

    /// 観測点の時系列。過去 30 時間ぶんを 3 時間ごとのファイルで取る。確定したものは
    /// キャッシュして使い回し、最新の 2 つは毎回取り直す。
    private func fetchObservationSeries(station: String, now: Double) async {
        for (k, block) in Self.observationBlocks(now: now).enumerated() {
            let file = cache.observationSeries(station: station, block: block)
            if k < 2 || !CacheFolder.isFresh(file, maxAge: .infinity) {
                await client.download("amedas/data/point/\(station)/\(block).json", to: file)
            }
        }
    }

    /// 時系列のファイルの名前 (日本時間の「日付_時」。時は 3 の倍数)。新しい順に 10 個
    static func observationBlocks(now: Double) -> [String] {
        (0..<10).map { k in
            let t = now - Double(k * 3 * 3600)
            let hour = Int(JapanTime.string(t, "HH"))!
            return JapanTime.string(t, "yyyyMMdd") + "_" + String(format: "%02d", hour / 3 * 3)
        }
    }

    /// キャッシュのデータからカードを描き、キャッシュに置く。予報が無ければ nil
    @discardableResult
    func draw(_ station: Place.Station, now: Double, dark: Bool, minHeight: Double) -> PlaceCard? {
        let decoder = JSONDecoder()
        let office = JMAClient.forecastOffice(for: station.office)
        // ファイルが無いのは、まだ取れていないだけ。中身を読めないときだけ記録する
        func decode<T: Decodable>(_ type: T.Type, _ file: URL) -> T? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            do {
                return try decoder.decode(type, from: data)
            } catch {
                logger.error("読めない: \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard let forecast = decode([ForecastReport].self, cache.forecast(office: office)), !forecast.isEmpty
        else { return nil }
        var series: [String: AmedasObservation] = [:]
        for block in Self.observationBlocks(now: now) {
            let values = decode([String: AmedasObservation].self, cache.observationSeries(station: station.code, block: block))
            series.merge(values ?? [:]) { _, new in new }
        }

        let report = WeatherReport(
            station: station, forecast: forecast,
            timeSeries: decode(TimeSeriesForecast.self, cache.timeSeriesForecast(class10: station.class10)),
            latest: decode([String: AmedasObservation].self, cache.latestObservations) ?? [:],
            latestTime: CacheFolder.readText(cache.latestObservationsTime) ?? "",
            series: series, telops: telops, stations: stations, stale: staleStations.contains(station.code),
            now: now, dark: dark, minHeight: minHeight)

        let (image, naturalHeight) = WeatherCard(input: report.card).render()
        let card = PlaceCard(menuBarLine: report.menuBarLine, cardLine: SwiftBar.imageLine(image),
                             naturalHeight: Int(ceil(naturalHeight)), menuItemSummary: report.menuItemSummary)
        card.write(to: cache.card(station: station.code, dark: dark))
        cache.deleteOldFiles(days: 2) { $0.hasPrefix("body-") }
        return card
    }
}
