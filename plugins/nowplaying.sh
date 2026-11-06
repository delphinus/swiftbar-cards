#!/bin/bash
# <xbar.title>Now Playing (Music.app)</xbar.title>
# <xbar.desc>Music.app で再生中の曲をメニューバーに出す</xbar.desc>
# <xbar.version>v1.0.1</xbar.version>
# <xbar.author>delphinus</xbar.author>
# <xbar.author.github>delphinus</xbar.author.github>
# <xbar.abouturl>https://github.com/delphinus/swiftbar-cards</xbar.abouturl>
# <swiftbar.type>streamable</swiftbar.type>
# <swiftbar.useTrailingStreamSeparator>true</swiftbar.useTrailingStreamSeparator>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# 常駐型 (streamable) のプラグイン。中身は ../Sources/nowplaying/ の Swift のプログラムで、ここでは
# それをコンパイルして起動するだけ。Music.app の通知で更新し、再生中だけ 5 秒ごとに
# 再生位置を問い合わせる。一時停止中・停止中は何もしない。
#
# Music.app に Apple Events (ScriptingBridge) で問い合わせるだけなので、macOS 15.4 で
# 塞がれた MediaRemote には頼らない。初回は SwiftBar から Music を操作する許可を
# 求められる。メニューの操作の項目は、このスクリプトを `control <操作>` の引数で
# 起動する (引数はそのままプログラムに渡す)。
#
# 中身の区切りの「~~~」は、中身の後ろに出す (useTrailingStreamSeparator)。既定の
# 「前に出す」方式では、SwiftBar はパイプから届いたかたまりごとに中身を書き足して
# メニューを作り直す。カードの画像は Base64 で 200 KB ほどあり、1 回の更新が
# 複数のかたまりで届くので、SwiftBar 本体が 1 コアの 5% ほどを使っていた。
# 後ろに出す方式なら、「~~~」が届いたときに 1 回だけ差し替える。

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

cache=~/Library/Caches/swiftbar-nowplaying
mkdir -p "$cache"
# shellcheck source=SCRIPTDIR/../scripts/lib.sh
. "$(dirname "$0")/../scripts/lib.sh"
bin=$cache/nowplaying
build_helper nowplaying "$bin"
if [[ ! -x $bin ]]; then
	echo " | sfimage=music.note"
	echo "---"
	echo "nowplaying: コンパイルできない"
	exit 0
fi
# 以前の形 (nowplaying.5s.sh) で使っていたファイルを消す
rm -f "$cache/nowplaying-card" "$cache/out.txt" "$cache"/*.jpg "$cache"/*.small "$cache"/*.large
exec "$bin" "$@"
