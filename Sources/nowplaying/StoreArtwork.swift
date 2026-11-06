import AppKit
#if canImport(Shared)
import Shared
#endif

/// Apple Music のカタログから直接再生している曲 (ライブラリに入れていない曲) のアートワークを、
/// iTunes Search API で探す。
///
/// Music.app はこういう曲を「URL track」として扱い、Apple Events にはアートワークを渡さない
/// (artworks が空になる。2026-11-06 に確かめた)。曲名とアーティストは読めるので、それで
/// ストアを検索し、見つかった曲のアートワークを取る。API キーは要らない。
/// https://performance-partners.apple.com/search-api
enum StoreArtwork {
    private static let logger = makeLogger("nowplaying")

    /// 検索の結果のうち、使う値だけ。`Decodable` にすると、JSONDecoder が同じ名前のキーを読む
    private struct SearchResponse: Decodable {
        let results: [Song]
    }

    private struct Song: Decodable {
        let trackName: String?
        let collectionName: String?
        /// 100×100 の画像の URL。例: …/cover.jpg/100x100bb.jpg
        let artworkUrl100: String?
    }

    /// 曲のアートワークを探す。見つからなければ nil。通信を待つので、メインスレッドでは呼ばない
    static func find(for track: Track) async -> NSImage? {
        guard let song = await search(track),
              let small = song.artworkUrl100,
              // ファイル名の大きさを書き換えると、その大きさの画像が返る
              let url = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")),
              let data = await fetch(url) else { return nil }
        return NSImage(data: data)
    }

    /// 「アーティスト 曲名」で検索し、曲名とアルバムが一致するものを選ぶ。無ければ曲名だけが
    /// 一致するもの。どちらも無ければ nil (違う曲のアートワークを出すよりは、出さないほうがよい)。
    /// アーティスト名はストアの国によって表記が変わる (日本のストアではカタカナになることが
    /// ある) ので、比べるのには使わない。
    private static func search(_ track: Track) async -> Song? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(track.artist) \(track.name)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            // Music.app と同じストア (地域の設定) で探す
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        guard let url = components.url, let data = await fetch(url) else { return nil }
        let songs: [Song]
        do {
            songs = try JSONDecoder().decode(SearchResponse.self, from: data).results
        } catch {
            logger.error("検索の結果を読めない: \(String(describing: error), privacy: .public)")
            return nil
        }
        return songs.first { $0.trackName == track.name && $0.collectionName == track.album }
            ?? songs.first { $0.trackName == track.name }
    }

    /// `url` を取る。取れなければ (応答が 200 でなければ) 理由を記録して nil
    private static func fetch(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                logger.error("取得に失敗: \(url.host ?? "", privacy: .public)\(url.path, privacy: .public): HTTP \(status)")
                return nil
            }
            return data
        } catch {
            logger.error("取得に失敗: \(url.host ?? "", privacy: .public)\(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
