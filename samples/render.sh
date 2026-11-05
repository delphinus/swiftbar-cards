#!/bin/bash
# README の画像 (docs/images/*.png) を作る。
#   samples/render.sh [出力先]
# nowplaying と sysmon は samples/ の架空の値で、weather は東京の今の予報で描く。
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
sed "s#\"artwork.png\"#\"$work/artwork.png\"#" "$repo/samples/nowplaying.json" >"$work/nowplaying.json"
"$work/bin/nowplaying" --render "$work/nowplaying.json" "$work/nowplaying"
"$work/bin/sysmon" --render "$repo/samples/sysmon.json" "$work/sysmon"

# weather: プラグインをそのまま動かし、メニューバーの行とカードを取り出す
mkdir -p "$work/home" "$work/weather"
for appearance in light dark; do
	o=$work/weather/out-$appearance.txt
	HOME=$work/home XDG_CONFIG_HOME=$work/home/.config OS_APPEARANCE=$([[ $appearance == dark ]] && echo Dark || echo Light) \
		"$repo/plugins/weather.10m.sh" >"$o"
	sed -n 3p "$o" | sed -nE 's/.*image=([^ ]+).*/\1/p' | base64 -d >"$work/weather/card-$appearance.png"
done

for appearance in light dark; do
	"$work/bin/compose" "$appearance" "$work/nowplaying/menubar-$appearance.png" "$work/nowplaying/card-$appearance.png" \
		"$out/nowplaying-$appearance.png" "pause.circle:一時停止" "forward.end.circle:次の曲" "arrow.up.forward.circle:Music を開く"
	"$work/bin/compose" "$appearance" "$work/sysmon/menubar-$appearance.png" "$work/sysmon/card-$appearance.png" \
		"$out/sysmon-$appearance.png" "arrow.up.forward.circle:アクティビティモニタを開く"
	"$work/bin/compose" "$appearance" "text:$(head -1 "$work/weather/out-$appearance.txt")" "$work/weather/card-$appearance.png" \
		"$out/weather-$appearance.png" "gearshape.circle:設定ファイルを開く" "arrow.up.forward.circle:気象庁の天気予報を開く"
done
ls "$out"
