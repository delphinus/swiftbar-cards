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

import AppKit
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

// 次のときは、次の 10 秒の区切りを待たずに描き直す。描くループは別のスレッドで寝て
// いるので、受けたらセマフォで起こす。
// - メニューバーの項目を縮めるか (MenuBarDensity) が変わったとき
// - Space を切り替えたとき。メニューバーの画像は明るい用と暗い用の 2 枚で、SwiftBar は
//   メニューを受け取ったときにだけ、そのときのメニューバーの見た目でどちらかを選ぶ。
//   フルスクリーンの Space ではメニューバーが黒くなるので、切り替えたら出し直して
//   選び直させる。切り替えの直後はメニューバーの見た目がまだ前の Space のままの
//   ことがあるので、少し待ってから出し、念のためもう 1 回出す
let redrawRequested = DispatchSemaphore(value: 0)
MenuBarDensity.observeChanges(on: DispatchQueue(label: "sysmon.density")) { redrawRequested.signal() }
let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { redrawRequested.signal() }
        }
    }

// 描くループ。メインスレッドは Space の切り替えの通知を受けるために NSApplication を
// 回すので、別のスレッドで回す
let drawingThread = Thread {
    var snapshot = monitor.takeSnapshot()
    // メニューバーの行の末尾に空白を足すか。取り直さずに描き直すたびに切り替える。
    // SwiftBar は常駐型のプラグインの出力が前回と同じなら読み捨てるので、同じ値で
    // 描き直しても画像を選び直してくれない。行の末尾の空白は引数の区切りとして
    // 読み飛ばされ、見た目は変わらないが、出力は前回と違うものになる
    var padsMenuBarLine = false
    while true {
        // 1 回ごとに autorelease pool を空にする。このループは RunLoop で回して
        // いないので、囲まないと毎回描く画像や文字列が解放されずに溜まり続ける
        // (1 時間で 2 GB ほど増えていた)。
        autoreleasepool {
            let compact = MenuBarDensity.isCompact
            let menuBar = SystemMenuBar(snapshot: snapshot, compact: compact)
            let light = menuBar.render(dark: false)
            // 戻したときに増える幅を、縮めるかを決める側に伝える
            let otherWidth = SystemMenuBar(snapshot: snapshot, compact: !compact).render(dark: false).size.width
            MenuBarDensity.report(plugin: "sysmon", compact: compact,
                                  extraWidth: abs(light.size.width - otherWidth))
            let card = SystemCard(snapshot: snapshot, dark: isDarkAppearance())
            SwiftBar.replaceMenu(with: [
                SwiftBar.menuBarImageLine(light: light, dark: menuBar.render(dark: true)) + (padsMenuBarLine ? " " : ""),
                "---",
                // カードの下には区切り線を引かない (カードの地の縁が境目になる)
                SwiftBar.imageLine(card.render()),
                openActivityMonitor,
            ])
        }

        // 次の 10 秒の区切りまで寝る。途中で起こされたら、値は取り直さずに描き直す
        // (取り直すと、CPU の使用率の履歴に、間隔の短い 1 回が入ってしまう)
        let now = Date().timeIntervalSince1970
        let next = (floor(now / monitor.interval) + 1) * monitor.interval
        if redrawRequested.wait(timeout: .now() + max(1, next - now)) == .timedOut {
            snapshot = autoreleasepool { monitor.takeSnapshot() }
        } else {
            padsMenuBarLine.toggle()
        }
    }
}
// 画像を描くので、メインスレッドと同じ大きさのスタックを持たせる
drawingThread.stackSize = 8 << 20
drawingThread.start()

// Space の切り替えの通知は、NSApplication を回しているプログラムにしか届かない
// (RunLoop を回すだけでは届かなかった)。Dock やアプリの切り替えには出さない
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
