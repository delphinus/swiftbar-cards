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
	cp "$dir"/*.icns "$tmp/Contents/Resources/" 2>/dev/null
	if swiftc -O -suppress-warnings -o "$tmp/Contents/MacOS/$name" "$dir"/*.swift 2>/dev/null &&
		codesign --force --sign - "$tmp" 2>/dev/null; then
		rm -rf "$app"
		mv "$tmp" "$app"
	else
		rm -rf "$tmp"
		return 1
	fi
}

# メニューバーの項目を縮めるかを決める .app (Sources/menubar/) をビルドする。3 つの
# プラグインが同時に起動しても 1 つだけがビルドするよう、ディレクトリを作れたもの
# だけが進む。起動はプラグインの Swift のプログラムが行う (Shared の MenuBarDensity)。
# SWIFTBAR_CARDS_COMPACT で決め打ちしているときは使わないので、ビルドしない。
#
# .app のファイル名は、システム設定の許可の一覧にそのまま出るので swiftbar-cards.app
# にする。アドホック署名なので、ビルドし直すと前に与えた許可が通らなくなり、しかも
# 一覧の項目を OFF → ON しても直らない (項目が前の署名のまま残る)。そこでビルドし
# 直したら、この .app の許可の項目を消す。.app は次に起動したときに許可を求め直す。
#   build_menubar_app
build_menubar_app() {
	[[ -z ${SWIFTBAR_CARDS_COMPACT:-} ]] || return 0
	local dir=$HOME/Library/Caches/swiftbar-cards lock app before after
	lock=$dir/build.lock
	app=$dir/swiftbar-cards.app
	mkdir -p "$dir"
	# 前のビルドが途中で落ちて残ったロックは、10 分経ったら捨てる
	find "$lock" -maxdepth 0 -mmin +10 -exec rmdir {} \; 2>/dev/null
	mkdir "$lock" 2>/dev/null || return 0
	before=$(stat -f %m "$app/Contents/MacOS/menubar" 2>/dev/null)
	build_app menubar "$app"
	after=$(stat -f %m "$app/Contents/MacOS/menubar" 2>/dev/null)
	if [[ -n $before && -n $after && $before != "$after" ]]; then
		tccutil reset Accessibility dev.delphinus.swiftbar-cards.menubar >/dev/null 2>&1
	fi
	rmdir "$lock"
}
