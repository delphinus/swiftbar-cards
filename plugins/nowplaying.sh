#!/bin/bash
# <xbar.title>Now Playing (Music.app)</xbar.title>
# <xbar.desc>Music.app で再生中の曲をメニューバーに出す</xbar.desc>
# <swiftbar.type>streamable</swiftbar.type>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# 常駐型 (streamable) のプラグイン。中身は ../helpers/nowplaying.swift で、ここでは
# それをコンパイルして起動するだけ。Music.app の通知で更新し、再生中だけ 5 秒ごとに
# 再生位置を問い合わせる。一時停止中・停止中は何もしない。
#
# Music.app に AppleScript で問い合わせるだけなので、macOS 15.4 で塞がれた
# MediaRemote には頼らない。初回は SwiftBar から Music を操作する許可を求められる。

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

cache=~/Library/Caches/swiftbar-nowplaying
mkdir -p "$cache"
src=$(cd "$(dirname "$0")/../helpers" 2>/dev/null && pwd)/nowplaying.swift
bin=$cache/nowplaying
if [[ -f $src && (! -x $bin || $src -nt $bin) ]]; then
	swiftc -O -o "$bin.tmp" "$src" 2>/dev/null && mv "$bin.tmp" "$bin"
fi
if [[ ! -x $bin ]]; then
	echo " | sfimage=music.note"
	echo "---"
	echo "nowplaying: コンパイルできない"
	exit 0
fi
# 以前の形 (nowplaying.5s.sh) で使っていたファイルを消す
rm -f "$cache/nowplaying-card" "$cache/out.txt" "$cache"/*.jpg "$cache"/*.small "$cache"/*.large
exec "$bin"
