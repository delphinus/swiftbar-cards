#!/bin/bash
# <xbar.title>System Monitor</xbar.title>
# <xbar.desc>CPU・メモリ・温度をメニューバーに出し、上位のプロセスと Bluetooth 機器のバッテリーをメニューに出す</xbar.desc>
# <xbar.dependencies>macmon (brew install macmon), jq</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
#
# 常駐の監視アプリより軽くするため、CPU を使う処理を減らしてある。
# - 更新は 10 秒ごと。メニューを開いたときにも更新するので、メニューには最新の値が出る。
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

# CPU 使用率の履歴。メニューバーには直近 8 回分 (80 秒)、メニューには 36 回分
# (6 分) を折れ線グラフ風に出す。
read -r cpu_us cpu_sy _ < <(tail -1 "$tmp/iostat")
history=~/Library/Caches/swiftbar-sysmon-cpu-history.txt
hist=$( { cat "$history" 2>/dev/null; echo $((cpu_us + cpu_sy)); } | tail -36)
printf "%s\n" "$hist" >"$history"
# awk の -v には改行を含められないので空白区切りで渡す
hist=${hist//$'\n'/ }

# ansi=true の行では、色を指定していない部分が SwiftBar の既定の色 (暗い灰) で
# 描かれ、ダークモードのメニューでは読めない。システムの外観に合わせた文字色を、
# 行頭と色のリセットの後ろに入れる。メニューバーの行 (最初の --- より前) は
# メニューバーの外観で描かれるので触らない。
fg_fix() {
	local fg=$'\e[30m'
	[[ $(defaults read -g AppleInterfaceStyle 2>/dev/null) == Dark ]] && fg=$'\e[97m'
	FG=$fg perl -pe 'BEGIN { $fg = $ENV{FG} } if ($menu && / ansi=true/) { s/\e\[0m/\e[0m$fg/g; $_ = $fg . $_ } $menu = 1 if /^---$/'
}

# メモリは Activity Monitor の「使用済みメモリ」と同じく、アプリ (anonymous から
# purgeable を除く) + wired + 圧縮で数える。
# メモリプレッシャーは 1 = 正常、2 = 警告、4 = 危険。
# SwiftBar は " | " 以降を表示のパラメータとして読むので、名前の中の | を逃がす。
# 色は ANSI のエスケープで付ける (SwiftBar の ansi=true)。
awk -v tmp="$tmp" -v names="$bt_names" -v temps="$temps" -v hist="$hist" '
function gb(b) { return sprintf("%.1f GB", b / 1073741824) }
function size(k) { return k >= 1048576 ? sprintf("%.1f GB", k / 1048576) : sprintf("%d MB", k / 1024) }
function esc(s) { gsub(/\|/, "｜", s); return s }
function rest(  s, i) { s = $3; for (i = 4; i <= NF; i++) s = s " " $i; return s }
# 値に応じた色。warn 以上で黄、crit 以上で赤。
function color(v, warn, crit) { return v >= crit ? RED : v >= warn ? YELLOW : GREEN }
function paint(s, v, warn, crit) { return color(v, warn, crit) s RESET }
# 0〜100 の値を 1 文字の高さで表す
function level(v,  i) { i = int(v / 100 * 8) + 1; if (i < 1) i = 1; if (i > 8) i = 8; return BLOCK[i] }
# 横棒のメーター。width 文字ぶんを 1/8 刻みで塗り、col の色を付ける。
function meter(v, width, col,  cells, full, part, s, i) {
	if (v < 0) v = 0; if (v > 100) v = 100
	cells = v / 100 * width; full = int(cells); part = int((cells - full) * 8)
	s = ""
	for (i = 0; i < full; i++) s = s "█"
	if (full < width) { s = s (part ? PART[part] : " "); for (i = full + 1; i < width; i++) s = s " " }
	return col s RESET DIM "▏" RESET
}
# 履歴の末尾 n 個で折れ線グラフ風の文字列を作る。足りない分は最低の高さで埋める。
function spark(n, warn, crit,  s, i, v) {
	s = ""
	for (i = nh - n + 1; i <= nh; i++) { v = (i >= 1) ? H[i] : 0; s = s color(v, warn, crit) level(v) }
	return s RESET
}
BEGIN {
	GREEN = "\033[32m"; YELLOW = "\033[33m"; RED = "\033[31m"; DIM = "\033[2m"; RESET = "\033[0m"
	split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", BLOCK, " ")
	split("▏ ▎ ▍ ▌ ▋ ▊ ▉", PART, " ")
	mono = "font=Menlo size=12 ansi=true"
	nh = split(hist, H, " ")

	while ((getline < (tmp "/iostat")) > 0) { us = $1; sy = $2; la = $4 " / " $5 " / " $6 }
	cpu = us + sy

	if (temps != "") while ((getline < temps) > 0) { ctemp = $1; gtemp = $2; ecpu = $3; pcpu = $4 }

	n = 0
	while ((getline line < (tmp "/sysctl")) > 0) s[++n] = line
	total = s[1]; pagesize = s[2]
	split(s[3], sw, " "); for (i in sw) if (sw[i] == "used") swap = sw[i + 2]
	pl = s[4] + 0
	pressure = pl == 1 ? GREEN "正常" : pl == 2 ? YELLOW "警告" : pl == 4 ? RED "危険" : "不明"

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
	# 数字の幅が変わっても位置がずれないよう等幅のフォントにする。
	bar = "CPU " spark(8, 50, 80) sprintf(" %2d%%", cpu)
	bar = bar "  MEM " paint(level(mem) sprintf(" %2d%%", mem), mem, 70, 85)
	if (ctemp != "") bar = bar "  " paint(ctemp "°C", ctemp, 70, 85)
	if (low) bar = bar " " RED "⚠︎" RESET
	print bar " | font=Menlo size=11 ansi=true"
	print "---"

	print "CPU | sfimage=cpu"
	printf "使用率    %s %3d%%  (ユーザ %d%% / システム %d%%) | %s\n", meter(cpu, 16, color(cpu, 50, 80)), cpu, us, sy, mono
	if (ecpu != "") {
		printf "E コア    %s %3d%% | %s\n", meter(ecpu, 16, color(ecpu, 70, 90)), ecpu, mono
		printf "P コア    %s %3d%% | %s\n", meter(pcpu, 16, color(pcpu, 50, 80)), pcpu, mono
	}
	printf "推移      %s  (6 分) | %s\n", spark(36, 50, 80), mono
	printf "負荷      %s | %s\n", la, mono
	if (ctemp != "") {
		# 温度のメーターは 30〜100°C を 0〜100% として描く
		printf "CPU 温度  %s %3d°C | %s\n", meter((ctemp - 30) / 70 * 100, 16, color(ctemp, 70, 85)), ctemp, mono
		printf "GPU 温度  %s %3d°C | %s\n", meter((gtemp - 30) / 70 * 100, 16, color(gtemp, 70, 85)), gtemp, mono
	} else printf "温度      macmon が見つからない | %s\n", mono
	print "---"

	print "メモリ | sfimage=memorychip"
	printf "使用済み  %s %3d%%  (%s / %s) | %s\n", meter(mem, 16, color(mem, 70, 85)), mem, gb(used), gb(total), mono
	printf "圧縮      %s | %s\n", gb(compressed), mono
	printf "スワップ  %s | %s\n", (swap == "" ? "0" : swap), mono
	printf "メモリプレッシャー  %s%s | %s\n", pressure, RESET, mono
	print "---"

	# ps の %CPU は直近の平均で、1 コアを使い切ると 100%。メーターは 100% で頭打ちにする。
	print "CPU を使っているプロセス | sfimage=flame"
	while ((getline < (tmp "/ps_cpu")) > 0) printf "%s %6.1f%%  %s | %s\n", meter($1, 8, color($1, 50, 90)), $1, esc(rest()), mono
	# メモリのメーターは 4 GB を 100% として描く
	print "メモリを使っているプロセス | sfimage=square.stack.3d.up"
	while ((getline < (tmp "/ps_mem")) > 0) printf "%s %8s  %s | %s\n", meter($2 / 4194304 * 100, 8, color($2 / 4194304 * 100, 50, 90)), size($2), esc(rest()), mono
	print "---"

	if (nb) {
		print "バッテリー | sfimage=battery.75percent"
		# 残量は少ないほど危ないので、少ないときに黄・赤にする
		for (i = 1; i <= nb; i++)
			printf "%s %3d%%  %s | %s\n", meter(bp[i], 10, (bp[i] < 20 ? RED : bp[i] < 40 ? YELLOW : GREEN)), bp[i], esc(bn[i]), mono
		print "---"
	}
	print "アクティビティモニタを開く | sfimage=arrow.up.forward.circle bash=/usr/bin/open param1=-a param2=\"Activity Monitor\" terminal=false"
}' | fg_fix
