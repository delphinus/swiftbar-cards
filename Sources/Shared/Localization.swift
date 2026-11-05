import Foundation

/// 表示の言語。SWIFTBAR_CARDS_LANG (ja / en) で決め打ちできる。無ければ OS の優先言語の
/// 先頭が日本語なら日本語、それ以外は英語。scripts/lib.sh の cards_lang と同じ規則。
public let isJapanese: Bool = {
    if let v = ProcessInfo.processInfo.environment["SWIFTBAR_CARDS_LANG"], v == "ja" || v == "en" {
        return v == "ja"
    }
    return Locale.preferredLanguages.first?.hasPrefix("ja") ?? false
}()

/// 日本語と英語の文言から、表示の言語のほうを選ぶ
public func L(_ ja: String, _ en: String) -> String { isJapanese ? ja : en }
