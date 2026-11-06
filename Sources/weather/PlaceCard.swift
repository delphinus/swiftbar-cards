import Foundation

/// 地点ごとに描いたメニューの行。キャッシュのファイル (`CacheFolder.card`) に 4 行で書く。
/// 1 行目がメニューバーの行、2 行目がカードの行、3 行目がカードの本来の高さ (下を
/// 空ける前)、4 行目が地点の切り替えの項目に添える行 (1 行目と同じ中身を、メニューの
/// 地に合わせた色で書いたもの)。
///
/// ファイルに置くのは、地点を切り替えたときに取り直しを待たずに出すためと、高さを
/// そろえる元にするため。SwiftBar を起動し直したときも、すぐにカードを出せる。
struct PlaceCard {
    let menuBarLine: String
    let cardLine: String
    let naturalHeight: Int
    let menuItemSummary: String

    static func read(_ file: URL) -> PlaceCard? {
        guard let text = CacheFolder.readText(file) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 3, !lines[0].isEmpty else { return nil }
        return PlaceCard(menuBarLine: lines[0], cardLine: lines[1], naturalHeight: Int(lines[2]) ?? 0,
                         menuItemSummary: lines.count >= 4 ? lines[3] : "")
    }

    func write(to file: URL) {
        CacheFolder.writeText([menuBarLine, cardLine, String(naturalHeight), menuItemSummary].joined(separator: "\n") + "\n",
                              to: file)
    }
}
