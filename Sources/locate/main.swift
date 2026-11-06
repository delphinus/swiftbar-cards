// weather が使う、現在地を調べるプログラム。
//
// SwiftBar から起動したプログラムで位置情報を読むと、macOS は SwiftBar の許可として
// 扱う。SwiftBar は位置情報を使う設定 (Info.plist の NSLocationUsageDescription) を
// 持っていないので、許可を求めることすらできない。そこでこのプログラムは .app の形に
// して (scripts/lib.sh の build_app)、NSWorkspace で起動してもらう (`open` と同じ)。
// こうすると自分の許可を持てる。
//
//   open -g -a <.app> --args <キャッシュのフォルダ>
//
// 結果はキャッシュのフォルダに書く (起動した側は標準出力を受け取れない)。
// - location         最後に取れた現在地。「緯度 経度 精度 (m) UNIX 時刻」の 1 行
// - location-status  ok / denied (許可されていない) / disabled (位置情報サービスが
//                    切ってある) / error (取れなかった) のどれか
//
// 初回は許可を求めるダイアログが出る。weather はこのプログラムを待たずに先へ進む
// ので、答えるまで待ってよい (最長 3 分)。書いたファイルは、常駐している weather が
// フォルダの変化から気付いて読む。

import AppKit
import CoreLocation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: locate <キャッシュのフォルダ>\n".data(using: .utf8)!)
    exit(2)
}
let cacheDir = URL(fileURLWithPath: args[1], isDirectory: true)
let locationFile = cacheDir.appendingPathComponent("location")
let statusFile = cacheDir.appendingPathComponent("location-status")

func write(_ text: String, to url: URL) {
    try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
}

final class Locator: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
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
        finish("ok")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 許可を求めている最中にも届くことがある。そのときは答えを待つ
        if manager.authorizationStatus == .notDetermined { return }
        if (error as? CLError)?.code == .denied { return finish("denied") }
        finish("error")
    }

    func finish(_ status: String) {
        write(status, to: statusFile)
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
