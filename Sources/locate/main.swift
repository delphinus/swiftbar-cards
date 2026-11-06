// weather.10m.sh が使う、現在地を調べるプログラム。
//
// SwiftBar から起動したプログラムで位置情報を読むと、macOS は SwiftBar の許可として
// 扱う。SwiftBar は位置情報を使う設定 (Info.plist の NSLocationUsageDescription) を
// 持っていないので、許可を求めることすらできない。そこでこのプログラムは .app の形に
// して (scripts/lib.sh の build_app)、`open` で起動する。こうすると自分の許可を持てる。
//
//   open -g -a <.app> --args <キャッシュのフォルダ> [プラグインの名前]
//
// 結果はキャッシュのフォルダに書く (`open` では標準出力を受け取れない)。
// - location         最後に取れた現在地。「緯度 経度 精度 (m) UNIX 時刻」の 1 行
// - location-status  ok / denied (許可されていない) / disabled (位置情報サービスが
//                    切ってある) / error (取れなかった) のどれか
//
// 初回は許可を求めるダイアログが出る。プラグインはこのプログラムを待たずに先へ進む
// ので、答えるまで待ってよい (最長 3 分)。状態が変わったか、前の位置から 1 km 以上
// 動いたときは、SwiftBar にプラグインの更新を指示する。プラグインの名前を渡さなければ
// 指示しない (テスト用)。

import AppKit
import CoreLocation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: locate <キャッシュのフォルダ> [プラグインの名前]\n".data(using: .utf8)!)
    exit(2)
}
let cacheDir = URL(fileURLWithPath: args[1], isDirectory: true)
let pluginName = args.count >= 3 ? args[2] : ""
let locationFile = cacheDir.appendingPathComponent("location")
let statusFile = cacheDir.appendingPathComponent("location-status")

func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func write(_ text: String, to url: URL) {
    try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
}

final class Locator: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    let previousStatus = read(statusFile)
    let previousLocation: CLLocation? = {
        let f = read(locationFile).split(separator: " ").compactMap { Double($0) }
        return f.count >= 2 ? CLLocation(latitude: f[0], longitude: f[1]) : nil
    }()
    var requested = false

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // 許可のダイアログに答えるまでの時間を含めて 3 分で諦める
        Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in self.finish("error") }
        guard CLLocationManager.locationServicesEnabled() else { return finish("disabled") }
        // 許可の状態は、delegate を設定したあとに locationManagerDidChangeAuthorization で届く
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish("denied")
        default:
            guard !requested else { return }
            requested = true
            manager.requestLocation()
            // 取れるまでに時間がかかりすぎるときは諦める
            Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in self.finish("error") }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let c = loc.coordinate
        write(String(format: "%.5f %.5f %.0f %.0f", c.latitude, c.longitude, loc.horizontalAccuracy,
                     loc.timestamp.timeIntervalSince1970), to: locationFile)
        let moved = previousLocation.map { $0.distance(from: loc) >= 1000 } ?? true
        finish("ok", changed: moved)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 許可を求めている最中にも届くことがある。そのときは答えを待つ
        if manager.authorizationStatus == .notDetermined { return }
        if (error as? CLError)?.code == .denied { return finish("denied") }
        finish("error")
    }

    func finish(_ status: String, changed: Bool = false) {
        write(status, to: statusFile)
        if !pluginName.isEmpty && (changed || status != previousStatus),
           let url = URL(string: "swiftbar://refreshplugin?name=\(pluginName)") {
            NSWorkspace.shared.open(url)
        }
        exit(0)
    }
}

// .app として起動されるので、NSApplication の run loop の上で動かす。Dock にも
// メニューバーにも出さない (Info.plist の LSUIElement)。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let locator = Locator()
locator.start()
app.run()
