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
# 何も出力しないと SwiftBar は項目を隠すので、停止中・未起動のときは空にする。

# `tell application "Music"` は Music が起動していなければ起動してしまうので先に見る。
pgrep -xq Music || exit 0

info=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "Music"
	if player state is not playing then return ""
	set t to current track
	return (name of t) & tab & (artist of t) & tab & (album of t)
end tell
APPLESCRIPT
)
[[ -n $info ]] || exit 0

IFS=$'\t' read -r name artist album <<<"$info"

# SwiftBar は " | " 以降を表示のパラメータとして読むので、曲名中の | を逃がす。
esc() { printf '%s' "${1//|/｜}"; }
name=$(esc "$name")
artist=$(esc "$artist")
album=$(esc "$album")

ctl() { echo "$1 | sfimage=$2 bash=/usr/bin/osascript param1=-e param2='tell application \"Music\" to $3' terminal=false refresh=true"; }

# 長い曲名はノッチの裏に隠れるので切る (切った分はツールチップで全文が出る)。
echo "$name — $artist | sfimage=music.note length=30"
echo "---"
echo "$name | sfimage=music.note"
echo "$artist | sfimage=person"
[[ -n $album ]] && echo "$album | sfimage=square.stack"
echo "---"
ctl "一時停止" pause.fill playpause
ctl "次の曲" forward.fill "next track"
ctl "前の曲" backward.fill "previous track"
echo "Music を開く | sfimage=music.note.list bash=/usr/bin/open param1=-a param2=Music terminal=false"
