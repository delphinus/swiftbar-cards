# プラグインが読み込む共通の関数。SwiftBar はプラグインのフォルダにある実行できる
# ファイルをプラグインとして扱うので、ここ (plugins の外) に置く。
# shellcheck shell=bash

cards_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Swift のプログラムをビルドする。Sources/Shared と Sources/<名前> の *.swift を
# まとめて swiftc に渡す (SwiftPM を通さないので、初回も数秒で済む)。ソースの
# どれかがバイナリより新しいときだけビルドし直す。
#   build_helper <名前> <バイナリのパス>
build_helper() {
	local name=$1 bin=$2 src newer=
	local sources=("$cards_root"/Sources/Shared/*.swift "$cards_root/Sources/$name"/*.swift)
	if [[ -x $bin ]]; then
		for src in "${sources[@]}"; do [[ $src -nt $bin ]] && newer=1; done
	else
		newer=1
	fi
	[[ -n $newer ]] || return 0
	swiftc -O -suppress-warnings -o "$bin.tmp" "${sources[@]}" 2>/dev/null && mv "$bin.tmp" "$bin"
}

# Swift のプログラムを .app の形にビルドする。Sources/<名前> の *.swift だけを
# コンパイルし (Sources/Shared は使わない)、同じフォルダの Info.plist と *.lproj を
# 入れて、アドホック署名する。ソースのどれかが .app より新しいときだけビルドし直す。
# 位置情報のように、macOS の許可をプログラム自身が持つ必要があるときに使う。
#   build_app <名前> <.app のパス>
build_app() {
	local name=$1 app=$2 src tmp newer=
	local dir=$cards_root/Sources/$name
	if [[ -x $app/Contents/MacOS/$name ]]; then
		while IFS= read -r src; do [[ $src -nt $app/Contents/MacOS/$name ]] && newer=1; done < <(find "$dir" -type f)
	else
		newer=1
	fi
	[[ -n $newer ]] || return 0
	tmp=$app.tmp.$$
	rm -rf "$tmp"
	mkdir -p "$tmp/Contents/MacOS" "$tmp/Contents/Resources"
	cp "$dir/Info.plist" "$tmp/Contents/"
	cp -R "$dir"/*.lproj "$tmp/Contents/Resources/" 2>/dev/null
	if swiftc -O -suppress-warnings -o "$tmp/Contents/MacOS/$name" "$dir"/*.swift 2>/dev/null &&
		codesign --force --sign - "$tmp" 2>/dev/null; then
		rm -rf "$app"
		mv "$tmp" "$app"
	else
		rm -rf "$tmp"
		return 1
	fi
}

# 表示の言語 (ja / en)。SWIFTBAR_CARDS_LANG で決め打ちできる。無ければ OS の優先
# 言語の先頭が日本語なら ja、それ以外は en。Sources/Shared/Localization.swift と同じ規則。
cards_lang() {
	case ${SWIFTBAR_CARDS_LANG:-} in
	ja | en)
		echo "$SWIFTBAR_CARDS_LANG"
		return
		;;
	esac
	local first
	first=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ",')
	[[ $first == ja* ]] && echo ja || echo en
}
