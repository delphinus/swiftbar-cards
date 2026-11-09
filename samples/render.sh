#!/bin/bash
# README の画像 (docs/images/*.png) を作る。
#   samples/render.sh [出力先]
# 日本語と英語のそれぞれを docs/images/ja と docs/images/en に描く。nowplaying と
# sysmon は samples/ の架空の値で、weather は東京の今の予報で描く。
# 手元のキャッシュや設定ファイルには触らない (HOME を一時ディレクトリにする)。

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
out=$(mkdir -p "${1:-$repo/docs/images}" && cd "${1:-$repo/docs/images}" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export LANG=en_US.UTF-8
# weather の現在地は、位置情報を読む .app を起動せず、東京駅の座標にする
export SWIFTBAR_CARDS_LOCATION="35.6812 139.7671"

mkdir -p "$work/bin"
for h in nowplaying sysmon; do
	swiftc -O -suppress-warnings -o "$work/bin/$h" "$repo"/Sources/Shared/*.swift "$repo/Sources/$h"/*.swift
done
swiftc -O -suppress-warnings -o "$work/bin/compose" "$repo/samples/compose.swift"

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

	# weather: プラグインを 1 回だけ動かし (--once)、メニューバーの画像とカードを取り出す。
	# メニューバーの行は「image=明るい用,暗い用」の 2 枚の画像なので、外観に合う方を取る。
	# 地点を 2 つ設定して、切り替えの項目も見せる。
	mkdir -p "$work/home/.config/swiftbar-cards" "$work/$l/weather"
	printf 'place=東京\nplace=大阪\n' >"$work/home/.config/swiftbar-cards/weather.conf"
	for appearance in light dark; do
		o=$work/$l/weather/out-$appearance.txt
		HOME=$work/home XDG_CONFIG_HOME=$work/home/.config SWIFTBAR_CARDS_APPEARANCE=$appearance \
			"$repo/plugins/weather.sh" --once >"$o"
		sed -n 3p "$o" | sed -nE 's/.*image=([^ ]+).*/\1/p' | base64 -d >"$work/$l/weather/card-$appearance.png"
		i=1
		[[ $appearance == dark ]] && i=2
		sed -n 1p "$o" | sed -nE 's/.*image=([^ ]+).*/\1/p' | cut -d, -f$i | base64 -d >"$work/$l/weather/menubar-$appearance.png"
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
	done
done
ls -R "$out"
