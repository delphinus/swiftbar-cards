import AppKit
#if canImport(Shared)
import Shared
#endif

/// メニューバーの画像。
///
///     [天気のアイコン] 9°  [傘] 60%  [警報の印]  [古いデータの印]
///
/// 明るい用と暗い用の 2 枚を描き、SwiftBar がメニューバーの見た目に合うほうを選ぶ
/// (SwiftBar.menuBarImageLine)。文字は sysmon の見出しのアイコンと同じく白か黒で、
/// アイコンは天気と降水確率の色で描く。メニューバーのほかの文字に合わせて、数字は
/// 等幅にしない。
///
/// 文字とアイコンを置く高さは MenuBarLayout に従う。
struct WeatherMenuBar {
    let icon: String
    let temperature: String
    let precipitationChance: String
    /// 印を出す警報 (警報以上)。無ければ nil
    let warning: WeatherWarning?
    let stale: Bool

    private let height = MenuBarLayout.height
    /// メニューバーのほかの文字 (SwiftBar が描く文字や時計) と同じフォント
    private let font = NSFont.menuBarFont(ofSize: 0)
    private let iconPointSize = MenuBarLayout.iconPointSize
    /// アイコンと文字の間 (文中に置いたときの空白に合わせる)
    private let spacing: CGFloat = 4
    /// 気温と傘、降水確率と警報や古いデータの印の間
    private let itemGap: CGFloat = 7

    func render(dark: Bool) -> PNGImage {
        let textColor = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
        func label(_ string: String) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: textColor])
        }
        func symbol(_ name: String, _ colors: ColorSet) -> NSImage? {
            NSImage.symbol(name, pointSize: iconPointSize, color: NSColor(hex: colors.menuBar(dark: dark)) ?? textColor)
        }

        // 雨のアイコンは塗りつぶしの形にする。線だけの形はメニューバーの小ささでは細く、
        // 青い壁紙の上で見失いやすかった
        var pieces: [Piece] = []
        let weatherSymbol = icon == "cloud.rain" ? "cloud.rain.fill" : icon
        if let image = symbol(weatherSymbol, WeatherStyle.colors(forIcon: icon)) { pieces.append(.icon(image)) }
        if !temperature.isEmpty { pieces.append(.gap(spacing)); pieces.append(.text(label(temperature))) }
        if !precipitationChance.isEmpty,
           let umbrella = symbol("umbrella.fill", WeatherStyle.colors(forPrecipitationChance: precipitationChance)) {
            pieces += [.gap(itemGap), .icon(umbrella), .gap(spacing), .text(label("\(precipitationChance)%"))]
        }
        if let warning, let mark = symbol(WeatherStyle.symbol(forWarningLevel: warning.level),
                                          WeatherStyle.colors(forWarningLevel: warning.level)) {
            pieces += [.gap(itemGap), .icon(mark)]
        }
        if stale, let mark = symbol(WeatherStyle.staleSymbol, WeatherStyle.staleColors) {
            pieces += [.gap(itemGap), .icon(mark)]
        }

        let width = ceil(pieces.reduce(0) { $0 + $1.width }) + 1
        return PNGImage.draw(width: width, height: height) { _ in
            var x: CGFloat = 0
            for piece in pieces {
                switch piece {
                case .icon(let image): image.drawUpright(in: MenuBarLayout.iconRect(image, x: x))
                case .text(let text):
                    // MenuBarLayout の文字と同じ高さに、ベースラインをそろえて置く
                    text.draw(at: CGPoint(x: x, y: MenuBarLayout.baseline - font.ascender))
                case .gap: break
                }
                x += piece.width
            }
        }
    }

    private enum Piece {
        case icon(NSImage)
        case text(NSAttributedString)
        case gap(CGFloat)

        var width: CGFloat {
            switch self {
            case .icon(let image): image.size.width
            case .text(let text): text.size().width
            case .gap(let width): width
            }
        }
    }
}
