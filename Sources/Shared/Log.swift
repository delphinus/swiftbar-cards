import os

/// 失敗したときの記録に使う。macOS の統合ログに出す。
///
/// 常駐型のプラグインの標準エラーは SwiftBar が見せないので、標準エラーには書かない。
/// 値が取れなかったときにメニューやカードに何を出すかは各プラグインが決め、ここでは
/// 後から原因を追えるように理由を残すだけにする。見るには:
///
///     /usr/bin/log stream --predicate 'subsystem == "dev.delphinus.swiftbar-cards"'
///     /usr/bin/log show --last 1h --predicate 'subsystem == "dev.delphinus.swiftbar-cards"'
///
/// category にはプラグインの名前 (weather・sysmon・nowplaying) を入れる。locate は
/// Shared を使わないので、同じ subsystem で自分の Logger を作る。
public let logSubsystem = "dev.delphinus.swiftbar-cards"

public func makeLogger(_ category: String) -> Logger {
    Logger(subsystem: logSubsystem, category: category)
}
