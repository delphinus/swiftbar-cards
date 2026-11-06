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
    let musicIsRunning: Bool

    func lines() -> [String] {
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

    /// メニューバーの画像とカード
    private func trackLines() -> [String] {
        let images = NowPlayingImages(track: track, artwork: artwork)
        let menuBar: String
        if track.isPlaying {
            menuBar = SwiftBar.menuBarLine(title: images.menuBarTitle(), image: images.menuBarArtwork())
        } else {
            // 一時停止中のメニューバーは、音符のアイコンだけにする
            menuBar = Self.musicNoteIcon
        }
        let card = SwiftBar.imageLine(images.card(dark: isDarkAppearance()))
        // カードの下には区切り線を引かない (カードの地の縁が境目になる)
        return [menuBar, "---", card]
    }

    /// 操作の項目。前の曲に戻る操作は頻度が低いので、⌥ を押している間だけ「次の曲」と
    /// 差し替える (SwiftBar の alternate)。
    private func controlLines() -> [String] {
        [
            track.isPlaying
                ? Self.control(L("一時停止", "Pause"), icon: "pause.circle", command: "playpause")
                : Self.control(L("再生", "Play"), icon: "play.circle", command: "play"),
            Self.control(L("次の曲", "Next Track"), icon: "forward.end.circle", command: "next track"),
            Self.control(L("前の曲", "Previous Track"), icon: "backward.end.circle", command: "previous track",
                         extra: " alternate=true"),
            Self.openMusic,
        ]
    }

    // メニューのアイコンは幅 15pt のもの (円で囲んだ系統など) でそろえる。SF Symbols は
    // アイコンごとに幅が違い、その差だけ文字の書き出し位置がずれる。

    /// メニューバーの音符。SwiftBar の sfimage は大きさ (scale) を large で描くので、
    /// そのままではほかのアイコンより一回り大きい (14×20pt)。sfconfig で medium にして、
    /// sysmon の見出しのアイコン (13pt) と同じ 11×15pt にする。sfconfig は次の JSON を
    /// Base64 にしたもの。色を指定しないので、テンプレート画像のまま (メニューバーの
    /// 地に合わせた色で描かれる) になる。
    ///
    ///     {"renderingMode":"Hierarchical","colors":[],"scale":"medium"}
    private static let musicNoteIcon = " | sfimage=music.note sfconfig=eyJyZW5kZXJpbmdNb2RlIjoiSGllcmFyY2hpY2FsIiwiY29sb3JzIjpbXSwic2NhbGUiOiJtZWRpdW0ifQ=="

    private static let openMusic = L("Music を開く", "Open Music")
        + " | sfimage=arrow.up.forward.circle bash=/usr/bin/open param1=-a param2=Music terminal=false"

    /// Music.app を AppleScript で操作する項目
    private static func control(_ title: String, icon: String, command: String, extra: String = "") -> String {
        "\(title) | sfimage=\(icon) bash=/usr/bin/osascript param1=-e param2='tell application \"Music\" to \(command)' terminal=false\(extra)"
    }
}
