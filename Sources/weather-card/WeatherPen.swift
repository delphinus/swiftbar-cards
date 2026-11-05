import AppKit
#if canImport(Shared)
import Shared
#endif

/// カードの色。weather.10m.sh が外観に合わせて選んだ色 ("#RRGGBB") もここで NSColor にする。
struct CardColors {
    let dark: Bool
    let primary: NSColor
    let secondary: NSColor
    /// グラフの目盛りの線
    let grid: NSColor
    /// 節の間の区切り線
    let rule: NSColor

    // 明るい外観の色は、背後が透けて灰色に見えるポップアップでも読めるように濃くする
    // (sysmon の CardColors に経緯を書いた)
    init(dark: Bool) {
        self.dark = dark
        primary = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.05, alpha: 1)
        secondary = dark ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.2, alpha: 1)
        grid = dark ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.16)
        rule = dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.22)
    }

    /// 雨の量と土曜日の青
    var blue: NSColor { NSColor(hex: dark ? "#64B5FF" : "#0047B3")! }
    /// 日曜日の赤
    var red: NSColor { NSColor(hex: dark ? "#FF6961" : "#A3000F")! }

    /// JSON で渡された色。無ければ (空文字列や null なら) 標準の文字色
    func color(_ hex: String?) -> NSColor {
        NSColor(hex: hex) ?? primary
    }
}

/// カードに描く。描画先と色を持ち、文字・アイコン・線を描く。
struct WeatherPen {
    let context: CGContext
    let colors: CardColors

    /// 文字を、y を上端として描き、描いた大きさを返す。数字は等幅の数字 (tabular figures)
    /// にする。`align` が `.right` なら x は右端、`.center` なら中央。
    @discardableResult
    func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor? = nil,
              weight: NSFont.Weight = .regular, align: NSTextAlignment = .left) -> CGSize {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let text = Typesetting.attributedString(string, font: font, color: color ?? colors.primary, size: size, weight: weight)
        let textSize = text.size()
        let dx: CGFloat = switch align {
        case .center: -textSize.width / 2
        case .right: -textSize.width
        default: 0
        }
        text.draw(at: CGPoint(x: x + dx, y: y))
        return textSize
    }

    /// 幅を決めて折り返して描く文。高さは `Self.wrappedTextHeight` で測れる。
    func wrappedText(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat) {
        Self.wrappedString(string, size: size, color: colors.primary)
            .draw(with: CGRect(x: x, y: y, width: width, height: .greatestFiniteMagnitude),
                  options: [.usesLineFragmentOrigin])
    }

    /// `wrappedText` で描いたときの高さ。描く前に、行の高さを決めるのに使う
    static func wrappedTextHeight(_ string: String, width: CGFloat, size: CGFloat) -> CGFloat {
        // 色は大きさに関係しないので、何でもよい
        wrappedString(string, size: size, color: .black)
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            .height
    }

    private static func wrappedString(_ string: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let text = NSMutableAttributedString(attributedString:
            Typesetting.attributedString(string, font: font, color: color, size: size, weight: .regular))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// SF Symbols のアイコンを、中心が (cx, cy) に来るよう描く
    func symbol(_ name: String, color: NSColor, cx: CGFloat, cy: CGFloat, size: CGFloat) {
        NSImage.symbol(name, pointSize: size, color: color)?.drawUpright(centeredAt: CGPoint(x: cx, y: cy))
    }

    /// 横線 (区切り線やグラフの目盛り)
    func horizontalLine(y: CGFloat, from x0: CGFloat, to x1: CGFloat, color: NSColor) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [])
        context.move(to: CGPoint(x: x0, y: y))
        context.addLine(to: CGPoint(x: x1, y: y))
        context.strokePath()
    }
}

/// 曜日の名前 (0 が日曜)
func weekdayName(_ dayOfWeek: Int) -> String {
    let i = (dayOfWeek % 7 + 7) % 7
    return L(["日", "月", "火", "水", "木", "金", "土"][i], ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][i])
}
