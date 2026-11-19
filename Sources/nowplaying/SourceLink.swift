import Foundation
#if canImport(Shared)
import Shared
#endif

/// 再生中の曲のソース (曲のページ) を探す。カードをクリックすると開く。
///
/// Apple Music → Bandcamp → SoundCloud → Beatport → Discogs の順に探し、最初に見つかったものを使う。
/// どれも API キーは要らない。
/// - Apple Music: iTunes Search API (StoreSearch)
/// - Bandcamp: 検索の欄の候補を出す API (autocomplete_elastic)。検索のページは JavaScript の
///   チャレンジを挟むので読めない
/// - SoundCloud: 検索のページ。JavaScript を切ったとき用の <noscript> に、曲名と曲のページへの
///   リンクが 10 件ほど入っている
/// - Beatport: 検索のページ。Next.js のページで、検索の結果が __NEXT_DATA__ の JSON に入っている
/// - Discogs: database/search の API。認証無しでも 1 分に 25 回まで使える
///
/// 違う曲のページを開くよりは、どこにも飛ばないほうがよいので、曲名とアーティストが
/// 一致するものだけを選ぶ (SourceMatch)。
struct SourceLink {
    enum Source: String, CaseIterable {
        case appleMusic = "Apple Music"
        case bandcamp = "Bandcamp"
        case soundCloud = "SoundCloud"
        case beatport = "Beatport"
        case discogs = "Discogs"
    }

    let source: Source
    let url: URL

    /// 探した結果。どこかで通信に失敗したときは `complete` が false (次に同じ曲が
    /// かかったときに探し直す)。
    struct Result {
        let link: SourceLink?
        let complete: Bool
    }

    static func find(for track: Track) async -> Result {
        var complete = true
        for source in Source.allCases {
            do {
                if let url = try await find(track, in: source) {
                    return Result(link: SourceLink(source: source, url: url), complete: complete)
                }
            } catch {
                // 通信に失敗したソースは飛ばして、次のソースを探す
                complete = false
            }
        }
        return Result(link: nil, complete: complete)
    }

    private static func find(_ track: Track, in source: Source) async throws -> URL? {
        switch source {
        case .appleMusic: return try await appleMusic(track)
        case .bandcamp: return try await bandcamp(track)
        case .soundCloud: return try await soundCloud(track)
        case .beatport: return try await beatport(track)
        case .discogs: return try await discogs(track)
        }
    }

    // MARK: - Apple Music

    /// 曲名が一致し、アルバムかアーティストも一致するもの。アートワーク (StoreArtwork) と
    /// 違って曲名だけの一致では選ばない。ライブラリの曲 (Bandcamp で買った曲など) と
    /// 同じ名前の別の曲に飛んでしまう。
    ///
    /// 曲名が一致するものが無ければ、「曲名 (Extended Mix)」「曲名 (X Remix (Extended))」の
    /// ような同じ曲の長さ違いを選ぶ (SourceMatch.sameVersionRank)。DJ mix のアルバムに
    /// 入れた曲は、ミックス名を書かないか、長さ違いの印を省いて書くことが多い。
    private static func appleMusic(_ track: Track) async throws -> URL? {
        let match = SourceMatch(track)
        let songs = try await StoreSearch.songs(for: track).filter { song in
            match.album(song.collectionName ?? "") || match.artist(song.artistName ?? "")
        }
        let song = songs.first { match.title($0.trackName ?? "") }
            ?? songs.compactMap { song in match.sameVersionRank(song.trackName ?? "").map { (song, $0) } }
                .min { $0.1 < $1.1 }?.0
        return song?.trackViewUrl.flatMap(URL.init(string:))
    }

    // MARK: - Bandcamp

    /// 検索の欄の候補を出す API。検索の語をすべて含む曲しか返さないので、曲名の括弧
    /// (ミックス名) は外して探す。Bandcamp では「(X Remix)」が「(X Mix)」と書かれている
    /// ことがあり、括弧ごと入れると見つからない。返った曲の中から曲名で選ぶ。
    ///
    /// 曲名はレーベルのページだと「アーティスト - 曲名」と書かれることがある。そのときは
    /// 「 - 」の前をアーティストとみなす。
    private static func bandcamp(_ track: Track) async throws -> URL? {
        guard let url = URL(string: "https://bandcamp.com/api/bcsearch_public_api/1/autocomplete_elastic") else { return nil }
        let data = try await HTTP.post(url, json: [
            "search_text": "\(track.artist) \(SourceMatch.withoutBrackets(track.name))",
            "search_filter": "t",
            "full_page": false,
        ])
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = (root?["auto"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        let match = SourceMatch(track)
        let songs: [(name: String, url: String)] = results.compactMap { result in
            guard result["type"] as? String == "t",
                  var name = result["name"] as? String,
                  let url = result["item_url_path"] as? String else { return nil }
            var artist = result["band_name"] as? String ?? ""
            if let dash = name.range(of: " - "), match.artist(String(name[..<dash.lowerBound])) {
                artist = String(name[..<dash.lowerBound])
                name = String(name[dash.upperBound...])
            }
            return match.artist(artist) ? (name, url) : nil
        }
        let song = songs.first { match.title($0.name) }
            ?? songs.compactMap { song in match.sameVersionRank(song.name).map { (song, $0) } }
                .min { $0.1 < $1.1 }?.0
        return song.flatMap { URL(string: $0.url) }
    }

    // MARK: - SoundCloud

    /// 検索のページの <noscript> にある `<h2><a href="/ユーザ/曲">曲名</a></h2>`。
    /// 曲名は「アーティスト - 曲名 [FREE DOWNLOAD]」のように書かれることが多い。
    /// 「アーティスト - 」が無ければ、ユーザ名 (URL の 1 つめ) をアーティストとみなす。
    private static func soundCloud(_ track: Track) async throws -> URL? {
        guard let url = HTTP.url("https://soundcloud.com/search/sounds", ["q": "\(track.artist) \(track.name)"])
        else { return nil }
        let html = String(decoding: try await HTTP.get(url), as: UTF8.self)
        guard let noscript = html.range(of: "<noscript><ul>").map({ html[$0.lowerBound...] }) else { return nil }
        let match = SourceMatch(track)
        let pattern = #/<h2><a href="(/[^"/]+/[^"]+)">([^<]*)</a></h2>/#
        for found in noscript.matches(of: pattern) {
            let path = String(found.1)
            let user = String(path.dropFirst().prefix { $0 != "/" })
            // [FREE DOWNLOAD] や *Free Download* のような飾りを外す
            let title = decodeHTMLEntities(String(found.2))
                .replacing(#/\[[^\]]*\]|\*[^*]*\*/#, with: "")
                .trimmingCharacters(in: .whitespaces)
            let artist: String
            let name: String
            if let dash = title.range(of: " - ") {
                artist = String(title[..<dash.lowerBound])
                name = String(title[dash.upperBound...])
            } else {
                artist = user
                name = title
            }
            guard match.title(name, allowingSuffix: true),
                  match.artist(artist) || match.artist(user.replacingOccurrences(of: "-", with: " "))
            else { continue }
            return URL(string: "https://soundcloud.com\(path)")
        }
        return nil
    }

    // MARK: - Beatport

    /// 検索のページの __NEXT_DATA__ にある曲。曲名は track_name とミックス名 (mix_name) に
    /// 分かれている。Music.app の曲名は「曲名 (Extended Mix)」のようにミックス名まで
    /// 書いてあることも、書いていないこともある。書いていなければ Original Mix を選び、
    /// 無ければ同じ曲の長さ違い (SourceMatch.sameVersionRank) を選ぶ。
    private static func beatport(_ track: Track) async throws -> URL? {
        guard let url = HTTP.url("https://www.beatport.com/search/tracks", ["q": "\(track.artist) \(track.name)"])
        else { return nil }
        let html = String(decoding: try await HTTP.get(url), as: UTF8.self)
        guard let json = html.firstMatch(of: #/<script id="__NEXT_DATA__"[^>]*>(.*?)<\/script>/#.dotMatchesNewlines()),
              let root = try? JSONSerialization.jsonObject(with: Data(json.1.utf8)) else { return nil }
        let songs = beatportTracks(in: root)
        let match = SourceMatch(track)
        let byArtist = songs.filter { song in
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["artist_name"] as? String }
            return artists.contains(where: match.artist)
        }
        func name(_ song: [String: Any]) -> String { song["track_name"] as? String ?? "" }
        func mix(_ song: [String: Any]) -> String { song["mix_name"] as? String ?? "" }
        let song = byArtist.first { match.title("\(name($0)) (\(mix($0)))") }
            ?? byArtist.compactMap { song in match.sameVersionRank("\(name(song)) (\(mix(song)))").map { (song, $0) } }
                .min { $0.1 < $1.1 }?.0
        guard let song, let id = song["track_id"] as? Int else { return nil }
        // URL の名前の部分は何でもよい (ID で引かれる)。ページと同じ形にしておく
        let slug = name(song).lowercased()
            .replacing(#/[^\p{L}\p{N}]+/#, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return URL(string: "https://www.beatport.com/track/\(slug.isEmpty ? "-" : slug)/\(id)")
    }

    /// JSON のどこかにある、track_id と track_name を持つ要素の配列を集める。検索の結果は
    /// props.pageProps.dehydratedState.queries[].state.data.data にあるが、ページの作りが
    /// 変わっても探せるよう、場所は決め打ちしない。
    private static func beatportTracks(in object: Any) -> [[String: Any]] {
        if let array = object as? [Any] {
            let tracks = array.compactMap { $0 as? [String: Any] }.filter { $0["track_id"] != nil && $0["track_name"] != nil }
            if !tracks.isEmpty { return tracks }
            return array.flatMap(beatportTracks(in:))
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.values.flatMap(beatportTracks(in:))
        }
        return []
    }

    // MARK: - Discogs

    /// アーティストと曲名で、その曲が入ったリリースを探す。曲名の一致は Discogs の検索に任せる。
    /// 見つからなければ、曲名から「(Original Mix)」のような括弧を外して探し直す。
    ///
    /// Discogs の検索には、次の癖がある。
    /// - 日本語の語では引けない (「夕焼け」では何も返らず、「Fading Day」なら返る)。曲名に
    ///   日本語が入っていれば、最後に日本語の部分を外した曲名でも探す。
    /// - 曲名にアポストロフィがあると引けない (「Doesn't Matter」では何も返らず、「Doesnt Matter」
    ///   なら返る)。いつも外して探す。
    /// - 複数のアーティストのリリースは、アーティストが 1 人ずつ登録されていて、並べた名前
    ///   (「Hypasonic V Jorg Schmid」) では引けない。見つからなければ先頭の 1 人で探し直す。
    ///
    /// 同じ曲のリリース (CD・12 インチ・配信など) が並んで返るので、リリース名にミックス名が
    /// 入っているものを選ぶ。無ければ master (それらをまとめたページ) を、それも無ければ
    /// 最初に返ったものを選ぶ。
    private static func discogs(_ track: Track) async throws -> URL? {
        let base = SourceMatch.withoutBrackets(track.name)
        var names = [track.name]
        if !base.isEmpty, base != track.name { names.append(base) }
        let latin = SourceMatch.withoutCJK(track.name)
        if !SourceMatch.withoutBrackets(latin).isEmpty, !names.contains(latin) { names.append(latin) }
        names = names.map { $0.replacing(#/['’]/#, with: "") }
        var artists = [track.artist]
        let main = SourceMatch.mainArtist(of: track.artist)
        if !main.isEmpty, main != track.artist { artists.append(main) }
        let match = SourceMatch(track)
        for artist in artists {
            for name in names {
                guard let url = HTTP.url("https://api.discogs.com/database/search",
                                         ["artist": artist, "track": name, "per_page": "10"])
                else { continue }
                let data = try await HTTP.get(url)
                let results = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]] ?? [])
                    .filter { ["master", "release"].contains($0["type"] as? String ?? "") }
                let result = results.first { match.mixName($0["title"] as? String ?? "") }
                    ?? results.first { $0["type"] as? String == "master" }
                    ?? results.first
                if let uri = result?["uri"] as? String {
                    return URL(string: "https://www.discogs.com\(uri)")
                }
            }
        }
        return nil
    }

    // MARK: -

    /// SoundCloud の曲名に出てくる文字参照 (&amp; &#39; など) を文字に戻す
    private static func decodeHTMLEntities(_ text: String) -> String {
        let named = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
        var result = text.replacing(#/&#(x?)([0-9a-fA-F]+);/#) { match in
            let scalar = UInt32(match.2, radix: match.1.isEmpty ? 10 : 16).flatMap(Unicode.Scalar.init)
            return scalar.map { String(Character($0)) } ?? String(match.0)
        }
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}

/// 検索の結果が再生中の曲かどうかを見分ける。
///
/// 大文字と小文字、アクセント記号、全角と半角、空白や記号の違いは無視して比べる
/// (「Satellite (Original Mix)」と「satellite - original mix」は同じ)。曲名の「Remix」は
/// 「Mix」と同じとみなす (Bandcamp では「(Diakronik Remix)」が「(Diakronik Mix)」と書かれていた)。
/// 曲名の「(feat. X)」は外して比べる (Apple Music は「Change (feat. Allison Gray) [Technikore Remix]」
/// のように、ゲストのアーティストを曲名に書く)。
struct SourceMatch {
    private let name: String
    private let baseName: String
    private let nameHasMix: Bool
    private let album: String
    private let artist: String
    /// 「A & B」「A feat. B」の A
    private let mainArtist: String
    /// 曲名の括弧の中のミックス名 (「Re-Con & Squad-E Remix」)。Original Mix や、括弧が無ければ空
    private let mix: String

    init(_ track: Track) {
        name = Self.titleKey(track.name)
        baseName = Self.titleKey(Self.withoutOriginalMix(track.name))
        nameHasMix = Self.withoutFeaturing(track.name).contains("(")
        album = Self.key(track.album)
        artist = Self.key(track.artist)
        mainArtist = Self.key(Self.mainArtist(of: track.artist))
        let mixName = Self.withoutFeaturing(track.name).firstMatch(of: #/[(\[]\s*([^()\[\]]+?)\s*[)\]]/#).map { String($0.1) } ?? ""
        mix = mixName.lowercased() == "original mix" ? "" : Self.titleKey(mixName)
    }

    /// 「A & B」「A feat. B」「A V B」の A
    static func mainArtist(of artist: String) -> String {
        artist.split(separator: #/ & | and |, | feat\.? | ft\.? | featuring | x | vs?\.? /#.ignoresCase())
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? artist
    }

    /// リリース名に、曲名のミックス名が入っているか (Discogs の「Doesn't Matter (Recon & Squad E Remix) /
    /// (Dougal & Gammer Remix)」に「Re-Con & Squad-E Remix」が入っている)
    func mixName(_ releaseTitle: String) -> Bool {
        !mix.isEmpty && Self.titleKey(releaseTitle).contains(mix)
    }

    /// 曲名が同じか。「(Original Mix)」は付いていてもいなくても同じとみなす。
    /// `allowingSuffix` のときは、こちらの曲名がミックス名まで書いてあれば、後ろに続く
    /// 飾り (レーベル名など) を許す (SoundCloud の「曲名 (X Remix) (レーベル)」)。
    func title(_ candidate: String) -> Bool { title(candidate, allowingSuffix: false) }

    func title(_ candidate: String, allowingSuffix: Bool) -> Bool {
        guard !name.isEmpty else { return false }
        let key = Self.titleKey(candidate)
        if key == name || Self.titleKey(Self.withoutOriginalMix(candidate)) == baseName { return true }
        return allowingSuffix && nameHasMix && key.hasPrefix(name)
    }

    /// 同じ曲の長さ違いとみなすミックス名。先にあるものほど優先する (DJ mix で使うのは長いほう)。
    /// Original Mix は title が扱う。「(X Remix)」「(X VIP)」「(X Edit)」のような別の人の手が
    /// 入ったものは含めない。違うミックスのページを開くよりは、どこにも飛ばないほうがよい。
    static let sameVersionMixes = ["extended mix", "extended", "extended version", "club mix", "radio mix", "radio edit"]

    /// 候補が同じ曲の長さ違いなら、その順位 (小さいほど優先)。title で一致しないときに使う。
    ///
    /// - Music.app の曲名にミックス名が書いていないとき: 候補が「曲名 (ミックス名)」か
    ///   「曲名 - ミックス名」で、ミックス名が sameVersionMixes にあるもの
    /// - 書いてあるとき: 候補が Music.app の曲名の後ろに、sameVersionMixes にある印を足したもの。
    ///   Apple Music は「I Like the Way (Alaguan Remix (Extended))」のように括弧の中に書き、
    ///   ほかでは「曲名 (X Remix) [Extended Mix]」のように後ろに書く
    func sameVersionRank(_ candidate: String) -> Int? {
        guard !name.isEmpty else { return nil }
        let text = Self.withoutFeaturing(candidate)
        let base: String
        let mix: String
        if nameHasMix {
            guard let found = text.wholeMatch(of: #/(.+?)\s*[(\[]\s*([^()\[\]]+?)\s*[)\]](\s*[)\]])?\s*/#)
            else { return nil }
            base = String(found.1) + String(found.3 ?? "")
            mix = String(found.2)
        } else {
            guard let found = text.wholeMatch(of: #/(.+?)\s*(?:[(\[]\s*([^)\]]+?)\s*[)\]]|\s-\s+(.+?))\s*/#)
            else { return nil }
            base = String(found.1)
            mix = String(found.2 ?? found.3 ?? "")
        }
        guard Self.titleKey(base) == name || Self.titleKey(Self.withoutOriginalMix(base)) == baseName else { return nil }
        return Self.sameVersionMixes.firstIndex(of: mix.lowercased())
    }

    func album(_ candidate: String) -> Bool {
        !album.isEmpty && Self.key(candidate) == album
    }

    /// アーティストが同じか。片方がもう片方を含んでいればよい (「A & B」と「A」)。
    func artist(_ candidate: String) -> Bool {
        let key = Self.key(candidate)
        guard !key.isEmpty, !artist.isEmpty else { return false }
        return key == artist || key.contains(mainArtist) || artist.contains(key)
    }

    /// 比べるための形。文字と数字だけを残し、小文字にそろえる
    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// 曲名を比べるための形。「(feat. X)」を外し、「Remix」を「Mix」にそろえてから key にする
    private static func titleKey(_ text: String) -> String {
        key(withoutFeaturing(text).replacing(#/\bremix\b/#.ignoresCase(), with: "mix"))
    }

    /// 曲名から「(feat. X)」「[ft. X]」「(featuring X)」を外したもの
    static func withoutFeaturing(_ text: String) -> String {
        text.replacing(#/\s*[(\[]\s*(?:feat\.?|ft\.?|featuring)\s[^)\]]*[)\]]/#.ignoresCase(), with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 曲名から括弧 (「(Extended Mix)」「[Free Download]」など) を外したもの。検索の語に使う
    static func withoutBrackets(_ text: String) -> String {
        text.replacing(#/\s*[(\[][^)\]]*[)\]]/#, with: "").trimmingCharacters(in: .whitespaces)
    }

    /// 曲名から日本語・中国語・韓国語の文字と、それを囲む波線 (「～」「〜」「~」) を外したもの。
    /// 「夕焼け ～Fading Day～ (2025 Ver. Extended)」は「Fading Day (2025 Ver. Extended)」になる。
    /// 日本語が入っていなければそのまま返す。検索の語に使う
    static func withoutCJK(_ text: String) -> String {
        guard text.contains(#/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/#) else { return text }
        return text.replacing(#/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}ー～〜~・「」『』]+/#, with: " ")
            .replacing(#/\s+/#, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func withoutOriginalMix(_ text: String) -> String {
        text.replacing(#/\s*[(\[]\s*original mix\s*[)\]]/#.ignoresCase(), with: "")
    }
}
