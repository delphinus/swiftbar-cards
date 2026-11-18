import Foundation
#if canImport(Shared)
import Shared
#endif

/// 与えた値でメニューバーの項目を 1 回だけ描く (README の画像用)。
///
///     weather --render-menubar <天気のアイコン> <気温> <降水確率> <出力先>
///
/// 例: `weather --render-menubar cloud.sun 17° 20 out`。天気のアイコンは WeatherStyle の
/// アイコンの名前 (sun.max・cloud.sun・cloud.rain・cloud.snow など)、降水確率は % を付けない
/// 数字。出力先に menubar-light.png・menubar-dark.png を書く。縮めるかは、ほかの描き方と
/// 同じく MenuBarDensity で決まる (SWIFTBAR_CARDS_COMPACT=on|off で決め打ちする)。
///
/// weather のカードは気象庁のデータから組み立てるので、サンプルの値では描かない
/// (samples/render.sh は --once で今の予報を描く)。メニューバーは、通常表示と縮小表示の
/// 違いを見せるのに、決まった値で描く必要がある (降水確率が 30% 未満でないと違いが出ない)。
enum SampleRender {
    static func run(_ arguments: [String]) -> Never {
        guard arguments.count == 6 else {
            exitWithError("usage: weather --render-menubar <天気のアイコン> <気温> <降水確率> <出力先>")
        }
        let menuBar = WeatherMenuBar(icon: arguments[2], temperature: arguments[3],
                                     precipitationChance: arguments[4], warning: nil, stale: false)
        let directory = URL(fileURLWithPath: arguments[5], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                try menuBar.render(dark: dark).write(to: directory, name: "menubar-\(dark ? "dark" : "light")")
            }
        } catch {
            exitWithError("画像を書き出せない: \(error)")
        }
        exit(0)
    }
}
