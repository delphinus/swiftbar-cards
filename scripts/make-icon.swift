// Sources/menubar/AppIcon.icns を描く。アイコンを変えるときだけ手で動かし、できた
// .icns をコミットする (プラグインがビルドするときには動かさない)。
//
//   swift scripts/make-icon.swift Sources/menubar/AppIcon.icns
//
// 角を丸めた青い地に、白でメニューバーの記号 (SF Symbols の menubar.rectangle) を描く。
// システム設定の一覧 (デバイスの制御とデータへのアクセス) で、何のアプリか分かるように。

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <出力の .icns>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let size = CGFloat(pixels)
    // macOS のアイコンの格子: 1024 の中に 824 の角丸の四角を置く
    let inset = size * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0.27, green: 0.62, blue: 1.0, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.36, blue: 0.85, alpha: 1))!.draw(in: shape, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: body.width * 0.5, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let s = symbol.size
        symbol.draw(in: CGRect(x: body.midX - s.width / 2, y: body.midY - s.height / 2, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

// iconutil に渡す .iconset を一時ディレクトリに作る
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try draw(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try draw(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
