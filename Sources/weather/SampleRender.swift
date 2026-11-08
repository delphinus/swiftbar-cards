import Foundation
#if canImport(Shared)
import Shared
#endif

/// 与えたデータで 1 回だけ描く (テスト用)。気象庁には取りに行かない。
///
///     weather --render <値の JSON> <出力先>
///
/// JSON は samples/weather/sample.json の形で、今の時刻・地点 (観測点と予報区)・祝日を
/// 書く。気象庁のデータは、JSON と同じフォルダの cache/ をキャッシュのフォルダとして
/// 読む (samples/weather/capture.sh が写したもの)。出力先に card-light.png・
/// card-dark.png と、メニューバーの行 (menubar.txt) を書く。メニューバーは画像では
/// なく、SwiftBar が描く文字とアイコンの行なので、行をそのまま書く。
enum SampleRender {
    private struct Sample: Decodable {
        /// 今の時刻 ("2026-11-08T14:20:00+09:00" の形)
        var now: String
        var station: Station
        /// 祝日・休日 ("2026-11-23" の形)
        var holidays: [String]?

        struct Station: Decodable {
            var code, name, enName, office, officeName, officeEnName: String
            var class10, class10EnName, temperaturePoint, temperaturePointName: String
        }
    }

    static func run(jsonPath: String, outputDirectory: String, telops: [String: Telop]) -> Never {
        let sample: Sample
        do {
            guard let data = FileManager.default.contents(atPath: jsonPath) else { exitWithError("JSON を読めない: \(jsonPath)") }
            sample = try JSONDecoder().decode(Sample.self, from: data)
        } catch {
            exitWithError("JSON の形が違う: \(error)")
        }
        guard let now = JapanTime.epoch(sample.now) else { exitWithError("now を時刻として読めない: \(sample.now)") }
        let s = sample.station
        let station = Place.Station(
            code: s.code, isHere: false, name: s.name, enName: s.enName,
            office: s.office, officeName: s.officeName, officeEnName: s.officeEnName,
            class10: s.class10, class10EnName: s.class10EnName,
            temperaturePoint: s.temperaturePoint, temperaturePointName: s.temperaturePointName)

        let cache = CacheFolder(url: URL(fileURLWithPath: jsonPath).deletingLastPathComponent().appendingPathComponent("cache"))
        let maker = CardMaker(cache: cache, telops: telops)
        maker.holidays = Holidays(dates: Set(sample.holidays ?? []))

        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let appearance = dark ? "dark" : "light"
                guard let report = maker.report(station, now: now, dark: dark, minHeight: 0) else {
                    exitWithError("予報を読めない: \(cache.url.path)")
                }
                try WeatherCard(input: report.card).render().image.write(to: directory, name: "card-\(appearance)")
                // メニューバーの行は、明るい用と暗い用の色を , で並べて持つので 1 つでよい
                if !dark {
                    try (report.menuBarLine + "\n").write(to: directory.appendingPathComponent("menubar.txt"),
                                                          atomically: true, encoding: .utf8)
                }
            }
        } catch {
            exitWithError("書き出せない: \(error)")
        }
        exit(0)
    }
}
