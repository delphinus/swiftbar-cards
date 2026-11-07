import AppKit
#if canImport(Shared)
import Shared
#endif

/// 曲の情報から、メニューバーとカードの画像を描く
struct NowPlayingImages {
    let track: Track
    let artwork: NSImage?

    // MARK: - メニューバー

    /// メニューバーの曲名を切る幅
    static let menuBarTitleWidth: CGFloat = 220
    /// メニューバーのアートワークの右に足す余白
    static let menuBarArtworkGap: CGFloat = 3

    /// メニューバーのアートワーク (18pt)。曲名は画像に描かず、SwiftBar の文字として
    /// 並べる (SwiftBar.menuBarLine)。アートワークが無いときの音符は、明るい地にも
    /// 暗い地にも見える中間の灰色で描く。
    ///
    /// 右に透明な余白 (`menuBarArtworkGap`) を足す。画像と文字の間はメニューバーの
    /// ボタンが決める 3pt しか空かず、sysmon や weather のアイコンと数字の間 (5〜6pt)
    /// より狭く見えた。SwiftBar には大きさを整数の pt で渡すので、余白も整数にする
    /// (端数にすると、切り上げた幅に画像が引き伸ばされる)。
    func menuBarArtwork() -> PNGImage {
        let artSize: CGFloat = 18
        return PNGImage.draw(width: artSize + Self.menuBarArtworkGap, height: artSize) { context in
            drawArtwork(context, in: CGRect(x: 0, y: 0, width: artSize, height: artSize),
                        radius: 3, placeholderColor: NSColor(white: 0.55, alpha: 1), shadow: false)
        }
    }

    /// メニューバーの曲名。220pt を超える分は末尾を「…」にして切る。
    func menuBarTitle() -> String {
        let font = NSFont.menuBarFont(ofSize: 0)
        let name = track.name
        guard textWidth(name, font: font) > Self.menuBarTitleWidth else { return name }
        var characters = Array(name)
        while !characters.isEmpty, textWidth(String(characters) + "…", font: font) > Self.menuBarTitleWidth {
            characters.removeLast()
        }
        return String(characters).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// README とテスト用に、メニューバーの見た目 (アートワークと曲名) を 1 枚に描く。
    /// 実際のメニューバーでは、曲名は SwiftBar が文字として描く。
    func menuBarPreview(dark: Bool) -> PNGImage {
        let height: CGFloat = 22
        let artSize: CGFloat = 18
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = menuBarTitle()
        let titleWidth = ceil(textWidth(title, font: font))
        // アートワークと曲名の間は、メニューバーのボタンが空ける 3pt と、アートワークの
        // 画像の右の余白を足したもの
        let titleX = artSize + 3 + Self.menuBarArtworkGap
        let width = titleX + titleWidth + 1
        let color = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)

        return PNGImage.draw(width: width, height: height) { context in
            drawArtwork(context, in: CGRect(x: 0, y: (height - artSize) / 2, width: artSize, height: artSize),
                        radius: 3, placeholderColor: NSColor(white: 0.55, alpha: 1), shadow: false)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            drawText(title, in: CGRect(x: titleX, y: (height - lineHeight) / 2 - 1, width: titleWidth + 1, height: lineHeight),
                     font: font, color: color)
        }
    }

    // MARK: - カード

    /// カード: 左にアートワーク (96pt)、右に曲名 (2 行まで)・アーティスト・アルバム、下に再生位置
    func card(dark: Bool) -> PNGImage {
        let width: CGFloat = 320
        let artSize: CGFloat = 96
        let showsProgress = (track.duration ?? 0) > 0
        let height = artSize + (showsProgress ? 34 : 4)

        // 明るい外観の色は、背後が透けて灰色に見えるポップアップでも読めるように濃くする
        // (sysmon の CardColors に経緯を書いた)
        let primary = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.05, alpha: 1)
        let secondary = dark ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.2, alpha: 1)
        let progressTrack = dark ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 0, alpha: 0.18)

        return PNGImage.drawCard(width: width, height: height, dark: dark) { context in
            drawArtwork(context, in: CGRect(x: 2, y: 2, width: artSize, height: artSize),
                        radius: 8, placeholderColor: secondary, shadow: true)

            // 右側の文字
            let textX = artSize + 16
            let textAreaWidth = width - textX - 2
            let titleFont = NSFont.card(size: 15, weight: .semibold)
            drawText(track.name, in: CGRect(x: textX, y: 6, width: textAreaWidth, height: 40),
                     font: titleFont, color: primary, lines: 2)
            // 曲名が 1 行に収まるときは、アーティストとアルバムを上に詰める
            let titleHeight = NSAttributedString(string: track.name, attributes: [.font: titleFont])
                .boundingRect(with: CGSize(width: textAreaWidth, height: 40), options: [.usesLineFragmentOrigin]).height
            var y = 6 + min(ceil(titleHeight), 40) + 6
            drawText(track.artist, in: CGRect(x: textX, y: y, width: textAreaWidth, height: 18),
                     font: .card(size: 13), color: primary)
            y += 19
            if !track.album.isEmpty {
                drawText(track.album, in: CGRect(x: textX, y: y, width: textAreaWidth, height: 18),
                         font: .card(size: 12), color: secondary)
            }
            if !track.isPlaying {
                drawText(L("一時停止中", "Paused"), in: CGRect(x: textX, y: artSize - 14, width: textAreaWidth, height: 16),
                         font: .card(size: 11), color: secondary)
            }

            // 下の再生位置
            if showsProgress, let duration = track.duration {
                drawProgress(context, top: artSize + 14, width: width, duration: duration,
                             colors: (bar: primary, track: progressTrack, text: secondary))
            }
        }
    }

    /// 再生位置のバーと、経過時間・残り時間
    private func drawProgress(_ context: CGContext, top: CGFloat, width: CGFloat, duration: Double,
                              colors: (bar: NSColor, track: NSColor, text: NSColor)) {
        let position = min(max(track.position ?? 0, 0), duration)
        let bar = CGRect(x: 2, y: top, width: width - 4, height: 4)
        context.fillRoundedRect(bar, radius: 2, color: colors.track)
        let filled = CGRect(x: bar.minX, y: bar.minY, width: max(4, bar.width * CGFloat(position / duration)), height: 4)
        context.fillRoundedRect(filled, radius: 2, color: colors.bar)

        func minutesAndSeconds(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        let font = NSFont.card(size: 10, digits: .tabular)
        drawText(minutesAndSeconds(position), in: CGRect(x: 2, y: top + 6, width: 60, height: 14),
                 font: font, color: colors.text)
        let remaining = "-" + minutesAndSeconds(duration - position)
        let remainingWidth = ceil(textWidth(remaining, font: font))
        drawText(remaining, in: CGRect(x: width - 2 - remainingWidth, y: top + 6, width: remainingWidth + 1, height: 14),
                 font: font, color: colors.text)
    }

    // MARK: - アートワークと文字

    /// 角を丸めたアートワーク。無ければ音符のアイコンを置いた四角を描く。
    private func drawArtwork(_ context: CGContext, in rect: CGRect, radius: CGFloat,
                             placeholderColor: NSColor, shadow: Bool) {
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if shadow {
            // 影は、アートワークと同じ形の灰色の四角に付けて描く
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: 0.35).cgColor)
            context.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(shape)
        context.clip()
        if let artwork {
            artwork.drawUpright(in: rect)
        } else {
            context.setFillColor(placeholderColor.withAlphaComponent(0.25).cgColor)
            context.fill(rect)
            NSImage.symbol("music.note", pointSize: rect.height * 0.45, color: placeholderColor)?
                .drawUpright(centeredAt: CGPoint(x: rect.midX, y: rect.midY))
        }
        context.restoreGState()
    }

    /// 文字を四角の中に描く。はみ出す分は末尾を「…」で切る。
    private func drawText(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, lines: Int = 1) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
