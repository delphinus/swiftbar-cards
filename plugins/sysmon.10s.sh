#!/bin/bash
# <xbar.title>System Monitor</xbar.title>
# <xbar.desc>CPU・メモリ・温度をメニューバーに出し、上位のプロセスと Bluetooth 機器のバッテリーをメニューに出す</xbar.desc>
# <xbar.dependencies>macmon (brew install macmon), jq</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# 常駐の監視アプリより軽くするため、CPU を使う処理を減らしてある。
# - 更新は 10 秒ごと。メニューを開いたときには更新しない (refreshOnOpen を付けない)。
#   付けると、開くたびにこのスクリプトの完了 (iostat の計測で 1 秒以上) を待ってから
#   メニューが開くので、クリックしてから開くまでに間が空く。
# - awk や jq を 1 行ごとに呼ばない (それだけで 1 回 0.3 秒ほど CPU を使う)。
#   値の整形は最後に awk 1 回でまとめて行う。
# - ps は 1 回で 0.05 秒ほど使うので 1 回にまとめ、並べ替えは sort に任せる。
# - top -l は 1 回で 1 秒近く使うので避け、CPU 使用率は iostat から取る。
# - 温度 (macmon) はゆっくりしか変わらないので、30 秒に 1 回だけ取り直す。

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# macmon の cpu_usage_pct はコアが起きていた時間の割合で、Activity Monitor の
# 使用率より大きく出る (アイドルに近くても 50% を超える)。使用率は iostat の
# us + sy を使い、macmon は温度と E / P コアの稼働率だけに使う。
temps=~/Library/Caches/swiftbar-sysmon-temps.txt
if command -v macmon >/dev/null && [[ ! -s $temps || -z $(find "$temps" -mtime -30s 2>/dev/null) ]]; then
	{
		macmon pipe -s 1 -i 500 2>/dev/null |
			jq -r '"\(.temp.cpu_temp_avg | round) \(.temp.gpu_temp_avg | round) \(.ecpu_active_ratio * 100 | round) \(.pcpu_active_ratio * 100 | round)"' \
				>"$temps.tmp" && mv "$temps.tmp" "$temps"
	} &
fi
iostat -c 2 -w 1 -n 0 >"$tmp/iostat" 2>/dev/null &

# Bluetooth 機器の名前は system_profiler から取る (ioreg の Product は空になる
# 機器がある)。名前は変わらないので、アドレスとの対応を 1 時間ごとに作り直す。
bt_names=~/Library/Caches/swiftbar-sysmon-bt-names.tsv
if [[ ! -s $bt_names || -n $(find "$bt_names" -mmin +60 2>/dev/null) ]]; then
	system_profiler SPBluetoothDataType -json 2>/dev/null |
		jq -r '.SPBluetoothDataType[0] | ((.device_connected // []) + (.device_not_connected // []))[]
			| to_entries[] | select(.value.device_address) | "\(.value.device_address | ascii_upcase)\t\(.key)"' \
			>"$bt_names.tmp" && mv "$bt_names.tmp" "$bt_names"
fi

ioreg -r -k BatteryPercent -l >"$tmp/ioreg"
vm_stat >"$tmp/vm_stat"
sysctl -n hw.memsize hw.pagesize vm.swapusage kern.memorystatus_vm_pressure_level >"$tmp/sysctl"
ps -Aceo pcpu=,rss=,comm= >"$tmp/ps"
sort -k1,1nr "$tmp/ps" | head -5 >"$tmp/ps_cpu"
sort -k2,2nr "$tmp/ps" | head -5 >"$tmp/ps_mem"
wait

# CPU 使用率の履歴。メニューバーには直近 8 回分 (80 秒) をブロック文字で、
# カードには 60 回分 (10 分) を折れ線グラフで出す。
read -r cpu_us cpu_sy _ < <(tail -1 "$tmp/iostat")
history=~/Library/Caches/swiftbar-sysmon-cpu-history.txt
hist=$( { cat "$history" 2>/dev/null; echo $((cpu_us + cpu_sy)); } | tail -60)
printf "%s\n" "$hist" >"$history"
# awk の -v には改行を含められないので空白区切りで渡す
hist=${hist//$'\n'/ }

dark=false
[[ ${OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null)} == Dark ]] && dark=true

# メニューの中身は 1 枚のカードの画像にする (../helpers/sysmon-card.swift が描く)。
# 初回 (とソースを変えたとき) にコンパイルする。1 回の描画は 0.05 秒ほど。
cache=~/Library/Caches/swiftbar-sysmon
mkdir -p "$cache"
src=$(cd "$(dirname "$0")/../helpers" 2>/dev/null && pwd)/sysmon-card.swift
bin=$cache/sysmon-card
if [[ -f $src && (! -x $bin || $src -nt $bin) ]]; then
	swiftc -O -o "$bin.tmp" "$src" 2>/dev/null && mv "$bin.tmp" "$bin"
fi

# 1 行目にメニューバーの文字の行 (画像を描けなかったとき用)、2 行目にカードの JSON を出す。
# メモリは Activity Monitor の「使用済みメモリ」と同じく、アプリ (anonymous から
# purgeable を除く) + wired + 圧縮で数える。
# メモリプレッシャーは 1 = 正常、2 = 警告、4 = 危険。
# メニューバーの色は ANSI のエスケープで付ける (SwiftBar の ansi=true)。
awk -v tmp="$tmp" -v names="$bt_names" -v temps="$temps" -v hist="$hist" -v dark="$dark" '
# 2 桁に満たない数は、前を数字 1 文字分の空白 (U+2007 figure space) で埋める
function pad2(n) { n = int(n); return (n < 10 ? "\342\200\207" : "") n }
function rest(  s, i) { s = $3; for (i = 4; i <= NF; i++) s = s " " $i; return s }
# JSON の文字列にする
function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return "\"" s "\"" }
function num(v) { return v == "" ? "null" : v + 0 }
# 値に応じた色。warn 以上で黄、crit 以上で赤。
function color(v, warn, crit) { return v >= crit ? RED : v >= warn ? YELLOW : GREEN }
function paint(s, v, warn, crit) { return color(v, warn, crit) s RESET }
# 0〜100 の値を 1 文字の高さ (▁〜▇ の 7 段階) で表す。█ は使わない。▁〜▇ は
# 文字の基準線から上に伸びるが、█ は下にはみ出る部分まで塗るので、並べると
# 上下に一回り大きく見える。
function level(v,  i) { i = int(v / 100 * 7) + 1; if (i < 1) i = 1; if (i > 7) i = 7; return BLOCK[i] }
# 履歴の末尾 n 個で折れ線グラフ風の文字列を作る。足りない分は最低の高さで埋める。
function spark(n, warn, crit,  s, i, v) {
	s = ""
	for (i = nh - n + 1; i <= nh; i++) { v = (i >= 1) ? H[i] : 0; s = s color(v, warn, crit) level(v) }
	return s RESET
}
BEGIN {
	GREEN = "\033[32m"; YELLOW = "\033[33m"; RED = "\033[31m"; RESET = "\033[0m"
	split("▁ ▂ ▃ ▄ ▅ ▆ ▇", BLOCK, " ")
	nh = split(hist, H, " ")

	while ((getline < (tmp "/iostat")) > 0) { us = $1; sy = $2; la = $4 " / " $5 " / " $6 }
	cpu = us + sy

	if (temps != "") while ((getline < temps) > 0) { ctemp = $1; gtemp = $2; ecpu = $3; pcpu = $4 }

	n = 0
	while ((getline line < (tmp "/sysctl")) > 0) s[++n] = line
	total = s[1]; pagesize = s[2]
	split(s[3], sw, " "); for (i in sw) if (sw[i] == "used") swap = sw[i + 2]
	pl = s[4] + 0

	FS = ":"
	while ((getline < (tmp "/vm_stat")) > 0) { v = $2; gsub(/[ .]/, "", v); vm[$1] = v }
	compressed = vm["Pages occupied by compressor"] * pagesize
	used = (vm["Anonymous pages"] - vm["Pages purgeable"] + vm["Pages wired down"]) * pagesize + compressed
	mem = int(used * 100 / total)

	FS = "\t"
	while ((getline < names) > 0) btname[$1] = $2
	FS = " = "
	nb = 0
	while ((getline < (tmp "/ioreg")) > 0) {
		if ($0 ~ /"DeviceAddress" = /) { a = $2; gsub(/"/, "", a); gsub(/-/, ":", a); addr = toupper(a) }
		if ($0 ~ /"BatteryPercent" = /) {
			nb++; bp[nb] = $2 + 0; bn[nb] = (addr in btname) ? btname[addr] : addr; addr = ""
			if (bp[nb] < 20) low = 1
		}
	}
	FS = " "

	# メニューバー。CPU は直近 80 秒の推移、メモリは 1 文字の高さ、温度は色で示す。
	# フォントは指定せず、隣の項目 (天気など) と同じシステムフォントで描かせる。
	# システムフォントは数字ごとに幅が違い、値が変わると項目の幅が少し伸び縮みする。
	# 1 桁のときは数字 1 文字分の空白 (figure space) で埋めて、伸び縮みを小さくする。
	bar = "CPU " spark(8, 50, 80) " " pad2(cpu) "%"
	bar = bar "  MEM " paint(level(mem) " " pad2(mem) "%", mem, 70, 85)
	if (ctemp != "") bar = bar "  " paint(ctemp "°C", ctemp, 70, 85)
	if (low) bar = bar " " RED "⚠︎" RESET
	print bar " | ansi=true"

	# カードの JSON
	h = ""; for (i = 1; i <= nh; i++) h = h (i > 1 ? "," : "") (H[i] + 0)
	j = "{\"dark\":" dark ",\"interval\":10"
	j = j ",\"cpu\":{\"total\":" cpu ",\"user\":" us ",\"sys\":" sy ",\"e\":" num(ecpu) ",\"p\":" num(pcpu)
	j = j ",\"load\":" js(la) ",\"temp\":" num(ctemp) ",\"gpu\":" num(gtemp) ",\"hist\":[" h "]}"
	j = j ",\"mem\":{\"used\":" used ",\"total\":" total ",\"compressed\":" compressed ",\"swap\":" js(swap == "" ? "0" : swap) ",\"pressure\":" pl "}"
	# ps の %CPU は直近の平均なので、iostat の値と合計は一致しない
	j = j ",\"procCpu\":["; k = 0
	while ((getline < (tmp "/ps_cpu")) > 0) j = j (k++ ? "," : "") "{\"name\":" js(rest()) ",\"value\":" ($1 + 0) "}"
	j = j "],\"procMem\":["; k = 0
	while ((getline < (tmp "/ps_mem")) > 0) j = j (k++ ? "," : "") "{\"name\":" js(rest()) ",\"value\":" ($2 + 0) "}"
	j = j "],\"battery\":["
	for (i = 1; i <= nb; i++) j = j (i > 1 ? "," : "") "{\"name\":" js(bn[i]) ",\"percent\":" bp[i] "}"
	j = j "]}"
	print j
}' >"$tmp/out"

# メニューバーも画像にする (CPU の推移を小さな折れ線グラフで描く)。描けなかった
# ときは awk が作った文字の行 (1 行目) を出す。
# カードの行には動作を付けない (無効な項目にする)。動作を付けると、マウスを
# 載せたときにカード全体が選択の色で塗られる。画像は無効な項目でも薄くならない。
if [[ -x $bin ]] && out=$(tail -n +2 "$tmp/out" | "$bin" 2>/dev/null) && [[ -n $out ]]; then
	{ read -r cw ch; read -r card; read -r bw bh; read -r bar_light; read -r bar_dark; } <<<"$out"
	if [[ -n $bar_dark ]]; then
		echo " | image=$bar_light,$bar_dark width=$bw height=$bh"
	else
		head -1 "$tmp/out"
	fi
	echo "---"
	echo " | image=$card width=$cw height=$ch"
else
	head -1 "$tmp/out"
	echo "---"
	echo "カードを描けなかった | refresh=true"
fi
echo "---"
echo "アクティビティモニタを開く | sfimage=arrow.up.forward.circle bash=/usr/bin/open param1=-a param2=\"Activity Monitor\" terminal=false"
