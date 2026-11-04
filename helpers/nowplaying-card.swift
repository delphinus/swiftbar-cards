// nowplaying.5s.sh が使う、再生中の曲のメニューバーの画像とカードを描くプログラム。
//
// 標準入力に JSON を受け取り、次の 5 行を書く。
//   1. メニューバーの画像の大きさ (pt) を「幅 高さ」で
//   2・3. 明るい / 暗いメニューバー用の PNG の Base64
//   4. カードの大きさ   5. カードの PNG の Base64
//
// メニューバー: アートワーク (角を丸める) と曲名。長い曲名は末尾を「…」で切る
// (ノッチの裏に隠れないように)。
// カード: 左にアートワーク、右に曲名・アーティスト・アルバム。下に再生位置のバーと
// 経過時間 / 曲の長さ。
//
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。nowplaying.5s.sh が初回にコンパイルする。

import AppKit

struct Input: Decodable {
    let dark: Bool
    let playing: Bool
    let name: String
    let artist: String
    let album: String
    let art: String       // アートワークの画像ファイルのパス (無ければ空)
    let position: Double? // 秒
    let duration: Double? // 秒
}

let data = FileHandle.standardInput.readDataToEndOfFile()
let input: Input
do {
    input = try JSONDecoder().decode(Input.self, from: data)
} catch {
    FileHandle.standardError.write("nowplaying-card: JSON を読めない: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let art = input.art.isEmpty ? nil : NSImage(contentsOfFile: input.art)
let scale: CGFloat = 2

// 上から下へ座標を取る (y は上端からの距離) 描画先を作り、body で描いて PNG にする
func render(_ w: CGFloat, _ h: CGFloat, _ body: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: h)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    body(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// 角を丸めたアートワーク。無ければ音符のアイコンを置いた四角を描く。
func drawArt(_ cg: CGContext, _ r: CGRect, radius: CGFloat, placeholder: NSColor, shadow: Bool) {
    if shadow {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: 0.35).cgColor)
        cg.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
        cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.fillPath()
        cg.restoreGState()
    }
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.clip()
    if let art {
        art.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    } else {
        cg.setFillColor(placeholder.withAlphaComponent(0.25).cgColor)
        cg.fill(r)
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height * 0.45, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [placeholder]))
        if let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = img.size
            img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
    cg.restoreGState()
}

// 文字を矩形の中に描く。はみ出す分は末尾を「…」で切る。
func draw(_ s: String, in r: CGRect, font: NSFont, color: NSColor, lines: Int = 1) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    str.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

// 1. メニューバー: アートワーク (18pt) と曲名。曲名は 220pt で切る。
let barH: CGFloat = 22
let barFont = NSFont.systemFont(ofSize: 13)
let titleMax: CGFloat = 220
let titleW = min(ceil(NSAttributedString(string: input.name, attributes: [.font: barFont]).size().width), titleMax)
let barW = 18 + 5 + titleW + 1
func bar(dark: Bool) -> Data {
    let fg = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
    return render(barW, barH) { cg in
        drawArt(cg, CGRect(x: 0, y: (barH - 18) / 2, width: 18, height: 18), radius: 3, placeholder: fg, shadow: false)
        let lineH = ceil(barFont.ascender - barFont.descender + barFont.leading)
        draw(input.name, in: CGRect(x: 23, y: (barH - lineH) / 2, width: titleW, height: lineH), font: barFont, color: fg)
    }
}

// 2. カード: 左にアートワーク (96pt)、右に曲名 (2 行まで)・アーティスト・アルバム、下に再生位置
let cardW: CGFloat = 320
let artSize: CGFloat = 96
let hasProgress = (input.duration ?? 0) > 0
let cardH: CGFloat = artSize + (hasProgress ? 34 : 4)
let card = render(cardW, cardH) { cg in
    let fg = input.dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    let sub = input.dark ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.42, alpha: 1)
    let track = input.dark ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 0, alpha: 0.12)
    drawArt(cg, CGRect(x: 2, y: 2, width: artSize, height: artSize), radius: 8, placeholder: sub, shadow: true)
    let tx: CGFloat = artSize + 16, tw = cardW - tx - 2
    let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    let titleRect = CGRect(x: tx, y: 6, width: tw, height: 40)
    draw(input.name, in: titleRect, font: titleFont, color: fg, lines: 2)
    // 曲名が 1 行に収まるときは、アーティストとアルバムを上に詰める
    let titleH = NSAttributedString(string: input.name, attributes: [.font: titleFont])
        .boundingRect(with: CGSize(width: tw, height: 40), options: [.usesLineFragmentOrigin]).height
    var y = 6 + min(ceil(titleH), 40) + 6
    draw(input.artist, in: CGRect(x: tx, y: y, width: tw, height: 18), font: .systemFont(ofSize: 13), color: fg)
    y += 19
    if !input.album.isEmpty {
        draw(input.album, in: CGRect(x: tx, y: y, width: tw, height: 18), font: .systemFont(ofSize: 12), color: sub)
    }
    if !input.playing {
        draw("一時停止中", in: CGRect(x: tx, y: artSize - 14, width: tw, height: 16), font: .systemFont(ofSize: 11), color: sub)
    }
    if hasProgress, let dur = input.duration {
        let pos = min(max(input.position ?? 0, 0), dur)
        let by = artSize + 14
        let r = CGRect(x: 2, y: by, width: cardW - 4, height: 4)
        cg.setFillColor(track.cgColor)
        cg.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
        cg.fillPath()
        cg.setFillColor(fg.cgColor)
        cg.addPath(CGPath(roundedRect: CGRect(x: r.minX, y: r.minY, width: max(4, r.width * CGFloat(pos / dur)), height: 4),
                          cornerWidth: 2, cornerHeight: 2, transform: nil))
        cg.fillPath()
        func mmss(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        let tf = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        draw(mmss(pos), in: CGRect(x: 2, y: by + 6, width: 60, height: 14), font: tf, color: sub)
        let rest = NSAttributedString(string: "-" + mmss(dur - pos), attributes: [.font: tf])
        let rw = ceil(rest.size().width)
        draw("-" + mmss(dur - pos), in: CGRect(x: cardW - 2 - rw, y: by + 6, width: rw + 1, height: 14), font: tf, color: sub)
    }
}

let light = bar(dark: false), dark = bar(dark: true)
print("\(Int(ceil(barW))) \(Int(barH))")
print(light.base64EncodedString())
print(dark.base64EncodedString())
print("\(Int(cardW)) \(Int(cardH))")
print(card.base64EncodedString())
