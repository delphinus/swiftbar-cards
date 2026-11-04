#!/bin/bash
# <xbar.title>Now Playing (Music.app)</xbar.title>
# <xbar.desc>Music.app で再生中の曲をメニューバーに出す</xbar.desc>
# <xbar.dependencies>jq</xbar.dependencies>
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
#
# 再生中のメニューバー (アートワークと曲名) とメニューのカード (アートワーク・曲名・
# アーティスト・アルバム・再生位置) は ../helpers/nowplaying-card.swift が画像に描く。
# 初回 (とソースを変えたとき) にコンパイルする。操作 (一時停止・次の曲など) は
# 画像の中ではクリックした位置を区別できないので、文字の項目として残す。

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# メニューのアイコンは幅 15pt のもの (円で囲んだ系統など) で揃える。SF Symbols は
# アイコンごとに幅が違い (music.note は 11、forward.fill は 20)、その差だけ文字の
# 書き出し位置がずれる。
open_music="Music を開く | sfimage=arrow.up.forward.circle bash=/usr/bin/open param1=-a param2=Music terminal=false"

# `tell application "Music"` は Music が起動していなければ起動してしまうので先に見る。
if ! pgrep -xq Music; then
	echo " | sfimage=music.note"
	echo "---"
	echo "$open_music"
	exit 0
fi

# 状態と曲の情報を US (0x1f) 区切りで返す。タブで区切ると、read が空の欄を
# 詰めてしまい後ろの欄がずれる。停止中は current track が取れないので状態だけ。
# 再生位置と曲の長さは秒に丸めて返す (小数のままだと、ロケールによって小数点が
# 「,」になる)。丸めは as integer で行う。round は AppleScript 自身の命令なので、
# tell application "Music" の中では Music に送られて失敗する。
info=$(
	osascript <<'APPLESCRIPT' 2>/dev/null
tell application "Music"
	set s to player state as text
	set us to character id 31
	try
		set t to current track
		set p to ""
		try
			set p to ((player position) as integer) as text
		end try
		set d to ""
		try
			set d to ((duration of t) as integer) as text
		end try
		return s & us & (persistent ID of t) & us & (count of artworks of t) & us & p & us & d & us & (name of t) & us & (artist of t) & us & (album of t)
	on error
		return s
	end try
end tell
APPLESCRIPT
)

IFS=$'\x1f' read -r state pid nart pos dur name artist album <<<"$info"

ctl() { echo "$1 | sfimage=$2 bash=/usr/bin/osascript param1=-e param2='tell application \"Music\" to $3' terminal=false refresh=true$4"; }
# 操作は 3 行にまとめる。前の曲に戻る操作は頻度が低いので、⌥ を押している間だけ
# 「次の曲」と差し替える (SwiftBar の alternate)。
controls() {
	if [[ $state == playing ]]; then
		ctl "一時停止" pause.circle playpause
	else
		ctl "再生" play.circle play
	fi
	ctl "次の曲" forward.end.circle "next track"
	ctl "前の曲" backward.end.circle "previous track" " alternate=true"
	echo "$open_music"
}

# 停止中 (曲が無い) ときは、音符のアイコンと操作だけを出す
if [[ -z $pid ]]; then
	echo " | sfimage=music.note"
	echo "---"
	controls
	exit 0
fi

# アートワークは曲が変わったときだけ書き出し、600px の JPEG にしてキャッシュする
# (5 秒ごとに書き出すと重い)。描画のプログラムは同じフォルダに置くので、
# 曲が変わったときに消すのはアートワークのファイルだけにする。
cache=~/Library/Caches/swiftbar-nowplaying
mkdir -p "$cache"
art=
if [[ ${nart:-0} -gt 0 ]]; then
	if [[ ! -s $cache/$pid.jpg ]]; then
		rm -f "$cache"/*.jpg "$cache"/*.small "$cache"/*.large "$cache/out.txt"
		# write は tell の外で行う。tell の中で書くと先頭に余計なデータが付く。
		osascript -e 'tell application "Music" to set r to raw data of artwork 1 of current track' \
			-e "set f to open for access POSIX file \"$cache/raw\" with write permission" \
			-e 'write r to f' -e 'close access f' >/dev/null 2>&1 &&
			sips -s format jpeg -s formatOptions 85 -Z 600 "$cache/raw" --out "$cache/$pid.jpg" >/dev/null 2>&1
		rm -f "$cache/raw"
	fi
	[[ -s $cache/$pid.jpg ]] && art=$cache/$pid.jpg
fi

src=$(cd "$(dirname "$0")/../helpers" 2>/dev/null && pwd)/nowplaying-card.swift
bin=$cache/nowplaying-card
if [[ -f $src && (! -x $bin || $src -nt $bin) ]]; then
	swiftc -O -o "$bin.tmp" "$src" 2>/dev/null && mv "$bin.tmp" "$bin"
fi

dark=false
[[ ${OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null)} == Dark ]] && dark=true

# 表示が前回と同じ (一時停止中など) なら、前回描いた画像を使い回す。再生中は
# 再生位置が変わるので、5 秒ごとに描き直す (1 回 0.05 秒ほど)。
key="$pid|$state|$pos|$dur|$dark|$art"
out=
if [[ -s $cache/out.txt && $(head -1 "$cache/out.txt") == "$key" ]]; then
	out=$(tail -n +2 "$cache/out.txt")
elif [[ -x $bin ]]; then
	out=$(jq -n --argjson dark "$dark" --arg state "$state" --arg name "$name" --arg artist "$artist" \
		--arg album "$album" --arg art "$art" --arg pos "$pos" --arg dur "$dur" \
		'{dark: $dark, playing: ($state == "playing"), name: $name, artist: $artist, album: $album, art: $art,
		  position: ($pos | tonumber? // null), duration: ($dur | tonumber? // null)}' | "$bin" 2>/dev/null) &&
		[[ -n $out ]] && { echo "$key"; echo "$out"; } >"$cache/out.txt"
fi

# SwiftBar は " | " 以降を表示のパラメータとして読むので、曲名中の | を逃がす。
esc() { printf '%s' "${1//|/｜}"; }

if [[ -n $out ]]; then
	{ read -r bw bh; read -r bar_light; read -r bar_dark; read -r cw ch; read -r card; } <<<"$out"
	# 一時停止中のメニューバーは、音符のアイコンだけにする
	if [[ $state == playing ]]; then
		echo " | image=$bar_light,$bar_dark width=$bw height=$bh"
	else
		echo " | sfimage=music.note"
	fi
	echo "---"
	# カードの行には動作を付けない (無効な項目にする)。動作を付けると、マウスを
	# 載せたときにカード全体が選択の色で塗られる。画像は無効な項目でも薄くならない。
	echo " | image=$card width=$cw height=$ch"
	echo "---"
else
	# 画像を描けなかったときは文字で出す
	if [[ $state == playing ]]; then
		echo "$(esc "$name") | sfimage=music.note length=30"
	else
		echo " | sfimage=music.note"
	fi
	echo "---"
	echo "$(esc "$name") | sfimage=waveform.circle"
	echo "$(esc "$artist") | sfimage=person.circle"
	[[ -n $album ]] && echo "$(esc "$album") | sfimage=opticaldisc"
	echo "---"
fi
controls
