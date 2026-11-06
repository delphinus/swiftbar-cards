import AppKit

// 気象庁の予報の文の折り返し位置を整える。文字のフォントと括弧の扱いは、
// ほかのプラグインと共通の Shared/Typography.swift に従う。

enum Typesetting {
    /// 気象庁の予報の文は「晴れ　明け方　まで　くもり」のように全角の空白で語を
    /// 区切って配られる。空白は詰めて描き、折り返しは語の間でだけ起きるようにする
    /// (語の中の字の間に U+2060 WORD JOINER、語の間に U+200B ZERO WIDTH SPACE を
    /// 置く)。字の間のどこでも折り返すと、「雷を伴」と「う」に分かれたりする。
    /// 助詞で始まる語 (まで・で・から・を など) は前の語につなげ、手前で折らない。
    /// 英語の天気の名前のように全角の空白を含まない文は、そのまま返す (普通に語の間で折り返す)。
    static func forecastPhrases(_ text: String) -> String {
        guard text.contains("　") else { return text }
        let particles = ["まで", "では", "で", "から", "を", "に", "の", "より"]
        var words: [String] = []
        for word in text.split(separator: "　").map(String.init) {
            if let last = words.last, particles.contains(where: { word.hasPrefix($0) }) {
                words[words.count - 1] = last + word
            } else {
                words.append(word)
            }
        }
        return words
            .map { word in word.map(String.init).joined(separator: "\u{2060}") }
            .joined(separator: "\u{200B}")
    }
}
