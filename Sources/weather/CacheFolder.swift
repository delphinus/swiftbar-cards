import Foundation
#if canImport(Shared)
import Shared
#endif

/// 失敗したときの記録 (Shared の makeLogger)
let logger = makeLogger("weather")

/// キャッシュのフォルダ (~/Library/Caches/swiftbar-weather) の中のファイル。
///
/// 取得した気象庁のデータ、地点ごとに描いたカード、現在地 (Locate.app が書く)、
/// メニューの項目から届いた指示を置く。
struct CacheFolder {
    let url: URL

    /// ~ の展開 (expandingTildeInPath) は環境変数 HOME を見ないので、HOME から組む。
    /// HOME を一時ディレクトリにして動かすテスト (tests/smoke.sh) で本物を書き換えない。
    static let standard: CacheFolder = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return CacheFolder(url: URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/swiftbar-weather"))
    }()

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    // MARK: - 中のファイル

    /// メニューで選んだ地点 (設定ファイルに書かれた文字列)
    var selected: URL { file("selected") }
    /// メニューの項目から届いた指示 (`Command.swift`)。常駐している本体が読んで消す
    var request: URL { file("request") }
    /// 最後に取れた現在地。「緯度 経度 精度 (m) UNIX 時刻」の 1 行 (Locate.app が書く)
    var location: URL { file("location") }
    /// 現在地を取れたか。ok / denied / disabled / error のどれか (Locate.app が書く)
    var locationStatus: URL { file("location-status") }
    /// 位置情報を読む .app (plugins/weather.sh がビルドする)
    var locateApp: URL { file("Locate.app") }
    /// 観測点と予報区の表
    func constant(_ name: String) -> URL { file("const/\(name)") }
    /// 府県予報。地域を変えたあとで取得に失敗したとき、前の地域の予報を出さないよう、
    /// ファイル名に地域の番号を入れる
    func forecast(office: String) -> URL { file("forecast-\(office).json") }
    func timeSeriesForecast(class10: String) -> URL { file("vpfd-\(class10).json") }
    /// 警報・注意報。府県予報区ごと
    func warnings(office: String) -> URL { file("warning-\(office).json") }
    /// アメダスの全観測点の最新値
    var latestObservations: URL { file("amedas.json") }
    /// その観測の時刻 ("2026-11-04T20:30:00+09:00")
    var latestObservationsTime: URL { file("amedas-time.txt") }
    /// 観測点の 3 時間ごとの時系列
    func observationSeries(station: String, block: String) -> URL { file("amedas/\(station)_\(block).json") }
    /// 地点ごとに描いたカード (`PlaceCard`)
    func card(station: Place.Station, dark: Bool) -> URL {
        file("body-\(station.cacheKey)-\(isJapaneseCode)-\(dark).txt")
    }

    private var isJapaneseCode: String { isJapanese ? "ja" : "en" }

    // MARK: - ファイルの扱い

    func prepare() {
        for dir in [url, file("const"), file("const/class20s"), file("amedas")] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 前回書き換えてからの秒数。ファイルが無ければ nil
    static func age(of file: URL) -> TimeInterval? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// 空でないファイルがあり、`maxAge` 秒より新しいか
    static func isFresh(_ file: URL, maxAge: TimeInterval) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 0,
              let age = age(of: file) else { return false }
        return age <= maxAge
    }

    static func readText(_ file: URL) -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    /// 書き終えてから置き換える (読む側が書きかけのファイルを読まない)
    static func writeText(_ text: String, to file: URL) {
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            logger.error("書けない: \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `directory` の中で、名前が `matching` に当てはまり、`days` 日より古いファイルを消す
    func deleteOldFiles(in directory: String = "", days: Double, matching: (String) -> Bool) {
        let dir = directory.isEmpty ? url : file(directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where matching(name) {
            let path = dir.appendingPathComponent(name)
            if let age = Self.age(of: path), age > days * 86400 {
                try? FileManager.default.removeItem(at: path)
            }
        }
    }
}
