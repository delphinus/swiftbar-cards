import AppKit

/// メニューバーの項目を縮めて描くか。
///
/// MacBook のメニューバーの右側 (ノッチの右) に項目が収まらないと、macOS は収まらない
/// 分を隠す。そのときは各プラグインが項目を縮めて (出す値を減らし、グラフや間隔を
/// 詰めて) 描き、できるだけ全部が出るようにする。
///
/// 決めるのは、常駐する小さな .app (Sources/menubar/、キャッシュの swiftbar-cards.app)。
/// アクセシビリティ API でメニューバーの項目を読み、隠れている項目があれば縮め、
/// 戻しても収まるだけ空いていれば戻すと決めて、キャッシュのフォルダに書く。
/// プラグインはそれを読み、戻したときに増える幅を書いて返す (`report`)。
///
/// .app が決められないとき (アクセシビリティが許可されていない、動いていない、
/// 隠れた項目のボタンが無い macOS) は、ディスプレイの構成で決める。外部の
/// ディスプレイが 1 台も無ければ縮める。SwiftBar はどのディスプレイのメニューバーにも
/// 同じ画像を出すので、外部のディスプレイがあれば広いほうで見る前提で縮めない。
///
/// SWIFTBAR_CARDS_COMPACT を on / off にすると、どちらかに決め打ちできる。
public enum MenuBarDensity {
    /// 縮めて描くか
    public static var isCompact: Bool {
        let (value, source): (Bool, String)
        switch override {
        case "on": (value, source) = (true, "SWIFTBAR_CARDS_COMPACT")
        case "off": (value, source) = (false, "SWIFTBAR_CARDS_COMPACT")
        default:
            if let decision = watcherDecision() {
                (value, source) = (decision, "swiftbar-cards.app")
            } else {
                (value, source) = (!hasExternalDisplay(), "displays")
            }
        }
        // 変わったときだけ、何で決めたかを統合ログに残す (切り替わりの原因を追うため)
        if value != lastLogged?.value || source != lastLogged?.source {
            lastLogged = (value, source)
            makeLogger("menubar").notice("\(ProcessInfo.processInfo.processName, privacy: .public): \(value ? "compact" : "full", privacy: .public) (\(source, privacy: .public))")
        }
        return value
    }

    nonisolated(unsafe) private static var lastLogged: (value: Bool, source: String)?

    /// 戻したときに増える幅を、決める側 (swiftbar-cards.app) に伝える。描くたびに呼んでよい
    /// (変わったときだけ書く)。`plugin` はファイル名に使う
    public static func report(plugin: String, compact: Bool, extraWidth: CGFloat) {
        guard override == nil else { return }
        let line = "\(compact ? "compact" : "full") \(Int(ceil(max(0, extraWidth))))"
        guard reported[plugin] != line else { return }
        reported[plugin] = line
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (line + "\n").write(to: folder.appendingPathComponent("menubar-extra-\(plugin)"), atomically: true, encoding: .utf8)
        } catch {
            makeLogger("menubar").error("書けない: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// キャッシュのフォルダ。~ の展開は環境変数 HOME を見ないので、HOME から組む
    /// (HOME を一時ディレクトリにして動かすテストで、本物を書き換えない)
    public static let folder: URL = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/swiftbar-cards")
    }()

    private static var override: String? {
        let value = ProcessInfo.processInfo.environment["SWIFTBAR_CARDS_COMPACT"]
        return value == "on" || value == "off" ? value : nil
    }

    nonisolated(unsafe) private static var reported: [String: String] = [:]

    // MARK: - swiftbar-cards.app

    private static var stateFile: URL { folder.appendingPathComponent("menubar-state") }
    private static var app: URL { folder.appendingPathComponent("swiftbar-cards.app") }
    nonisolated(unsafe) private static var launchedAt = Date.distantPast

    /// swiftbar-cards.app が決めた描き方。決められていなければ nil。動いていなければ起動する
    private static func watcherDecision() -> Bool? {
        guard let fields = (try? String(contentsOf: stateFile, encoding: .utf8))?.split(separator: " "),
              fields.count >= 2, let pid = pid_t(fields[0]), kill(pid, 0) == 0 else {
            launchWatcher()
            return nil
        }
        switch fields[1] {
        case "compact": return true
        case "full": return false
        default: return nil
        }
    }

    /// swiftbar-cards.app を裏で起動する (open -g と同じく前に出さない)。.app が二重に動かない
    /// ようにしているので、3 つのプラグインが起動しても 1 つだけが残る
    private static func launchWatcher() {
        guard FileManager.default.fileExists(atPath: app.path), Date().timeIntervalSince(launchedAt) > 30 else { return }
        launchedAt = Date()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", app.path, "--args", folder.path]
        do {
            try open.run()
        } catch {
            makeLogger("menubar").error("swiftbar-cards.app を起動できない: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - ディスプレイの構成

    /// 内蔵でないディスプレイが動いているか。調べられなければ true (縮めない)
    private static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return true }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    // MARK: - 変化の通知

    nonisolated(unsafe) private static var handler: (() -> Void)?
    nonisolated(unsafe) private static var queue = DispatchQueue.main
    nonisolated(unsafe) private static var lastValue: Bool?
    nonisolated(unsafe) private static var folderWatcher: DispatchSourceFileSystemObject?

    /// `isCompact` が変わったら、`handler` を `queue` で呼ぶ。1 つのプログラムで 1 回だけ
    /// 呼ぶ。気付くきっかけは次の 2 つ。
    /// - キャッシュのフォルダの変化 (swiftbar-cards.app が決め直した)
    /// - ディスプレイの抜き差し (.app が決められないとき)。登録したスレッドの RunLoop に
    ///   届くので、RunLoop.main を回しているプログラムでだけ働く。回していない sysmon は
    ///   10 秒ごとに描き直すときに `isCompact` を見るので、それで足りる
    public static func observeChanges(on queue: DispatchQueue = .main, _ handler: @escaping () -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler
        self.queue = queue
        lastValue = isCompact

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
            source.setEventHandler { notifyIfChanged() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            folderWatcher = source
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // 構成が変わり始めるときにも呼ばれるので、変わり終わったときだけ見る。
            // ディスプレイ 1 台ごとに呼ばれるが、前と同じなら何もしない
            guard !flags.contains(.beginConfigurationFlag) else { return }
            MenuBarDensity.queue.async { MenuBarDensity.notifyIfChanged() }
        }, nil)
    }

    /// フォルダの変化はプラグインが `report` で書いたときにも届くが、描き方が前と
    /// 同じなら何もしない
    private static func notifyIfChanged() {
        let value = isCompact
        guard value != lastValue else { return }
        lastValue = value
        handler?()
    }
}
