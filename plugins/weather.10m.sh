#!/bin/bash
# <xbar.title>Weather (JMA)</xbar.title>
# <xbar.desc>気象庁の天気予報とアメダスの観測値をメニューバーに出す</xbar.desc>
# <xbar.dependencies>jq, curl</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# 気象庁のサイト (www.jma.go.jp/bosai/) が裏で読んでいる JSON を使う。API キーは要らない。
# アメダスは 10 分ごと、予報は 1 日 3 回 (5 時・11 時・17 時) 更新される。
#
# 地域は設定ファイル (~/.config/swiftbar-cards/weather.conf) で、アメダスの
# 観測点の名前を 1 つ書いて決める。無ければ東京。
#   place=横浜
#   amedas=44116   # 同じ名前の観測点が複数あるときは番号で選ぶ (place より優先)
# 観測点から、予報に要るコード (府県予報区・一次細分区域・予報の気温の地点) を
# 引く。予報の気温の地点 (forecast_area.json に区域ごとに 1 つある) のうち、
# 観測点と同じ地域でいちばん近いものの区域を使う。

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

cache=~/Library/Caches/swiftbar-weather
mkdir -p "$cache"
base=https://www.jma.go.jp/bosai
conf=${XDG_CONFIG_HOME:-$HOME/.config}/swiftbar-cards/weather.conf

fetch() { curl -sf --max-time 10 "$1" -o "$2.tmp" && mv "$2.tmp" "$2"; }

# メニューの「設定ファイルを開く」から呼ばれる。無ければひな形を作る。
if [[ ${1:-} == open-config ]]; then
	if [[ ! -f $conf ]]; then
		mkdir -p "$(dirname "$conf")"
		cat >"$conf" <<-'EOF'
			# アメダスの観測点の名前 (https://www.jma.go.jp/bosai/amedas/ で探せる)
			place=東京
			# 同じ名前の観測点が複数あるときは、番号で選ぶ (place より優先)
			#amedas=44132
		EOF
	fi
	open -t "$conf"
	exit 0
fi

# 設定ファイルを読む。シェルとして読み込まず、key=value の行だけを拾う。
place=東京 amedas_pin=
if [[ -f $conf ]]; then
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%%#*}
		[[ $line == *=* ]] || continue
		k=${line%%=*} v=${line#*=}
		k=${k//[[:space:]]/} v=$(echo "$v" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
		case $k in
		place) [[ -n $v ]] && place=$v ;;
		amedas) amedas_pin=$v ;;
		esac
	done <"$conf"
fi

# 観測点の表と、予報区と観測点の対応表。めったに変わらないので週に 1 回取り直す。
mkdir -p "$cache/const"
for f in amedas/const/amedastable.json forecast/const/forecast_area.json common/const/area.json; do
	out=$cache/const/${f##*/}
	if [[ ! -s $out || -n $(find "$out" -mtime +7) ]]; then
		fetch "$base/$f" "$out"
	fi
done

# 設定の不備をメニューに出して終わる
config_error() {
	echo ":exclamationmark.triangle: 天気"
	echo "---"
	printf '%s\n' "$@"
	echo "---"
	echo "設定ファイルを開く | sfimage=gearshape.circle bash=$0 param1=open-config terminal=false"
	exit 0
}
if [[ ! -s $cache/const/amedastable.json || ! -s $cache/const/forecast_area.json || ! -s $cache/const/area.json ]]; then
	echo " | sfimage=exclamationmark.icloud"
	echo "---"
	echo "気象庁のデータを取得できない"
	exit 0
fi

# 観測点の名前 (か番号) から地域を引く。1 行目が ok / notfound / ambiguous。
# ok のときは 2 行目以降に「府県予報区 一次細分区域 観測点の番号 観測点の名前
# 予報の気温の地点の番号 その名前」を 1 行ずつ出す。ambiguous のときは候補を出す。
location=$(jq -n -r --arg place "$place" --arg pin "$amedas_pin" \
	--slurpfile am "$cache/const/amedastable.json" --slurpfile fa "$cache/const/forecast_area.json" \
	--slurpfile ar "$cache/const/area.json" '
	def deg: .[0] + .[1] / 60;
	$am[0] as $am | $ar[0].offices as $offices
	# 予報の気温の地点と、それが属する府県予報区・一次細分区域
	| [$fa[0] | to_entries[] | .key as $o | .value[] | .class10 as $c | .amedas[]
	   | select($am[.] != null) | { office: $o, class10: $c, temp: ., lat: ($am[.].lat | deg), lon: ($am[.].lon | deg) }] as $points
	| (if $pin != "" then [$pin | select($am[.] != null)]
	   else [$am | to_entries[] | select(.value.kjName == $place) | .key] end) as $cands
	| [$cands[] | . as $c | $am[$c] as $s | ($s.lat | deg) as $la | ($s.lon | deg) as $lo
	   | ($la * 3.14159265 / 180 | cos) as $k
	   # 番号の上 2 桁は地域 (おおむね府県予報区) を表すので、同じ地域の地点から
	   # 選ぶ。近さだけで選ぶと、県境の近くで隣の県の地点を拾う (東京都の府中は
	   # 東京とさいたまからほぼ同じ距離にある)。
	   | ([$points[] | select(.temp[0:2] == $c[0:2])] | if length > 0 then . else $points end)
	   | min_by(((.lat - $la) | . * .) + ((.lon - $lo) * $k | . * .)) as $best
	   | { amedas: $c, name: $s.kjName, office: $best.office, class10: $best.class10,
	       temp: $best.temp, tempName: $am[$best.temp].kjName, officeName: $offices[$best.office].name }] as $found
	| if ($found | length) == 0 then "notfound"
	  elif ($found | length) > 1 then "ambiguous", ($found[] | "\(.name) (\(.officeName)): amedas=\(.amedas)")
	  else "ok", ($found[0] | .office, .class10, .amedas, .name, .temp, .tempName) end')
case $(head -1 <<<"$location") in
ok) { read -r _; read -r office; read -r class10; read -r amedas; read -r obs_name; read -r temp_code; read -r temp_name; } <<<"$location" ;;
notfound)
	if [[ -n $amedas_pin ]]; then
		config_error "アメダスの観測点 $amedas_pin が見つからない"
	else
		config_error "「${place}」という名前のアメダスの観測点が見つからない" \
			"気象庁の「アメダス」のページで観測点の名前を確かめる | href=https://www.jma.go.jp/bosai/amedas/"
	fi
	;;
*) config_error "「${place}」という名前の観測点が複数ある。設定ファイルに番号で書く:" "$(tail -n +2 <<<"$location")" ;;
esac
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
	echo " | sfimage=exclamationmark.icloud"
	echo "---"
	echo "気象庁のデータを取得できない"
	exit 0
fi

# メニューの中身は 1 枚のカードの画像にする (../helpers/weather-card.swift が描く)。
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

src=$(cd "$(dirname "$0")/../helpers" 2>/dev/null && pwd)/weather-card.swift
bin=$cache/weather-card
if [[ -f $src && (! -x $bin || $src -nt $bin) ]]; then
	swiftc -O -o "$bin.tmp" "$src" 2>/dev/null && mv "$bin.tmp" "$bin"
fi
rm -f "$cache/weather-graph" "$cache/graph.b64" # 以前の名前の残り

dark=false
[[ ${OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null)} == Dark ]] && dark=true

# 1 行目にメニューバーの行、2 行目以降にカードの JSON を出す
jq -n -r --argjson now "$now" --argjson dark "$dark" \
	--slurpfile f "$forecast" --slurpfile a "$cache/amedas.json" --slurpfile v "$vpfd" \
	--arg class10 "$class10" --arg office "$office" --arg amedas "$amedas" --arg obsname "$obs_name" \
	--arg tempcode "$temp_code" --arg tempname "$temp_name" \
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
	def wday($t): ["日","月","火","水","木","金","土"][$t[0:10] + "T00:00:00Z" | fromdate | strftime("%w") | tonumber];
	def dir: ["静穏","北北東","北東","東北東","東","東南東","南東","南南東","南","南南西","南西","西南西","西","西北西","北西","北北西","北"][.] // null;
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
	| ([$p.timeDefines | to_entries[] | select(.value <= (now + 32400 | strftime("%Y-%m-%dT%H:%M:%S+09:00")) or .key == 0) | .key] | last) as $pi
	| ($wa.weatherCodes[0]) as $code
	| ($pa.pops[$pi] // "") as $pop
	| (":\($code | code_icon): \(if $nowtemp != null then "\($nowtemp | round)°" else "" end)"
	   + (if $pop != "" then " :umbrella.fill: \($pop)%" else "" end)
	   + (if $stale != "" then " :exclamationmark.triangle:" else "" end)
	   + " | sfcolor=\($code | code_icon | icon_colors | bar)"
	   + (if $pop != "" then " sfcolor2=\($pop | pop_colors | bar)" else "" end)
	   + (if $stale != "" then " sfcolor\(if $pop != "" then 3 else 2 end)=#D70015,#FF6961" else "" end)),

	# カード
	({ dark: $dark, now: $now,
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
	   daysTitle: "\($wa.area.name)の予報 (\($short.reportDatetime[11:16]) 発表)",
	   # 予報は 5・11・17 時に発表されるので、日付が変わってから次の発表までは
	   # 先頭が昨日の分になる。今日より前の日は出さない。
	   days: [$w.timeDefines | to_entries[] | select(.value[0:10] >= $today) | ($wa.weatherCodes[.key] | code_icon) as $ic
		# 「今日」「明日」は日付をまたぐと指す日が変わって分かりにくいので、日付で出す
		| { label: "\(.value[5:7] | tonumber)/\(.value[8:10] | tonumber)(\(wday(.value)))",
		    # 全角の空白 (語の区切り) は残し、カードの側で折り返しの位置に使う
		    text: $wa.weathers[.key], icon: $ic, color: ($ic | icon_colors | pick) }],
	   # 週間予報の初日 (明日) は、気温と降水確率が空欄で配られる (短期予報で
	   # 発表されるため)。空欄なら短期予報の値で埋める。気温は 0 時の値が最低、
	   # 9 時の値が最高。降水確率は 6 時間ごとの値のうちいちばん高いもの。
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
			| (($wt.tempsMin[.key] // "") | if . == "" and $ta then
				[$t.timeDefines | to_entries[] | select(.value[0:10] == $d and .value[11:13] == "00") | $ta.temps[.key]][0] // ""
				else . end) as $tmin
			| (($wwa.pops[.key] // "") | if . == "" then
				[$p.timeDefines | to_entries[] | select(.value[0:10] == $d) | $pa.pops[.key] // "" | select(. != "") | tonumber]
				| (max // null) | if . == null then "" else tostring end
				else . end) as $wpop
			| ($wwa.weatherCodes[.key] | code_icon) as $ic
			| { date: "\(.value[5:7] | tonumber)/\(.value[8:10] | tonumber)", wday: wday(.value),
				icon: $ic, color: ($ic | icon_colors | pick),
				max: $tmax, maxColor: ($tmax | temp_color), min: $tmin, minColor: ($tmin | temp_color),
				pop: $wpop, popColor: (if $wpop == "" then null else ($wpop | pop_colors | pick) end) }]
		  else [] end) } | tojson)
' "${point_files[@]}" >"$cache/menu.txt" 2>/dev/null

head -1 "$cache/menu.txt"
echo "---"
# カードの行には動作を付けない (無効な項目にする)。動作を付けると、マウスを
# 載せたときにカード全体が選択の色で塗られる。無効な項目でも、文字と違って
# 画像は薄くならずに描かれる (2026-11-05 に確かめた)。
if [[ -x $bin ]] && card=$(tail -n +2 "$cache/menu.txt" | "$bin" 2>/dev/null) && [[ -n $card ]]; then
	{ read -r cw ch; read -r b64; } <<<"$card"
	echo " | image=$b64 width=$cw height=$ch"
else
	echo "天気のカードを描けなかった | refresh=true"
fi
echo "---"
echo "設定ファイルを開く | sfimage=gearshape.circle bash=$0 param1=open-config terminal=false"
echo "気象庁の天気予報を開く | sfimage=arrow.up.forward.circle href=https://www.jma.go.jp/bosai/forecast/#area_type=offices&area_code=$office"
