import Foundation

/// Music.app の再生の状態と、再生中の曲
struct Track {
    enum State: String {
        case playing, paused, stopped
    }

    var state: State = .stopped
    /// 曲の persistent ID。曲が変わったかを見分けるのに使う。曲が無ければ空
    var id = ""
    var name = ""
    var artist = ""
    var album = ""
    /// 再生位置 (秒)
    var position: Double?
    /// 曲の長さ (秒)
    var duration: Double?

    var isPlaying: Bool { state == .playing }
    var hasTrack: Bool { !id.isEmpty }
}
