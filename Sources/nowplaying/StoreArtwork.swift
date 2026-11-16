import AppKit
#if canImport(Shared)
import Shared
#endif

/// Apple Music のカタログから直接再生している曲 (ライブラリに入れていない曲) のアートワークを、
/// iTunes Search API で探す。
///
/// Music.app はこういう曲を「URL track」として扱い、Apple Events にはアートワークを渡さない
/// (artworks が空になる。2026-11-06 に確かめた)。曲名とアーティストは読めるので、それで
/// ストアを検索し、見つかった曲のアートワークを取る。
enum StoreArtwork {
    /// 曲のアートワークを探す。見つからなければ nil。通信を待つので、メインスレッドでは呼ばない
    ///
    /// 曲名とアルバムが一致するものを選ぶ。無ければ曲名だけが一致するもの。どちらも無ければ
    /// nil (違う曲のアートワークを出すよりは、出さないほうがよい)。アーティスト名はストアの
    /// 国によって表記が変わる (日本のストアではカタカナになることがある) ので、比べるのには
    /// 使わない。
    static func find(for track: Track) async -> NSImage? {
        guard let songs = try? await StoreSearch.songs(for: track),
              let song = songs.first(where: { $0.trackName == track.name && $0.collectionName == track.album })
                ?? songs.first(where: { $0.trackName == track.name }),
              let small = song.artworkUrl100,
              // ファイル名の大きさを書き換えると、その大きさの画像が返る
              let url = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")),
              let data = try? await HTTP.get(url) else { return nil }
        return NSImage(data: data)
    }
}

/// iTunes Search API での曲の検索。API キーは要らない。
/// https://performance-partners.apple.com/search-api
enum StoreSearch {
    private static let logger = makeLogger("nowplaying")

    /// 検索の結果のうち、使う値だけ。`Decodable` にすると、JSONDecoder が同じ名前のキーを読む
    private struct Response: Decodable {
        let results: [Song]
    }

    struct Song: Decodable {
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        /// 100×100 の画像の URL。例: …/cover.jpg/100x100bb.jpg
        let artworkUrl100: String?
        /// Apple Music の曲のページ。例: https://music.apple.com/jp/album/…?i=…&uo=4
        let trackViewUrl: String?
    }

    /// 「アーティスト 曲名」で検索する。Music.app と同じストア (地域の設定) で探す。
    /// 取れなければ `HTTP.Failure` を投げる。
    static func songs(for track: Track) async throws -> [Song] {
        guard let url = HTTP.url("https://itunes.apple.com/search", [
            "term": "\(track.artist) \(track.name)",
            "entity": "song",
            "limit": "10",
            "country": Locale.current.region?.identifier ?? "US",
        ]) else { return [] }
        let data = try await HTTP.get(url)
        do {
            return try JSONDecoder().decode(Response.self, from: data).results
        } catch {
            logger.error("検索の結果を読めない: \(String(describing: error), privacy: .public)")
            throw HTTP.Failure()
        }
    }
}
