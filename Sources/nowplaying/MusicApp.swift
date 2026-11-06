import AppKit
import ScriptingBridge

/// Music.app への問い合わせと操作。ScriptingBridge (MusicScripting.swift) で、
/// このプロセスの中から Apple Events を送る (osascript などのプロセスは起動しない)。
///
/// `enum` に case を書かずに static のメンバーだけを置くと、インスタンスを作れない
/// 「名前空間」として使える。
enum MusicApp {
    static let bundleID = "com.apple.Music"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Music.app。起動していなければ nil。起動していないときに問い合わせると、
    /// Music.app を起動してしまうため。
    private static var music: MusicApplication? {
        guard isRunning else { return nil }
        return SBApplication(bundleIdentifier: bundleID)
    }

    /// 状態と曲の情報を問い合わせる
    static func currentTrack() -> Track {
        guard let music else { return Track() }

        var track = Track()
        switch music.playerState {
        case .playing: track.state = .playing
        case .stopped: track.state = .stopped
        // 早送り中・巻き戻し中は、一時停止中と同じに扱う
        default: track.state = .paused
        }

        // 曲が無いと、properties は空になる
        let properties = music.currentTrack?.properties ?? [:]
        guard let id = properties["persistentID"] as? String else { return track }
        track.id = id
        track.name = properties["name"] as? String ?? ""
        track.artist = properties["artist"] as? String ?? ""
        track.album = properties["album"] as? String ?? ""
        track.duration = properties["duration"] as? Double
        track.position = music.playerPosition
        return track
    }

    /// 再生位置 (秒) だけを問い合わせる
    static func playerPosition() -> Double? {
        music?.playerPosition
    }

    /// 再生中の曲のアートワーク
    static func artwork() -> NSImage? {
        let artwork = music?.currentTrack?.artworks?().firstObject as? MusicArtwork
        switch artwork?.data {
        case let image as NSImage:
            return image
        case let descriptor as NSAppleEventDescriptor:
            // 中身は画像のファイルのバイト列 (PNG・JPEG)
            return NSImage(data: descriptor.data)
        default:
            return nil
        }
    }

    /// メニューの操作の項目から呼ばれる、Music.app の操作
    enum Command: String {
        case playpause, play, next, previous
    }

    static func perform(_ command: Command) {
        guard let music else { return }
        switch command {
        case .playpause: music.playpause?()
        case .play: music.playOnce?(false)
        case .next: music.nextTrack?()
        case .previous: music.previousTrack?()
        }
    }
}
