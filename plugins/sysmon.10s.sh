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

# メモリは Activity Monitor の「使用済みメモリ」と同じく、アプリ (anonymous から
# purgeable を除く) + wired + 圧縮で数える。
# メモリプレッシャーは 1 = 正常、2 = 警告、4 = 危険。
# SwiftBar は " | " 以降を表示のパラメータとして読むので、名前の中の | を逃がす。
awk -v mono="font=Menlo size=12" -v tmp="$tmp" -v names="$bt_names" -v temps="$temps" '
function gb(b) { return sprintf("%.1f GB", b / 1073741824) }
function size(k) { return k >= 1048576 ? sprintf("%.1f GB", k / 1048576) : sprintf("%d MB", k / 1024) }
function esc(s) { gsub(/\|/, "｜", s); return s }
function rest(  s, i) { s = $3; for (i = 4; i <= NF; i++) s = s " " $i; return s }
BEGIN {
	while ((getline < (tmp "/iostat")) > 0) { us = $1; sy = $2; la = $4 " / " $5 " / " $6 }
	cpu = us + sy

	if (temps != "") while ((getline < temps) > 0) { ctemp = $1; gtemp = $2; ecpu = $3; pcpu = $4 }

	n = 0
	while ((getline line < (tmp "/sysctl")) > 0) s[++n] = line
	total = s[1]; pagesize = s[2]
	split(s[3], sw, " "); for (i in sw) if (sw[i] == "used") swap = sw[i + 2]
	pressure = s[4] == 1 ? "正常" : s[4] == 2 ? "警告" : s[4] == 4 ? "危険" : "不明"

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

	# メニューバー。数字の幅が変わっても位置がずれないよう等幅のフォントにする。
	bar = sprintf("CPU %2d%% MEM %2d%%", cpu, mem)
	if (ctemp != "") bar = bar " " ctemp "°C"
	if (low) bar = bar " ⚠︎"
	print bar " | font=Menlo size=11"
	print "---"

	print "CPU | sfimage=cpu"
	printf "使用率      %3d%%  (ユーザ %d%% / システム %d%%) | %s\n", cpu, us, sy, mono
	if (ecpu != "") printf "コアの稼働  E %d%% / P %d%% | %s\n", ecpu, pcpu, mono
	printf "負荷        %s | %s\n", la, mono
	if (ctemp != "") printf "温度        CPU %d°C / GPU %d°C | %s\n", ctemp, gtemp, mono
	else printf "温度        macmon が見つからない | %s\n", mono
	print "---"

	print "メモリ | sfimage=memorychip"
	printf "使用済み    %s / %s  (%d%%) | %s\n", gb(used), gb(total), mem, mono
	printf "圧縮        %s | %s\n", gb(compressed), mono
	printf "スワップ    %s | %s\n", (swap == "" ? "0" : swap), mono
	printf "メモリプレッシャー  %s | %s\n", pressure, mono
	print "---"

	# ps の %CPU は直近の平均なので、iostat の値と合計は一致しない。
	print "CPU を使っているプロセス | sfimage=flame"
	while ((getline < (tmp "/ps_cpu")) > 0) printf "%6.1f%%  %s | %s\n", $1, esc(rest()), mono
	print "メモリを使っているプロセス | sfimage=square.stack.3d.up"
	while ((getline < (tmp "/ps_mem")) > 0) printf "%9s  %s | %s\n", size($2), esc(rest()), mono
	print "---"

	if (nb) {
		print "バッテリー | sfimage=battery.75percent"
		for (i = 1; i <= nb; i++) printf "%4d%%  %s | %s\n", bp[i], esc(bn[i]), mono
		print "---"
	}
	print "アクティビティモニタを開く | sfimage=arrow.up.forward.circle bash=/usr/bin/open param1=-a param2=\"Activity Monitor\" terminal=false"
}'
