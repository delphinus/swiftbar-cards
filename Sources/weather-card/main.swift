// weather.10m.sh が使う、天気のカードを描くプログラム。
//
// 標準入力に JSON を受け取り、PNG を Base64 にして標準出力に書く。
// 1 行目に「幅 高さ 本来の高さ (下を空ける前)」を pt で書き、2 行目に Base64 を書く。
//
// 色は weather.10m.sh が外観 (ダーク / ライト) に合わせて選んで渡す。
// メニューの文字と違い、画像の中の色は指定どおりに描かれる。
//
// ファイルの分け方:
// - main.swift              ここ。起動したときに上から順に実行される
// - CardInput.swift         受け取る JSON の形
// - WeatherCard.swift       カード (観測値・3 日分の予報・週間予報の節)
// - WeatherCard+Graph.swift カードの気温のグラフの節
// - WeatherPen.swift        カードの色と、文字・アイコン・線の描き方
// - Typesetting.swift       日本語の括弧と、予報の文の折り返し
// - MonotoneCurve.swift     点を通る滑らかな曲線
//
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。weather.10m.sh が初回にコンパイルする。

import Foundation
#if canImport(Shared)
import Shared
#endif

let input: CardInput
do {
    input = try JSONDecoder().decode(CardInput.self, from: FileHandle.standardInput.readDataToEndOfFile())
} catch {
    exitWithError("weather-card: JSON を読めない: \(error)")
}

let (image, naturalHeight) = WeatherCard(input: input).render()
print("\(Int(image.size.width)) \(Int(ceil(image.size.height))) \(Int(ceil(naturalHeight)))")
print(image.base64)
