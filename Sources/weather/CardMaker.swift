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
    let telops: [String: Telop]
    /// 観測点の番号 → 観測点。週間予報の気温の地点の英語名を引くのに使う。観測点の表を
    /// 読んだら WeatherPlugin が入れる
    var stations: [String: AmedasStation] = [:]
    /// 祝日・休日。曜日を日曜と同じ赤にするのに使う。WeatherPlugin が入れる
    var holidays = Holidays(dates: [])
    /// 予報区の名前と親子関係。警報・注意報の市町村の名前と府県予報区を引くのに使う。
    /// WeatherPlugin が入れる
    var areaNames: AreaNames?
    /// 前回の取り直しで取得に失敗した地点 (`Place.Station.cacheKey`)。描き直すときも
    /// 古いデータの印を付ける
    private var staleStations: Set<String> = []
    /// 地点 (`Place.Station.cacheKey`) → 警報・注意報の市町村 (class20)
    private var class20s: [String: String] = [:]

    init(cache: CacheFolder, telops: [String: Telop]) {
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
        if !(await fetchWarnings(station)) { stale = true }

        if stale { staleStations.insert(station.cacheKey) } else { staleStations.remove(station.cacheKey) }
        cache.deleteOldFiles(days: 2) { $0.hasPrefix("forecast-") || $0.hasPrefix("vpfd-") || $0.hasPrefix("warning-") }
        cache.deleteOldFiles(in: "amedas", days: 2) { $0.hasSuffix(".json") }
    }

    /// 地点の市町村を (まだ決めていなければ) 決め、その府県予報区の警報・注意報を取る。
    /// 市町村を決められないか、取得に失敗したら false
    private func fetchWarnings(_ station: Place.Station) async -> Bool {
        if needsLocating(station) {
            let locator = Class20Locator(cache: cache, client: client)
            guard let code = await locator.locate(latitude: station.latitude, longitude: station.longitude) else { return false }
            class20s[station.cacheKey] = code
            located[station.cacheKey] = (station.latitude, station.longitude)
        }
        guard let class20 = class20s[station.cacheKey], let office = areaNames?.office(ofClass20: class20) else { return false }
        return await client.download("warning/data/r8/\(office).json", to: cache.warnings(office: office))
    }

    /// 市町村を決めたときの座標 (現在地は動くので、動いたら決め直す)
    private var located: [String: (Double, Double)] = [:]

    private func needsLocating(_ station: Place.Station) -> Bool {
        guard let (latitude, longitude) = located[station.cacheKey] else { return true }
        return latitude != station.latitude || longitude != station.longitude
    }

    /// 地点の市町村と、そこに出ている警報・注意報。市町村が決まっていないか、
    /// 警報・注意報のファイルを読めなければ nil
    private func warningArea(_ station: Place.Station, decode: ([WarningReport].Type, URL) -> [WarningReport]?) -> WarningArea? {
        guard let code = class20s[station.cacheKey], let names = areaNames, let area = names.class20s[code],
              let office = names.office(ofClass20: code),
              let reports = decode([WarningReport].self, cache.warnings(office: office)) else { return nil }
        return WarningArea(code: code, name: area.name, enName: area.enName,
                           warnings: WarningReport.warnings(in: reports, class20: code))
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
            series: series, telops: telops, stations: stations, holidays: holidays,
            warningArea: warningArea(station, decode: decode), stale: staleStations.contains(station.cacheKey),
            now: now, dark: dark, minHeight: minHeight)

        let (image, naturalHeight) = WeatherCard(input: report.card).render()
        let card = PlaceCard(menuBarLine: report.menuBarLine, cardLine: SwiftBar.imageLine(image),
                             naturalHeight: Int(ceil(naturalHeight)), menuItemSummary: report.menuItemSummary,
                             notices: report.notices)
        card.write(to: cache.card(station: station, dark: dark))
        cache.deleteOldFiles(days: 2) { $0.hasPrefix("body-") }
        return card
    }
}
