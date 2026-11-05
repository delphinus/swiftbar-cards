import AppKit

// 日本語の文の組み方。括弧の字形と、予報の文の折り返し位置を整える。

enum Typesetting {
    /// 和文の中の括弧は、全角の括弧にしてヒラギノ角ゴシックの palt (プロポーショナル
    /// メトリクス) で描く。半角の括弧は欧文の字形で、基準線の下まで伸びる位置にある
    /// ので、和文の中に置くと括弧が下にずれて見える。日本語の組版では、括弧を全角に
    /// するか半角にするかは中身ではなく置かれた文で決める (JIS X 4051、日本語組版処理の
    /// 要件)。そこで、括弧の直前が和字か、括弧の中に和字を含むなら全角にし、前の空白は
    /// 消す (全角の括弧は字形に空きを含む)。前後も中身も英数字だけなら半角のままにする。
    static func attributedString(_ string: String, font: NSFont, color: NSColor,
                                 size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        let ns = string as NSString
        let result = NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let parenthesisFont = hiragino(size, weight)
        // 後ろから置き換える (前から置き換えると、後ろの一致の位置がずれる)
        for match in parenthesisPattern.matches(in: string, range: NSRange(location: 0, length: ns.length)).reversed() {
            let inner = ns.substring(with: match.range(at: 2))
            // 括弧 (と前の空白) の直前の文字
            let before = match.range.location > 0
                ? ns.substring(with: NSRange(location: match.range.location - 1, length: 1)) : ""
            guard inner.contains(where: isWaji) || before.contains(where: isWaji) else { continue }

            let replacement = NSMutableAttributedString(string: "（", attributes: [.font: parenthesisFont, .foregroundColor: color])
            replacement.append(NSAttributedString(string: inner, attributes: [.font: font, .foregroundColor: color]))
            replacement.append(NSAttributedString(string: "）", attributes: [.font: parenthesisFont, .foregroundColor: color]))
            // 前の空白も含めて置き換える (match.range は空白から閉じ括弧まで)
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result
    }

    /// 前に空白があってもよい半角の括弧の組。1 つめの組が空白、2 つめの組が中身
    private static let parenthesisPattern = try! NSRegularExpression(pattern: "( ?)\\(([^()]*)\\)")

    /// 和字 (全角の文字) か
    private static func isWaji(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3000...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
        }
    }

    /// ヒラギノ角ゴシックを palt を有効にして使う。無ければシステムのフォント
    private static func hiragino(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let suffix = switch weight {
        case .light: "W2"
        case .medium: "W5"
        case .semibold: "W6"
        case .bold: "W7"
        default: "W3"
        }
        let palt: [NSFontDescriptor.FeatureKey: Any] = [
            NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureTag as String): "palt",
            NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureValue as String): 1,
        ]
        let descriptor = NSFontDescriptor(name: "HiraginoSans-\(suffix)", size: size)
            .addingAttributes([.featureSettings: [palt]])
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

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
