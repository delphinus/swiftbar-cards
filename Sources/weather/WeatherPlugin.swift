import AppKit
#if canImport(Shared)
import Shared
#endif

/// 常駐して、天気を取り直してはメニューを差し替える。
///
/// 次のときに更新する。
/// - 10 分ごと (アメダスの更新の間隔) と、スリープから戻ったとき
/// - メニューで地点を選んだときと「今すぐ更新」を押したとき。キャッシュのフォルダに
///   指示が書かれる (Command.swift) ので、フォルダの変化を見て気付く
/// - 現在地が変わったとき。Locate.app がキャッシュのフォルダに書く
/// - 外観 (ダーク / ライト) が変わったとき。取り直さずに描き直す
///
/// 状態 (読み込んだ表・前回の出力など) を持ち続けるので class にする。中身はすべて
/// メインスレッドで動かす (`@MainActor`)。取り直しの最中に次のきっかけが来ても
/// 重ならないよう、仕事は 1 つずつ順に片付ける。
@MainActor
final class WeatherPlugin {
    /// 片付ける仕事
    enum Job: Equatable {
        /// 取り直して出す。`forceLocate` なら、古さによらず現在地も調べ直させる
        case update(forceLocate: Bool)
        /// 地点を選んだか「今すぐ更新」を押した。取り直しには数秒かかるので、先に
        /// キャッシュのカードと「更新中…」を出す
        case switched(forceLocate: Bool)
        /// 外観が変わった。取り直さずに描き直す
        case redraw
        /// 現在地が変わった。現在地に当たる観測点が変わったときだけ取り直す
        case locationChanged
    }

    /// 常駐している本体。main.swift が持たせておく (手放すと止まる)
    static var running: WeatherPlugin?

    private let cache: CacheFolder
    private let maker: CardMaker
    private let pluginPath: String

    private var tables: StationTables?
    private var tablesLoadedAt = Date.distantPast
    /// 前回出したメニュー。同じなら出し直さない
    private var lastOutput = ""
    /// フォルダの変化に気付いたときに、現在地が変わったかを比べる元
    private var lastLocation: CurrentLocation?
    /// 前回の更新での、現在地に当たる観測点と現在地の状態
    private var lastHereSignature = ""

    private var jobs: [Job] = []
    private var isWorking = false
    // 解除するときに要るので持っておく (このプログラムは終了するまで解除しない)
    private var observers: [NSObjectProtocol] = []
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var timer: Timer?

    init(cache: CacheFolder, pluginPath: String, telops: [String: Telop]) {
        self.cache = cache
        self.pluginPath = pluginPath
        self.maker = CardMaker(cache: cache, telops: telops)
    }

    // MARK: - 常駐

    func start() {
        // 前に起動していたときの指示の残りは捨てる
        try? FileManager.default.removeItem(at: cache.request)
        lastLocation = CurrentLocation.read(from: cache)
        startObserving()
        enqueue(.update(forceLocate: false))
    }

    private func startObserving() {
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enqueue(.update(forceLocate: false)) }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enqueue(.update(forceLocate: false)) }
            })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enqueue(.redraw) }
            })
        watchCacheFolder()
    }

    /// キャッシュのフォルダの中身が変わったら (ファイルを足した・置き換えた・消した)、
    /// 指示と現在地を見に行く。自分で取ったデータを書いたときにも呼ばれるが、小さな
    /// ファイルを 3 つ読むだけなので構わない。
    private func watchCacheFolder() {
        let descriptor = open(cache.url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.cacheFolderDidChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderWatcher = source
    }

    private func cacheFolderDidChange() {
        if let request = Command.takeRequest(from: cache) {
            enqueue(.switched(forceLocate: request == .refreshNow))
        }
        let location = CurrentLocation.read(from: cache)
        if location != lastLocation {
            lastLocation = location
            enqueue(.locationChanged)
        }
    }

    // MARK: - 仕事の順番

    private func enqueue(_ job: Job) {
        guard !jobs.contains(job) else { return }
        jobs.append(job)
        runNextJob()
    }

    private func runNextJob() {
        guard !isWorking, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        isWorking = true
        Task { @MainActor in
            await perform(job)
            isWorking = false
            runNextJob()
        }
    }

    private func perform(_ job: Job) async {
        switch job {
        case .update(let forceLocate):
            CurrentLocation.requestUpdate(cache: cache, always: forceLocate)
            await refresh(fetch: true, showCachedFirst: false)
        case .switched(let forceLocate):
            // 地点を選んだだけなら、現在地は調べ直さない (すぐ後に取り直しが控えている)
            if forceLocate { CurrentLocation.requestUpdate(cache: cache, always: true) }
            await refresh(fetch: true, showCachedFirst: true)
        case .redraw:
            lastOutput = "" // 中身は同じでも色が変わるので、前回と比べずに出す
            await refresh(fetch: false, showCachedFirst: false)
        case .locationChanged:
            guard let state = await loadState(), hereSignature(state) != lastHereSignature else { return }
            await refresh(fetch: true, showCachedFirst: false)
        }
    }

    // MARK: - 更新

    /// 1 回だけ更新してメニューを出す (`--once`)。テストで使う。選んでいない地点の
    /// カードも描いてから戻る。
    func refreshOnce() async {
        await refresh(fetch: true, showCachedFirst: false, publishAgain: false)
    }

    /// 選んでいる地点を取り直して (`fetch`)、描いて、メニューを出す。続けて選んで
    /// いない地点のカードを描いておく。
    private func refresh(fetch: Bool, showCachedFirst: Bool, publishAgain: Bool = true) async {
        guard let state = await loadState() else { return publish(WeatherMenu.noDataLines()) }
        lastHereSignature = hereSignature(state)
        let dark = Appearance.isDark
        let menu = WeatherMenu(state: state, cache: cache, dark: dark, pluginPath: pluginPath)
        guard let station = state.selected.station else { return publish(menu.configurationErrorLines()) }

        if showCachedFirst, let card = PlaceCard.read(cache.card(station: station.code, dark: dark)) {
            publish(menu.lines(card: card, office: station.office, updating: true))
        }
        let now = Date().timeIntervalSince1970
        let minHeight = minimumHeight(state, dark: dark)
        guard let card = await makeCard(station, now: now, dark: dark, minHeight: minHeight, fetch: fetch) else {
            return publish(WeatherMenu.noDataLines())
        }
        publish(menu.lines(card: card, office: station.office, updating: false))

        guard await prefetchOtherPlaces(state, dark: dark, now: now), publishAgain else { return }
        // 描いた地点のカードが今のカードより高ければ、今のカードを下を空けて描き直す。
        // 地点の項目に添える天気も増えるので、どちらにしても出し直す。
        var selectedCard = card
        let newMinHeight = minimumHeight(state, dark: dark)
        if newMinHeight > minHeight, let redrawn = maker.draw(station, now: now, dark: dark, minHeight: newMinHeight) {
            selectedCard = redrawn
        }
        publish(menu.lines(card: selectedCard, office: station.office, updating: false))
    }

    /// カードを描く。`fetch` でなくても、キャッシュに予報が無ければ取り直す
    private func makeCard(_ station: Place.Station, now: Double, dark: Bool, minHeight: Double, fetch: Bool) async -> PlaceCard? {
        if !fetch, let card = maker.draw(station, now: now, dark: dark, minHeight: minHeight) { return card }
        await maker.fetch(station, now: now)
        return maker.draw(station, now: now, dark: dark, minHeight: minHeight)
    }

    /// 選んでいない地点のうち、キャッシュのカードが 60 分より古い (か無い) ものを描いて
    /// おく。地点を選んだときにすぐ出せるようにし、高さをそろえる元にもする。
    /// 1 つでも描いたら true
    private func prefetchOtherPlaces(_ state: WeatherState, dark: Bool, now: Double) async -> Bool {
        guard state.places.count > 1 else { return false }
        var drew = false
        for (i, place) in state.places.enumerated() where i != state.selectedIndex {
            guard let station = place.station,
                  !CacheFolder.isFresh(cache.card(station: station.code, dark: dark), maxAge: 3600) else { continue }
            await maker.fetch(station, now: now)
            if maker.draw(station, now: now, dark: dark, minHeight: minimumHeight(state, dark: dark)) != nil { drew = true }
        }
        return drew
    }

    /// 設定した地点のカードの高さをそろえる。地点を切り替えた直後にメニューを開き直すと、
    /// 開いている最中に中身が差し替わることがあり、SwiftBar はそのとき高さの変わった
    /// カードに合わせてメニューを描き直さない (上がはみ出す)。高さが同じなら崩れない。
    /// そろえる高さは、各地点のカードの本来の高さ (キャッシュ) のうち最大のもの。
    private func minimumHeight(_ state: WeatherState, dark: Bool) -> Double {
        guard state.places.count > 1 else { return 0 }
        let heights = state.stations.compactMap { station -> Int? in
            let file = cache.card(station: station.code, dark: dark)
            guard CacheFolder.isFresh(file, maxAge: 3 * 3600) else { return nil }
            return PlaceCard.read(file)?.naturalHeight
        }
        return Double(heights.max() ?? 0)
    }

    // MARK: - 状態

    /// 設定ファイル・現在地・選んでいる地点を読み、地点を観測点に当てはめる。
    /// 観測点の表を読めなければ nil
    private func loadState() async -> WeatherState? {
        if tables == nil || Date().timeIntervalSince(tablesLoadedAt) > 86400 {
            if let loaded = await StationTables.load(cache: cache, client: maker.client) {
                tables = loaded
                tablesLoadedAt = Date()
                maker.stations = loaded.stations
            }
        }
        guard let tables else { return nil }
        let here = CurrentLocation.read(from: cache)
        let resolver = PlaceResolver(tables: tables, here: here)
        let places = Configuration.places().map(resolver.resolve)
        let selected = CacheFolder.readText(cache.selected)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WeatherState(places: places, selectedIndex: PlaceResolver.selectedIndex(in: places, selected: selected), here: here)
    }

    /// 現在地に当たる観測点と、現在地の状態。変わったときだけ現在地の変化で取り直す
    /// (Locate.app は調べるたびに結果を書き直すので、少し動いただけでは取り直さない)
    private func hereSignature(_ state: WeatherState) -> String {
        let station = state.places.first(where: \.isHere)?.station?.code ?? ""
        return "\(station) \(state.here.isKnown) \(state.here.status)"
    }

    private func publish(_ lines: [String]) {
        let output = lines.joined(separator: "\n")
        guard output != lastOutput else { return }
        lastOutput = output
        SwiftBar.replaceMenu(with: lines)
    }
}

/// 外観。SWIFTBAR_CARDS_APPEARANCE (dark / light) で決め打ちできる (テスト用)
enum Appearance {
    static var isDark: Bool {
        switch ProcessInfo.processInfo.environment["SWIFTBAR_CARDS_APPEARANCE"] {
        case "dark": true
        case "light": false
        default: isDarkAppearance()
        }
    }
}
