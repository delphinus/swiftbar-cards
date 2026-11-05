import AppKit
#if canImport(Shared)
import Shared
#endif

/// 与えた曲で 1 回だけ描く (テストと README の画像用)。
///
///     nowplaying --render <曲の JSON> <出力先>
///
/// 出力先に menubar-light.png・menubar-dark.png・card-light.png・card-dark.png を書く。
enum SampleRender {
    /// 曲の JSON の形。`Decodable` にすると、JSONDecoder がプロパティの名前と同じキーを読む。
    /// 省いてよい値は Optional (`?`) にする。
    private struct Sample: Decodable {
        var state: String?
        var name: String?
        var artist: String?
        var album: String?
        var position: Double?
        var duration: Double?
        /// 画像のパス。相対パスは JSON のファイルの場所から辿る
        var artwork: String?
    }

    static func run(jsonPath: String, outputDirectory: String) -> Never {
        guard let data = FileManager.default.contents(atPath: jsonPath),
              let sample = try? JSONDecoder().decode(Sample.self, from: data) else {
            exitWithError("曲の JSON を読めない: \(jsonPath)")
        }
        let track = Track(state: Track.State(rawValue: sample.state ?? "playing") ?? .playing, id: "sample",
                          name: sample.name ?? "", artist: sample.artist ?? "", album: sample.album ?? "",
                          position: sample.position, duration: sample.duration)
        let artwork = sample.artwork.flatMap { path in
            NSImage(contentsOf: URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: jsonPath).deletingLastPathComponent()))
        }

        let images = NowPlayingImages(track: track, artwork: artwork)
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let appearance = dark ? "dark" : "light"
                try images.menuBar(dark: dark).write(to: directory, name: "menubar-\(appearance)")
                try images.card(dark: dark).write(to: directory, name: "card-\(appearance)")
            }
        } catch {
            exitWithError("画像を書き出せない: \(error)")
        }
        exit(0)
    }
}
