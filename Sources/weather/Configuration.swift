import Foundation
#if canImport(Shared)
import Shared
#endif

/// 設定ファイル (~/.config/swiftbar-cards/weather.conf)。地点を、アメダスの観測点の
/// 名前で 1 行に 1 つ書く。現在地 (いちばん近い、気温を観測している観測点) は常に
/// あり、書かなければ先頭に出る。
///
///     place=東京
///     place=横浜
///     place=44116   # 同じ名前の観測点が複数あるときは番号で書く
///     place=現在地  # 現在地を先頭以外に置くとき (here とも書ける)
enum Configuration {
    static var file: URL {
        let environment = ProcessInfo.processInfo.environment
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (environment["HOME"] ?? NSHomeDirectory()) + "/.config"
        return URL(fileURLWithPath: configHome).appendingPathComponent("swiftbar-cards/weather.conf")
    }

    /// 現在地を表す書き方
    static func isHere(_ place: String) -> Bool { place == "現在地" || place == "here" }

    /// 設定した地点。現在地が書かれていなければ先頭に足す (書かれていればその位置に置く)
    static func places() -> [String] {
        var places = readPlaces()
        if !places.contains(where: isHere) {
            places.insert("現在地", at: 0)
        }
        return places
    }

    /// 設定ファイルを読む。key=value の行だけを拾い、# から後ろは捨てる。
    /// 以前の amedas=<番号> も、1 つの地点として読む。
    private static func readPlaces() -> [String] {
        guard let text = CacheFolder.readText(file) else { return [] }
        var places: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].filter { !$0.isWhitespace }
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if (key == "place" || key == "amedas") && !value.isEmpty {
                places.append(value)
            }
        }
        return places
    }

    /// 設定ファイルが無ければ、ひな形を書く
    static func createTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        CacheFolder.writeText(isJapanese ? japaneseTemplate : englishTemplate, to: file)
    }

    private static let japaneseTemplate = """
        # 現在地の天気は常に出る。ほかの地点を足すには、アメダスの観測点の名前
        # (https://www.jma.go.jp/bosai/amedas/ で探せる) を書く。
        # 足した地点は、メニューから選んで切り替えられる。
        #place=東京
        #place=横浜
        # 同じ名前の観測点が複数あるときは、番号で書く
        #place=44116
        # 現在地は先頭に出る。別の位置に置くときは、その位置に書く
        #place=現在地

        """

    private static let englishTemplate = """
        # The weather for your location is always shown. To add other locations,
        # write names of AMeDAS stations, in Japanese (see https://www.jma.go.jp/bosai/amedas/).
        # Choose between them from the menu.
        #place=東京
        #place=横浜
        # When more than one station has the same name, use its number
        #place=44116
        # Your location comes first. To put it elsewhere, write it in that position
        #place=here

        """
}
