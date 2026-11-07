#!/bin/bash
# data/jma-telops.json (天気コード → 英語の名前・日本語の名前・代表の天気) を作り直す。
# 気象庁の予報のページ (www.jma.go.jp/bosai/forecast/) の HTML に埋め込まれた
# TELOPS という表 (コード → [昼のアイコン, 夜のアイコン, 代表のコード, 日本語, 英語])
# から抜き出す。英語は全部大文字で配られるので、文頭だけ大文字にする。代表のコードは
# 100 (晴)・200 (曇)・300 (雨)・400 (雪) のどれかで、天気のアイコンを決めるのに使う。
set -euo pipefail
out=$(cd "$(dirname "$0")/.." && pwd)/data/jma-telops.json
curl -sf https://www.jma.go.jp/bosai/forecast/ |
	perl -0ne 'print $1 if /TELOPS=(\{.*?\]\})/s' |
	perl -pe 's/(\d+):\[/"$1":[/g' |
	jq -S 'map_values({
		en: (.[4] | ascii_downcase | gsub(",(?! )"; ", ") | (.[0:1] | ascii_upcase) + .[1:]),
		ja: .[3],
		base: .[2]
	})' >"$out.tmp"
[[ $(jq length "$out.tmp") -gt 100 ]] || {
	echo "表を抜き出せなかった" >&2
	rm -f "$out.tmp"
	exit 1
}
mv "$out.tmp" "$out"
echo "$out: $(jq length "$out") 件"
