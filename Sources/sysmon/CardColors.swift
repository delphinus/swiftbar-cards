import AppKit
#if canImport(Shared)
import Shared
#endif

/// カードの色。
///
/// 明るい外観の色は、灰色に見えるポップアップでも読めるように濃くする。macOS 26 の
/// ポップアップは背後 (壁紙) が透けるので、暗い壁紙だとライトモードでも #9096A6
/// 前後の灰色になる。白地を前提にした薄い色では、地との差が 1.1〜1.8:1 しかなかった。
struct CardColors {
    let primary: NSColor
    let secondary: NSColor
    /// メーターの溝とグラフの目盛り
    let track: NSColor
    /// 節の間の区切り線
    let rule: NSColor
    let green: NSColor
    let yellow: NSColor
    let red: NSColor

    init(dark: Bool) {
        primary = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.05, alpha: 1)
        secondary = dark ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.2, alpha: 1)
        track = dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.16)
        rule = dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.22)
        green = NSColor(rgb: dark ? 0x30D158 : 0x146B2C)
        yellow = NSColor(rgb: dark ? 0xFFD60A : 0x7A5000)
        red = NSColor(rgb: dark ? 0xFF453A : 0xA3000F)
    }

    /// 値に応じた色。`warning` 以上で黄、`critical` 以上で赤、それ未満は緑。
    func level(_ value: Double, warning: Double, critical: Double) -> NSColor {
        if value >= critical { return red }
        if value >= warning { return yellow }
        return green
    }
}
