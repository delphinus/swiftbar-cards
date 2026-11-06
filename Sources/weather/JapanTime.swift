import Foundation

/// 日本時間の日付と時刻。気象庁のデータは日本時間なので、Mac のタイムゾーンによらず
/// 日本時間で読み書きする。
enum JapanTime {
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    /// "2026-11-05T03:00:00+09:00" の形の時刻を UNIX 時刻にする
    static func epoch(_ text: String) -> Double? {
        isoFormatter.date(from: text)?.timeIntervalSince1970
    }

    /// アメダスの時系列のキー ("20261104210000") を UNIX 時刻にする
    static func epoch(compact text: String) -> Double? {
        compactFormatter.date(from: text)?.timeIntervalSince1970
    }

    /// UNIX 時刻を、`format` (DateFormatter の書式) の日本時間の文字列にする。
    /// 例: `string(now, "yyyy-MM-dd")` は "2026-11-05"
    static func string(_ epoch: Double, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// "2026-11-05T…" の形の時刻の日付から、"11/5" の形の文字と曜日 (0 が日曜) を作る
    static func monthDay(_ text: String) -> (label: String, weekday: Int) {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return (String(text.prefix(10)), 0)
        }
        return ("\(parts[1])/\(parts[2])", calendar.component(.weekday, from: date) - 1)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static let compactFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()
}

extension String {
    /// 先頭から数えて `from` 文字目から `to` 文字目の手前まで (jq の `.[from:to]` と同じ)。
    /// 気象庁の時刻の文字列から、日付 (0..<10) や時刻 (11..<16) を切り出すのに使う。
    func slice(_ from: Int, _ to: Int) -> String {
        let characters = Array(self)
        guard from < characters.count else { return "" }
        return String(characters[from..<Swift.min(to, characters.count)])
    }
}
