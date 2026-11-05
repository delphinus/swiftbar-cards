// README 用に、メニューバーの項目とカードを、メニューを開いたときの見た目に組む。
//   swift samples/compose.swift <light|dark> <メニューバー> <カードの PNG> <出力の PNG> [項目 ...]
// メニューバーは PNG のパスか、「text:」に続けて SwiftBar の行 (weather のように
// :symbol: を埋め込んだ文字と sfcolor=明るい用,暗い用) を渡す。
// 項目は「SF Symbols の名前:文字」の形で、カードの下に並べる。末尾に「:checked」を
// 付けるとチェックマークを付ける。「-」だけの項目は区切り線にする。
// 実物の見た目を写し取るものではなく、カードがどう使われるかを伝えるための絵。
import AppKit

let a = CommandLine.arguments
let dark = a[1] == "dark"
func load(_ path: String) -> (NSImage, CGSize) {
    let img = NSImage(contentsOfFile: path)!
    let px = img.representations[0]
    return (img, CGSize(width: CGFloat(px.pixelsWide) / 2, height: CGFloat(px.pixelsHigh) / 2))
}
let (card, cardSize) = load(a[3])
let items: [(symbol: String, label: String, checked: Bool)] = a.dropFirst(5).map {
    if $0 == "-" { return ("-", "", false) }
    var p = $0.split(separator: ":").map(String.init)
    let checked = p.count > 2 && p.last == "checked"
    if checked { p.removeLast() }
    return (p[0], p.dropFirst().joined(separator: ":"), checked)
}

let fg = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.1, alpha: 1)

// メニューバーの項目。文字の行なら、:symbol: をアイコンにして 1 枚の文字列にする。
func hex(_ s: String) -> NSColor {
    let v = UInt32(s.dropFirst(), radix: 16) ?? 0
    return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
func barText(_ line: String) -> NSAttributedString {
    let parts = line.components(separatedBy: " | ")
    var colors: [Int: NSColor] = [:]
    for kv in (parts.count > 1 ? parts[1] : "").split(separator: " ") {
        let f = kv.split(separator: "=", maxSplits: 1).map(String.init)
        guard f.count == 2, f[0].hasPrefix("sfcolor") else { continue }
        let n = Int(f[0].dropFirst("sfcolor".count)) ?? 1
        let pair = f[1].split(separator: ",").map(String.init)
        colors[n] = hex(dark && pair.count > 1 ? pair[1] : pair[0])
    }
    let font = NSFont.systemFont(ofSize: 13)
    let barFG = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
    let out = NSMutableAttributedString()
    var n = 0
    for (i, piece) in parts[0].components(separatedBy: ":").enumerated() {
        if i % 2 == 1, let img = NSImage(systemSymbolName: piece, accessibilityDescription: nil) {
            n += 1
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [colors[n] ?? barFG]))
            let att = NSTextAttachment()
            att.image = img.withSymbolConfiguration(cfg)
            out.append(NSAttributedString(attachment: att))
        } else {
            out.append(NSAttributedString(string: piece, attributes: [.font: font, .foregroundColor: barFG]))
        }
    }
    return out
}
let barLine = a[2].hasPrefix("text:") ? barText(String(a[2].dropFirst(5))) : nil
let barImage = barLine == nil ? load(a[2]) : nil
let barSize = barLine.map { CGSize(width: ceil($0.size().width), height: ceil($0.size().height)) } ?? barImage!.1
let barBG = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
let selected = dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.09)
let popBG = dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.94, alpha: 1)
let border = dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)
let rule = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.1)

let margin: CGFloat = 24, barH: CGFloat = 26, popPad: CGFloat = 14, rowH: CGFloat = 24
// SwiftBar (macOS 26) は画像の項目の後ろに空白を足すので、画像の右に約 10pt 空く
// (カードの画像は、その分の透明な幅を左に持っている。PNGImage.cardLeadingSpace)
let imageTrailing: CGFloat = 10
let popW = cardSize.width + imageTrailing + popPad * 2
let contentW = popW - popPad * 2
let sepH: CGFloat = 11
let itemsH = items.isEmpty ? 0 : 9 + items.reduce(0) { $0 + ($1.symbol == "-" ? sepH : rowH) } + 4
let popH = popPad + cardSize.height + 12 + itemsH
let popX = margin, popY = barH + 6
let width = popW + margin * 2
let height = popY + popH + margin
let scale: CGFloat = 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
cg.translateBy(x: 0, y: height)
cg.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

// テンプレートの画像を 1 色で塗る (透けている部分は透けたまま)
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// メニューバー (帯) と、開いている項目の背景
cg.setFillColor(barBG.cgColor)
cg.fill(CGRect(x: 0, y: 0, width: width, height: barH))
let barX = popX + 8
cg.setFillColor(selected.cgColor)
cg.addPath(rounded(CGRect(x: barX - 7, y: 2, width: barSize.width + 14, height: barH - 4), (barH - 4) / 2))
cg.fillPath()
if let barLine {
    barLine.draw(at: CGPoint(x: barX, y: (barH - barSize.height) / 2))
} else {
    barImage!.0.draw(in: CGRect(x: barX, y: (barH - barSize.height) / 2, width: barSize.width, height: barSize.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

// ポップアップ
let pop = CGRect(x: popX, y: popY, width: popW, height: popH)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: NSColor(white: 0, alpha: dark ? 0.5 : 0.22).cgColor)
cg.setFillColor(popBG.cgColor)
cg.addPath(rounded(pop, 14))
cg.fillPath()
cg.restoreGState()
cg.setStrokeColor(border.cgColor)
cg.setLineWidth(1)
cg.addPath(rounded(pop.insetBy(dx: 0.5, dy: 0.5), 14))
cg.strokePath()

card.draw(in: CGRect(x: popX + popPad, y: popY + popPad, width: cardSize.width, height: cardSize.height),
          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

// 操作の項目
if !items.isEmpty {
    var y = popY + popPad + cardSize.height + 12
    cg.setFillColor(rule.cgColor)
    cg.fill(CGRect(x: popX + popPad, y: y, width: contentW, height: 1))
    y += 9
    for (sym, label, checked) in items {
        if sym == "-" {
            cg.setFillColor(rule.cgColor)
            cg.fill(CGRect(x: popX + popPad, y: y + sepH / 2, width: contentW, height: 1))
            y += sepH
            continue
        }
        if checked {
            let ccfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [fg]))
            if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(ccfg) {
                let s = img.size
                img.draw(in: CGRect(x: popX + popPad - s.width / 2 - 2, y: y + (rowH - s.height) / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        // メニューの sfimage と同じく 1 色の型 (テンプレート) として描く。パレットの色で描くと、
        // mappin.circle.fill の中のピンまで同じ色になり、ただの丸に見える。
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(cfg).map({ tinted($0, fg) }) {
            let s = img.size
            img.draw(in: CGRect(x: popX + popPad + 8 - s.width / 2 + 7, y: y + (rowH - s.height) / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let str = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: fg])
        str.draw(at: CGPoint(x: popX + popPad + 30, y: y + (rowH - str.size().height) / 2))
        y += rowH
    }
}

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[4]))
