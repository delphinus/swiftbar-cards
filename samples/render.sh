#!/bin/bash
# README の画像 (docs/images/*.png) を作る。
#   samples/render.sh [出力先]
# 日本語と英語のそれぞれを docs/images/ja と docs/images/en に描く。nowplaying と
# sysmon は samples/ の架空の値で、weather は東京の今の予報で描く。
# weather の「雨雲の動き」の地図は、RADAR_LOCATION (「緯度 経度」) の地点で描く。
# 雨の無い地点では地図が空になるので、描く日に雨の降っている地点を渡す
# (例: RADAR_LOCATION="35.4681 133.0484" samples/render.sh で松江)。既定は東京駅。
# 手元のキャッシュや設定ファイルには触らない (HOME を一時ディレクトリにする)。

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
out=$(mkdir -p "${1:-$repo/docs/images}" && cd "${1:-$repo/docs/images}" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export LANG=en_US.UTF-8
# weather の現在地は、位置情報を読む .app を起動せず、東京駅の座標にする
export SWIFTBAR_CARDS_LOCATION="35.6812 139.7671"
radar_location=${RADAR_LOCATION:-$SWIFTBAR_CARDS_LOCATION}
# メニューバーは縮めずに描く (外部のディスプレイが無い Mac では、何もしないと縮める)
export SWIFTBAR_CARDS_COMPACT=off

mkdir -p "$work/bin"
for h in nowplaying sysmon weather; do
	swiftc -O -suppress-warnings -o "$work/bin/$h" "$repo"/Sources/Shared/*.swift "$repo/Sources/$h"/*.swift
done
swiftc -O -suppress-warnings -o "$work/bin/compose" "$repo/samples/compose.swift"
swiftc -O -suppress-warnings -o "$work/bin/density" "$repo/samples/density.swift"

# nowplaying: アートワークも図形から描く
swift "$repo/samples/artwork.swift" "$work/artwork.png"
# 曲は言語ごとに用意した架空のもの (日本語は samples/nowplaying.ja.json)
sed "s#\"artwork.png\"#\"$work/artwork.png\"#" "$repo/samples/nowplaying.json" >"$work/nowplaying-en.json"
sed "s#\"artwork.png\"#\"$work/artwork.png\"#" "$repo/samples/nowplaying.ja.json" >"$work/nowplaying-ja.json"
for l in ja en; do
	export SWIFTBAR_CARDS_LANG=$l
	mkdir -p "$out/$l"
	"$work/bin/nowplaying" --render "$work/nowplaying-$l.json" "$work/$l/nowplaying"
	"$work/bin/sysmon" --render "$repo/samples/sysmon.json" "$work/$l/sysmon"
	# 通常表示と縮小表示を並べる絵のために、縮めたメニューバーも描く。weather は今の予報では
	# 違いが出ないことがあるので、降水確率が 30% 未満の決まった値で両方を描く
	SWIFTBAR_CARDS_COMPACT=on "$work/bin/nowplaying" --render "$work/nowplaying-$l.json" "$work/$l/nowplaying-compact"
	SWIFTBAR_CARDS_COMPACT=on "$work/bin/sysmon" --render "$repo/samples/sysmon.json" "$work/$l/sysmon-compact"
	"$work/bin/weather" --render-menubar cloud.sun 17° 20 "$work/$l/weather-full"
	SWIFTBAR_CARDS_COMPACT=on "$work/bin/weather" --render-menubar cloud.sun 17° 20 "$work/$l/weather-compact"

	# weather: プラグインを 1 回だけ動かし (--once)、メニューバーの画像とカードを取り出す。
	# メニューバーの行は「image=明るい用,暗い用」の 2 枚の画像なので、外観に合う方を取る。
	# 地点を 2 つ設定して、切り替えの項目も見せる。
	mkdir -p "$work/home/.config/swiftbar-cards" "$work/$l/weather"
	printf 'place=東京\nplace=大阪\n' >"$work/home/.config/swiftbar-cards/weather.conf"
	for appearance in light dark; do
		o=$work/$l/weather/out-$appearance.txt
		HOME=$work/home XDG_CONFIG_HOME=$work/home/.config SWIFTBAR_CARDS_APPEARANCE=$appearance \
			"$repo/plugins/weather.sh" --once >"$o"
		# カードはメニューバーの次の画像だけの行。警報・注意報が出ているとその上に行が入る
		awk 'NR > 1 && /^ \| image=/ { print; exit }' "$o" | sed -nE 's/.*image=([^ ]+).*/\1/p' | base64 -d >"$work/$l/weather/card-$appearance.png"
		i=1
		[[ $appearance == dark ]] && i=2
		sed -n 1p "$o" | sed -nE 's/.*image=([^ ]+).*/\1/p' | cut -d, -f$i | base64 -d >"$work/$l/weather/menubar-$appearance.png"
	done
	# 雨雲の動き: サブメニューの中の地図のカードをそのまま置く
	for appearance in light dark; do
		o=$work/$l/weather/radar-$appearance.txt
		HOME=$work/home XDG_CONFIG_HOME=$work/home/.config SWIFTBAR_CARDS_APPEARANCE=$appearance \
			SWIFTBAR_CARDS_LOCATION=$radar_location "$repo/plugins/weather.sh" --once >"$o"
		grep -m1 '^-- | image=' "$o" | sed -nE 's/.*image=([^ ]+).*/\1/p' | base64 -d >"$out/$l/weather-radar-$appearance.png"
	done
	# 地点の項目 (選んでいる地点は塗りつぶしたピン)。compose の項目の形にする。添えた天気の
	# アイコン (:symbol:) の色を compose が読めるよう、sfcolor を含む行のまま渡す
	locations=()
	while IFS= read -r line; do
		item="mappin.circle:$line"
		[[ $line == *sfimage=mappin.circle.fill* ]] && item="mappin.circle.fill:$line"
		locations+=("$item")
	done < <(grep 'param1=select' "$work/$l/weather/out-light.txt")

	T() { if [[ $l == ja ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
	for appearance in light dark; do
		"$work/bin/compose" "$appearance" "$work/$l/nowplaying/menubar-$appearance.png" "$work/$l/nowplaying/card-$appearance.png" \
			"$out/$l/nowplaying-$appearance.png" "pause.circle:$(T 一時停止 Pause)" "forward.end.circle:$(T 次の曲 'Next Track')" \
			"arrow.up.forward.circle:$(T 'Music を開く' 'Open Music')"
		"$work/bin/compose" "$appearance" "$work/$l/sysmon/menubar-$appearance.png" "$work/$l/sysmon/card-$appearance.png" \
			"$out/$l/sysmon-$appearance.png" "arrow.up.forward.circle:$(T アクティビティモニタを開く 'Open Activity Monitor')"
		"$work/bin/compose" "$appearance" "$work/$l/weather/menubar-$appearance.png" "$work/$l/weather/card-$appearance.png" \
			"$out/$l/weather-$appearance.png" "${locations[@]}" - "gearshape.circle:$(T 設定ファイルを開く 'Open Configuration File')" \
			"arrow.clockwise.circle:$(T 今すぐ更新 'Refresh Now')" \
			"arrow.up.forward.circle:$(T 気象庁の天気予報を開く 'Open JMA Forecast')"
		"$work/bin/density" "$appearance" "$out/$l/menubar-density-$appearance.png" "$(T 通常表示 Full)" "$(T 縮小表示 Compact)" \
			sysmon "$work/$l/sysmon/menubar-$appearance.png" "$work/$l/sysmon-compact/menubar-$appearance.png" \
			weather "$work/$l/weather-full/menubar-$appearance.png" "$work/$l/weather-compact/menubar-$appearance.png" \
			nowplaying "$work/$l/nowplaying/menubar-$appearance.png" "$work/$l/nowplaying-compact/menubar-$appearance.png"
	done
done
ls -R "$out"
