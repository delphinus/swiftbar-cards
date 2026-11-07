// weather.sh が起動する、気象庁の天気予報とアメダスの観測値をメニューバーに出す
// 常駐型のプログラム。
//
// SwiftBar の常駐型 (streamable) プラグインとして動き、10 分ごとに気象庁のデータを
// 取り直してカードを描き、メニューの中身を標準出力に書く。中身の後ろに「~~~」の
// 行を書くと、SwiftBar がメニューを差し替える (weather.sh の useTrailingStreamSeparator)。
//
// 以前は 10 分ごとに起動するシェルのスクリプト (weather.10m.sh) で、curl・jq・date
// などを毎回起動し、地点を切り替えたときは自分を裏で起動し直してから SwiftBar に
// 更新を指示していた。常駐すれば、地点を切り替えたときもその場でメニューを差し替え
// られる。
//
// 表示の言語は OS の設定に従う (Sources/Shared/Localization.swift)。英語のときは、
// 観測点や区域の名前に気象庁の表の英語名を使い、予報の文 (日本語でしか配られない)
// の代わりに天気コードの英語名 (data/jma-telops.json) を出す。
//
// ファイルの分け方:
// - main.swift              ここ。起動したときに上から順に実行される
// - Command.swift           メニューの項目から引数付きで起動されたときの仕事
// - WeatherPlugin.swift     常駐して、きっかけを受けて取り直し、メニューを差し替える
// - WeatherMenu.swift       メニューの行
// 地点:
// - Configuration.swift     設定ファイル (地点の並び)
// - CurrentLocation.swift   現在地 (Locate.app が調べた結果)
// - StationTables.swift     観測点と予報区の表
// - Place.swift             地点を観測点に当てはめ、予報区を決める
// データ:
// - JMAClient.swift         気象庁のサイトから取る
// - JMAData.swift           取ったデータ (JSON) の形
// - CacheFolder.swift       キャッシュのフォルダの中のファイル
// - JapanTime.swift         日本時間の日付と時刻
// カード:
// - CardMaker.swift         地点のデータを取り直してカードを描き、キャッシュに置く
// - WeatherReport.swift     データから、メニューバーの行とカードに描く値を組み立てる
// - WeatherStyle.swift      天気・降水確率・気温のアイコンと色
// - PlaceCard.swift         地点ごとに描いたメニューの行 (キャッシュ)
// - CardInput.swift         カードに描く値
// - WeatherCard.swift       カード (観測値・3 日分の予報・週間予報の節)
// - WeatherCard+Graph.swift カードの気温のグラフの節
// - WeatherPen.swift        カードの色と、文字・アイコン・線の描き方
// - Typesetting.swift       予報の文の折り返し
// - MonotoneCurve.swift     点を通る滑らかな曲線
//
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。weather.sh が初回 (とソースを変えたとき) にコンパイルする。

import Foundation
#if canImport(Shared)
import Shared
#endif

let cache = CacheFolder.standard
let arguments = CommandLine.arguments
Command.runIfRequested(arguments, cache: cache)
cache.prepare()

// weather.sh が自分のパスを渡す。メニューの項目の動作でプラグインを起動するのに使い、
// リポジトリの data/ もそこからたどる
let pluginPath = ProcessInfo.processInfo.environment["SWIFTBAR_CARDS_PLUGIN"] ?? arguments[0]
let telopsFile = URL(fileURLWithPath: pluginPath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("data/jma-telops.json")
let telops: [String: Telop] = {
    do {
        return try JSONDecoder().decode([String: Telop].self, from: Data(contentsOf: telopsFile))
    } catch {
        // 読めなくても動く (英語の表示で天気の文が日本語のままになり、天気のアイコンは
        // コードの百の位だけで決める)
        logger.error("読めない: \(telopsFile.path, privacy: .public): \(String(describing: error), privacy: .public)")
        return [:]
    }
}()

SwiftBar.beginStreaming()
let runsOnce = arguments.contains("--once")
Task { @MainActor in
    let plugin = WeatherPlugin(cache: cache, pluginPath: pluginPath, telops: telops)
    if runsOnce {
        await plugin.refreshOnce()
        exit(0)
    }
    plugin.start()
    // 常駐しているあいだ、plugin を手放さない
    WeatherPlugin.running = plugin
}
// タイマー・通知・フォルダの変化を待ち続ける (ここから先へは進まない)
RunLoop.main.run()
