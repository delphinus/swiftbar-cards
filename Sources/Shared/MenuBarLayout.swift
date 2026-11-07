import AppKit

/// メニューバーに出す画像の高さと、その中で文字・アイコン・図形を置く高さ。sysmon と
/// nowplaying が使う。
///
/// 高さは文字に合わせる。文字は画像の真ん中から 1pt 持ち上げる (真ん中に置くと、
/// メニューバーのほかの文字 (天気や時計) より 1pt 下に見えた。メニューバーを撮った
/// 画像で数字の上下端を測った)。アイコンは文字の中に置いたときと同じく、ベースラインに
/// 乗せる (SF Symbols の alignmentRect は、ベースラインから大文字の高さまでの枠)。
/// グラフや棒のような図形は、数字の中心 (ベースラインから大文字の高さの半分の位置) に
/// 置く。アイコンを画像の真ん中に置くと、文字より 0.75pt ほど下に出て、隣の数字と段差が
/// できた。weather の項目も、アイコンを文字に埋め込んで同じ高さに並べている。
public enum MenuBarLayout {
    /// 画像の高さ
    public static let height: CGFloat = 22
    /// 文字のフォント
    public static let font = NSFont.card(size: 13, digits: .tabular)
    /// SF Symbols のアイコンの大きさ。文字と同じ 13pt
    public static let iconPointSize: CGFloat = 13
    /// 文字を真ん中から持ち上げる量
    private static let textRaise: CGFloat = 1

    /// 文字の上端。どの文字も同じフォントなので、行の高さは文字列によらない
    public static var textTop: CGFloat {
        (height - NSAttributedString(string: "0", attributes: [.font: font]).size().height) / 2 - textRaise
    }
    /// 文字のベースライン
    public static var baseline: CGFloat { textTop + font.ascender }
    /// 数字の中心。グラフや棒はここを中心に置く
    public static var midline: CGFloat { baseline - font.capHeight / 2 }

    /// アイコンを、文字の中に置いたときと同じくベースラインに乗せる枠
    public static func iconRect(_ icon: NSImage, x: CGFloat) -> CGRect {
        // alignmentRect は下から上へ取った座標。minY がベースラインの位置
        CGRect(x: x, y: baseline + icon.alignmentRect.minY - icon.size.height,
               width: icon.size.width, height: icon.size.height)
    }
}
