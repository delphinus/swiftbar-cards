import AppKit

/// Music.app への問い合わせ。AppleScript を NSAppleScript でこのプロセスの中から実行する
/// (osascript などのプロセスは起動しない)。
///
/// `enum` に case を書かずに static のメンバーだけを置くと、インスタンスを作れない
/// 「名前空間」として使える。
enum MusicApp {
    static let bundleID = "com.apple.Music"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// 状態と曲の情報をまとめて問い合わせる
    static func currentTrack() -> Track {
        // 1 回の問い合わせで済むよう、値を US (0x1f) で区切った 1 つの文字列で返す
        let source = """
            tell application "Music"
                set s to player state as text
                set us to character id 31
                try
                    set t to current track
                    set p to ""
                    try
                        set p to (player position) as text
                    end try
                    return s & us & (persistent ID of t) & us & p & us & ((duration of t) as text) & us & (name of t) & us & (artist of t) & us & (album of t)
                on error
                    return s
                end try
            end tell
            """
        guard let reply = run(source)?.stringValue else { return Track() }

        let fields = reply.components(separatedBy: "\u{1f}")
        var track = Track()
        // 早送り中 (fast forwarding) などは、一時停止中と同じに扱う
        track.state = Track.State(rawValue: fields[0]) ?? .paused
        if fields.count >= 7 {
            track.id = fields[1]
            track.position = number(fields[2])
            track.duration = number(fields[3])
            track.name = fields[4]
            track.artist = fields[5]
            track.album = fields[6]
        }
        return track
    }

    /// 再生位置 (秒) だけを問い合わせる
    static func playerPosition() -> Double? {
        guard let reply = run("tell application \"Music\" to player position"),
              reply.descriptorType != typeNull else { return nil }
        return reply.doubleValue
    }

    /// 再生中の曲のアートワーク
    static func artwork() -> NSImage? {
        guard let reply = run("tell application \"Music\" to get raw data of artwork 1 of current track") else { return nil }
        return NSImage(data: reply.data)
    }

    /// AppleScript を実行して結果を返す。Music が起動していなければ実行しない
    /// (tell application "Music" は Music を起動してしまう)。
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard isRunning else { return nil }
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    /// AppleScript が返した数を読む。ロケールによって小数点が「,」になる
    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }
}
