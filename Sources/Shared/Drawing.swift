import AppKit

public extension NSColor {
    /// 0xRRGGBB の形の数で色を作る。例: `NSColor(rgb: 0x30D158)`
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255,
                  green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255,
                  alpha: 1)
    }

    /// "#RRGGBB" の形の文字列で色を作る。空文字列や nil なら nil を返す。
    convenience init?(hex: String?) {
        guard let hex, !hex.isEmpty else { return nil }
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(rgb: UInt32(truncatingIfNeeded: value))
    }
}

public extension NSImage {
    /// 大きさと色を指定した SF Symbols のアイコン。名前が無ければ nil。
    static func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// 上から下へ座標を取る描画先 (`PNGImage.draw`) に、上下を反転させずに描く
    func drawUpright(in rect: CGRect) {
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// 中心が `center` に来るように描く
    func drawUpright(centeredAt center: CGPoint) {
        drawUpright(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                               width: size.width, height: size.height))
    }
}

public extension CGContext {
    /// 角を丸めた四角を塗る
    func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor) {
        setFillColor(color.cgColor)
        addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        fillPath()
    }
}

/// 文字列を 1 行で描いたときの幅
public func textWidth(_ string: String, font: NSFont) -> CGFloat {
    NSAttributedString(string: string, attributes: [.font: font]).size().width
}

/// 小数点以下の桁数を決めて数を文字にする。例: `formatted(23.45, digits: 1)` は "23.5"
public func formatted(_ value: Double, digits: Int = 0) -> String {
    String(format: "%.\(digits)f", value)
}
