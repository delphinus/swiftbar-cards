import Foundation
#if canImport(Shared)
import Shared
#endif

/// アートワークや曲のソースを探すときの通信。
enum HTTP {
    private static let logger = makeLogger("nowplaying")

    /// 取れなかったときに投げる。理由はログに書いてあるので、中身は持たない
    struct Failure: Error {}

    /// URLSession のキャッシュは使わない。ephemeral でもメモリ上のキャッシュはあり、
    /// 常駐しているあいだは一度掴んだ失敗の応答を返し続けることがある (weather で起きた)。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        // Discogs の API は、名乗らない要求を断る
        configuration.httpAdditionalHeaders = ["User-Agent": "swiftbar-cards (+https://github.com/delphinus/swiftbar-cards)"]
        return URLSession(configuration: configuration)
    }()

    /// `url` を取る。取れなければ (応答が 200 でなければ) 理由を記録して `Failure` を投げる
    static func get(_ url: URL) async throws -> Data {
        let where_ = "\(url.host ?? "")\(url.path)"
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                logger.error("取得に失敗: \(where_, privacy: .public): HTTP \(status)")
                throw Failure()
            }
            return data
        } catch let error as Failure {
            throw error
        } catch {
            logger.error("取得に失敗: \(where_, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw Failure()
        }
    }

    /// クエリを付けた URL
    static func url(_ base: String, _ query: [String: String]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components?.url
    }
}
