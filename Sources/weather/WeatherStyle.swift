import Foundation
#if canImport(Shared)
import Shared
#endif

/// メニューバー・メニュー・カードで使う色の組 ("#RRGGBB")。
///
/// 明るい外観では、メニューバーとカードで別の色を使う。カードを出すポップアップは背後の
/// 壁紙を透かして灰色に見えるので、白地を前提にしたメニューバーの色では読めなかった。
///
/// 暗い外観のメニューバーも壁紙を透かすので、青い壁紙では青い色が地に沈む。沈む色には
/// メニューバー用に白寄りの色 (darkMenuBar) を別に持たせる。指定が無ければ dark を使う。
struct ColorSet {
    let lightMenuBar: String
    let dark: String
    let lightCard: String
    let darkMenuBar: String

    init(lightMenuBar: String, dark: String, lightCard: String, darkMenuBar: String? = nil) {
        self.lightMenuBar = lightMenuBar
        self.dark = dark
        self.lightCard = lightCard
        self.darkMenuBar = darkMenuBar ?? dark
    }

    /// メニューバーの画像に描く色。外観に合うほう
    func menuBar(dark: Bool) -> String { dark ? darkMenuBar : lightMenuBar }
    /// メニューの項目 (背後の壁紙を透かす地) の sfcolor に渡す「明るい用,暗い用」。
    /// 明るい外観ではカードと同じ濃い色にする
    var menuItem: String { "\(lightCard),\(dark)" }
    /// カードに描く色。外観に合うほう
    func card(dark: Bool) -> String { dark ? self.dark : lightCard }
}

/// 天気・降水確率・気温・風向から、アイコンと色を決める
enum WeatherStyle {
    /// 天気コードのアイコン。気象庁の表 (`telop`) にある代表の天気 (晴・曇・雨・雪) で
    /// 大まかに分け、晴と曇は日本語の名前で晴れ間・曇り間のあるものを分ける。
    ///
    /// - 雨・雪: 「曇時々雨」(203) や「晴一時雨」(102) も、気象庁の代表の天気に従って
    ///   雨にする (降水確率が高いのに晴れ間のアイコンが出ていた)。
    /// - 曇: 「曇時々晴」「曇後晴」のように晴を含めば晴れ間のあるくもり。「霧」(209) は霧。
    /// - 晴: 「晴時々曇」「晴後曇」のように曇を含めば晴れ間のあるくもり。
    ///
    /// 表が無いとき (data/jma-telops.json を読めないとき) は、コードの百の位で分ける。
    static func icon(forCode code: String, telop: Telop?) -> String {
        guard let telop else {
            switch Int(code) ?? 0 {
            case 400...: return "cloud.snow"
            case 300...: return "cloud.rain"
            case 200...: return "cloud"
            case 100: return "sun.max"
            case 101...: return "cloud.sun"
            default: return "questionmark"
            }
        }
        switch telop.base {
        case "400": return "cloud.snow"
        case "300": return "cloud.rain"
        case "200":
            if telop.ja.contains("晴") { return "cloud.sun" }
            return telop.ja.hasPrefix("霧") ? "cloud.fog" : "cloud"
        case "100": return telop.ja.contains("曇") ? "cloud.sun" : "sun.max"
        default: return "questionmark"
        }
    }

    /// 地域時系列予報の天気のアイコン。こちらは天気が文字で配られる
    static func icon(forText text: String) -> String {
        if text.contains("雪") { return "cloud.snow" }
        if text.contains("雨") { return "cloud.rain" }
        if text.contains("くもり") { return text.contains("晴") ? "cloud.sun" : "cloud" }
        if text.contains("晴") { return "sun.max" }
        return "questionmark"
    }

    /// アイコンの色
    static func colors(forIcon icon: String) -> ColorSet {
        switch icon {
        case "sun.max": ColorSet(lightMenuBar: "#F08A00", dark: "#FFB340", lightCard: "#A85400")
        case "cloud.sun": ColorSet(lightMenuBar: "#E09A00", dark: "#FFC75A", lightCard: "#8A5C00")
        case "cloud.rain":
            ColorSet(lightMenuBar: "#0A6FD8", dark: "#64B5FF", lightCard: "#0050C0", darkMenuBar: "#A8D4FF")
        case "cloud.snow": ColorSet(lightMenuBar: "#3A9BC1", dark: "#9EDCF5", lightCard: "#14668A")
        default: ColorSet(lightMenuBar: "#6E6E73", dark: "#AEAEB2", lightCard: "#47474D")
        }
    }

    /// 降水確率の色。青の鮮やかさだけで段階を付け、高いほど目立たせる。
    /// 0〜20% は灰、30〜50% はくすんだ青、60% 以上は鮮やかな青 (暗い外観のメニューバーでは
    /// 青い壁紙に沈まないよう、白寄りの水色)。
    static func colors(forPrecipitationChance percent: String) -> ColorSet {
        switch Int(percent) ?? 0 {
        case 60...:
            ColorSet(lightMenuBar: "#0A6FD8", dark: "#64B5FF", lightCard: "#0047B3", darkMenuBar: "#A8D4FF")
        case 30...: ColorSet(lightMenuBar: "#5B7FA6", dark: "#7895B8", lightCard: "#2F5480")
        default: ColorSet(lightMenuBar: "#8E8E93", dark: "#7C7C80", lightCard: "#5A5A60")
        }
    }

    /// 気温の色 (カード用)。暑いほど赤、寒いほど青。どれにも当たらなければ nil (標準の文字色)。
    static func color(forTemperature temperature: Double?, dark: Bool) -> String? {
        guard let t = temperature else { return nil }
        let pair: (dark: String, light: String)
        switch t {
        case 30...: pair = ("#FF6961", "#A3000F")
        case 25...: pair = ("#FFD60A", "#7A5000")
        case ...5: pair = ("#64B5FF", "#0047B3")
        case ...12: pair = ("#5AD8E6", "#005E73")
        default: return nil
        }
        return dark ? pair.dark : pair.light
    }

    /// 気温の色。気温を文字で受け取る (週間予報の値は文字で配られ、空のことがある)
    static func color(forTemperature text: String, dark: Bool) -> String? {
        color(forTemperature: Double(text), dark: dark)
    }

    /// 風向の名前。アメダスの風向は 0 が静穏、1〜16 が北北東から時計回りに北まで
    static func windDirection(_ index: Int) -> String? {
        let names = isJapanese
            ? ["静穏", "北北東", "北東", "東北東", "東", "東南東", "南東", "南南東",
               "南", "南南西", "南西", "西南西", "西", "西北西", "北西", "北北西", "北"]
            : ["Calm", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
               "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW", "N"]
        return names.indices.contains(index) ? names[index] : nil
    }

    /// 地域時系列予報の風向 (風が吹いてくる方角の名前) から、風が吹いていく向き
    /// (北が 0 度で時計回り) を返す。知らない名前なら nil
    static func windHeading(_ direction: String) -> Double? {
        let names = ["北", "北北東", "北東", "東北東", "東", "東南東", "南東", "南南東",
                     "南", "南南西", "南西", "西南西", "西", "西北西", "北西", "北北西"]
        guard let index = names.firstIndex(of: direction) else { return nil }
        return (Double(index) * 22.5 + 180).truncatingRemainder(dividingBy: 360)
    }

    /// 「取り直せなかったので古いデータを出している」印。以前は赤い三角
    /// (exclamationmark.triangle) にしていたが、警報の印に見えた。気象庁のデータを
    /// まったく取れないときのメニューバー (WeatherMenu.noDataLines) と同じ形にする
    static let staleSymbol = "exclamationmark.icloud"
    /// その色。警報の色と紛れないよう、天気の分からないときと同じ灰色
    static let staleColors = colors(forIcon: "")

    /// 警報・注意報の印。特別警報は八角形にする (色が黒で、暗い外観では白にするので、
    /// 色だけではほかの段階と見分けにくい)
    static func symbol(forWarningLevel level: Int) -> String {
        level >= 5 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    /// 警報・注意報の色。気象庁の段階の色 (注意報は黄、警報は赤、危険警報は紫、
    /// 特別警報は黒) に寄せる。黄は白地で読めないので、明るい外観では暗い黄土色にする。
    /// 黒は暗い地で見えないので、暗い外観では白にする
    static func colors(forWarningLevel level: Int) -> ColorSet {
        switch level {
        case 5...: ColorSet(lightMenuBar: "#0C000C", dark: "#FFFFFF", lightCard: "#0C000C")
        case 4: ColorSet(lightMenuBar: "#AA00AA", dark: "#E57EE5", lightCard: "#8A008A")
        case 3: ColorSet(lightMenuBar: "#E62200", dark: "#FF6347", lightCard: "#C41E00")
        default: ColorSet(lightMenuBar: "#B39A00", dark: "#F2E700", lightCard: "#7A6500")
        }
    }
}
