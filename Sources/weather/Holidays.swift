import Foundation

/// 国民の祝日と休日 (振替休日・国民の休日を含む)。カードの曜日を、祝日も日曜と同じ
/// 赤にするのに使う。
///
/// 内閣府が公開している一覧 (syukujitsu.csv) を週に 1 回取り直す。春分の日・秋分の日の
/// ように年ごとに決まる日も、翌年の分まで載っている。文字コードは Shift_JIS で、
/// 1 行目が見出し、2 行目から「2026/11/23,勤労感謝の日」の形 (月と日はゼロ埋めしない)。
/// 取れず、キャッシュも無いときは祝日が無いものとして扱う (曜日だけで色を決める)。
struct Holidays {
    static let url = "https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv"

    /// 祝日・休日の日付 ("2026-11-23" の形)
    let dates: Set<String>

    /// その日 ("2026-11-23" の形) が祝日・休日か
    func contains(_ date: String) -> Bool { dates.contains(date) }

    /// 古ければ取り直してから読む
    static func load(cache: CacheFolder, client: JMAClient) async -> Holidays {
        let file = cache.constant("syukujitsu.csv")
        if !CacheFolder.isFresh(file, maxAge: 7 * 86400) {
            await client.download(url, to: file)
        }
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .shiftJIS) else { return Holidays(dates: []) }
        return Holidays(dates: parse(text))
    }

    /// CSV から日付を取り出す。日付として読めない行 (見出しなど) は飛ばす
    static func parse(_ text: String) -> Set<String> {
        var dates: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let field = line.split(separator: ",").first else { continue }
            let parts = field.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            dates.insert(String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2]))
        }
        return dates
    }
}
