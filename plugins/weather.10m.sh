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

# メニューの等幅の行に使うフォント。日本語を英数字のちょうど 2 倍の幅で描くものを
# 使い、空白で列を揃える (Menlo は日本語を別のフォントで代わりに描き、その幅が
# 英数字 2 文字分にならないので列がずれる)。入っているものを次の順に選ぶ。
# 大きさと太さは、メニューの見出し (13pt のシステムフォント) と英字の高さ・
# 行の高さ (16pt)・線の濃さが揃うように選んである。
# - SF Mono Square (brew install delphinus/sfmono-square/sfmono-square): Bold の 16pt。
#   Regular は見出しより線が細く、同じポイント数だと小さく描かれる。
#   ブロック文字は幅 1 で、メーターを 1/8 刻みで描ける。
# - M PLUS 1 Code (Google Fonts): Medium の 13pt。英字が小さく細めなので一段太くする。
#   ブロック文字を持たず、代わりに描かれるブロック文字は幅 2。
# - Menlo: 日本語を含む列はずれる。
# block_width はブロック文字 1 個の幅 (英数字を 1 とする)。sysmon のメーターとグラフで使う。
mono_font=Menlo mono_size=12 block_width=1
for d in ~/Library/Fonts /Library/Fonts; do
	[[ -f $d/MPLUS1Code-Medium.ttf ]] && mono_font=MPLUS1Code-Medium mono_size=13 block_width=2 && break
done
for d in ~/Library/Fonts /Library/Fonts; do
	[[ -f $d/SFMonoSquare-Bold.otf ]] && mono_font=SFMonoSquare-Bold mono_size=16 block_width=1 && break
done

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

# 気温のグラフ (今後 24 時間を実線、前日の同じ時刻を破線)。
# - 予報: 地域時系列予報 (3 時間ごとの気温と天気)
# - 観測: アメダスの観測点の時系列。3 時間ごとのファイルに 10 分ごとの値が入っている。
#   過去 24 時間ぶん (9 ファイル) を、確定したものはキャッシュして使い回す。
#   最新の 2 つは書き足されている途中のことがあるので毎回取り直す。
# 描画は ../helpers/weather-graph.swift。初回 (と、ソースを変えたとき) にコンパイルする。
graph_png=$cache/graph.b64
rm -f "$graph_png"
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
src=$(cd "$(dirname "$0")/../helpers" 2>/dev/null && pwd)/weather-graph.swift
bin=$cache/weather-graph
if [[ -f $src && (! -x $bin || $src -nt $bin) ]]; then
	swiftc -O -o "$bin.tmp" "$src" 2>/dev/null && mv "$bin.tmp" "$bin"
fi
dark=false
[[ ${OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null)} == Dark ]] && dark=true
if [[ -x $bin && -s $cache/vpfd.json && ${#point_files[@]} -gt 0 ]]; then
	jq -n --argjson now "$now" --argjson dark "$dark" --arg point "$JMA_TEMP_POINT" \
		--slurpfile v "$cache/vpfd.json" --slurpfile f "$cache/forecast.json" --arg area "$JMA_AREA" '
		# 2026-11-05T03:00:00+09:00 → UNIX 時刻
		def epoch: .[0:19] + "Z" | fromdate - 32400;
		def icon: if test("雪") then "cloud.snow" elif test("雨") then "cloud.rain"
			elif test("くもり") then (if test("晴") then "cloud.sun" else "cloud" end)
			elif test("晴") then "sun.max" else "questionmark" end;
		# weather.10m.sh のメニューと同じ色。明るいメニュー用と暗いメニュー用を選ぶ。
		def color: ({ "sun.max": ["#F08A00", "#FFB340"], "cloud.sun": ["#E09A00", "#FFC75A"],
			"cloud.rain": ["#0A6FD8", "#64B5FF"], "cloud.snow": ["#3A9BC1", "#9EDCF5"] }[.]
			// ["#6E6E73", "#AEAEB2"])[if $dark then 1 else 0 end];
		# 観測値は正時のものだけを使う (20261104210000 の形のキー)
		[inputs | to_entries[] | select(.key | endswith("0000")) | select(.value.temp[0] != null)
		 | [(.key | strptime("%Y%m%d%H%M%S") | mktime - 32400), .value.temp[0]]]
		| sort_by(.[0]) as $past
		| $v[0] as $vp
		| ($vp.pointTimeSeries | if type == "array" then (map(select(.pointNameJP == $point))[0] // .[0]) else . end) as $pt
		| ($vp.areaTimeSeries | if type == "array" then .[0] else . end) as $at
		| { now: $now, dark: $dark,
			current: ($past | last | .[1]),
			past: ($past | map(select(.[0] >= $now - 25 * 3600))),
			forecast: [range($pt.temperature | length) as $i
				| select($pt.temperature[$i] != "" and $pt.temperature[$i] != null)
				| [(($pt.timeDefines // ($vp.pointTimeSeries | if type == "object" then .timeDefines else null end))[$i].dateTime | epoch), ($pt.temperature[$i] | tonumber)]],
			# 降水確率は府県予報の 6 時間ごとの値 (一次細分区域ごと)
			pops: ($f[0][0].timeSeries[1] as $ps | ($ps.areas | map(select(.area.name == $area))[0]) as $pa
				| [range($ps.timeDefines | length) as $i | ($pa.pops[$i] // "") as $p | select($p != "")
				| [($ps.timeDefines[$i] | epoch | tostring), $p,
				   ((if ($p | tonumber) >= 60 then ["#0A6FD8", "#64B5FF"] elif ($p | tonumber) >= 30 then ["#B07800", "#FFD60A"]
				     else ["#6E6E73", "#AEAEB2"] end)[if $dark then 1 else 0 end])]]),
			weather: [range($at.weather | length) as $i
				| ($at.weather[$i] | icon) as $ic
				| [($at.timeDefines[$i].dateTime | epoch | tostring), $ic, ($ic | color)]] }
		' "${point_files[@]}" 2>/dev/null | "$bin" >"$graph_png" 2>/dev/null || rm -f "$graph_png"
fi

# メニューの見た目を整える。メニューバーの行 (最初の --- より前) は触らない。
# クリックしても何も起きない項目は、macOS が無効の項目として文字も色も薄く描く。
# どの項目もクリックでプラグインを更新する (refresh=true) ようにして、有効な
# 項目として描かせる。
#
# ansi=true の行で色を付けない部分には、何も指定しない。SwiftBar のメニューでは
# 白 (\e[97m や \e[37m) を指定するとかえって灰色に描かれ、指定しなければ
# メニューの標準の文字色で描かれる (2026-11-04 に並べて描かせて確かめた)。
menu_fix() {
	perl -pe '
		if ($menu && !/^---$/ && !/ (bash|href|refresh)=/) { chomp; $_ .= (/ \| / ? " refresh=true" : " | refresh=true") . "\n" }
		$menu = 1 if /^---$/'
}

jq -r -n \
	--slurpfile f "$cache/forecast.json" \
	--slurpfile a "$cache/amedas.json" \
	--arg area "$JMA_AREA" --arg point "$JMA_TEMP_POINT" --arg amedas "$JMA_AMEDAS" \
	--arg latest "${latest:-}" --arg stale "$stale" --arg office "$JMA_OFFICE" \
	--arg today "$(date +%F)" --arg mono_font "$mono_font" --arg mono_size "$mono_size" \
	--rawfile graph <(cat "$graph_png" 2>/dev/null) '
	def mono: " | font=\($mono_font) size=\($mono_size) ansi=true";
	# 天気コードの百の位で大まかに分ける (1 晴れ・2 くもり・3 雨・4 雪)。
	# 十の位以下は「時々」「のち」などの組み合わせ。
	def icon:
		(tonumber? // 0) as $c
		| if $c >= 400 then "cloud.snow"
		  elif $c >= 300 then "cloud.rain"
		  elif $c >= 200 then (if ($c % 100) >= 2 and ($c % 100) < 10 then "cloud.sun" else "cloud" end)
		  elif $c >= 100 then (if $c == 100 then "sun.max" else "cloud.sun" end)
		  else "questionmark" end;

	# アイコンの色 (SwiftBar の sfcolor)。「明るいメニューバー用,暗いメニューバー用」。
	# メニューの天気のアイコンは幅を 15pt に揃える。アイコンは天気ごとに縦横比が違い
	# (くもりは横長、雪は縦長)、そのままだと幅の差だけ後ろの文字がずれる。
	# SwiftBar は width と height の両方を指定するとその大きさに描き直すので、
	# 高さは元の縦横比 (SF Symbols の large の大きさ) から決める。
	def icon_size:
		{ "sun.max": "width=15 height=15", "cloud.sun": "width=15 height=12", "cloud": "width=15 height=11",
		  "cloud.rain": "width=15 height=16", "cloud.snow": "width=15 height=16" }[icon] // "";
	def icon_color:
		{ "sun.max": "#F08A00,#FFB340", "cloud.sun": "#E09A00,#FFC75A", "cloud": "#6E6E73,#AEAEB2",
		  "cloud.rain": "#0A6FD8,#64B5FF", "cloud.snow": "#3A9BC1,#9EDCF5" }[icon] // "#6E6E73,#AEAEB2";
	# 降水確率の色。0〜20% は灰、30〜50% は黄、60% 以上は青。
	def pop_color: (tonumber? // 0) as $p
		| if $p >= 60 then "#0A6FD8,#64B5FF" elif $p >= 30 then "#B07800,#FFD60A" else "#6E6E73,#AEAEB2" end;

	# メニューの中は ANSI のエスケープで色を付ける (sfcolor で色が変わるのは文中のアイコンだけ)
	def esc($c): "\u001b[\($c)m";
	def reset: esc("0");
	def pop_ansi: (tonumber? // -1) as $p
		| if $p >= 60 then esc("34") elif $p >= 30 then esc("33") elif $p >= 0 then esc("2") else "" end;
	# 気温の色。暑いほど赤、寒いほど青。
	def temp_ansi: (tonumber? // null) as $t
		| if $t == null then "" elif $t >= 30 then esc("31") elif $t >= 25 then esc("33")
		  elif $t <= 5 then esc("34") elif $t <= 12 then esc("36") else "" end;
	def pop_txt: (. // "") | if . == "" then "-" else pop_ansi + . + "%" + reset end;

	def squash: gsub("　"; "");
	# 気温を 2 桁の幅に揃え、色を付ける。値が無い日 (週間予報の初日) は "-" にする。
	def pad2: (. // "") | if . == "" then " -" else (if length < 2 then " " + . else . end) as $s | temp_ansi + $s + reset end;
	def wday($t): ["日","月","火","水","木","金","土"][$t[0:10] + "T00:00:00Z" | fromdate | strftime("%w") | tonumber];
	# 週間予報で桁が揃うよう、月日は 0 で埋める (11/06(金))
	def mdw($t): "\($t[5:7])/\($t[8:10])(\(wday($t)))";
	# 表示の幅 (英数字を 1、日本語を 2 とする) が $n になるまで後ろに空白を足す
	def padr($n): (explode | map(if . >= 11904 then 2 else 1 end) | add // 0) as $w
		| if $w < $n then . + (" " * ($n - $w)) else . end;
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

	# メニューバー: 今日の天気のアイコン、現在の気温、いまの時間帯の降水確率。
	# アイコンは :name: の形で文中に書く (SwiftBar の symbolize)。sfimage と違って
	# 1 行に複数置けて、どれも同じ大きさで描かれる。sfcolor と sfcolor2 が
	# 1 個目と 2 個目のアイコンの色になる。symbolize と ansi は同時に使えない。
	| ([$p.timeDefines | to_entries[] | select(.value <= (now + 32400 | strftime("%Y-%m-%dT%H:%M:%S+09:00")) or .key == 0) | .key] | last) as $pi
	| ($wa.weatherCodes[0]) as $code
	| ($pa.pops[$pi] // "") as $pop
	| ":\($code | icon): \(if $now != null then "\($now | round)°" else "" end)"
	  + (if $pop != "" then " :umbrella.fill: \($pop)%" else "" end)
	  + (if $stale != "" then " :exclamationmark.triangle:" else "" end)
	  + " | sfcolor=\($code | icon_color)"
	  + (if $pop != "" then " sfcolor2=\($pop | pop_color)" else "" end)
	  + (if $stale != "" then " sfcolor\(if $pop != "" then 3 else 2 end)=#D70015,#FF6961" else "" end),
	  "---",

	  # 現在の観測値
	  (if $now != null then
		"アメダス (\($point)) \($latest[11:16]) の観測 | sfimage=thermometer.medium",
		"気温      \($now | tostring | temp_ansi)\($now)°C\(reset)" + mono,
		(if val("humidity") != null then "湿度      \(val("humidity"))%" + mono else empty end),
		(if val("precipitation1h") != null then
			"降水量    \(if val("precipitation1h") > 0 then esc("34") else "" end)\(val("precipitation1h")) mm\(reset) (1 時間)" + mono
		 else empty end),
		(if val("wind") != null then "風        \(val("windDirection") | dir) \(val("wind")) m/s" + mono else empty end),
		"---"
	  else empty end),

	  # 気温のグラフ (weather-graph.swift が描いた PNG)
	  (if ($graph | length) > 0 then
		"今後 24 時間の気温と降水確率 (実線: 予報 / 破線: 前日の観測) | sfimage=chart.xyaxis.line",
		" | image=\($graph | rtrimstr("\n")) width=320 height=166",
		"---"
	  else empty end),

	  # 今日・明日・明後日の予報
	  ("\($area)の予報 (\($short.reportDatetime[11:16]) 発表) | sfimage=calendar"),
	  ($w.timeDefines | to_entries[] |
		# 日付の欄は今日・明日・11/06(金) で幅が違うので、等幅のフォントで
		# 11/06(金) の幅 (9) に揃える
		"\(.value as $tv | day($tv) | if test("^[0-9]") then mdw($tv) else . end | padr(9))  \($wa.weathers[.key] | squash) | sfimage=\($wa.weatherCodes[.key] | icon) \($wa.weatherCodes[.key] | icon_size) sfcolor=\($wa.weatherCodes[.key] | icon_color) font=\($mono_font) size=\($mono_size)"),
	  # 降水確率は気温のグラフの中 (天気のアイコンの下) に出す。短期予報の最高・
	  # 最低気温は、週間予報の初日 (明日) の欄に入れてあるのでここには出さない。
	  "---",

	  # 週間予報
	  (($f[0][1] // null) as $week
	   | if $week then
		($week.timeSeries[0]) as $ww
		| ($ww.areas[0]) as $wwa
		| ($week.timeSeries[1].areas | map(select(.area.name == $point))[0]) as $wt
		| "週間予報 | sfimage=calendar.badge.clock",
		  # 週間予報の初日 (明日) は、気温と降水確率が空欄で配られる (短期予報で
		  # 発表されるため)。空欄なら短期予報の値で埋める。気温は 0 時の値が最低、
		  # 9 時の値が最高。降水確率は 6 時間ごとの値のうちいちばん高いもの。
		  ($ww.timeDefines | to_entries[] | .value[0:10] as $d
			| (($wt.tempsMax[.key] // "") | if . == "" and $ta then
				[$t.timeDefines | to_entries[] | select(.value[0:10] == $d and .value[11:13] != "00") | $ta.temps[.key]][0] // ""
				else . end) as $tmax
			| (($wt.tempsMin[.key] // "") | if . == "" and $ta then
				[$t.timeDefines | to_entries[] | select(.value[0:10] == $d and .value[11:13] == "00") | $ta.temps[.key]][0] // ""
				else . end) as $tmin
			| (($wwa.pops[.key] // "") | if . == "" then
				[$p.timeDefines | to_entries[] | select(.value[0:10] == $d) | $pa.pops[.key] // "" | select(. != "") | tonumber]
				| (max // null) | if . == null then "" else tostring end
				else . end) as $pop
			| "\(mdw(.value))  \($tmax | pad2)/\($tmin | pad2)°C  降水 \($pop | pop_txt) | sfimage=\($wwa.weatherCodes[.key] | icon) \($wwa.weatherCodes[.key] | icon_size) sfcolor=\($wwa.weatherCodes[.key] | icon_color) font=\($mono_font) size=\($mono_size) ansi=true"),
		  "---"
	   else empty end),
	  "気象庁の天気予報を開く | sfimage=arrow.up.forward.circle href=https://www.jma.go.jp/bosai/forecast/#area_type=offices&area_code=\($office)"
' | menu_fix
