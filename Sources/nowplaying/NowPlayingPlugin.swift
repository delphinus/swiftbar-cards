import AppKit
#if canImport(Shared)
import Shared
#endif

/// 常駐して、Music.app の状態が変わるたびにメニューを差し替える。
///
/// 状態 (曲・アートワーク・前回の出力) を持ち、通知やタイマーから呼ばれて書き換えるので、
/// 値型の struct ではなく参照型の class にする。`final` は継承させないという印。
final class NowPlayingPlugin {
    private var track = Track()
    private var artwork: NSImage?
    /// `artwork` がどの曲のものか。曲が変わったときだけアートワークを取り直す
    private var artworkTrackID = ""
    /// 再生中の曲のソース (カードをクリックすると開くページ)。探しているあいだは nil
    private var sourceLink: SourceLink?
    /// `sourceLink` がどの曲のものか
    private var sourceLinkTrackID = ""
    /// 探し終えた曲のソース。同じ曲がまたかかったときに探し直さない (見つからなかった曲も
    /// nil として覚える)。プレイリストを繰り返しても検索を何度も送らないよう、曲の ID で持つ
    private var sourceLinks: [String: SourceLink?] = [:]
    /// 前回出したメニュー。同じなら出し直さない
    private var lastOutput = ""
    /// 通知の受け取りの登録。解除するときに要るので持っておく (このプログラムは終了するまで解除しない)
    private var observers: [NSObjectProtocol] = []

    // MARK: - 更新のきっかけ

    /// 通知とタイマーを登録する。
    /// - Music.app が再生・一時停止・曲の切り替えのたびに出す通知
    ///   (com.apple.Music.playerInfo)。受けたらすぐに更新する。
    /// - 再生中は、再生位置のバーのために 5 秒ごとに再生位置を問い合わせる。
    ///   一時停止中・停止中は問い合わせず、通知が来るまで何もしない。
    /// - Music.app の起動・終了、外観 (ダーク / ライト) の切り替え。
    /// - ディスプレイの抜き差しで、メニューバーの項目を縮めるか (MenuBarDensity) が
    ///   変わったとき。
    func startObserving() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"),
                                                 object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(distributed.addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                 object: nil, queue: .main) { [weak self] _ in
            // 曲は同じでも色が変わるので、前回と同じかどうかを見ずに出す
            self?.lastOutput = ""
            self?.publishMenu()
        })

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == MusicApp.bundleID else { return }
                if name == NSWorkspace.didTerminateApplicationNotification { self?.forgetTrack() }
                self?.refresh()
            })
        }

        // ディスプレイを繋いだり外したりしたら、メニューバーの曲名を切る幅が変わる
        MenuBarDensity.observeChanges(plugin: "nowplaying") { [weak self] in
            self?.publishMenu()
        }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshPosition()
        }
    }

    // MARK: - 状態の更新

    /// 状態と曲を問い合わせ直して、メニューを出す
    func refresh() {
        track = MusicApp.currentTrack()
        refreshArtworkIfTrackChanged()
        refreshSourceLinkIfTrackChanged()
        publishMenu()
    }

    /// 再生中なら、再生位置だけを問い合わせ直す
    private func refreshPosition() {
        guard track.isPlaying else { return }
        if let position = MusicApp.playerPosition() {
            track.position = position
        }
        publishMenu()
    }

    private func refreshArtworkIfTrackChanged() {
        guard track.id != artworkTrackID else { return }
        artworkTrackID = track.id
        artwork = track.hasTrack ? MusicApp.artwork() : nil
        if artwork == nil && track.hasTrack {
            findStoreArtwork()
        }
    }

    /// Music.app がアートワークを渡さない曲 (StoreArtwork.swift) のアートワークを、ストアで
    /// 探す。通信を待つあいだはアートワーク無しで出しておき、見つかったら差し替える。
    /// `Task` は、待ち合わせ (await) を含む処理を裏で動かす。`@MainActor` を付けると、
    /// 中の処理はメインスレッドで動き、通信を待つあいだだけメインスレッドを空ける。
    private func findStoreArtwork() {
        let requested = track
        Task { @MainActor [weak self] in
            guard let image = await StoreArtwork.find(for: requested),
                  let self, self.track.id == requested.id else { return }
            self.artwork = image
            self.publishMenu()
        }
    }

    /// 曲のソースを探す (SourceLink.swift)。アートワークと同じく、通信を待つあいだは
    /// ソース無しで出しておき、見つかったら差し替える。
    private func refreshSourceLinkIfTrackChanged() {
        guard track.id != sourceLinkTrackID else { return }
        sourceLinkTrackID = track.id
        sourceLink = nil
        guard track.hasTrack else { return }
        if let known = sourceLinks[track.id] {
            sourceLink = known
            return
        }
        let requested = track
        Task { @MainActor [weak self] in
            let result = await SourceLink.find(for: requested)
            guard let self else { return }
            if result.complete {
                // 増えすぎないよう、覚えておくのは 500 曲まで
                if self.sourceLinks.count >= 500 { self.sourceLinks.removeAll() }
                self.sourceLinks[requested.id] = result.link
            }
            guard self.track.id == requested.id else { return }
            self.sourceLink = result.link
            self.publishMenu()
        }
    }

    private func forgetTrack() {
        track = Track()
        artwork = nil
        artworkTrackID = ""
        sourceLink = nil
        sourceLinkTrackID = ""
    }

    // MARK: - メニュー

    private func publishMenu() {
        let lines = NowPlayingMenu(track: track, artwork: artwork, sourceLink: sourceLink, musicIsRunning: MusicApp.isRunning).lines()
        let output = lines.joined(separator: "\n")
        guard output != lastOutput else { return }
        lastOutput = output
        SwiftBar.replaceMenu(with: lines)
    }
}
