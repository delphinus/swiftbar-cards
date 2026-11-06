import AppKit
import ScriptingBridge

// ScriptingBridge で Music.app を操作するための宣言。
//
// ScriptingBridge は、AppleScript と同じ Apple Events を Swift のプロパティやメソッドの
// 呼び出しとして送る仕組み。`SBApplication` に Music.app の用語 (current track・player
// state など) を名前で問い合わせる。用語の一覧は Music.app の用語説明 (スクリプトエディタの
// 「ファイル > 用語説明を開く」) にある。Swift から呼ぶには、使う用語だけを @objc の
// プロトコルに書き、SBApplication と SBObject がそれに準拠していると宣言する。
// 名前は用語を lowerCamelCase にしたもの (player state → playerState)。
//
// プロパティを 1 つ読むたびに Apple Event が 1 往復する。曲の情報は `properties` で
// まとめて 1 回で読む。
//
// `@objc optional` にするのは、実体が Music.app の側にあり、Swift のコンパイラからは
// 本当にあるかを確かめられないため。呼ぶ側は `?` を付けて読む。

/// Music.app 本体 (application)
@objc protocol MusicApplication {
    /// 再生の状態。4 文字のコード (`MusicPlayerState`)
    @objc optional var playerState: MusicPlayerState { get }
    /// 再生位置 (秒)
    @objc optional var playerPosition: Double { get }
    /// 再生中の曲。曲が無いときも nil にはならず、読むと中身が空になる
    @objc optional var currentTrack: MusicTrack { get }

    @objc optional func playpause()
    /// play には省いてよい引数 once があるので、ScriptingBridge での名前は playOnce: になる
    /// (引数の無い play という名前は無い)
    @objc optional func playOnce(_ once: Bool)
    @objc optional func nextTrack()
    @objc optional func previousTrack()
}

/// 曲 (track)
@objc protocol MusicTrack {
    /// 曲のプロパティをまとめた辞書。キーは name・artist・album・duration・persistentID など
    @objc optional var properties: [String: Any] { get }
    /// アートワークの一覧。要素は `MusicArtwork`
    @objc optional func artworks() -> SBElementArray
}

/// 曲のアートワーク (artwork)
@objc protocol MusicArtwork {
    /// 画像。ScriptingBridge は NSImage にして返すことも、画像の形式によっては
    /// (PNG のアートワークで起きた) Apple Event の値 (NSAppleEventDescriptor) のまま
    /// 返すこともある。型を決めつけると、違う型が来たときに描く段階で落ちるので、
    /// Any で受けて MusicApp.artwork() で見分ける。
    @objc optional var data: Any { get }
}

extension SBApplication: MusicApplication {}
extension SBObject: MusicTrack, MusicArtwork {}

/// 再生の状態の 4 文字のコード。Music.app の用語説明の ePlS にある。
/// Objective-C から見える型にするため、@objc を付けて整数 (FourCharCode) の enum にする。
@objc enum MusicPlayerState: FourCharCode {
    case stopped = 0x6B50_5353 // 'kPSS'
    case playing = 0x6B50_5350 // 'kPSP'
    case paused = 0x6B50_5370 // 'kPSp'
    case fastForwarding = 0x6B50_5346 // 'kPSF'
    case rewinding = 0x6B50_5352 // 'kPSR'
}
