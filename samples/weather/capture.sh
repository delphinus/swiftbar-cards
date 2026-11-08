#!/bin/bash
# weather の --render に渡すデータ (samples/weather/) を、気象庁の今のデータで取り直す。
#   samples/weather/capture.sh
# プラグインを 1 回だけ動かし (--once)、東京のキャッシュを cache/ に写す。アメダスの
# 全観測点の最新値 (amedas.json) は、東京 (44132) の分だけに絞る。sample.json の
# now は、その観測の時刻に書き換える (観測点・祝日などの残りの値は手で書いたもの)。
# 取り直したら、比べる元の画像 (tests/baseline/) も作り直すこと (README の
# 「画像のリグレッションテスト」)。

set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$dir/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home XDG_CONFIG_HOME=$work/home/.config LANG=en_US.UTF-8
export SWIFTBAR_CARDS_LOCATION="35.6812 139.7671" SWIFTBAR_CARDS_APPEARANCE=light
mkdir -p "$HOME"
"$repo/plugins/weather.sh" --once >/dev/null

src=$HOME/Library/Caches/swiftbar-weather
rm -rf "$dir/cache"
mkdir -p "$dir/cache/amedas"
cp "$src/forecast-130000.json" "$src/vpfd-130010.json" "$src/amedas-time.txt" "$dir/cache/"
cp "$src"/amedas/44132_*.json "$dir/cache/amedas/"
jq -c '{"44132": .["44132"]}' "$src/amedas.json" >"$dir/cache/amedas.json"
now=$(cat "$src/amedas-time.txt")
jq --arg now "$now" '.now = $now' "$dir/sample.json" >"$work/sample.json"
mv "$work/sample.json" "$dir/sample.json"
echo "now: $now"
