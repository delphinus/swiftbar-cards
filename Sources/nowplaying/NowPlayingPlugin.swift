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

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshPosition()
        }
    }

    // MARK: - 状態の更新

    /// 状態と曲を問い合わせ直して、メニューを出す
    func refresh() {
        track = MusicApp.currentTrack()
        refreshArtworkIfTrackChanged()
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
    }

    private func forgetTrack() {
        track = Track()
        artwork = nil
        artworkTrackID = ""
    }

    // MARK: - メニュー

    private func publishMenu() {
        let lines = NowPlayingMenu(track: track, artwork: artwork, musicIsRunning: MusicApp.isRunning).lines()
        let output = lines.joined(separator: "\n")
        guard output != lastOutput else { return }
        lastOutput = output
        SwiftBar.replaceMenu(with: lines)
    }
}
