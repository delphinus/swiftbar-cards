import Foundation
#if canImport(Shared)
import Shared
#endif

/// 1 回の更新で使う、そのときの地点の状態
struct WeatherState {
    /// 設定した地点 (現在地を含む)
    let places: [Place]
    let selectedIndex: Int
    let here: CurrentLocation

    var selected: Place { places[selectedIndex] }

    /// 観測点が決まった地点
    var stations: [Place.Station] { places.compactMap(\.station) }
}

/// メニューの行を組み立てる。書式は https://github.com/swiftbar/SwiftBar#plugin-api にある。
///
/// メニューの項目の動作は、このプラグインを引数付きで起動する (`bash=<プラグイン>
/// param1=select …`)。起動されたプラグインは指示をキャッシュのフォルダに書くだけで、
/// 常駐している本体がそれを読んでメニューを差し替える (Command.swift)。refresh=true は
/// 付けない (常駐型のプラグインでは、プラグインを起動し直してしまう)。
struct WeatherMenu {
    let state: WeatherState
    let cache: CacheFolder
    let dark: Bool
    /// このプラグインのシェルスクリプトのパス
    let pluginPath: String

    // MARK: - メニュー全体

    /// 選んでいる地点のカードを出すメニュー。`updating` なら、「今すぐ更新」の代わりに
    /// 「更新中…」(動作の無い項目なので薄く出る) を出す。
    func lines(card: PlaceCard, office: String, updating: Bool) -> [String] {
        [card.menuBarLine, "---"]
            // 取り直せなかったことと警報・注意報は、カードの上に出す
            + card.notices
            // カードの下には区切り線を引かない (カードの地の縁が境目になる)
            + [card.cardLine]
            + hereNote()
            + locationItems()
            + [openConfigurationItem,
               updating ? L("更新中…", "Updating…") + " | sfimage=arrow.triangle.2.circlepath" : refreshItem,
               L("気象庁の天気予報を開く", "Open JMA Forecast")
                   + " | sfimage=arrow.up.forward.circle href=https://www.jma.go.jp/bosai/forecast/#area_type=offices&area_code=\(office)"]
    }

    /// 選んでいる地点の観測点が決まらないとき (設定の不備) のメニュー
    func configurationErrorLines() -> [String] {
        let query = state.selected.query
        var messages: [String] = []
        switch state.selected.match {
        case .notFound where query.allSatisfy({ $0.isASCII && $0.isNumber }):
            messages = [L("アメダスの観測点 \(query) が見つからない", "No AMeDAS station numbered \(query)")]
        case .notFound:
            messages = [L("「\(query)」という名前のアメダスの観測点が見つからない", "No AMeDAS station named \"\(query)\""),
                        L("気象庁の「アメダス」のページで観測点の名前を確かめる", "Look up station names on the JMA AMeDAS page")
                            + " | href=https://www.jma.go.jp/bosai/amedas/"]
        case .ambiguous(let stations):
            messages = [L("「\(query)」という名前の観測点が複数ある。設定ファイルに番号で書く:",
                          "More than one station is named \"\(query)\". Write its number in the configuration file:")]
                + stations.map { L("\($0.localizedName)（\($0.officeName)）: place=\($0.code)",
                                    "\($0.localizedName) (\($0.officeEnName)): place=\($0.code)") }
        case .found:
            break
        }
        return [":exclamationmark.triangle: " + L("天気", "Weather"), "---"] + messages + ["---"]
            + locationItems() + [openConfigurationItem, refreshItem]
    }

    /// 気象庁のデータを取れないときのメニュー
    static func noDataLines() -> [String] {
        [" | sfimage=exclamationmark.icloud", "---", L("気象庁のデータを取得できない", "Could not get data from JMA")]
    }

    // MARK: - 項目

    /// 現在地を選んでいて、現在地が分からない (東京を出している) ときに、その理由を出す
    private func hereNote() -> [String] {
        guard state.selected.isHere, !state.here.isKnown else { return [] }
        let openSettings = L("位置情報サービスの設定を開く", "Open Location Services Settings")
            + " | sfimage=gearshape.circle href=x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        let warning = " | sfimage=location.slash color=#D70015,#FF6961"
        let lines: [String] = switch state.here.status {
        case "denied":
            [L("位置情報の利用が許可されていないので、東京を表示中", "Location access is not allowed. Showing Tokyo") + warning, openSettings]
        case "disabled":
            [L("位置情報サービスが切ってあるので、東京を表示中", "Location Services are off. Showing Tokyo") + warning, openSettings]
        case "error":
            [L("現在地を取得できないので、東京を表示中", "Could not get your location. Showing Tokyo") + " | sfimage=location.slash"]
        default:
            [L("現在地を取得中なので、東京を表示中", "Getting your location. Showing Tokyo") + " | sfimage=location"]
        }
        return lines + ["---"]
    }

    /// 地点の切り替え。地点が 2 つ以上あるときだけ、選んでいる地点の印を付けて並べる。
    /// サブメニューにしないのは、SwiftBar 2.1.1 では、メニューを差し替えたときに動作の
    /// 無いサブメニューの親が押せない状態のまま残ることがあるため。
    private func locationItems() -> [String] {
        guard state.places.count > 1 else { return [] }
        return state.places.enumerated().map { i, place in locationItem(place, selected: i == state.selectedIndex) } + ["---"]
    }

    private func locationItem(_ place: Place, selected: Bool) -> String {
        // 選んでいる地点は、チェックマークではなく塗りつぶしたピンで示す。チェックマークを
        // 付けると、macOS がメニュー全体にその欄を取り、カードの左が 14pt 空く。
        // 現在地はピンではなく、位置情報の矢印で示す
        var icon = place.isHere ? "location.circle" : "mappin.circle"
        if selected { icon += ".fill" }

        // 地点名の後ろに、その地点のメニューバーの行 (天気・気温・降水確率) を添える。
        // 取り直さず、キャッシュのカードの 4 行目 (メニューの地に合わせた色で書いたもの)
        // を使う。4 行目が無い古いキャッシュでは 1 行目 (メニューバーの行)。
        // 色の指定 (sfcolor・sfcolor2) で色が付くのは文中のアイコンだけで、sfimage の
        // ピンは標準の色のまま (SwiftBar の main のソースで確かめた。2026-11-06)。
        var summary = ""
        var parameters = ""
        if let station = place.station, let card = PlaceCard.read(cache.card(station: station, dark: dark)) {
            let line = card.menuItemSummary.isEmpty ? card.menuBarLine : card.menuItemSummary
            if let separator = line.range(of: " | ") {
                summary = "   " + line[..<separator.lowerBound]
                parameters = " " + line[separator.upperBound...]
            } else {
                summary = "   " + line
            }
        }
        return "\(label(of: place))\(summary) | sfimage=\(icon)\(parameters) \(action("select", place.query))"
    }

    /// 地点の表示名。解決できなかった地点は書かれたまま出す。現在地は「現在地（府中）」の
    /// ように、使っている観測点を添えて出す。英語では、macOS の天気・マップと同じ
    /// My Location。現在地が分からないあいだは「現在地」だけ。
    private func label(of place: Place) -> String {
        guard let station = place.station else { return place.query }
        guard station.isHere else { return station.localizedName }
        let name = L("現在地", "My Location")
        guard state.here.isKnown else { return name }
        return L("\(name)（\(station.localizedName)）", "\(name) (\(station.localizedName))")
    }

    private var openConfigurationItem: String {
        L("設定ファイルを開く", "Open Configuration File") + " | sfimage=gearshape.circle \(action("open-config"))"
    }

    /// 設定ファイルを書き換えたあと、次の更新 (10 分ごと) を待たずに反映する
    private var refreshItem: String {
        L("今すぐ更新", "Refresh Now") + " | sfimage=arrow.clockwise.circle \(action("refresh-now"))"
    }

    /// このプラグインを引数付きで起動する動作
    private func action(_ arguments: String...) -> String {
        let path = pluginPath.contains(" ") ? "\"\(pluginPath)\"" : pluginPath
        let parameters = arguments.enumerated().map { "param\($0.offset + 1)=\($0.element)" }
        return (["bash=\(path)"] + parameters + ["terminal=false"]).joined(separator: " ")
    }
}
