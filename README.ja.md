# swiftbar-cards

[English](README.md)

メニューの中身を、文字の行ではなく画像のカードで描く [SwiftBar](https://github.com/swiftbar/SwiftBar) のプラグインです。

| プラグイン | メニューバー | カード |
|---|---|---|
| `nowplaying` | Music.app で再生中の曲のアートワークと曲名 | アートワーク・曲名・アーティスト・アルバム・再生位置と、一時停止・次の曲の項目 |
| `sysmon` | CPU の推移と使用率、メモリ、温度 | CPU (使用率・過去 10 分の推移・E / P コア・温度)、メモリ、CPU とメモリを使っているプロセスの上位、Bluetooth 機器のバッテリー |
| `weather` | 今日の天気のアイコン、現在の気温、降水確率 | 気象庁のデータによる現在の観測値、今後 24 時間の気温のグラフ、地方の予報、週間予報 |

カードは小さな Swift のプログラムが描き、画像として SwiftBar に渡します。ライトモードとダークモードで別の色を使います。

## 必要なもの

- Apple シリコンの Mac (M1 Max・macOS 26 で確かめています)
- 常駐型 (streamable) のプラグインに対応した SwiftBar
- `swiftc` を使うための Xcode Command Line Tools (`xcode-select --install`)
- `weather` 用の `jq`

## インストール

```sh
git clone https://github.com/delphinus/swiftbar-cards.git
```

SwiftBar の設定で、プラグインのフォルダをクローンした中の `plugins` ディレクトリにします。プラグインは隣の `helpers` ディレクトリから Swift のソースを探すので、プラグインのファイルを 1 つずつ別の場所へコピーしたりリンクしたりしないでください。

各プラグインは、初回とソースを変えたときにヘルパーをコンパイルします。できたバイナリは `~/Library/Caches/` の下に置かれます。

`nowplaying` は再生中の曲を AppleScript で Music.app に問い合わせます。初回は、SwiftBar から Music を操作してよいかを macOS が尋ねます。

## 設定

`weather` は、何も設定しなければ東京を表示します。地域は今のところ `plugins/weather.10m.sh` の冒頭にある値 (`JMA_OFFICE`・`JMA_AREA`・`JMA_CLASS10`・`JMA_TEMP_POINT`・`JMA_AMEDAS`) で決まります。それぞれのコードの調べ方はそこのコメントにあります。地名を 1 つ指定するだけで済む設定ファイルを用意する予定です。

## 謝辞

`sysmon` は、[macmon](https://github.com/vladkens/macmon) (MIT License) と同じ方法で SMC から温度を読んでいます。

## ライセンス

[MIT](LICENSE)
