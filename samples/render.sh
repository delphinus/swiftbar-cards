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

mkdir -p "$work/bin"
for h in nowplaying sysmon; do
	swiftc -O -suppress-warnings -o "$work/bin/$h" "$repo"/Sources/Shared/*.swift "$repo/Sources/$h/main.swift"
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

	# weather: プラグインをそのまま動かし、メニューバーの行とカードを取り出す。
	# 地点を 2 つ設定して、切り替えの項目も見せる。
	mkdir -p "$work/home/.config/swiftbar-cards" "$work/$l/weather"
	printf 'place=東京\nplace=大阪\n' >"$work/home/.config/swiftbar-cards/weather.conf"
	for appearance in light dark; do
		o=$work/$l/weather/out-$appearance.txt
		HOME=$work/home XDG_CONFIG_HOME=$work/home/.config OS_APPEARANCE=$([[ $appearance == dark ]] && echo Dark || echo Light) \
			"$repo/plugins/weather.10m.sh" >"$o"
		sed -n 3p "$o" | sed -nE 's/.*image=([^ ]+).*/\1/p' | base64 -d >"$work/$l/weather/card-$appearance.png"
	done
	location=$(grep -m1 'sfimage=mappin.circle' "$work/$l/weather/out-light.txt" | sed 's/ |.*//')

	T() { if [[ $l == ja ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
	for appearance in light dark; do
		"$work/bin/compose" "$appearance" "$work/$l/nowplaying/menubar-$appearance.png" "$work/$l/nowplaying/card-$appearance.png" \
			"$out/$l/nowplaying-$appearance.png" "pause.circle:$(T 一時停止 Pause)" "forward.end.circle:$(T 次の曲 'Next Track')" \
			"arrow.up.forward.circle:$(T 'Music を開く' 'Open Music')"
		"$work/bin/compose" "$appearance" "$work/$l/sysmon/menubar-$appearance.png" "$work/$l/sysmon/card-$appearance.png" \
			"$out/$l/sysmon-$appearance.png" "arrow.up.forward.circle:$(T アクティビティモニタを開く 'Open Activity Monitor')"
		"$work/bin/compose" "$appearance" "text:$(head -1 "$work/$l/weather/out-$appearance.txt")" "$work/$l/weather/card-$appearance.png" \
			"$out/$l/weather-$appearance.png" "mappin.circle:$location" "gearshape.circle:$(T 設定ファイルを開く 'Open Configuration File')" \
			"arrow.up.forward.circle:$(T 気象庁の天気予報を開く 'Open JMA Forecast')"
	done
done
ls -R "$out"
