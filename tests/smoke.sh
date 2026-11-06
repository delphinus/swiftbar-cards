#!/bin/bash
# プラグインを実際に起動して、メニューの行とカードの画像が出るかを確かめる。
# CI (.github/workflows/ci.yml) と手元の両方で使う。
#
#   tests/smoke.sh [出力先]
#
# 描いた画像は出力先 (既定は ./smoke-out) に PNG で置く。HOME を一時ディレクトリに
# するので、手元のキャッシュや設定ファイルには触らない。weather は気象庁のデータを
# 実際に取りに行く。

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
out=$(mkdir -p "${1:-smoke-out}" && cd "${1:-smoke-out}" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home XDG_CONFIG_HOME=$work/home/.config
# SwiftBar と同じく、プラグインは shebang の /bin/bash (macOS 標準の 3.2) で、
# UTF-8 のロケールで動かす。bash 3.2 は UTF-8 のロケールで "$var」" の 」 まで
# 変数名として読むなど、新しい bash と振る舞いが違う。
export LANG=en_US.UTF-8
unset LC_ALL
# 表示の言語は OS の設定に従うので、確かめる文言に合わせて日本語に決め打ちする
# (CI の仮想マシンは英語)。英語の確認だけ SWIFTBAR_CARDS_LANG=en にする。
export SWIFTBAR_CARDS_LANG=ja
# 裏の取り直しが終わったときに、本物の SwiftBar へ更新を指示しない
export SWIFTBAR_CARDS_NO_REFRESH=1
# weather の現在地は、位置情報を読む .app を起動せず、東京駅の座標を使う
# (CI では位置情報を読めず、手元では許可のダイアログが出てしまう)
export SWIFTBAR_CARDS_LOCATION="35.6812 139.7671"
mkdir -p "$HOME"

failures=0
ok() { echo "ok - $*"; }
ng() {
	echo "not ok - $*"
	failures=$((failures + 1))
}

# 出力の中の image=<Base64> を PNG にして置く。1 つめの画像だけを取る
# (メニューバーの image= は「明るい用,暗い用」の 2 枚を , で並べている)。
save_image() { # <出力のファイル> <行番号> <名前>
	local b64
	b64=$(sed -n "$2p" "$1" | sed -nE 's/.*image=([^ ,]+).*/\1/p')
	[[ -n $b64 ]] && base64 -d <<<"$b64" >"$out/$3.png" 2>/dev/null && file -b "$out/$3.png" | grep -q '^PNG image'
}

echo "# shellcheck"
if command -v shellcheck >/dev/null; then
	if shellcheck -x "$repo"/plugins/*.sh "$repo"/tests/*.sh "$repo"/samples/*.sh "$repo"/scripts/*.sh; then ok shellcheck; else ng shellcheck; fi
else
	echo "skip - shellcheck が無い"
fi

echo "# ビルド"
for main in "$repo"/Sources/*/main.swift; do
	dir=$(dirname "$main")
	name=$(basename "$dir")
	if swiftc -O -o "$work/$name" "$repo"/Sources/Shared/*.swift "$dir"/*.swift 2>"$work/$name.log"; then ok "build $name"; else
		cat "$work/$name.log"
		ng "build $name"
	fi
done

echo "# サンプルの値で描く (--render)"
# nowplaying は曲の入ったカードを、CI でも描けるのはこの方法だけ (再生中の曲が無い)
swift "$repo/samples/artwork.swift" "$work/artwork.png"
sed "s#\"artwork.png\"#\"$work/artwork.png\"#" "$repo/samples/nowplaying.json" >"$work/nowplaying.json"
for h in nowplaying sysmon; do
	json=$repo/samples/$h.json
	[[ $h == nowplaying ]] && json=$work/nowplaying.json
	for l in ja en; do
		ok_all=1
		if SWIFTBAR_CARDS_LANG=$l "$work/$h" --render "$json" "$work/render-$h-$l"; then
			for f in menubar-light menubar-dark card-light card-dark; do
				if file -b "$work/render-$h-$l/$f.png" | grep -q '^PNG image'; then
					cp "$work/render-$h-$l/$f.png" "$out/render-$h-$l-$f.png"
				else ok_all=; fi
			done
		else ok_all=; fi
		if [[ -n $ok_all ]]; then ok "render $h ($l)"; else ng "render $h ($l)"; fi
	done
done

echo "# weather"
conf=$XDG_CONFIG_HOME/swiftbar-cards/weather.conf
mkdir -p "$(dirname "$conf")"
run_weather() { # <名前> <外観> [設定ファイルの中身]
	if [[ -n ${3:-} ]]; then printf '%s\n' "$3" >"$conf"; else rm -f "$conf"; fi
	OS_APPEARANCE=$2 "$repo/plugins/weather.10m.sh" >"$work/weather-$1.txt"
}
for appearance in Light Dark; do
	name=default-$appearance
	run_weather "$name" "$appearance"
	if head -1 "$work/weather-$name.txt" | grep -q '°' && save_image "$work/weather-$name.txt" 3 "weather-$name"; then
		ok "weather $name"
	else
		cut -c1-200 "$work/weather-$name.txt"
		ng "weather $name"
	fi
done
# 設定ファイルが無ければ現在地だけ (切り替えの項目は出ない)。東京駅にいちばん
# 近い気温の観測点は東京
if grep -q 'area_code=130000' "$work/weather-default-Light.txt" && ! grep -q 'param1=select' "$work/weather-default-Light.txt"; then
	ok "weather 既定は現在地"
else ng "weather 既定は現在地"; fi
SWIFTBAR_CARDS_LOCATION="43.0618 141.3545" run_weather here-sapporo Light "place=東京"
if grep -q 'area_code=016000' "$work/weather-here-sapporo.txt" && grep -q '^現在地 (札幌) .*sfimage=location.circle.fill ' "$work/weather-here-sapporo.txt"; then
	ok "weather 現在地 (札幌)"
else
	grep -v ' image=' "$work/weather-here-sapporo.txt"
	ng "weather 現在地 (札幌)"
fi
SWIFTBAR_CARDS_LOCATION=none run_weather here-none Light
if grep -q 'area_code=130000' "$work/weather-here-none.txt" && grep -q '^現在地を取得できないので、東京を表示中' "$work/weather-here-none.txt"; then
	ok "weather 現在地が分からなければ東京"
else
	grep -v ' image=' "$work/weather-here-none.txt"
	ng "weather 現在地が分からなければ東京"
fi
run_weather yokohama Light "place=横浜"
if grep -q 'image=' "$work/weather-yokohama.txt" && save_image "$work/weather-yokohama.txt" 3 weather-yokohama; then
	ok "weather place=横浜"
else ng "weather place=横浜"; fi
# 何も選んでいなければ現在地を出すので、設定の不備はその地点を選んでから確かめる
"$repo/plugins/weather.10m.sh" select 府中
run_weather fuchu Light "place=府中"
if grep -q 'place=44116' "$work/weather-fuchu.txt" && grep -q 'place=67326' "$work/weather-fuchu.txt"; then
	ok "weather place=府中 は候補を出す"
else
	cat "$work/weather-fuchu.txt"
	ng "weather place=府中 は候補を出す"
fi
# 現在地は書かなくても先頭に出る。書いてあればその位置に出る
run_weather multi Light "$(printf 'place=東京\nplace=横浜')"
if [[ $(grep -c 'param1=select' "$work/weather-multi.txt") == 3 ]] && grep -q '^現在地 (東京) .*sfimage=location.circle.fill ' "$work/weather-multi.txt" &&
	[[ $(grep 'param1=select' "$work/weather-multi.txt" | sed 's/ |.*//' | tr '\n' ,) == '現在地 (東京),東京,横浜,' ]]; then
	ok "weather 現在地と設定した地点を切り替えのメニューに出す"
else
	grep -v image= "$work/weather-multi.txt"
	ng "weather 現在地と設定した地点を切り替えのメニューに出す"
fi
run_weather here-last Light "$(printf 'place=東京\nplace=現在地')"
if [[ $(grep 'param1=select' "$work/weather-here-last.txt" | sed 's/ |.*//' | tr '\n' ,) == '東京,現在地 (東京),' ]]; then
	ok "weather 現在地を書いた位置に出す"
else
	grep -v ' image=' "$work/weather-here-last.txt"
	ng "weather 現在地を書いた位置に出す"
fi
# 東京にいるとき (現在地の観測点も東京) に東京を選んでも、現在地を選んだことにならない
"$repo/plugins/weather.10m.sh" select 東京
run_weather here-same Light "$(printf 'place=東京\nplace=横浜')"
if grep -q '^東京 .*sfimage=mappin.circle.fill ' "$work/weather-here-same.txt" && grep -q '^現在地 (東京) .*sfimage=location.circle ' "$work/weather-here-same.txt"; then
	ok "weather 現在地と同じ観測点を選んでも区別する"
else
	grep 'param1=select' "$work/weather-here-same.txt" | sed 's/ bash=.*//'
	ng "weather 現在地と同じ観測点を選んでも区別する"
fi
"$repo/plugins/weather.10m.sh" select 現在地
# 選んでいない地点 (横浜) のカードを裏で描いてキャッシュに置く
for ((i = 0; i < 60; i++)); do
	compgen -G "$HOME/Library/Caches/swiftbar-weather/body-46106-*" >/dev/null && break
	sleep 0.5
done
if compgen -G "$HOME/Library/Caches/swiftbar-weather/body-46106-*" >/dev/null; then
	ok "weather 選んでいない地点のカードを裏で描く"
else ng "weather 選んでいない地点のカードを裏で描く"; fi
"$repo/plugins/weather.10m.sh" select 横浜
run_weather multi-selected Light "$(printf 'place=東京\nplace=横浜')"
if grep -q '^横浜 .*sfimage=mappin.circle.fill ' "$work/weather-multi-selected.txt"; then ok "weather 選んだ地点を覚える"; else ng "weather 選んだ地点を覚える"; fi
# 選んだ直後はキャッシュのカードと「更新中…」を出し、裏で取り直す。取り直し終わると
# fresh の印が付き、続く実行は「更新中…」を出さない。
if grep -q '^更新中…' "$work/weather-multi-selected.txt"; then ok "weather 選んだ直後は更新中と出す"; else ng "weather 選んだ直後は更新中と出す"; fi
for ((i = 0; i < 60; i++)); do
	[[ -f $HOME/Library/Caches/swiftbar-weather/fresh ]] && break
	sleep 0.5
done
run_weather multi-fresh Light "$(printf 'place=東京\nplace=横浜')"
if [[ ! -f $HOME/Library/Caches/swiftbar-weather/fresh ]] && ! grep -q '^更新中…' "$work/weather-multi-fresh.txt" &&
	grep -q '^横浜 .*sfimage=mappin.circle.fill ' "$work/weather-multi-fresh.txt"; then
	ok "weather 取り直し終わったら更新中を消す"
else ng "weather 取り直し終わったら更新中を消す"; fi
# 同名の観測点がある地点を選んだあと、番号に書き換えても選んだままになる
"$repo/plugins/weather.10m.sh" select 府中
run_weather renumbered Light "$(printf 'place=東京\nplace=44116 # 府中')"
if grep -q '^府中 .*sfimage=mappin.circle.fill ' "$work/weather-renumbered.txt" && head -1 "$work/weather-renumbered.txt" | grep -q '°'; then
	ok "weather 番号に書き換えても選んだ地点のまま"
else ng "weather 番号に書き換えても選んだ地点のまま"; fi
"$repo/plugins/weather.10m.sh" select 東京
SWIFTBAR_CARDS_LANG=en run_weather english Light "place=横浜"
if grep -q 'Open JMA Forecast' "$work/weather-english.txt" && save_image "$work/weather-english.txt" 3 weather-english; then
	ok "weather 英語"
else ng "weather 英語"; fi
# 何も選んでいなければ現在地を出すので、設定の不備はその地点を選んでから確かめる
"$repo/plugins/weather.10m.sh" select 存在しない地点
run_weather missing Light "place=存在しない地点"
if grep -q '見つからない' "$work/weather-missing.txt"; then ok "weather 見つからない地点"; else
	cat "$work/weather-missing.txt"
	ng "weather 見つからない地点"
fi

# 常駐型のプラグインは、最初の区切り (~~~) が届いたら止める
run_stream() { # <プラグイン> <出力のファイル>
	"$repo/plugins/$1" >"$2" 2>/dev/null &
	local pid=$! i
	for ((i = 0; i < 120; i++)); do
		grep -qx '~~~' "$2" 2>/dev/null && break
		sleep 0.5
	done
	pkill -P "$pid" 2>/dev/null || true
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	grep -qx '~~~' "$2"
}

echo "# sysmon"
if run_stream sysmon.sh "$work/sysmon.txt" && save_image "$work/sysmon.txt" 1 sysmon-menubar && save_image "$work/sysmon.txt" 3 sysmon-card; then
	ok sysmon
else
	cut -c1-200 "$work/sysmon.txt"
	ng sysmon
fi

echo "# nowplaying"
if run_stream nowplaying.sh "$work/nowplaying.txt" && [[ -n $(head -1 "$work/nowplaying.txt") ]]; then
	ok nowplaying
else
	cut -c1-200 "$work/nowplaying.txt"
	ng nowplaying
fi

echo "# 画像: $out"
ls "$out"
if ((failures > 0)); then
	echo "失敗 $failures 件"
	exit 1
fi
