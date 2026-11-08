#!/bin/bash
# 比べる元の画像 (tests/baseline/) を、CI が描いた画像で置き換える。
#   scripts/update-baseline.sh [run の ID]
# 文字の描き方は macOS のバージョンで変わるので、比べる元は手元ではなく CI で描いたものを使う。
# run の ID を省くと、今のブランチで最後に終わった CI の run を使う。その run の
# artifact (cards) の visual/ を tests/baseline/ に写し、描いた macOS のバージョンを
# tests/baseline-macos-version.txt に書く。差分を見てからコミットすること。

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
run=${1:-}
if [[ -z $run ]]; then
	branch=$(git -C "$repo" branch --show-current)
	run=$(gh run list --workflow ci.yml --branch "$branch" --status completed --limit 1 --json databaseId -q '.[0].databaseId')
	[[ -n $run ]] || {
		echo "$branch の CI の run が見つからない" >&2
		exit 1
	}
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh run download "$run" --name cards --dir "$work"
[[ -d $work/visual ]] || {
	echo "run $run の artifact に visual/ が無い" >&2
	exit 1
}
rm -rf "$repo/tests/baseline"
cp -R "$work/visual" "$repo/tests/baseline"
cp "$work/macos-version.txt" "$repo/tests/baseline-macos-version.txt"
echo "run $run の画像で置き換えた (macOS $(cat "$repo/tests/baseline-macos-version.txt"))"
git -C "$repo" status --short -- tests/baseline tests/baseline-macos-version.txt
