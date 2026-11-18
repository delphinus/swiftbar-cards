// README 用に、メニューバーの項目の通常表示と縮小表示を並べた絵を組む。
//   swift samples/density.swift <light|dark> <出力の PNG> <通常表示の見出し> <縮小表示の見出し> \
//       <プラグインの名前> <通常表示の PNG> <縮小表示の PNG> [...]
// プラグインごとに 1 行で、左に名前、その右に通常表示と縮小表示の項目を、それぞれ
// メニューバーの帯に載せて並べる。帯の外は透明にする (README の地の色に任せる)。
import AppKit

let a = CommandLine.arguments
guard a.count >= 8, (a.count - 5) % 3 == 0 else {
    FileHandle.standardError.write("usage: density.swift <light|dark> <出力> <見出し> <見出し> <名前> <PNG> <PNG> [...]\n".data(using: .utf8)!)
    exit(2)
}
let dark = a[1] == "dark"

/// 2 倍で描いた PNG と、pt の大きさ
func load(_ path: String) -> (NSImage, CGSize) {
    let img = NSImage(contentsOfFile: path)!
    let px = img.representations[0]
    return (img, CGSize(width: CGFloat(px.pixelsWide) / 2, height: CGFloat(px.pixelsHigh) / 2))
}
let rows: [(name: String, full: (NSImage, CGSize), compact: (NSImage, CGSize))] =
    stride(from: 5, to: a.count, by: 3).map { (a[$0], load(a[$0 + 1]), load(a[$0 + 2])) }

let fg = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.1, alpha: 1)
let sub = dark ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.4, alpha: 1)
let barBG = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
let nameFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
let headFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
}

let barH: CGFloat = 26, barPad: CGFloat = 10, gap: CGFloat = 16, rowGap: CGFloat = 10, headH: CGFloat = 22
let names = rows.map { text($0.name, nameFont, sub) }
let heads = [text(a[3], headFont, fg), text(a[4], headFont, fg)]
let nameW = ceil(names.map { $0.size().width }.max() ?? 0)
// 列の幅は、その列でいちばん広い帯 (と見出し) に合わせる
let fullW = max(ceil(heads[0].size().width), rows.map { $0.full.1.width + barPad * 2 }.max() ?? 0)
let compactW = max(ceil(heads[1].size().width), rows.map { $0.compact.1.width + barPad * 2 }.max() ?? 0)
/// 外周の余白 (縁で文字や帯が切れて見えないように)
let margin: CGFloat = 4
let width = margin + nameW + gap + fullW + gap + compactW + margin
let height = margin + headH + CGFloat(rows.count) * barH + CGFloat(rows.count - 1) * rowGap + margin
let fullX = margin + nameW + gap, compactX = fullX + fullW + gap
let scale: CGFloat = 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * scale)), pixelsHigh: Int(ceil(height * scale)),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
cg.translateBy(x: 0, y: height)
cg.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

heads[0].draw(at: CGPoint(x: fullX, y: margin))
heads[1].draw(at: CGPoint(x: compactX, y: margin))
for (i, row) in rows.enumerated() {
    let y = margin + headH + CGFloat(i) * (barH + rowGap)
    let name = names[i]
    name.draw(at: CGPoint(x: margin + nameW - name.size().width, y: y + (barH - name.size().height) / 2))
    for (x, (image, size)) in [(fullX, row.full), (compactX, row.compact)] {
        // 帯は項目の幅に合わせる (縮んだ分が帯の長さで分かるように)
        let bar = CGRect(x: x, y: y, width: size.width + barPad * 2, height: barH)
        cg.setFillColor(barBG.cgColor)
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: 6, cornerHeight: 6, transform: nil))
        cg.fillPath()
        image.draw(in: CGRect(x: x + barPad, y: y + (barH - size.height) / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
