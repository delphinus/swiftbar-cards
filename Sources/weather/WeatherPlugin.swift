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
/// - 外観 (ダーク / ライト) が変わったときと、ディスプレイを繋いだり外したりして
///   メニューバーの項目を縮めるか (MenuBarDensity) が変わったとき。取り直さずに描き直す
/// - Space を切り替えたとき。取り直さずに描き直す (`observeSpaceChanges`)
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
        /// 外観か、メニューバーの項目を縮めるかが変わった。取り直さずに描き直す
        case redraw
        /// 現在地が変わった。現在地に当たる観測点が変わったときだけ取り直す
        case locationChanged
    }

    /// 常駐している本体。main.swift が持たせておく (手放すと止まる)
    static var running: WeatherPlugin?

    private let cache: CacheFolder
    private let maker: CardMaker
    private let radar: RadarMaker
    private let pluginPath: String
    /// 描いた雨雲の地図 (地点の cacheKey と外観 → サブメニュー)。地点を切り替えたときに、
    /// 取り直しを待たずに出す
    private var radarCards: [String: RadarCard] = [:]

    private var tables: StationTables?
    private var tablesLoadedAt = Date.distantPast
    /// 前回出したメニュー。同じなら出し直さない
    private var lastOutput = ""
    /// メニューバーの行の末尾に空白を足すか。描き直すたびに切り替える。
    ///
    /// SwiftBar は常駐型のプラグインの出力が前回と同じなら読み捨てるので、Space を
    /// 切り替えたときに同じ中身を出し直しても、画像を選び直してくれない
    /// (observeSpaceChanges)。行の末尾の空白は引数の区切りとして読み飛ばされ、
    /// 見た目は変わらないが、出力は前回と違うものになる。
    private var padsMenuBarLine = false
    /// フォルダの変化に気付いたときに、現在地が変わったかを比べる元
    private var lastLocation: CurrentLocation?
    /// 前回の更新での、現在地に当たる観測点と現在地の状態
    private var lastHereSignature = ""
    /// 地点 (`Place.Station.cacheKey`) → 最後に取り直した時刻 (UNIX 時刻)。選んでいない
    /// 地点のカードは取り直さずに描き直すことがあり、カードの更新時刻では取り直した
    /// 時刻が分からないので、別に覚えておく
    private var lastFetched: [String: Double] = [:]

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
        self.radar = RadarMaker(cache: cache, client: maker.client)
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
        // ディスプレイを繋いだり外したりしたら、メニューバーの項目を縮めるかが変わる
        MenuBarDensity.observeChanges(plugin: "weather") { [weak self] in
            Task { @MainActor in self?.enqueue(.redraw) }
        }
        observeSpaceChanges()
        watchCacheFolder()
    }

    /// Space を切り替えたら、メニューを出し直す。
    ///
    /// メニューバーの画像は明るい用と暗い用の 2 枚で、SwiftBar はメニューを受け取った
    /// ときにだけ、そのときのメニューバーの見た目でどちらかを選ぶ。選び直すのはシステムの
    /// 外観が変わったときだけで、Space の切り替えでは選び直さない。フルスクリーンの
    /// Space ではメニューバーが黒くなるので、通常の Space で選んだ黒い文字が黒い地に
    /// 載って消え、戻ると今度は白い文字が明るい地に載ったままになった。
    ///
    /// 切り替えの直後は、メニューバーの見た目がまだ前の Space のままのことがあるので、
    /// 少し待ってから出し、念のためもう 1 回出す。
    private func observeSpaceChanges() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    for delay in [0.5, 1.5] {
                        try? await Task.sleep(for: .seconds(delay))
                        self?.enqueue(.redraw)
                    }
                }
            })
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
            padsMenuBarLine.toggle()
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

        if showCachedFirst, let card = PlaceCard.read(cache.card(station: station, dark: dark)) {
            publish(menu.lines(card: card, radar: radarCards[radarKey(station, dark: dark)], office: station.office, updating: true))
        }
        let now = Date().timeIntervalSince1970
        let minHeight = minimumHeight(state, dark: dark)
        // 雨雲の地図のタイルは、予報と並べて取る
        async let radarCard = makeRadar(station, dark: dark, fetch: fetch)
        guard let card = await makeCard(station, now: now, dark: dark, minHeight: minHeight, fetch: fetch) else {
            _ = await radarCard
            return publish(WeatherMenu.noDataLines())
        }
        let radar = await radarCard
        // 戻したときに増える幅を、縮めるかを決める側に伝える
        if let extra = card.menuBarExtraWidth {
            MenuBarDensity.report(plugin: "weather", compact: MenuBarDensity.isCompact("weather"), extraWidth: extra)
        }
        publish(menu.lines(card: card, radar: radar, office: station.office, updating: false))

        guard await prefetchOtherPlaces(state, dark: dark, now: now), publishAgain else { return }
        // 描いた地点のカードが今のカードより高ければ、今のカードを下を空けて描き直す。
        // ほかの地点を取り直して全観測点の最新値が新しくなったときも、気温をそろえる
        // ために描き直す。地点の項目に添える天気も増えるので、どちらにしても出し直す。
        var selectedCard = card
        let newMinHeight = minimumHeight(state, dark: dark)
        if newMinHeight > minHeight || isBehindLatestObservations(station, dark: dark),
           let redrawn = maker.draw(station, now: now, dark: dark, minHeight: max(newMinHeight, minHeight)) {
            selectedCard = redrawn
        }
        publish(menu.lines(card: selectedCard, radar: radar, office: station.office, updating: false))
    }

    /// カードを描く。`fetch` でなくても、キャッシュに予報が無ければ取り直す
    private func makeCard(_ station: Place.Station, now: Double, dark: Bool, minHeight: Double, fetch: Bool) async -> PlaceCard? {
        if !fetch, let card = maker.draw(station, now: now, dark: dark, minHeight: minHeight) { return card }
        await fetchData(station, now: now)
        return maker.draw(station, now: now, dark: dark, minHeight: minHeight)
    }

    /// 雨雲の地図を描く。`fetch` でなくても、地点のタイルがまだ無ければ取る。
    /// 取れなければ nil (サブメニューを出さない)
    private func makeRadar(_ station: Place.Station, dark: Bool, fetch: Bool) async -> RadarCard? {
        let key = radarKey(station, dark: dark)
        var card = fetch ? nil : radar.draw(latitude: station.latitude, longitude: station.longitude, dark: dark)
        if card == nil {
            await radar.fetch(latitude: station.latitude, longitude: station.longitude)
            card = radar.draw(latitude: station.latitude, longitude: station.longitude, dark: dark)
        }
        radarCards[key] = card
        return card
    }

    private func radarKey(_ station: Place.Station, dark: Bool) -> String { "\(station.cacheKey)-\(dark)" }

    /// 選んでいない地点のカードを描いておく。地点を選んだときにすぐ出せるようにし、
    /// 高さをそろえる元にもする。1 つでも描いたら true
    ///
    /// 取り直すのは、60 分より前に取り直した (か、まだ取り直していない) 地点だけ。
    /// 取り直さない地点も、カードを描いたあとに全観測点の最新値が新しくなっていれば、
    /// キャッシュのデータから描き直す。最新値は全地点で共有していて、選んでいる地点を
    /// 取り直したときに一緒に取れるので、地点の項目に添える気温がそれで新しくなる。
    /// 描き直さないと、同じ観測点の「現在地（東京）」と「東京」で気温が最大 1 時間ぶん
    /// 食い違った。外観を切り替えたときも、もう一方の外観のカードは古いことがあるので、
    /// 同じように見て描き直す。
    ///
    /// 取り直しを先に全部済ませてから描く。取り直すと全観測点の最新値が新しい時刻の
    /// もので上書きされることがあり、交互にすると、先に描いた地点だけ古い気温が残る。
    private func prefetchOtherPlaces(_ state: WeatherState, dark: Bool, now: Double) async -> Bool {
        guard state.places.count > 1 else { return false }
        let others = state.places.enumerated().compactMap { i, place in i == state.selectedIndex ? nil : place.station }
        var fetched: Set<String> = []
        for station in others where needsFetch(station, dark: dark, now: now) {
            await fetchData(station, now: now)
            fetched.insert(station.cacheKey)
        }
        var drew = false
        for station in others where fetched.contains(station.cacheKey) || isBehindLatestObservations(station, dark: dark) {
            if maker.draw(station, now: now, dark: dark, minHeight: minimumHeight(state, dark: dark)) != nil { drew = true }
        }
        return drew
    }

    /// 選んでいない地点を取り直すか。60 分より前に取り直したか、カードが無いとき。
    ///
    /// 取り直した時刻は起動しているあいだしか覚えていないので、覚えていなければ
    /// (起動した直後は) カードの更新時刻で代わりに判断する。起動するたびに全地点を
    /// 取り直さないため。カードは取り直さずに描き直すこともあるので、カードの更新時刻は
    /// 取り直した時刻より新しいことがある。
    private func needsFetch(_ station: Place.Station, dark: Bool, now: Double) -> Bool {
        let file = cache.card(station: station, dark: dark)
        guard CacheFolder.isFresh(file, maxAge: .infinity) else { return true }
        let sinceFetch = lastFetched[station.cacheKey].map { now - $0 } ?? CacheFolder.age(of: file) ?? .infinity
        return sinceFetch > 3600
    }

    /// カードを描いたあとに、全観測点の最新値が新しくなったか
    private func isBehindLatestObservations(_ station: Place.Station, dark: Bool) -> Bool {
        guard let cardAge = CacheFolder.age(of: cache.card(station: station, dark: dark)),
              let observationsAge = CacheFolder.age(of: cache.latestObservationsTime) else { return false }
        return cardAge > observationsAge
    }

    /// 地点のデータを取り直し、取り直した時刻を覚えておく
    private func fetchData(_ station: Place.Station, now: Double) async {
        await maker.fetch(station, now: now)
        lastFetched[station.cacheKey] = now
    }

    /// 設定した地点のカードの高さをそろえる。地点を切り替えた直後にメニューを開き直すと、
    /// 開いている最中に中身が差し替わることがあり、SwiftBar はそのとき高さの変わった
    /// カードに合わせてメニューを描き直さない (上がはみ出す)。高さが同じなら崩れない。
    /// そろえる高さは、各地点のカードの本来の高さ (キャッシュ) のうち最大のもの。
    private func minimumHeight(_ state: WeatherState, dark: Bool) -> Double {
        guard state.places.count > 1 else { return 0 }
        let heights = state.stations.compactMap { station -> Int? in
            let file = cache.card(station: station, dark: dark)
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
                maker.areaNames = loaded.areaNames
            }
            maker.holidays = await Holidays.load(cache: cache, client: maker.client)
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
        var lines = lines
        if padsMenuBarLine, !lines.isEmpty { lines[0] += " " }
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
