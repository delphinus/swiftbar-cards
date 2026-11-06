#!/bin/bash
# <xbar.title>Weather (JMA)</xbar.title>
# <xbar.desc>気象庁の天気予報とアメダスの観測値をメニューバーに出す</xbar.desc>
# <xbar.version>v1.0.1</xbar.version>
# <xbar.author>delphinus</xbar.author>
# <xbar.author.github>delphinus</xbar.author.github>
# <xbar.abouturl>https://github.com/delphinus/swiftbar-cards</xbar.abouturl>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# 気象庁のサイト (www.jma.go.jp/bosai/) が裏で読んでいる JSON を使う。API キーは要らない。
# アメダスは 10 分ごと、予報は 1 日 3 回 (5 時・11 時・17 時) 更新される。
#
# 地点は設定ファイル (~/.config/swiftbar-cards/weather.conf) に、アメダスの観測点の
# 名前を書いて足す。現在地 (いちばん近い、気温を観測している観測点) は常に先頭に
# あり、足した地点とメニューから切り替えられる。
#   place=東京
#   place=横浜
#   place=44116   # 同じ名前の観測点が複数あるときは番号で書く
#   place=現在地  # 現在地を先頭以外に置くとき (here とも書ける)
# 観測点から、予報に要るコード (府県予報区・一次細分区域・予報の気温の地点) を
# 引く。予報の気温の地点 (forecast_area.json に区域ごとに 1 つある) のうち、
# 観測点と同じ地域でいちばん近いものの区域を使う。
#
# 現在地は、位置情報を読む小さな .app (../Sources/locate/) に調べさせる。SwiftBar
# から起動したプログラムには位置情報の許可を持たせられないため。.app は待たずに
# 裏で動かし、結果 (キャッシュの location) は次の実行から使う。取れたら .app が
# SwiftBar に更新を指示する。取れないあいだは東京を出す。
#
# 表示の言語は OS の設定に従う (scripts/lib.sh の cards_lang)。英語のときは、
# 観測点や区域の名前に気象庁の表の英語名を使い、予報の文 (日本語でしか配られない)
# の代わりに天気コードの英語名 (data/jma-telops.json) を出す。

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
# shellcheck source=SCRIPTDIR/../scripts/lib.sh
. "$(dirname "$0")/../scripts/lib.sh"

cache=~/Library/Caches/swiftbar-weather
mkdir -p "$cache"
base=https://www.jma.go.jp/bosai
conf=${XDG_CONFIG_HOME:-$HOME/.config}/swiftbar-cards/weather.conf
lang=$(cards_lang)
# 日本語と英語の文言から、表示の言語のほうを選ぶ
T() { if [[ $lang == ja ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# 一時ファイルの名前にプロセスの番号を入れる (裏で他の地点を描く処理と重なっても壊れない)
fetch() {
	if curl -sf --max-time 10 "$1" -o "$2.tmp.$$"; then
		mv "$2.tmp.$$" "$2"
	else
		rm -f "$2.tmp.$$"
		return 1
	fi
}

case ${1:-} in
# メニューの「設定ファイルを開く」から呼ばれる。無ければひな形を作る。
open-config)
	if [[ ! -f $conf ]]; then
		mkdir -p "$(dirname "$conf")"
		if [[ $lang == ja ]]; then
			cat >"$conf" <<-'EOF'
				# 現在地の天気は常に出る。ほかの地点を足すには、アメダスの観測点の名前
				# (https://www.jma.go.jp/bosai/amedas/ で探せる) を書く。
				# 足した地点は、メニューから選んで切り替えられる。
				#place=東京
				#place=横浜
				# 同じ名前の観測点が複数あるときは、番号で書く
				#place=44116
				# 現在地は先頭に出る。別の位置に置くときは、その位置に書く
				#place=現在地
			EOF
		else
			cat >"$conf" <<-'EOF'
				# The weather for your location is always shown. To add other locations,
				# write names of AMeDAS stations, in Japanese (see https://www.jma.go.jp/bosai/amedas/).
				# Choose between them from the menu.
				#place=東京
				#place=横浜
				# When more than one station has the same name, use its number
				#place=44116
				# Your location comes first. To put it elsewhere, write it in that position
				#place=here
			EOF
		fi
	fi
	open -t "$conf"
	exit 0
	;;
# メニューの地点の項目と「今すぐ更新」から呼ばれる。続く実行 (refresh=true) で、
# キャッシュのカードと「更新中…」を出し、裏で取り直すよう印を付ける。
select | refresh-now)
	[[ $1 == select ]] && printf '%s\n' "${2:-}" >"$cache/selected"
	touch "$cache/switched"
	exit 0
	;;
# 裏で呼ばれる。prefetch は地点のカードを描いてキャッシュに置くだけ。update は
# 選んでいる地点を取り直し、終わったら SwiftBar にプラグインの更新を指示する。
prefetch) prefetch=${2:-} ;;
update) update=1 ;;
esac

# 設定ファイルを読む。シェルとして読み込まず、key=value の行だけを拾う。
# 以前の amedas=<番号> も、1 つの地点として読む。
places=()
if [[ -f $conf ]]; then
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%%#*}
		[[ $line == *=* ]] || continue
		k=${line%%=*} v=${line#*=}
		k=${k//[[:space:]]/} v=$(echo "$v" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
		case $k in
		place | amedas) [[ -n $v ]] && places+=("$v") ;;
		esac
	done <"$conf"
fi
# 現在地は常に出す。書かれていなければ先頭に足す (書かれていればその位置に置く)。
is_here() { [[ $1 == 現在地 || $1 == here ]]; }
uses_here=
for p in "${places[@]}"; do is_here "$p" && uses_here=1; done
[[ -n $uses_here ]] || places=(現在地 "${places[@]}")

# 現在地。キャッシュの location (緯度 経度 精度 時刻) を読み、10 分より古ければ
# .app を裏で起動して取り直させる。地点を選んだ直後・取り直しの直後の実行と、裏で
# 描くだけの実行では起動しない (どちらもすぐ後に別の実行が控えている)。「今すぐ
# 更新」のあとの取り直し (update) では、古さによらず起動する。
# SWIFTBAR_CARDS_LOCATION="<緯度> <経度>" があれば、それを現在地にする (テスト用。
# none なら取れなかったことにする)。
here=null here_status=
if [[ -n ${SWIFTBAR_CARDS_LOCATION:-} ]]; then
	if [[ $SWIFTBAR_CARDS_LOCATION == none ]]; then here_status=error; else
		read -r lat lon _ <<<"$SWIFTBAR_CARDS_LOCATION"
		here="[$lat,$lon]" here_status=ok
	fi
else
	if [[ -z ${prefetch:-} && ( -n ${update:-} || ! ( -f $cache/switched || -f $cache/fresh ) ) ]] &&
		[[ -n ${update:-} || ! -s $cache/location || -n $(find "$cache/location" -mmin +10) ]]; then
		app=$cache/Locate.app
		name=${0##*/}
		build_app locate "$app" && open -g -a "$app" --args "$cache" "${name%%.*}" 2>/dev/null
	fi
	here_status=$(cat "$cache/location-status" 2>/dev/null || true)
	if [[ -s $cache/location ]]; then
		read -r lat lon _ <"$cache/location"
		[[ $lat =~ ^-?[0-9.]+$ && $lon =~ ^-?[0-9.]+$ ]] && here="[$lat,$lon]"
	fi
	# 許可を取り消された (か位置情報サービスを切った) ら、前に取れた現在地も使わない。
	# 一時的に取れなかった (error) だけなら、前に取れた現在地を使い続ける。
	case $here_status in denied | disabled) here=null ;; esac
fi

# 観測点の表と、予報区と観測点の対応表。めったに変わらないので週に 1 回取り直す。
mkdir -p "$cache/const"
for f in amedas/const/amedastable.json forecast/const/forecast_area.json common/const/area.json; do
	out=$cache/const/${f##*/}
	if [[ ! -s $out || -n $(find "$out" -mtime +7) ]]; then
		fetch "$base/$f" "$out"
	fi
done
if [[ ! -s $cache/const/amedastable.json || ! -s $cache/const/forecast_area.json || ! -s $cache/const/area.json ]]; then
	echo " | sfimage=exclamationmark.icloud"
	echo "---"
	T "気象庁のデータを取得できない" "Could not get data from JMA"
	echo
	exit 0
fi

# 地点ごとに、観測点の名前 (か番号) から地域を引く。地点 1 つにつき 1 つ、
# { status: ok / notfound / ambiguous, found: [候補] } を返す。
resolved=$(printf '%s\n' "${places[@]}" | jq -R . | jq -s -c \
	--slurpfile am "$cache/const/amedastable.json" --slurpfile fa "$cache/const/forecast_area.json" \
	--slurpfile ar "$cache/const/area.json" --argjson here "$here" '
	def deg: .[0] + .[1] / 60;
	# 2 点の距離の 2 乗 (緯度の差と、経度の差に cos(緯度) を掛けたもの。近さを比べるだけ)
	def dist2($la; $lo): ((.lat - $la) | . * .) + ((.lon - $lo) * ($la * 3.14159265 / 180 | cos) | . * .);
	$am[0] as $am | $ar[0] as $ar
	# 予報の気温の地点と、それが属する府県予報区・一次細分区域
	| [$fa[0] | to_entries[] | .key as $o | .value[] | .class10 as $c | .amedas[]
	   | select($am[.] != null) | { office: $o, class10: $c, temp: ., lat: ($am[.].lat | deg), lon: ($am[.].lon | deg) }] as $points
	| map(. as $q
		| ($q == "現在地" or $q == "here") as $isHere
		# 現在地なら、いちばん近い観測点のうち気温を観測しているもの (elems の 1 文字目が 1)。
		# 現在地が分からなければ東京。数字だけなら観測点の番号、それ以外は名前。
		| (if $isHere then
			(if $here then [$am | to_entries[] | select(.value.elems[0:1] == "1")
				| { key, lat: (.value.lat | deg), lon: (.value.lon | deg) }]
				| min_by(dist2($here[0]; $here[1])) | [.key]
			 else ["44132"] end)
		   elif test("^[0-9]+$") then [$q | select($am[.] != null)]
		   else [$am | to_entries[] | select(.value.kjName == $q) | .key] end) as $cands
		| [$cands[] | . as $c | $am[$c] as $s | ($s.lat | deg) as $la | ($s.lon | deg) as $lo
		   # 番号の上 2 桁は地域 (おおむね府県予報区) を表すので、同じ地域の地点から
		   # 選ぶ。近さだけで選ぶと、県境の近くで隣の県の地点を拾う (東京都の府中は
		   # 東京とさいたまからほぼ同じ距離にある)。
		   | ([$points[] | select(.temp[0:2] == $c[0:2])] | if length > 0 then . else $points end)
		   | min_by(dist2($la; $lo)) as $best
		   | { amedas: $c, here: $isHere, name: $s.kjName, enName: $s.enName, office: $best.office, class10: $best.class10,
		       class10En: $ar.class10s[$best.class10].enName,
		       temp: $best.temp, tempName: $am[$best.temp].kjName,
		       officeName: $ar.offices[$best.office].name, officeEn: $ar.offices[$best.office].enName }] as $found
		| { query: $q, found: $found,
		    status: (if ($found | length) == 0 then "notfound" elif ($found | length) > 1 then "ambiguous" else "ok" end) })')
# 選んでいる地点。覚えている文字列と、書かれた文字列・観測点の名前・番号のどれかが
# 一致する地点を選ぶ。同名の観測点が複数あって「山口」を選んだあと、設定を
# place=81286 に書き換えても、山口を選んだままにするため。無ければ先頭にする。
# 書かれた文字列と一致する地点を先に探し、観測点の名前・番号では現在地を拾わない。
# 東京にいると現在地の観測点も東京なので、東京を選んでも現在地を選んだことになる。
selected=$(cat "$cache/selected" 2>/dev/null || true)
sel=$(jq -r --arg s "$selected" '
	([to_entries[] | select(.value.query == $s) | .key] | first)
	// ([to_entries[] | select([.value.found[] | select(.here | not) | .name, .amedas] | index($s) != null) | .key] | first)
	// 0' <<<"$resolved")
[[ -n ${update:-} ]] && prefetch=$sel
[[ -n ${prefetch:-} ]] && sel=$prefetch
place=${places[$sel]}
# 地点の表示名 (切り替えのメニュー用)。解決できなかった地点は書かれたまま出す。
# 現在地は「現在地 (府中)」のように、使っている観測点を添えて出す。英語では、
# macOS の天気・マップと同じ My Location。現在地が分からないあいだは「現在地」だけ。
place_label() { # <番号>
	jq -r --argjson i "$1" --arg lang "$lang" --arg known "$([[ $here != null ]] && echo 1)" '
		.[$i] | if .status != "ok" then .query
		elif .found[0].here then (if $lang == "ja" then "現在地" else "My Location" end)
			+ (if $known == "" then "" else .found[0] | " (\(if $lang == "ja" then .name else .enName end))" end)
		else .found[0] | (if $lang == "ja" then .name else .enName end) end' <<<"$resolved"
}
# 現在地を選んでいて、現在地が分からない (東京を出している) ときに、その理由を出す
here_note() {
	is_here "$place" && [[ $here == null ]] || return 0
	case $here_status in
	denied) echo "$(T "位置情報の利用が許可されていないので、東京を表示中" "Location access is not allowed. Showing Tokyo") | sfimage=location.slash color=#D70015,#FF6961" \
		&& echo "$(T "位置情報サービスの設定を開く" "Open Location Services Settings") | sfimage=gearshape.circle href=x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices" ;;
	disabled) echo "$(T "位置情報サービスが切ってあるので、東京を表示中" "Location Services are off. Showing Tokyo") | sfimage=location.slash color=#D70015,#FF6961" \
		&& echo "$(T "位置情報サービスの設定を開く" "Open Location Services Settings") | sfimage=gearshape.circle href=x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices" ;;
	error) echo "$(T "現在地を取得できないので、東京を表示中" "Could not get your location. Showing Tokyo") | sfimage=location.slash" ;;
	*) echo "$(T "現在地を取得中なので、東京を表示中" "Getting your location. Showing Tokyo") | sfimage=location" ;;
	esac
	echo "---"
}
# 地点の切り替え。地点が 2 つ以上あるときだけ、選んでいる地点の印を付けて
# 並べる。サブメニューにしないのは、SwiftBar 2.1.1 では、メニューを差し替えた
# ときに動作の無いサブメニューの親が押せない状態のまま残ることがあるため。
location_menu() {
	[[ ${#places[@]} -gt 1 ]] || return 0
	local i icon code summary params
	for i in "${!places[@]}"; do
		# 選んでいる地点は、チェックマークではなく塗りつぶしたピンで示す。チェックマークを
		# 付けると、macOS がメニュー全体にその欄を取り、カードの左が 14pt 空く。
		# 現在地はピンではなく、位置情報の矢印で示す
		icon=mappin.circle
		is_here "${places[$i]}" && icon=location.circle
		[[ $i == "$sel" ]] && icon=$icon.fill
		# 地点名の後ろに、その地点のメニューバーの行 (天気・気温・降水確率) を添える。
		# 取り直さず、キャッシュのカードの 4 行目 (メニューの地に合わせた色で書いた
		# もの) を使う。4 行目が無い古いキャッシュでは 1 行目 (メニューバーの行)。
		# 色の指定 (sfcolor・sfcolor2) で色が付くのは文中のアイコンだけで、sfimage の
		# ピンは標準の色のまま (SwiftBar の main のソースで確かめた。2026-11-06)。
		summary='' params=''
		code=$(jq -r --argjson i "$i" '.[$i] | select(.status == "ok") | .found[0].amedas' <<<"$resolved")
		if [[ -n $code && -s $cache/body-$code-$lang-$dark.txt ]]; then
			summary=$(sed -n 4p "$cache/body-$code-$lang-$dark.txt")
			[[ -n $summary ]] || summary=$(sed -n 1p "$cache/body-$code-$lang-$dark.txt")
			[[ $summary == *' | '* ]] && params=" ${summary#* | }" summary=${summary%% | *}
			summary="   $summary"
		fi
		echo "$(place_label "$i")$summary | sfimage=$icon$params bash=$0 param1=select param2=${places[$i]} terminal=false refresh=true"
	done
	echo "---"
}
# 設定ファイルを書き換えたあと、次の実行 (10 分ごと) を待たずに反映する
refresh_item() { echo "$(T "今すぐ更新" "Refresh Now") | sfimage=arrow.clockwise.circle bash=$0 param1=refresh-now terminal=false refresh=true"; }
# 設定の不備をメニューに出して終わる
config_error() {
	echo ":exclamationmark.triangle: $(T "天気" "Weather")"
	echo "---"
	printf '%s\n' "$@"
	echo "---"
	location_menu
	echo "$(T "設定ファイルを開く" "Open Configuration File") | sfimage=gearshape.circle bash=$0 param1=open-config terminal=false"
	refresh_item
	exit 0
}

field() { jq -r --argjson i "$sel" ".[\$i].found[0].$1 // \"\"" <<<"$resolved"; }
status=$(jq -r --argjson i "$sel" '.[$i].status' <<<"$resolved")
[[ -n ${prefetch:-} && $status != ok ]] && exit 0
case $status in
ok)
	office=$(field office) class10=$(field class10) amedas=$(field amedas)
	temp_code=$(field temp) temp_name=$(field tempName)
	if [[ $lang == ja ]]; then obs_name=$(field name) area_name=; else obs_name=$(field enName) area_name="$(field class10En), $(field officeEn)"; fi
	;;
notfound)
	if [[ $place =~ ^[0-9]+$ ]]; then
		config_error "$(T "アメダスの観測点 $place が見つからない" "No AMeDAS station numbered $place")"
	else
		config_error "$(T "「${place}」という名前のアメダスの観測点が見つからない" "No AMeDAS station named \"${place}\"")" \
			"$(T "気象庁の「アメダス」のページで観測点の名前を確かめる" "Look up station names on the JMA AMeDAS page") | href=https://www.jma.go.jp/bosai/amedas/"
	fi
	;;
*)
	config_error "$(T "「${place}」という名前の観測点が複数ある。設定ファイルに番号で書く:" "More than one station is named \"${place}\". Write its number in the configuration file:")" \
		"$(jq -r --argjson i "$sel" --arg lang "$lang" '.[$i].found[]
			| if $lang == "ja" then "\(.name) (\(.officeName)): place=\(.amedas)" else "\(.enName) (\(.officeEn)): place=\(.amedas)" end' <<<"$resolved")"
	;;
esac
dark=false
[[ ${OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null)} == Dark ]] && dark=true

# 地点ごとのキャッシュ。1 行目がメニューバーの行、2 行目がカードの行、3 行目が
# カードの本来の高さ (下を空ける前)、4 行目が地点の切り替えの項目に添える行
# (1 行目と同じ中身を、メニューの地に合わせた色で書いたもの)。
body=$cache/body-$amedas-$lang-$dark.txt
# メニューを出す。カードの行には動作を付けない (無効な項目にする)。動作を付けると、
# マウスを載せたときにカード全体が選択の色で塗られる。無効な項目でも、文字と違って
# 画像は薄くならずに描かれる (2026-11-05 に確かめた)。
# 裏の取り直しが終わった (か失敗した) ことを SwiftBar に知らせ、プラグインを更新させる。
# 続く実行は取得せずにキャッシュのカードを出す。プラグインの名前はファイル名の最初の
# . より前 (weather.10m.sh なら weather)。SWIFTBAR_CARDS_NO_REFRESH があれば知らせない
# (テスト用)。
notify_swiftbar() {
	touch "$cache/fresh"
	local name=${0##*/}
	[[ -n ${SWIFTBAR_CARDS_NO_REFRESH:-} ]] || open -g "swiftbar://refreshplugin?name=${name%%.*}"
	exit 0
}
# 引数に updating を渡すと、「今すぐ更新」の代わりに「更新中…」(動作の無い項目なので
# 薄く出る) を出す。
print_menu() {
	sed -n 1p "$body"
	echo "---"
	# カードの下には区切り線を引かない (カードの地の縁が境目になる)
	sed -n 2p "$body"
	here_note
	location_menu
	echo "$(T "設定ファイルを開く" "Open Configuration File") | sfimage=gearshape.circle bash=$0 param1=open-config terminal=false"
	if [[ ${1:-} == updating ]]; then
		echo "$(T "更新中…" "Updating…") | sfimage=arrow.triangle.2.circlepath"
	else
		refresh_item
	fi
	echo "$(T "気象庁の天気予報を開く" "Open JMA Forecast") | sfimage=arrow.up.forward.circle href=https://www.jma.go.jp/bosai/forecast/#area_type=offices&area_code=$office"
}
# 選んでいない地点のうち、キャッシュが 60 分より古い (か無い) ものを裏で描いておく。
# 地点を選んだときにすぐ出せるようにし、高さをそろえる元にもする。1 つずつ順に
# 描き、出力は捨てる (SwiftBar はプラグインの出力が閉じるまで待つ)。
prefetch_others() {
	[[ ${#places[@]} -gt 1 ]] || return 0
	local i code todo=()
	for i in "${!places[@]}"; do
		[[ $i == "$sel" ]] && continue
		code=$(jq -r --argjson i "$i" '.[$i] | select(.status == "ok") | .found[0].amedas' <<<"$resolved")
		[[ -n $code ]] || continue
		f=$cache/body-$code-$lang-$dark.txt
		[[ -s $f && -z $(find "$f" -mmin +60) ]] || todo+=("$i")
	done
	[[ ${#todo[@]} -gt 0 ]] || return 0
	(for i in "${todo[@]}"; do "$0" prefetch "$i"; done) </dev/null >/dev/null 2>&1 &
}
# 地点を選んだ直後と「今すぐ更新」の直後は、取得を待たずにキャッシュのカードと
# 「更新中…」を出し、裏で取り直す。取り直すと数秒かかり、その間にメニューを開き
# 直すと、開いている最中に中身が差し替わる (高さをそろえてあるので崩れはしない)。
# 取り直し終わると、裏の処理が SwiftBar にプラグインの更新を指示し (fresh の印を
# 付けて)、続く実行は取得せずに新しいカードを出す。
if [[ -z ${prefetch:-} ]]; then
	if [[ -f $cache/switched ]]; then
		rm -f "$cache/switched"
		if [[ -s $body ]]; then
			print_menu updating
			"$0" update </dev/null >/dev/null 2>&1 &
			exit 0
		fi
	elif [[ -f $cache/fresh ]]; then
		rm -f "$cache/fresh"
		if [[ -s $body ]]; then
			print_menu
			prefetch_others
			exit 0
		fi
	fi
fi

# 予報のファイルが別の府県予報区のものに入っている区域がある (2026-11 に全
# 58 区域を取って確かめた)
case $office in
014030) forecast_office=014100 ;; # 十勝地方 → 釧路・根室地方
460040) forecast_office=460100 ;; # 奄美地方 → 鹿児島県
*) forecast_office=$office ;;
esac
# 地域を変えたあとで取得に失敗したとき、前の地域の予報を出さないよう、
# キャッシュのファイル名に地域の番号を入れる
forecast=$cache/forecast-$forecast_office.json
vpfd=$cache/vpfd-$class10.json
rm -f "$cache/forecast.json" "$cache/vpfd.json" # 以前の名前の残り
find "$cache" -maxdepth 1 \( -name 'forecast-*.json' -o -name 'vpfd-*.json' \) -mtime +2 -delete

stale=
fetch "$base/forecast/data/forecast/$forecast_office.json" "$forecast" || stale=1
if latest=$(curl -sf --max-time 10 "$base/amedas/data/latest_time.txt"); then
	# 2026-11-04T20:30:00+09:00 → 20261104203000
	ts=${latest:0:19}
	ts=${ts//[-T:]/}
	fetch "$base/amedas/data/map/$ts.json" "$cache/amedas.json" || stale=1
else
	stale=1
fi

if [[ ! -s $forecast ]]; then
	[[ -n ${update:-} ]] && notify_swiftbar
	[[ -n ${prefetch:-} ]] && exit 0
	echo " | sfimage=exclamationmark.icloud"
	echo "---"
	T "気象庁のデータを取得できない" "Could not get data from JMA"
	echo
	exit 0
fi

# メニューの中身は 1 枚のカードの画像にする (../Sources/weather-card/ の Swift のプログラムが描く)。
# メニューの文字では、フォントで列を揃える・ANSI の 256 色で色を選ぶ、といった
# 制約が多く (ダークのメニューでは灰色の明るさが逆に描かれもした)、画像なら
# 色も配置も自由になる。画像にできないときは最小限の文字だけを出す。
#
# カードに使うデータ:
# - 今の観測値: アメダスの全観測点の最新値 (amedas.json)
# - 気温のグラフ: 地域時系列予報 (3 時間ごとの気温と天気) と、アメダスの観測点の
#   時系列 (3 時間ごとのファイルに 10 分ごとの値)。過去 24 時間ぶんのファイルを、
#   確定したものはキャッシュして使い回し、最新の 2 つは毎回取り直す。
# - 3 日分の予報の文・週間予報・降水確率: 府県予報 (forecast.json)
fetch "$base/jmatile/data/wdist/VPFD/$class10.json" "$vpfd"
mkdir -p "$cache/amedas"
find "$cache/amedas" -name '*.json' -mtime +2 -delete
now=$(date +%s)
point_files=()
for k in 0 1 2 3 4 5 6 7 8 9; do
	e=$((now - k * 3 * 3600))
	h=$(TZ=Asia/Tokyo date -r "$e" +%H)
	block=$(TZ=Asia/Tokyo date -r "$e" +%Y%m%d)_$(printf '%02d' $((10#$h / 3 * 3)))
	f=$cache/amedas/${amedas}_$block.json
	if [[ $k -lt 2 || ! -s $f ]]; then
		fetch "$base/amedas/data/point/$amedas/$block.json" "$f"
	fi
	[[ -s $f ]] && point_files+=("$f")
done
[[ -s $vpfd ]] || echo '{}' >"$vpfd"
[[ -s $cache/amedas.json ]] || echo '{}' >"$cache/amedas.json"

bin=$cache/weather-card
build_helper weather-card "$bin"
rm -f "$cache/weather-graph" "$cache/graph.b64" "$cache/menu.txt" # 以前の名前の残り

# 設定した地点のカードの高さをそろえる。地点を切り替えた直後にメニューを開き直すと、
# 開いている最中に中身が差し替わることがあり、SwiftBar はそのとき高さの変わった
# カードに合わせてメニューを描き直さない (上がはみ出す)。高さが同じなら崩れない。
# そろえる高さは、各地点のカードの本来の高さ (キャッシュの 3 行目) のうち最大のもの。
min_height=0
while IFS= read -r code; do
	f=$cache/body-$code-$lang-$dark.txt
	[[ -s $f && -z $(find "$f" -mmin +180) ]] || continue
	h=$(sed -n 3p "$f")
	[[ $h =~ ^[0-9]+$ && $h -gt $min_height ]] && min_height=$h
done < <([[ ${#places[@]} -gt 1 ]] && jq -r '.[] | select(.status == "ok") | .found[0].amedas' <<<"$resolved")
find "$cache" -maxdepth 1 -name 'body-*.txt' -mtime +2 -delete

# 1 行目にメニューバーの行、2 行目以降にカードの JSON を出す
jq -n -r --argjson now "$now" --argjson dark "$dark" --argjson minh "$min_height" \
	--slurpfile f "$forecast" --slurpfile a "$cache/amedas.json" --slurpfile v "$vpfd" \
	--arg class10 "$class10" --arg office "$office" --arg amedas "$amedas" --arg obsname "$obs_name" \
	--arg tempcode "$temp_code" --arg tempname "$temp_name" --arg lang "$lang" --arg areaname "$area_name" \
	--slurpfile tel "$cards_root/data/jma-telops.json" \
	--arg latest "${latest:-}" --arg stale "$stale" --arg today "$(TZ=Asia/Tokyo date +%F)" '
	# 2026-11-05T03:00:00+09:00 → UNIX 時刻
	def epoch: .[0:19] + "Z" | fromdate - 32400;
	# 色の組は「明るいメニューバー用, 暗い外観用, 明るいカード用」。メニューバーは
	# 先頭の 2 つを sfcolor に渡し、カードは外観に合うほうを pick で選ぶ。明るい
	# カード用を別に持つのは、ポップアップが背後の壁紙を透かして灰色に見えるため
	# (白地を前提にした色では読めなかった)。
	def pick: .[if $dark then 1 else 2 end];
	def bar: .[0:2] | join(",");
	# 天気コードの百の位で大まかに分ける (1 晴れ・2 くもり・3 雨・4 雪)。
	# 十の位以下は「時々」「のち」などの組み合わせ。
	def code_icon: (tonumber? // 0) as $c
		| if $c >= 400 then "cloud.snow" elif $c >= 300 then "cloud.rain"
		  elif $c >= 200 then (if ($c % 100) >= 2 and ($c % 100) < 10 then "cloud.sun" else "cloud" end)
		  elif $c >= 100 then (if $c == 100 then "sun.max" else "cloud.sun" end)
		  else "questionmark" end;
	# 地域時系列予報の天気は文字で配られる
	def text_icon: if test("雪") then "cloud.snow" elif test("雨") then "cloud.rain"
		elif test("くもり") then (if test("晴") then "cloud.sun" else "cloud" end)
		elif test("晴") then "sun.max" else "questionmark" end;
	def icon_colors: { "sun.max": ["#F08A00", "#FFB340", "#A85400"], "cloud.sun": ["#E09A00", "#FFC75A", "#8A5C00"],
		"cloud.rain": ["#0A6FD8", "#64B5FF", "#0050C0"], "cloud.snow": ["#3A9BC1", "#9EDCF5", "#14668A"] }[.]
		// ["#6E6E73", "#AEAEB2", "#47474D"];
	# 降水確率は青の鮮やかさだけで段階を付け、高いほど目立たせる。
	# 0〜20% は灰、30〜50% はくすんだ青、60% 以上は鮮やかな青。
	def pop_colors: (tonumber? // 0) as $p
		| if $p >= 60 then ["#0A6FD8", "#64B5FF", "#0047B3"] elif $p >= 30 then ["#5B7FA6", "#7895B8", "#2F5480"]
		  else ["#8E8E93", "#7C7C80", "#5A5A60"] end;
	# 気温の色。暑いほど赤、寒いほど青。どれにも当たらなければ null (標準の文字色)。
	def temp_color: (tonumber? // null) as $t
		| if $t == null then null elif $t >= 30 then (["", "#FF6961", "#A3000F"] | pick)
		  elif $t >= 25 then (["", "#FFD60A", "#7A5000"] | pick) elif $t <= 5 then (["", "#64B5FF", "#0047B3"] | pick)
		  elif $t <= 12 then (["", "#5AD8E6", "#005E73"] | pick) else null end;
	# 曜日 (0 が日曜)。名前はカードの側で言語に合わせて付ける。
	def dow($t): $t[0:10] + "T00:00:00Z" | fromdate | strftime("%w") | tonumber;
	def dir: (if $lang == "ja"
		then ["静穏","北北東","北東","東北東","東","東南東","南東","南南東","南","南南西","南西","西南西","西","西北西","北西","北北西","北"]
		else ["Calm","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW","N"] end)[.] // null;
	# 予報の文。英語のときは、日本語でしか配られない文の代わりに天気コードの英語名を使う。
	def forecast_text($text; $code): if $lang == "ja" then $text else ($tel[0][$code] // $text) end;
	def val($k): ($a[0][$amedas][$k] // [null])[0];

	$f[0][0] as $short
	| ($short.timeSeries[0]) as $w
	| ($w.areas | map(select(.area.code == $class10))[0]) as $wa
	| ($short.timeSeries[1]) as $p
	| ($p.areas | map(select(.area.code == $class10))[0]) as $pa
	| ($short.timeSeries[2]) as $t
	| ($t.areas | map(select(.area.code == $tempcode))[0]) as $ta
	| val("temp") as $nowtemp

	# 観測点の時系列 (正時の値だけ)。キーは 20261104210000 の形。
	| [inputs | to_entries[] | select(.key | endswith("0000")) | select(.value.temp[0] != null)
	   | [(.key | strptime("%Y%m%d%H%M%S") | mktime - 32400), .value.temp[0]]] | sort_by(.[0]) as $past
	| $v[0] as $vp
	| ($vp.pointTimeSeries // null | if type == "array" then (map(select(.pointNameJP == $tempname))[0] // .[0]) else . end) as $pt
	| ($vp.areaTimeSeries // null | if type == "array" then .[0] else . end) as $at

	# メニューバー: 今日の天気のアイコン、現在の気温、いまの時間帯の降水確率。
	# アイコンは :name: の形で文中に書く (SwiftBar の symbolize)。sfimage と違って
	# 1 行に複数置けて、どれも同じ大きさで描かれる。sfcolor と sfcolor2 が
	# 1 個目と 2 個目のアイコンの色になる。
	# 同じ行を、地点の切り替えの項目にも添える (キャッシュの 4 行目)。項目はメニュー
	# (背後の壁紙を透かす) の上に描かれるので、色はメニューバー用ではなく、明るい
	# 外観ではカードと同じ濃い色を使う (メニューバー用の色では読みにくかった)。
	| ([$p.timeDefines | to_entries[] | select(.value <= (now + 32400 | strftime("%Y-%m-%dT%H:%M:%S+09:00")) or .key == 0) | .key] | last) as $pi
	| ($wa.weatherCodes[0]) as $code
	| ($pa.pops[$pi] // "") as $pop
	| def summary(colors): ":\($code | code_icon): \(if $nowtemp != null then "\($nowtemp | round)°" else "" end)"
	   + (if $pop != "" then " :umbrella.fill: \($pop)%" else "" end)
	   + (if $stale != "" then " :exclamationmark.triangle:" else "" end)
	   + " | sfcolor=\($code | code_icon | icon_colors | colors)"
	   + (if $pop != "" then " sfcolor2=\($pop | pop_colors | colors)" else "" end)
	   + (if $stale != "" then " sfcolor\(if $pop != "" then 3 else 2 end)=#D70015,#FF6961" else "" end);
	  summary(bar), summary([.[2], .[1]] | join(",")),

	# カード
	({ dark: $dark, now: $now, minHeight: $minh,
	   obs: (if $nowtemp != null then
		{ point: $obsname, time: ($latest[11:16]), temp: $nowtemp, tempColor: ($nowtemp | tostring | temp_color),
		  humidity: val("humidity"), precip: val("precipitation1h"),
		  wind: val("wind"), windDir: (val("windDirection") | if . == null then null else dir end) }
		else null end),
	   graph: (if $pt and $at and ($past | length) > 0 then
		{ current: ($past | last | .[1]),
		  past: ($past | map(select(.[0] >= $now - 25 * 3600))),
		  forecast: [range($pt.temperature | length) as $i
			| select($pt.temperature[$i] != "" and $pt.temperature[$i] != null)
			| [(($pt.timeDefines // ($vp.pointTimeSeries | if type == "object" then .timeDefines else null end))[$i].dateTime | epoch),
			   ($pt.temperature[$i] | tonumber)]],
		  weather: [range($at.weather | length) as $i | ($at.weather[$i] | text_icon) as $ic
			| [($at.timeDefines[$i].dateTime | epoch | tostring), $ic, ($ic | icon_colors | pick)]],
		  # 降水確率は府県予報の 6 時間ごとの値 (一次細分区域ごと)
		  pops: [range($p.timeDefines | length) as $i | ($pa.pops[$i] // "") as $pp | select($pp != "")
			| [($p.timeDefines[$i] | epoch | tostring), $pp, ($pp | pop_colors | pick)]] }
		else null end),
	   daysTitle: (if $lang == "ja" then "\($wa.area.name)の予報 (\($short.reportDatetime[11:16]) 発表)"
		else "Forecast for \(if $areaname != "" then $areaname else $wa.area.name end) (issued \($short.reportDatetime[11:16]))" end),
	   # 予報は 5・11・17 時に発表されるので、日付が変わってから次の発表までは
	   # 先頭が昨日の分になる。今日より前の日は出さない。
	   days: [$w.timeDefines | to_entries[] | select(.value[0:10] >= $today) | ($wa.weatherCodes[.key] | code_icon) as $ic
		# 「今日」「明日」は日付をまたぐと指す日が変わって分かりにくいので、日付で出す
		| { date: "\(.value[5:7] | tonumber)/\(.value[8:10] | tonumber)", dow: dow(.value),
		    # 全角の空白 (語の区切り) は残し、カードの側で折り返しの位置に使う
		    text: forecast_text($wa.weathers[.key]; $wa.weatherCodes[.key]), icon: $ic, color: ($ic | icon_colors | pick) }],
	   # 週間予報の初日は、気温と降水確率が空欄で配られる (短期予報で発表される
	   # ため)。初日は、5 時の発表までは前の日の 17 時に出た週間予報の初日 (今日)、
	   # 11 時の発表からは明日。空欄なら短期予報の値で埋める。気温は 0 時の値が
	   # 最低、9 時の値が最高。降水確率は 6 時間ごとの値のうちいちばん高いもの。
	   # ただし短期予報は発表した日の最低気温を予報せず、その日の 0 時の欄にも最高
	   # 気温を入れて配る (11/6 11 時の発表の東京なら、11/6 の 9 時と 0 時がどちらも
	   # 25)。発表した日の最低気温は埋めずに空欄のままにする。
	   week: (($f[0][1] // null) as $week
		| if $week then
		  # 週間予報の天気は、一次細分区域ごとのことも府県でまとめてのこともある
		  ($week.timeSeries[0]) as $ww
		  | ($ww.areas | (map(select(.area.code == $class10))[0] // map(select(.area.code == $office))[0] // .[0])) as $wwa
		  # 週間予報の気温の地点は府県に 1 つだけのことがある (神奈川県なら横浜だけ)。
		  # 予報の気温の地点が無ければ先頭の地点を使う。
		  | ($week.timeSeries[1].areas | (map(select(.area.code == $tempcode))[0] // .[0])) as $wt
		  | [$ww.timeDefines | to_entries[] | .value[0:10] as $d
			| (($wt.tempsMax[.key] // "") | if . == "" and $ta then
				[$t.timeDefines | to_entries[] | select(.value[0:10] == $d and .value[11:13] != "00") | $ta.temps[.key]][0] // ""
				else . end) as $tmax
			| (($wt.tempsMin[.key] // "") | if . == "" and $ta and $d != $short.reportDatetime[0:10] then
				[$t.timeDefines | to_entries[] | select(.value[0:10] == $d and .value[11:13] == "00") | $ta.temps[.key]][0] // ""
				else . end) as $tmin
			| (($wwa.pops[.key] // "") | if . == "" then
				[$p.timeDefines | to_entries[] | select(.value[0:10] == $d) | $pa.pops[.key] // "" | select(. != "") | tonumber]
				| (max // null) | if . == null then "" else tostring end
				else . end) as $wpop
			| ($wwa.weatherCodes[.key] | code_icon) as $ic
			| { date: "\(.value[5:7] | tonumber)/\(.value[8:10] | tonumber)", dow: dow(.value),
				icon: $ic, color: ($ic | icon_colors | pick),
				max: $tmax, maxColor: ($tmax | temp_color), min: $tmin, minColor: ($tmin | temp_color),
				pop: $wpop, popColor: (if $wpop == "" then null else ($wpop | pop_colors | pick) end) }]
		  else [] end) } | tojson)
' "${point_files[@]}" >"$cache/menu-$$.txt" 2>/dev/null

{
	head -1 "$cache/menu-$$.txt"
	if [[ -x $bin ]] && card=$(tail -n +3 "$cache/menu-$$.txt" | "$bin" 2>/dev/null) && [[ -n $card ]]; then
		{ read -r cw ch nh; read -r b64; } <<<"$card"
		echo " | image=$b64 width=$cw height=$ch"
		echo "$nh"
	else
		echo "$(T "天気のカードを描けなかった" "Could not draw the weather card") | refresh=true"
		echo
	fi
	sed -n 2p "$cache/menu-$$.txt"
} >"$body.$$" && mv "$body.$$" "$body"
rm -f "$cache/menu-$$.txt"
[[ -n ${update:-} ]] && notify_swiftbar
[[ -n ${prefetch:-} ]] && exit 0
print_menu
prefetch_others
