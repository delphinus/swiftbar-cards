import AppKit
#if canImport(Shared)
import Shared
#endif

/// カードの色。WeatherStyle が外観に合わせて選んだ色 ("#RRGGBB") もここで NSColor にする。
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

    /// 曜日の文字の色。日曜と祝日・休日は赤、土曜は青、ほかは控えめな文字色 (0 が日曜)。
    /// 土曜の祝日も赤にする (カレンダーの多くと同じ)
    func weekday(_ dayOfWeek: Int, holiday: Bool) -> NSColor {
        if holiday { return red }
        return switch (dayOfWeek % 7 + 7) % 7 {
        case 6: blue
        case 0: red
        default: secondary
        }
    }

    /// WeatherStyle で選んだ色。無ければ (空文字列や null なら) 標準の文字色
    func color(_ hex: String?) -> NSColor {
        NSColor(hex: hex) ?? primary
    }
}

/// カードに描く。描画先と色を持ち、文字・アイコン・線を描く。
struct WeatherPen {
    let context: CGContext
    let colors: CardColors

    /// 文字を、y を上端として描き、描いた大きさを返す。数字の字形は `digits` で選ぶ
    /// (Typography.swift)。`align` が `.right` なら x は右端、`.center` なら中央。
    @discardableResult
    func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor? = nil,
              weight: NSFont.Weight = .regular, digits: Digits = .proportional,
              align: NSTextAlignment = .left) -> CGSize {
        drawCardText(string, x: x, y: y, font: .card(size: size, weight: weight, digits: digits),
                     color: color ?? colors.primary, align: align)
    }

    /// 色の違う文字列をつないで 1 行に描く (Typography.swift の drawCardText)
    @discardableResult
    func text(_ pieces: [(String, NSColor)], x: CGFloat, y: CGFloat, size: CGFloat,
              digits: Digits = .proportional) -> CGSize {
        drawCardText(pieces, x: x, y: y, font: .card(size: size, digits: digits))
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
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.card(size: size), .foregroundColor: color, .paragraphStyle: style,
        ])
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
