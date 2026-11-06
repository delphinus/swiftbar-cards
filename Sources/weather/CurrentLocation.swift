import AppKit

/// 現在地。位置情報を読む小さな .app (Sources/locate/、キャッシュの Locate.app) が
/// キャッシュのフォルダに書いた結果を読む。
///
/// SwiftBar から起動したプログラムには位置情報の許可を持たせられないので、.app に
/// 調べさせる。.app は待たずに裏で動かし、書き終えたら常駐している本体が
/// フォルダの変化に気付いて描き直す (WeatherPlugin)。
struct CurrentLocation: Equatable {
    /// 緯度と経度。分からなければ nil (そのあいだは東京を出す)
    let coordinate: (latitude: Double, longitude: Double)?
    /// ok / denied (許可されていない) / disabled (位置情報サービスが切ってある) /
    /// error (取れなかった) のどれか。まだ調べていなければ空
    let status: String

    var isKnown: Bool { coordinate != nil }

    static func == (a: CurrentLocation, b: CurrentLocation) -> Bool {
        a.status == b.status && a.coordinate?.latitude == b.coordinate?.latitude
            && a.coordinate?.longitude == b.coordinate?.longitude
    }

    /// 環境変数 SWIFTBAR_CARDS_LOCATION="<緯度> <経度>" があれば、それを現在地にする
    /// (テスト用。none なら取れなかったことにする)
    private static var override: String? { ProcessInfo.processInfo.environment["SWIFTBAR_CARDS_LOCATION"] }

    /// キャッシュのフォルダの結果を読む
    static func read(from cache: CacheFolder) -> CurrentLocation {
        if let override, !override.isEmpty {
            let numbers = override.split(separator: " ").compactMap { Double($0) }
            guard override != "none", numbers.count >= 2 else { return CurrentLocation(coordinate: nil, status: "error") }
            return CurrentLocation(coordinate: (numbers[0], numbers[1]), status: "ok")
        }

        let status = CacheFolder.readText(cache.locationStatus)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 許可を取り消された (か位置情報サービスを切った) ら、前に取れた現在地も使わない。
        // 一時的に取れなかった (error) だけなら、前に取れた現在地を使い続ける。
        guard status != "denied", status != "disabled",
              let numbers = CacheFolder.readText(cache.location)?.split(separator: " ").compactMap({ Double($0) }),
              numbers.count >= 2 else {
            return CurrentLocation(coordinate: nil, status: status)
        }
        return CurrentLocation(coordinate: (numbers[0], numbers[1]), status: status)
    }

    /// Locate.app を裏で起動して、現在地を調べ直させる。`always` でなければ、前に
    /// 調べてから 10 分経っていないときは起動しない。
    static func requestUpdate(cache: CacheFolder, always: Bool) {
        if let override, !override.isEmpty { return }
        if !always, CacheFolder.isFresh(cache.location, maxAge: 600) { return }
        guard FileManager.default.fileExists(atPath: cache.locateApp.path) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false // open -g と同じく、前に出さない
        configuration.arguments = [cache.url.path]
        NSWorkspace.shared.openApplication(at: cache.locateApp, configuration: configuration)
    }
}
