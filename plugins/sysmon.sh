#!/bin/bash
# <xbar.title>System Monitor</xbar.title>
# <xbar.desc>CPU・メモリ・温度をメニューバーに出し、上位のプロセスと Bluetooth 機器のバッテリーをメニューに出す</xbar.desc>
# <xbar.dependencies>macmon (brew install macmon)</xbar.dependencies>
# <swiftbar.type>streamable</swiftbar.type>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# 常駐型 (streamable) のプラグイン。中身は ../helpers/sysmon.swift で、ここでは
# それをコンパイルして起動するだけ。10 秒ごとに値を集めて描き、メニューを
# 差し替える。以前の 10 秒ごとにスクリプトを起動する形より CPU を使わない
# (平均して 1 コアの 2.5% ほどから 1% ほどへ)。

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

cache=~/Library/Caches/swiftbar-sysmon
mkdir -p "$cache"
src=$(cd "$(dirname "$0")/../helpers" 2>/dev/null && pwd)/sysmon.swift
bin=$cache/sysmon
if [[ -f $src && (! -x $bin || $src -nt $bin) ]]; then
	swiftc -O -o "$bin.tmp" "$src" 2>/dev/null && mv "$bin.tmp" "$bin"
fi
if [[ ! -x $bin ]]; then
	echo "sysmon: コンパイルできない | sfimage=exclamationmark.triangle"
	exit 0
fi
# 以前の形 (sysmon.10s.sh) で使っていたファイルを消す
rm -f "$cache/sysmon-card" ~/Library/Caches/swiftbar-sysmon-temps.txt ~/Library/Caches/swiftbar-sysmon-bt-names.tsv
exec "$bin"
