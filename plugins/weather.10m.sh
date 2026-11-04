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
#   アメダスの観測点: https://www.jma.go.jp/bosai/amedas/const/amedastable.json
: "${JMA_OFFICE:=130000}"         # 府県予報区 (東京都)
: "${JMA_AREA:=東京地方}"         # 一次細分区域の名前 (予報文と降水確率)
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

jq -r -n \
	--slurpfile f "$cache/forecast.json" \
	--slurpfile a "$cache/amedas.json" \
	--arg area "$JMA_AREA" --arg point "$JMA_TEMP_POINT" --arg amedas "$JMA_AMEDAS" \
	--arg latest "${latest:-}" --arg stale "$stale" --arg office "$JMA_OFFICE" \
	--arg today "$(date +%F)" '
	def mono: " | font=Menlo size=12";
	# 天気コードの百の位で大まかに分ける (1 晴れ・2 くもり・3 雨・4 雪)。
	# 十の位以下は「時々」「のち」などの組み合わせ。
	def icon:
		(tonumber? // 0) as $c
		| if $c >= 400 then "cloud.snow"
		  elif $c >= 300 then "cloud.rain"
		  elif $c >= 200 then (if ($c % 100) >= 2 and ($c % 100) < 10 then "cloud.sun" else "cloud" end)
		  elif $c >= 100 then (if $c == 100 then "sun.max" else "cloud.sun" end)
		  else "questionmark" end;
	def squash: gsub("　"; "");
	# 気温を 2 桁の幅に揃える。値が無い日 (週間予報の初日) は "-" にする。
	def pad2: (. // "") | if . == "" then "-" else . end | if length < 2 then " " + . else . end;
	def wday($t): ["日","月","火","水","木","金","土"][$t[0:10] + "T00:00:00Z" | fromdate | strftime("%w") | tonumber];
	# 週間予報で桁が揃うよう、月日は 0 で埋める (11/06(金))
	def mdw($t): "\($t[5:7])/\($t[8:10])(\(wday($t)))";
	def day($t): $t[0:10] as $d
		| if $d == $today then "今日"
		  elif $d == (($today + "T00:00:00Z" | fromdate) + 86400 | strftime("%Y-%m-%d")) then "明日"
		  else ($t[5:7] | tonumber | tostring) + "/" + ($t[8:10] | tonumber | tostring) + "(" + wday($t) + ")" end;
	def dir: ["静穏","北北東","北東","東北東","東","東南東","南東","南南東","南","南南西","南西","西南西","西","西北西","北西","北北西","北"][.] // "-";
	def val($k): ($a[0][$amedas][$k] // [null])[0];

	$f[0][0] as $short
	| ($short.timeSeries[0]) as $w
	| ($w.areas | map(select(.area.name == $area))[0]) as $wa
	| ($short.timeSeries[1]) as $p
	| ($p.areas | map(select(.area.name == $area))[0]) as $pa
	| ($short.timeSeries[2]) as $t
	| ($t.areas | map(select(.area.name == $point))[0]) as $ta
	| val("temp") as $now

	# メニューバー: 今日の天気のアイコン、現在の気温、いまの時間帯の降水確率
	| ([$p.timeDefines | to_entries[] | select(.value <= (now + 32400 | strftime("%Y-%m-%dT%H:%M:%S+09:00")) or .key == 0) | .key] | last) as $pi
	| (if $now != null then "\($now | round)°" else "" end) as $nowtxt
	| ($pa.pops[$pi] // "") as $pop
	| "\($nowtxt)\(if $pop != "" then " ☂\($pop)%" else "" end)\(if $stale != "" then " ⚠︎" else "" end) | sfimage=\($wa.weatherCodes[0] | icon)",
	  "---",

	  # 現在の観測値
	  (if $now != null then
		"アメダス (\($point)) \($latest[11:16]) の観測 | sfimage=thermometer.medium",
		"気温      \($now)°C" + mono,
		(if val("humidity") != null then "湿度      \(val("humidity"))%" + mono else empty end),
		(if val("precipitation1h") != null then "降水量    \(val("precipitation1h")) mm (1 時間)" + mono else empty end),
		(if val("wind") != null then "風        \(val("windDirection") | dir) \(val("wind")) m/s" + mono else empty end),
		"---"
	  else empty end),

	  # 今日・明日・明後日の予報
	  ("\($area)の予報 (\($short.reportDatetime[11:16]) 発表) | sfimage=calendar"),
	  ($w.timeDefines | to_entries[] |
		"\(day(.value))  \($wa.weathers[.key] | squash) | sfimage=\($wa.weatherCodes[.key] | icon)"),
	  "降水確率 | sfimage=umbrella",
	  ($p.timeDefines | to_entries[] |
		"  \(day(.value)) \(.value[11:13])時〜  \($pa.pops[.key] // "-" | if . == "" then "-" else . + "%" end)" + mono),
	  (if $ta then
		"気温 (\($point)) | sfimage=thermometer.sun",
		($t.timeDefines | to_entries[] |
			"  \(day(.value)) \(if .value[11:13] == "00" then "最低" else "最高" end)  \($ta.temps[.key])°C" + mono)
	  else empty end),
	  "---",

	  # 週間予報
	  (($f[0][1] // null) as $week
	   | if $week then
		($week.timeSeries[0]) as $ww
		| ($ww.areas[0]) as $wwa
		| ($week.timeSeries[1].areas | map(select(.area.name == $point))[0]) as $wt
		| "週間予報 | sfimage=calendar.badge.clock",
		  ($ww.timeDefines | to_entries[] |
			"\(mdw(.value))  \($wt.tempsMax[.key] | pad2)/\($wt.tempsMin[.key] | pad2)°C  ☂\(($wwa.pops[.key] // "") | if . == "" then "-" else . + "%" end) | sfimage=\($wwa.weatherCodes[.key] | icon) font=Menlo size=12"),
		  "---"
	   else empty end),
	  "気象庁の天気予報を開く | sfimage=arrow.up.forward.circle href=https://www.jma.go.jp/bosai/forecast/#area_type=offices&area_code=\($office)"
'
