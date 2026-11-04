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
# 地域は環境変数で変えられる。コードは次で調べる。
#   予報区 (府県): https://www.jma.go.jp/bosai/common/const/area.json の offices
#   一次細分区域: 同じファイルの class10s (地域時系列予報に使う)
#   アメダスの観測点: https://www.jma.go.jp/bosai/amedas/const/amedastable.json
: "${JMA_OFFICE:=130000}"         # 府県予報区 (東京都)
: "${JMA_AREA:=東京地方}"         # 一次細分区域の名前 (予報文と降水確率)
: "${JMA_CLASS10:=130010}"        # 一次細分区域のコード (東京地方。気温のグラフ)
: "${JMA_TEMP_POINT:=東京}"       # 予報の気温の地点名
: "${JMA_AMEDAS:=44132}"          # アメダスの観測点 (東京)

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

cache=~/Library/Caches/swiftbar-weather
mkdir -p "$cache"
base=https://www.jma.go.jp/bosai

fetch() { curl -sf --max-time 10 "$1" -o "$2.tmp" && mv "$2.tmp" "$2"; }

stale=
fetch "$base/forecast/data/forecast/$JMA_OFFICE.json" "$cache/forecast.json" || stale=1
if latest=$(curl -sf --max-time 10 "$base/amedas/data/latest_time.txt"); then
	# 2026-11-04T20:30:00+09:00 → 20261104203000
	ts=${latest:0:19}
	ts=${ts//[-T:]/}
	fetch "$base/amedas/data/map/$ts.json" "$cache/amedas.json" || stale=1
else
	stale=1
fi

if [[ ! -s $cache/forecast.json ]]; then
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
fetch "$base/jmatile/data/wdist/VPFD/$JMA_CLASS10.json" "$cache/vpfd.json"
mkdir -p "$cache/amedas"
find "$cache/amedas" -name '*.json' -mtime +2 -delete
now=$(date +%s)
point_files=()
for k in 0 1 2 3 4 5 6 7 8 9; do
	e=$((now - k * 3 * 3600))
	h=$(TZ=Asia/Tokyo date -r "$e" +%H)
	block=$(TZ=Asia/Tokyo date -r "$e" +%Y%m%d)_$(printf '%02d' $((10#$h / 3 * 3)))
	f=$cache/amedas/${JMA_AMEDAS}_$block.json
	if [[ $k -lt 2 || ! -s $f ]]; then
		fetch "$base/amedas/data/point/$JMA_AMEDAS/$block.json" "$f"
	fi
	[[ -s $f ]] && point_files+=("$f")
done
[[ -s $cache/vpfd.json ]] || echo '{}' >"$cache/vpfd.json"
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
	--slurpfile f "$cache/forecast.json" --slurpfile a "$cache/amedas.json" --slurpfile v "$cache/vpfd.json" \
	--arg area "$JMA_AREA" --arg point "$JMA_TEMP_POINT" --arg amedas "$JMA_AMEDAS" \
	--arg latest "${latest:-}" --arg stale "$stale" --arg today "$(date +%F)" '
	# 2026-11-05T03:00:00+09:00 → UNIX 時刻
	def epoch: .[0:19] + "Z" | fromdate - 32400;
	# 「明るい外観用, 暗い外観用」の組から外観に合うほうを選ぶ
	def pick: .[if $dark then 1 else 0 end];
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
	def icon_colors: { "sun.max": ["#F08A00", "#FFB340"], "cloud.sun": ["#E09A00", "#FFC75A"],
		"cloud.rain": ["#0A6FD8", "#64B5FF"], "cloud.snow": ["#3A9BC1", "#9EDCF5"] }[.] // ["#6E6E73", "#AEAEB2"];
	# 降水確率は青の鮮やかさだけで段階を付け、高いほど目立たせる。
	# 0〜20% は灰、30〜50% はくすんだ青、60% 以上は鮮やかな青。
	def pop_colors: (tonumber? // 0) as $p
		| if $p >= 60 then ["#0A6FD8", "#64B5FF"] elif $p >= 30 then ["#5B7FA6", "#7895B8"] else ["#8E8E93", "#7C7C80"] end;
	# 気温の色。暑いほど赤、寒いほど青。どれにも当たらなければ null (標準の文字色)。
	def temp_color: (tonumber? // null) as $t
		| if $t == null then null elif $t >= 30 then (["#D70015", "#FF6961"] | pick)
		  elif $t >= 25 then (["#B07800", "#FFD60A"] | pick) elif $t <= 5 then (["#0A6FD8", "#64B5FF"] | pick)
		  elif $t <= 12 then (["#0A8AA8", "#5AD8E6"] | pick) else null end;
	def squash: gsub("　"; "");
	def wday($t): ["日","月","火","水","木","金","土"][$t[0:10] + "T00:00:00Z" | fromdate | strftime("%w") | tonumber];
	def day($t): $t[0:10] as $d
		| if $d == $today then "今日"
		  elif $d == (($today + "T00:00:00Z" | fromdate) + 86400 | strftime("%Y-%m-%d")) then "明日"
		  else ($t[5:7] | tonumber | tostring) + "/" + ($t[8:10] | tonumber | tostring) + "(" + wday($t) + ")" end;
	def dir: ["静穏","北北東","北東","東北東","東","東南東","南東","南南東","南","南南西","南西","西南西","西","西北西","北西","北北西","北"][.] // null;
	def val($k): ($a[0][$amedas][$k] // [null])[0];

	$f[0][0] as $short
	| ($short.timeSeries[0]) as $w
	| ($w.areas | map(select(.area.name == $area))[0]) as $wa
	| ($short.timeSeries[1]) as $p
	| ($p.areas | map(select(.area.name == $area))[0]) as $pa
	| ($short.timeSeries[2]) as $t
	| ($t.areas | map(select(.area.name == $point))[0]) as $ta
	| val("temp") as $nowtemp

	# 観測点の時系列 (正時の値だけ)。キーは 20261104210000 の形。
	| [inputs | to_entries[] | select(.key | endswith("0000")) | select(.value.temp[0] != null)
	   | [(.key | strptime("%Y%m%d%H%M%S") | mktime - 32400), .value.temp[0]]] | sort_by(.[0]) as $past
	| $v[0] as $vp
	| ($vp.pointTimeSeries // null | if type == "array" then (map(select(.pointNameJP == $point))[0] // .[0]) else . end) as $pt
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
	   + " | sfcolor=\($code | code_icon | icon_colors | join(","))"
	   + (if $pop != "" then " sfcolor2=\($pop | pop_colors | join(","))" else "" end)
	   + (if $stale != "" then " sfcolor\(if $pop != "" then 3 else 2 end)=#D70015,#FF6961" else "" end)),

	# カード
	({ dark: $dark, now: $now,
	   obs: (if $nowtemp != null then
		{ point: $point, time: ($latest[11:16]), temp: $nowtemp, tempColor: ($nowtemp | tostring | temp_color),
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
	   daysTitle: "\($area)の予報 (\($short.reportDatetime[11:16]) 発表)",
	   # 予報は 5・11・17 時に発表されるので、日付が変わってから次の発表までは
	   # 先頭が昨日の分になる。今日より前の日は出さない。
	   days: [$w.timeDefines | to_entries[] | select(.value[0:10] >= $today) | ($wa.weatherCodes[.key] | code_icon) as $ic
		| { label: day(.value), text: ($wa.weathers[.key] | squash), icon: $ic, color: ($ic | icon_colors | pick) }],
	   # 週間予報の初日 (明日) は、気温と降水確率が空欄で配られる (短期予報で
	   # 発表されるため)。空欄なら短期予報の値で埋める。気温は 0 時の値が最低、
	   # 9 時の値が最高。降水確率は 6 時間ごとの値のうちいちばん高いもの。
	   week: (($f[0][1] // null) as $week
		| if $week then
		  ($week.timeSeries[0]) as $ww | ($ww.areas[0]) as $wwa
		  | ($week.timeSeries[1].areas | map(select(.area.name == $point))[0]) as $wt
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
# 画像の行はクリックでプラグインを更新する (refresh=true)。クリックしても何も
# 起きない項目は、macOS が無効の項目として薄く描く。
if [[ -x $bin ]] && card=$(tail -n +2 "$cache/menu.txt" | "$bin" 2>/dev/null) && [[ -n $card ]]; then
	{ read -r cw ch; read -r b64; } <<<"$card"
	echo " | image=$b64 width=$cw height=$ch refresh=true"
else
	echo "天気のカードを描けなかった | refresh=true"
fi
echo "---"
echo "気象庁の天気予報を開く | sfimage=arrow.up.forward.circle href=https://www.jma.go.jp/bosai/forecast/#area_type=offices&area_code=$JMA_OFFICE"
