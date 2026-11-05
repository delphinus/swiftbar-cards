import AppKit
#if canImport(Shared)
import Shared
#endif

/// カードに描く。描画先と色を持ち、文字・メーター・区切り線を描く。
struct Pen {
    let context: CGContext
    let colors: CardColors

    /// 文字を、y を上端として描き、描いた大きさを返す。数字は等幅の数字 (tabular figures)
    /// にする。`align` が `.right` なら x は右端、`.center` なら中央。`maxWidth` を
    /// 超える分は末尾を「…」で切る。
    ///
    /// `@discardableResult` は、戻り値を使わなくても警告を出さないという印。
    @discardableResult
    func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor? = nil,
              weight: NSFont.Weight = .regular, align: NSTextAlignment = .left, maxWidth: CGFloat? = nil) -> CGSize {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color ?? colors.primary, .paragraphStyle: style,
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

    /// 横棒のメーター。0〜100 の値を、角の丸い溝の上に色の棒で描く。
    func meter(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 6, value: Double, color: NSColor) {
        let radius = height / 2
        context.fillRoundedRect(CGRect(x: x, y: y, width: width, height: height), radius: radius, color: colors.track)
        guard value > 0 else { return }
        // 値が小さくても、丸い端の分 (高さと同じ幅) は描く
        let filledWidth = max(height, width * CGFloat(min(max(value, 0), 100) / 100))
        context.fillRoundedRect(CGRect(x: x, y: y, width: filledWidth, height: height), radius: radius, color: color)
    }

    /// 節の間の区切り線
    func horizontalRule(y: CGFloat, from x0: CGFloat, to x1: CGFloat) {
        context.setStrokeColor(colors.rule.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: x0, y: y))
        context.addLine(to: CGPoint(x: x1, y: y))
        context.strokePath()
    }
}

extension CGContext {
    /// 点を結ぶ折れ線と、その下 (`bottom` まで) の塗りつぶし。CPU の使用率の推移に使う。
    func drawFilledLine(through points: [CGPoint], bottom: CGFloat, color: NSColor,
                        fillAlpha: CGFloat, lineWidth: CGFloat) {
        guard let first = points.first, let last = points.last else { return }
        let line = CGMutablePath()
        line.addLines(between: points)

        let area = CGMutablePath()
        area.addPath(line)
        area.addLine(to: CGPoint(x: last.x, y: bottom))
        area.addLine(to: CGPoint(x: first.x, y: bottom))
        area.closeSubpath()
        addPath(area)
        setFillColor(color.withAlphaComponent(fillAlpha).cgColor)
        fillPath()

        addPath(line)
        setStrokeColor(color.cgColor)
        setLineWidth(lineWidth)
        setLineJoin(.round)
        strokePath()
    }
}
