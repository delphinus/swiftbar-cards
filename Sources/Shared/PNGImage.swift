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

    /// `--render` で画像をファイルに書き出すときに使う
    public func write(to directory: URL, name: String) throws {
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
