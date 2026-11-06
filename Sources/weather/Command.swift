import AppKit
import UniformTypeIdentifiers

/// メニューの項目から、プラグインを引数付きで起動したときの仕事。
///
/// 常駐している本体とは別のプロセスとして短く動き、指示をキャッシュのフォルダに書いて
/// 終わる。本体はフォルダの変化に気付いて指示を読み、メニューを差し替える
/// (WeatherPlugin)。
///
///     weather.sh select <地点>   地点を選ぶ
///     weather.sh refresh-now     今すぐ更新する
///     weather.sh open-config     設定ファイルを開く (無ければひな形を作る)
enum Command {
    /// 本体に伝える指示 (キャッシュの request に書く)
    enum Request: String {
        case select
        case refreshNow = "refresh-now"
    }

    /// 引数に当たる仕事をして終わる。当たらなければ何もせずに戻る
    static func runIfRequested(_ arguments: [String], cache: CacheFolder) {
        guard arguments.count >= 2 else { return }
        cache.prepare()
        switch arguments[1] {
        case "select":
            CacheFolder.writeText((arguments.count >= 3 ? arguments[2] : "") + "\n", to: cache.selected)
            send(.select, cache: cache)
        case "refresh-now":
            send(.refreshNow, cache: cache)
        case "open-config":
            openConfiguration()
        default:
            return
        }
        exit(0)
    }

    private static func send(_ request: Request, cache: CacheFolder) {
        CacheFolder.writeText(request.rawValue, to: cache.request)
    }

    /// 本体が呼ぶ。届いている指示を読んで消す
    static func takeRequest(from cache: CacheFolder) -> Request? {
        guard let text = CacheFolder.readText(cache.request) else { return nil }
        try? FileManager.default.removeItem(at: cache.request)
        return Request(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 設定ファイルを、既定のテキストエディタで開く (`open -t` と同じ)
    private static func openConfiguration() {
        Configuration.createTemplateIfMissing()
        let file = Configuration.file
        let workspace = NSWorkspace.shared
        guard let editor = workspace.urlForApplication(toOpen: .plainText) else {
            workspace.open(file)
            return
        }
        // 開き終わるのを待ってから終わる (待たずに終わると、開く前にプロセスが消える)
        let done = DispatchSemaphore(value: 0)
        workspace.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
    }
}
