import Foundation
#if canImport(Shared)
import Shared
#endif

/// 気象庁のサイトからデータを取る。API キーは要らない。
///
/// アメダスは 10 分ごと、予報は 1 日 3 回 (5 時・11 時・17 時) 更新される。
/// 取ったものはキャッシュのフォルダに書き、読むときはファイルから読む (取得に失敗
/// しても、前に取れたものを出せるように)。
struct JMAClient {
    static let base = URL(string: "https://www.jma.go.jp/bosai/")!

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    /// `path` (base からの相対) を取る。取れなければ (応答が 200 でなければ) nil。
    /// 気象庁以外のファイル (内閣府の祝日の一覧) は、`path` に URL をそのまま渡す
    func data(_ path: String) async -> Data? {
        guard let url = URL(string: path, relativeTo: Self.base) else { return nil }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            logger.error("取得に失敗: \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            logger.error("取得に失敗: \(path, privacy: .public): HTTP \(status)")
            return nil
        }
        return data
    }

    /// `path` を取って `file` に書く。取れなければファイルはそのままにして false を返す
    @discardableResult
    func download(_ path: String, to file: URL) async -> Bool {
        guard let data = await data(path) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// 予報のファイルが別の府県予報区のものに入っている区域がある (2026-11 に全
    /// 58 区域を取って確かめた)
    static func forecastOffice(for office: String) -> String {
        switch office {
        case "014030": "014100" // 十勝地方 → 釧路・根室地方
        case "460040": "460100" // 奄美地方 → 鹿児島県
        default: office
        }
    }
}
