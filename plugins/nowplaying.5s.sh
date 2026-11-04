#!/bin/bash
# <xbar.title>Now Playing (Music.app)</xbar.title>
# <xbar.desc>Music.app で再生中の曲をメニューバーに出す</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# Music.app に AppleScript で問い合わせるだけなので、macOS 15.4 で塞がれた
# MediaRemote には頼らない。初回は SwiftBar から Music を操作する許可を求められる。
#
# 再生していないときも何かを出す。空にすると項目が隠れ、見えるプラグインが
# 無くなった SwiftBar が代わりに「SwiftBar」という項目を出してしまうため。

open_music="Music を開く | sfimage=music.note.list bash=/usr/bin/open param1=-a param2=Music terminal=false"

# `tell application "Music"` は Music が起動していなければ起動してしまうので先に見る。
if ! pgrep -xq Music; then
	echo " | sfimage=music.note"
	echo "---"
	echo "$open_music"
	exit 0
fi

# 状態と曲の情報をタブ区切りで返す。停止中は current track が取れないので空にする。
info=$(
	osascript <<'APPLESCRIPT' 2>/dev/null
tell application "Music"
	set s to player state as text
	try
		set t to current track
		return s & tab & (name of t) & tab & (artist of t) & tab & (album of t)
	on error
		return s
	end try
end tell
APPLESCRIPT
)

IFS=$'\t' read -r state name artist album <<<"$info"

# SwiftBar は " | " 以降を表示のパラメータとして読むので、曲名中の | を逃がす。
esc() { printf '%s' "${1//|/｜}"; }
name=$(esc "$name")
artist=$(esc "$artist")
album=$(esc "$album")

ctl() { echo "$1 | sfimage=$2 bash=/usr/bin/osascript param1=-e param2='tell application \"Music\" to $3' terminal=false refresh=true"; }

if [[ $state == playing ]]; then
	# 長い曲名はノッチの裏に隠れるので切る (切った分はツールチップで全文が出る)。
	echo "$name — $artist | sfimage=music.note length=30"
else
	echo " | sfimage=music.note"
fi
echo "---"
if [[ -n $name ]]; then
	echo "$name | sfimage=music.note"
	echo "$artist | sfimage=person"
	[[ -n $album ]] && echo "$album | sfimage=square.stack"
	echo "---"
fi
if [[ $state == playing ]]; then
	ctl "一時停止" pause.fill playpause
else
	ctl "再生" play.fill play
fi
ctl "次の曲" forward.fill "next track"
ctl "前の曲" backward.fill "previous track"
echo "$open_music"
