// nowplaying.sh が起動する、Music.app で再生中の曲をメニューバーに出す常駐型のプログラム。
//
// SwiftBar の常駐型 (streamable) プラグインとして動き、メニューの中身を標準出力に
// 書く。中身の後ろに「~~~」の行を書くと、SwiftBar がメニューを差し替える
// (nowplaying.sh の useTrailingStreamSeparator)。
//
// Music.app の通知で更新し、再生中だけ 5 秒ごとに再生位置を問い合わせる。問い合わせは
// ScriptingBridge でこのプログラムの中から行い、osascript などのプロセスは起動しない。
// SwiftBar から起動されるので、Music を操作する許可は SwiftBar のものが使われる。
//
// 以前は 5 秒ごとにシェルのスクリプトを起動し、osascript・jq・描画のプログラムを
// 毎回起動していたので、再生していなくても平均して 1 コアの 3% ほどを使っていた。
//
// ファイルの分け方:
// - main.swift             ここ。起動したときに上から順に実行される
// - NowPlayingPlugin.swift 常駐して、通知やタイマーを受けてメニューを差し替える
// - MusicApp.swift         Music.app への問い合わせと操作
// - MusicScripting.swift   Music.app の用語の宣言 (ScriptingBridge)
// - Track.swift            曲の情報
// - NowPlayingMenu.swift   メニューの行
// - NowPlayingImages.swift メニューバーとカードの画像
// - SampleRender.swift     --render (サンプルの曲で描く)
//
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。nowplaying.sh が初回 (とソースを変えたとき) にコンパイルする。

import AppKit
#if canImport(Shared)
import Shared
#endif

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--render" {
    SampleRender.run(jsonPath: arguments[2], outputDirectory: arguments[3])
}
// メニューの操作の項目から `control <操作>` で呼ばれる。操作だけをして終わる
if arguments.count == 3, arguments[1] == "control" {
    guard let command = MusicApp.Command(rawValue: arguments[2]) else {
        exitWithError("nowplaying: 知らない操作: \(arguments[2])")
    }
    MusicApp.perform(command)
    exit(0)
}

SwiftBar.beginStreaming()
let plugin = NowPlayingPlugin()
plugin.startObserving()
plugin.refresh()
// 通知やタイマーを待ち続ける (ここから先へは進まない)
RunLoop.main.run()
