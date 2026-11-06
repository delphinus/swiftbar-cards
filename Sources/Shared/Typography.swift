import AppKit

// カードの文字の組み方。どのプラグインもここを通して文字を描き、Apple の純正アプリと
// 同じ組み方にそろえる。
//
// - フォントはシステムのフォント (SF Pro) だけを指定し、和字は OS のフォールバックに
//   任せる。和字には UI 用のヒラギノ (.HiraKakuInterface) が当たり、太さも OS が
//   合わせる。フォントの名前を指定しない (HiraginoSans-W3 などを指定すると、括弧の
//   空きや太さが純正アプリと違ってしまう)。
// - 括弧などの約物は、文字列を書くときに決める。日本語の文には全角の「（）」を、
//   英語の文には半角の「()」を書く。描くときに書き換えない。曲名や機器の名前の
//   ような外から来た文字列も、そのまま描く。
// - 数字は、縦に並ぶ所と値がその場で変わる所だけ等幅の数字にする (`Digits`)。

/// 数字の字形
public enum Digits {
    /// 字ごとに幅が違う数字 (SF Pro の普段の数字)。文の中の数字や見出しに使う
    case proportional
    /// 0〜9 がすべて同じ幅の数字 (tabular figures)。数字が縦に並んで桁をそろえたい所と、
    /// 値が変わっても幅を変えたくない所 (使用率・残り時間など) に使う。「1」の両側が
    /// 空くので、それ以外では使わない
    case tabular
}

public extension NSFont {
    /// カードの文字のフォント
    static func card(size: CGFloat, weight: Weight = .regular, digits: Digits = .proportional) -> NSFont {
        switch digits {
        case .proportional: systemFont(ofSize: size, weight: weight)
        case .tabular: monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
    }
}

/// 1 行の文字を、y を上端として描き、描いた大きさを返す。`align` が `.right` なら x は
/// 右端、`.center` なら中央。`maxWidth` を超える分は末尾を「…」で切る。
@discardableResult
public func drawCardText(_ string: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor,
                         align: NSTextAlignment = .left, maxWidth: CGFloat? = nil) -> CGSize {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    let text = NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: style,
    ])
    var textSize = text.size()
    if let maxWidth { textSize.width = min(textSize.width, maxWidth) }
    let dx: CGFloat = switch align {
    case .center: -textSize.width / 2
    case .right: -textSize.width
    default: 0
    }
    text.draw(with: CGRect(x: x + dx, y: y, width: textSize.width, height: textSize.height + 2),
              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    return textSize
}
