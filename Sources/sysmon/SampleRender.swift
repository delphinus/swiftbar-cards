import Foundation
#if canImport(Shared)
import Shared
#endif

/// 与えた値で 1 回だけ描く (テストと README の画像用)。
///
///     sysmon --render <Snapshot の JSON> <出力先>
///
/// JSON は Snapshot の形 (samples/sysmon.json)。出力先に menubar-light.png・
/// menubar-dark.png・card-light.png・card-dark.png を書く。
enum SampleRender {
    static func run(jsonPath: String, outputDirectory: String) -> Never {
        guard let data = FileManager.default.contents(atPath: jsonPath) else {
            exitWithError("JSON を読めない: \(jsonPath)")
        }
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            exitWithError("JSON の形が違う: \(error)")
        }

        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let appearance = dark ? "dark" : "light"
                try SystemCard(snapshot: snapshot, dark: dark).render().write(to: directory, name: "card-\(appearance)")
                try SystemMenuBar(snapshot: snapshot).render(dark: dark).write(to: directory, name: "menubar-\(appearance)")
            }
        } catch {
            exitWithError("画像を書き出せない: \(error)")
        }
        exit(0)
    }
}
