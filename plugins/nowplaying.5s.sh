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

# 状態と曲の情報を US (0x1f) 区切りで返す。タブで区切ると、read が空の欄を
# 詰めてしまい後ろの欄がずれる。停止中は current track が取れないので状態だけ。
info=$(
	osascript <<'APPLESCRIPT' 2>/dev/null
tell application "Music"
	set s to player state as text
	set us to character id 31
	try
		set t to current track
		return s & us & (persistent ID of t) & us & (count of artworks of t) & us & (name of t) & us & (artist of t) & us & (album of t)
	on error
		return s
	end try
end tell
APPLESCRIPT
)

IFS=$'\x1f' read -r state pid nart name artist album <<<"$info"

# SwiftBar は " | " 以降を表示のパラメータとして読むので、曲名中の | を逃がす。
esc() { printf '%s' "${1//|/｜}"; }
name=$(esc "$name")
artist=$(esc "$artist")
album=$(esc "$album")

ctl() { echo "$1 | sfimage=$2 bash=/usr/bin/osascript param1=-e param2='tell application \"Music\" to $3' terminal=false refresh=true"; }

# アートワークを書き出して縮め、Base64 にしてキャッシュする。5 秒ごとに書き出すと
# 重いので、曲が変わったときだけ作り直す。メニューバー用 (small) は PNG、
# メニュー用 (large) は PNG だと Base64 で 300 KB を超えるので JPEG にする。
# 大きさは表示側で width / height (ポイント) を指定するので、Retina 向けに 2 倍で作る。
cache=~/Library/Caches/swiftbar-nowplaying
art_small= art_large=
if [[ -n $pid && ${nart:-0} -gt 0 ]]; then
	if [[ ! -s $cache/$pid.large ]]; then
		rm -rf "$cache" && mkdir -p "$cache"
		# write は tell の外で行う。tell の中で書くと先頭に余計なデータが付く。
		osascript -e 'tell application "Music" to set r to raw data of artwork 1 of current track' \
			-e "set f to open for access POSIX file \"$cache/raw\" with write permission" \
			-e 'write r to f' -e 'close access f' >/dev/null 2>&1 &&
			sips -s format png -Z 36 "$cache/raw" --out "$cache/s.png" >/dev/null 2>&1 &&
			sips -s format jpeg -s formatOptions 80 -Z 400 "$cache/raw" --out "$cache/l.jpg" >/dev/null 2>&1 &&
			base64 -i "$cache/s.png" | tr -d '\n' >"$cache/$pid.small" &&
			base64 -i "$cache/l.jpg" | tr -d '\n' >"$cache/$pid.large"
		rm -f "$cache/raw" "$cache/s.png" "$cache/l.jpg"
	fi
	[[ -s $cache/$pid.small ]] && art_small=$(<"$cache/$pid.small")
	[[ -s $cache/$pid.large ]] && art_large=$(<"$cache/$pid.large")
fi

if [[ $state == playing ]]; then
	# 長い曲名はノッチの裏に隠れるので切る (切った分はツールチップで全文が出る)。
	if [[ -n $art_small ]]; then
		echo "$name — $artist | image=$art_small width=18 height=18 length=30"
	else
		echo "$name — $artist | sfimage=music.note length=30"
	fi
else
	echo " | sfimage=music.note"
fi
echo "---"
if [[ -n $name ]]; then
	[[ -n $art_large ]] && echo " | image=$art_large width=200 height=200"
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
