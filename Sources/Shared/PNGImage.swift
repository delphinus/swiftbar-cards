import AppKit

/// 描いた画像 (PNG) と、その大きさ (pt)。画素はこの大きさの `scale` 倍になる。
public struct PNGImage {
    public let data: Data
    public let size: CGSize

    public var base64: String { data.base64EncodedString() }

    /// 幅と高さ (pt) を決めて描き、PNG にする。
    ///
    /// `draw` には描画先の `CGContext` が渡される。座標は上から下へ取る (y は上端からの
    /// 距離)。AppKit の文字や画像の描画 (`NSAttributedString.draw` など) も同じ向きで
    /// 描けるよう、`NSGraphicsContext.current` もこの描画先にしておく。
    public static func draw(width: CGFloat, height: CGFloat, scale: CGFloat = 2,
                            _ draw: (CGContext) -> Void) -> PNGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: width, height: height)
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        // Core Graphics の座標は下から上へ取るので、上下を反転する
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()

        let png = bitmap.representation(using: .png, properties: [:])!
        return PNGImage(data: png, size: CGSize(width: width, height: height))
    }

    /// メニューを開いたときに出すカードを描く。周りに `cardInset` の余白を取り、
    /// 半透明の角丸の地を敷いてから、余白の内側に `draw` で描く。`width` と `height` は
    /// 余白の内側の大きさで、画像はその分だけ大きくなる。
    ///
    /// macOS 26 のポップアップは背後が透けるので、背後のウィンドウや壁紙によって明るく
    /// も暗くも見える。メニューの文字は macOS がその場で色を変えるが、カードは開く前に
    /// 描いておく画像なので追従できない (ダークモードで背後が明るいと、白い文字が明るい
    /// 灰色の地に載って読めなかった)。地を敷いて、背後によらず文字が読めるようにする。
    ///
    /// 地の左には、透明な `cardLeadingSpace` を足す (地とメニューの縁の間を左右でそろえる)。
    public static func drawCard(width: CGFloat, height: CGFloat, dark: Bool,
                                _ draw: (CGContext) -> Void) -> PNGImage {
        let inset = cardInset
        let leading = cardLeadingSpace
        let panel = CGRect(x: leading, y: 0, width: width + inset * 2, height: height + inset * 2)
        return Self.draw(width: leading + panel.width, height: panel.height) { context in
            let background = dark ? NSColor(white: 0.1, alpha: 0.72) : NSColor(white: 1, alpha: 0.72)
            context.fillRoundedRect(panel, radius: cardCornerRadius, color: background)
            context.translateBy(x: panel.minX + inset, y: inset)
            draw(context)
        }
    }

    /// カードの地の、文字から縁までの余白
    public static let cardInset: CGFloat = 8
    public static let cardCornerRadius: CGFloat = 8

    /// カードの地の左に足す透明な幅。macOS 26 の SwiftBar は、画像の後ろに空白を 2 つ
    /// 足してから項目の文字を並べる (SwiftBar の MenuBarItem.swift の menuTitle)。カードの
    /// 行は文字が空なので空白だけが残り、地とメニューの縁の間が左 15pt・右 25pt になって
    /// いた (メニューを開いて撮った画像で測った)。左に差の 10pt を足してそろえる。
    /// macOS 15 までの SwiftBar は画像を NSMenuItem.image に入れるので、足さない。
    public static var cardLeadingSpace: CGFloat {
        if #available(macOS 26, *) { return 10 }
        return 0
    }

    /// `--render` で画像をファイルに書き出すときに使う
    public func write(to directory: URL, name: String) throws {
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
