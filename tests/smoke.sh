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
	if shellcheck "$repo"/plugins/*.sh "$repo"/tests/*.sh; then ok shellcheck; else ng shellcheck; fi
else
	echo "skip - shellcheck が無い"
fi

echo "# ビルド"
for src in "$repo"/helpers/*.swift; do
	name=$(basename "$src" .swift)
	if swiftc -O -o "$work/$name" "$src" 2>"$work/$name.log"; then ok "build $name"; else
		cat "$work/$name.log"
		ng "build $name"
	fi
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
run_weather yokohama Light "place=横浜"
if grep -q 'image=' "$work/weather-yokohama.txt" && save_image "$work/weather-yokohama.txt" 3 weather-yokohama; then
	ok "weather place=横浜"
else ng "weather place=横浜"; fi
run_weather fuchu Light "place=府中"
if grep -q 'amedas=44116' "$work/weather-fuchu.txt" && grep -q 'amedas=67326' "$work/weather-fuchu.txt"; then
	ok "weather place=府中 は候補を出す"
else
	cat "$work/weather-fuchu.txt"
	ng "weather place=府中 は候補を出す"
fi
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
