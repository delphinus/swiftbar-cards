import AppKit
#if canImport(Shared)
import Shared
#endif

/// SwiftBar に渡すメニューの行を組み立てる。
///
/// 再生中のメニューバー: 角を丸めたアートワークと曲名。一時停止中・停止中は音符の
/// アイコンだけ。メニュー: アートワーク・曲名・アーティスト・アルバム・再生位置の
/// カードと、操作の項目 (操作は画像の中ではクリックした位置を区別できないので文字の
/// 項目にする)。
struct NowPlayingMenu {
    let track: Track
    let artwork: NSImage?
    /// カードをクリックしたときに開く、曲のソース。見つかっていなければ nil
    let sourceLink: SourceLink?
    let musicIsRunning: Bool

    func lines() -> [String] {
        reportExtraWidth()
        guard musicIsRunning else {
            return [Self.musicNoteIcon, "---", Self.openMusic]
        }
        var lines: [String] = []
        if track.hasTrack {
            lines += trackLines()
        } else {
            lines += [Self.musicNoteIcon, "---"]
        }
        lines += controlLines()
        return lines
    }

    /// 縮めるか (MenuBarDensity)。1 回のメニューの中ではそろえる
    private let compact = MenuBarDensity.isCompact("nowplaying")

    /// 戻したときに増える幅を、縮めるかを決める側に伝える。曲名を出すのは再生中だけで、
    /// 音符だけのときは縮めても戻しても幅は同じ
    private func reportExtraWidth() {
        let showsTitle = musicIsRunning && track.hasTrack && track.isPlaying
        let extra = showsTitle ? NowPlayingImages(track: track, artwork: nil).menuBarTitleExtraWidth() : 0
        MenuBarDensity.report(plugin: "nowplaying", compact: compact, extraWidth: extra)
    }

    /// メニューバーの画像とカード
    private func trackLines() -> [String] {
        let images = NowPlayingImages(track: track, artwork: artwork)
        let menuBar: String
        if track.isPlaying {
            menuBar = SwiftBar.menuBarLine(title: images.menuBarTitle(compact: compact), image: images.menuBarArtwork())
        } else {
            // 一時停止中のメニューバーは、音符のアイコンだけにする
            menuBar = Self.musicNoteIcon
        }
        var card = SwiftBar.imageLine(images.card(dark: isDarkAppearance()))
        if let sourceLink {
            // 動作を付けると、マウスを載せたときにカードが選択の色で塗られる。それでクリック
            // できることが分かるので、そのままにする
            card += " href=\(sourceLink.url.absoluteString) tooltip=\"\(L("\(sourceLink.source.rawValue) で開く", "Open in \(sourceLink.source.rawValue)"))\""
        }
        // カードの下には区切り線を引かない (カードの地の縁が境目になる)
        return [menuBar, "---", card]
    }

    /// 操作の項目。前の曲に戻る操作は頻度が低いので、⌥ を押している間だけ「次の曲」と
    /// 差し替える (SwiftBar の alternate)。曲があるときは「アーティスト - タイトル」を
    /// コピーする項目も出す。
    private func controlLines() -> [String] {
        var lines = [
            track.isPlaying
                ? Self.control(L("一時停止", "Pause"), icon: "pause.circle", command: .playpause)
                : Self.control(L("再生", "Play"), icon: "play.circle", command: .play),
            Self.control(L("次の曲", "Next Track"), icon: "forward.end.circle", command: .next),
            Self.control(L("前の曲", "Previous Track"), icon: "backward.end.circle", command: .previous,
                         extra: " alternate=true"),
        ]
        if track.hasTrack {
            lines.append(Self.copyArtistAndTitle)
        }
        lines.append(Self.openMusic)
        return lines
    }

    // メニューのアイコンは幅 15pt のもの (円で囲んだ系統など) でそろえる。SF Symbols は
    // アイコンごとに幅が違い、その差だけ文字の書き出し位置がずれる。

    /// メニューバーの音符。sysmon のアイコンと同じ大きさ (13pt) で、同じ高さ (文字の
    /// ベースラインに乗せる。MenuBarLayout) に描き、テンプレート画像として渡す。色は
    /// メニューバーの地に合わせて描かれる。
    ///
    /// SwiftBar の sfimage で渡すと、メニューバーの真ん中に置かれ、v1.1.3 で文字の高さに
    /// そろえた sysmon や weather のアイコンより 1pt ほど下に出た。
    private static let musicNoteIcon: String = {
        guard let icon = NSImage.symbol("music.note", pointSize: MenuBarLayout.iconPointSize, color: .black)
        else { return " | sfimage=music.note" }
        let image = PNGImage.draw(width: ceil(icon.size.width), height: MenuBarLayout.height) { _ in
            icon.drawUpright(in: MenuBarLayout.iconRect(icon, x: 0))
        }
        return SwiftBar.menuBarTemplateImageLine(image)
    }()

    /// .app の場所を href に渡すと、SwiftBar がそれを開く (Music.app を起動する)
    private static let openMusic = L("Music を開く", "Open Music")
        + " | sfimage=arrow.up.forward.circle href=file:///System/Applications/Music.app"

    /// 再生中の曲の「アーティスト - タイトル」をクリップボードにコピーする項目。クリックすると、
    /// SwiftBar がこのプラグインを `copy` の引数で起動し直す (main.swift)。
    /// doc.on.doc はほかのアイコンより 1pt 広いが、コピーを表す円で囲んだ系統のものが無い
    private static var copyArtistAndTitle: String {
        L("「アーティスト - タイトル」をコピー", "Copy \u{201C}Artist - Title\u{201D}")
            + " | sfimage=doc.on.doc bash=\(pluginPath) param1=copy terminal=false"
    }

    /// プラグインの場所。SwiftBar が環境変数 SWIFTBAR_PLUGIN_PATH で渡す
    private static var pluginPath: String {
        ProcessInfo.processInfo.environment["SWIFTBAR_PLUGIN_PATH"] ?? "nowplaying.sh"
    }

    /// Music.app を操作する項目。クリックすると、SwiftBar がこのプラグインを
    /// `control <操作>` の引数で起動し直し、その実行が操作だけをして終わる (main.swift)。
    /// 常駐しているほうは、Music.app の通知を受けてメニューを差し替える。
    private static func control(_ title: String, icon: String, command: MusicApp.Command, extra: String = "") -> String {
        "\(title) | sfimage=\(icon) bash=\(pluginPath) param1=control param2=\(command.rawValue) terminal=false\(extra)"
    }
}
