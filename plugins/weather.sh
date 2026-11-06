#!/bin/bash
# <xbar.title>Weather (JMA)</xbar.title>
# <xbar.desc>気象庁の天気予報とアメダスの観測値をメニューバーに出す</xbar.desc>
# <xbar.version>v1.1.0</xbar.version>
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
# 常駐型 (streamable) のプラグイン。中身は ../Sources/weather/ の Swift のプログラムで、ここでは
# それをコンパイルして起動するだけ。10 分ごとに気象庁のデータを取り直し、地点を
# 切り替えたときはその場でメニューを差し替える。
#
# メニューの項目は、このスクリプトを引数付き (select <地点>・refresh-now・open-config)
# で起動する。引数はそのままプログラムに渡し、プログラムが指示をキャッシュに書いて
# すぐ終わる。常駐している側がそれに気付いてメニューを差し替える。
#
# 現在地は、位置情報を読む小さな .app (../Sources/locate/) に調べさせる。SwiftBar
# から起動したプログラムには位置情報の許可を持たせられないため。ここで .app も
# ビルドしておく。
#
# 中身の区切りの「~~~」は、中身の後ろに出す (useTrailingStreamSeparator)。理由は
# sysmon.sh に書いた (カードの画像が大きく、1 回の更新が複数のかたまりで届く)。

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

cache=~/Library/Caches/swiftbar-weather
mkdir -p "$cache"
# shellcheck source=SCRIPTDIR/../scripts/lib.sh
. "$(dirname "$0")/../scripts/lib.sh"
bin=$cache/weather
# メニューの項目から引数付きで起動されたときは、ビルドせずにすぐ渡す
# (常駐している側が起動したときにビルドしてある)
if [[ $# -eq 0 || $1 == --once ]]; then
	build_helper weather "$bin"
	build_app locate "$cache/Locate.app"
	# 以前の形 (weather.10m.sh) で使っていたファイルを消す
	rm -f "$cache/weather-card" "$cache/switched" "$cache/fresh" "$cache"/menu-*.txt
fi
if [[ ! -x $bin ]]; then
	echo " | sfimage=exclamationmark.triangle"
	echo "---"
	echo "weather: コンパイルできない"
	exit 0
fi
# メニューの項目の動作で自分を起動できるよう、自分のパスを渡す
SWIFTBAR_CARDS_PLUGIN="$cards_root/plugins/$(basename "$0")" exec "$bin" "$@"
