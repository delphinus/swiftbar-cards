// sysmon.sh が起動する、システムの状態をメニューバーに出す常駐型のプログラム。
//
// SwiftBar の常駐型 (streamable) プラグインとして動き、10 秒ごとに値を集めて
// 描き、メニューの中身を標準出力に書く。中身の後ろに「~~~」の行を書くと、
// SwiftBar がメニューを差し替える (sysmon.sh の useTrailingStreamSeparator)。
//
// 以前は 10 秒ごとにシェルのスクリプトを起動し、iostat・ps・vm_stat・jq・描画の
// プログラムなどを毎回起動していた。その起動の積み重ねで、平均して 1 コアの
// 2.5% ほどを使っていたので、常駐して値を API から直接取るようにした。
//
// ファイルの分け方:
// - main.swift          ここ。起動したときに上から順に実行される
// - Snapshot.swift      ある時点のシステムの状態 (集める側と描く側の受け渡しに使う)
// 値を集める:
// - SystemMonitor.swift 下の部分を呼んで Snapshot を作る
// - CPUUsage.swift      CPU の使用率 (全体と E / P コア)
// - SMC.swift           温度
// - Memory.swift        メモリ
// - Processes.swift     CPU とメモリを使っているプロセス
// - Batteries.swift     本体と Bluetooth 機器のバッテリー
// - SystemCalls.swift   sysctl と外部のコマンド
// 描く:
// - SystemCard.swift    メニューを開いたときのカード
// - SystemMenuBar.swift メニューバーの画像
// - Pen.swift           カードの文字・メーター・区切り線
// - CardColors.swift    カードの色
// - SampleRender.swift  --render (サンプルの値で描く)
//
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。sysmon.sh が初回 (とソースを変えたとき) にコンパイルする。

import Foundation
#if canImport(Shared)
import Shared
#endif

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--render" {
    SampleRender.run(jsonPath: arguments[2], outputDirectory: arguments[3])
}

// ~ の展開 (expandingTildeInPath) は環境変数 HOME を見ないので、HOME から組む。
// sysmon.sh のキャッシュ (~/Library/Caches/swiftbar-sysmon) と同じ場所の考え方にそろえ、
// HOME を一時ディレクトリにして動かすテスト (tests/smoke.sh) で本物を書き換えない。
let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let monitor = SystemMonitor(interval: 10, historyFile: home + "/Library/Caches/swiftbar-sysmon-cpu-history.txt")

let openActivityMonitor = L("アクティビティモニタを開く", "Open Activity Monitor")
    + " | sfimage=arrow.up.forward.circle bash=/usr/bin/open param1=-a param2=\"Activity Monitor\" terminal=false"

SwiftBar.beginStreaming()
Thread.sleep(forTimeInterval: 1) // 最初の使用率を出すため、ティックの差分を取る間を置く

while true {
    // 1 回ごとに autorelease pool を空にする。このループは RunLoop で回して
    // いないので、囲まないと毎回描く画像や文字列が解放されずに溜まり続ける
    // (1 時間で 2 GB ほど増えていた)。
    autoreleasepool {
        let snapshot = monitor.takeSnapshot()
        let menuBar = SystemMenuBar(snapshot: snapshot)
        let card = SystemCard(snapshot: snapshot, dark: isDarkAppearance())
        SwiftBar.replaceMenu(with: [
            SwiftBar.menuBarImageLine(light: menuBar.render(dark: false), dark: menuBar.render(dark: true)),
            "---",
            // カードの下には区切り線を引かない (カードの地の縁が境目になる)
            SwiftBar.imageLine(card.render()),
            openActivityMonitor,
        ])

        // 次の 10 秒の区切りまで寝る
        let now = Date().timeIntervalSince1970
        let next = (floor(now / monitor.interval) + 1) * monitor.interval
        Thread.sleep(forTimeInterval: max(1, next - now))
    }
}
