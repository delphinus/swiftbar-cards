import AppKit

/// SwiftBar のプラグインとしての出力。メニューの行の書式は
/// https://github.com/swiftbar/SwiftBar#plugin-api にある。
public enum SwiftBar {
    /// 画像だけの行。動作を付けない (無効な項目になる) ので、マウスを載せても選択の色で
    /// 塗られない。画像は無効な項目でも薄くならない。
    public static func imageLine(_ image: PNGImage) -> String {
        " | image=\(image.base64) \(sizeParameters(image.size))"
    }

    /// メニューバーの画像の行。SwiftBar は「明るい用,暗い用」の 2 枚から、メニューバーの
    /// 見た目に合うほうを選ぶ。2 枚は同じ大きさであること。
    public static func menuBarImageLine(light: PNGImage, dark: PNGImage) -> String {
        " | image=\(light.base64),\(dark.base64) \(sizeParameters(light.size))"
    }

    /// テンプレート画像だけのメニューバーの行。画像の色は使わず、形 (不透明なところ) を
    /// メニューバーの地に合わせた色で描く。モニタごとの地にも合う。
    public static func menuBarTemplateImageLine(_ image: PNGImage) -> String {
        " | templateImage=\(image.base64) \(sizeParameters(image.size))"
    }

    /// 画像と文字を並べたメニューバーの行。文字は SwiftBar がメニューバーの文字として
    /// 描くので、色がモニタごとのメニューバーの地に合う (画像に描いた白や黒の文字は、
    /// メインのモニタに合わせた 1 枚がほかのモニタにも出るので、地によって消える)。
    /// 画像は明るい用と暗い用を分けない。
    ///
    /// 文字の中の「|」は引数との区切りに、「\」はエスケープに使われるので置き換える。
    /// 「:名前:」を SF Symbols や絵文字に置き換える機能 (symbolize・emojize) も切る。
    public static func menuBarLine(title: String, image: PNGImage) -> String {
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "｜")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(escaped) | image=\(image.base64) \(sizeParameters(image.size)) symbolize=false emojize=false"
    }

    private static func sizeParameters(_ size: CGSize) -> String {
        "width=\(Int(ceil(size.width))) height=\(Int(ceil(size.height)))"
    }

    /// 常駐型 (streamable) のプラグインとして出力する前に呼ぶ。標準出力を行ごとに
    /// 書き出すようにする (何もしないと、パイプへの出力はまとめて書き出される)。
    public static func beginStreaming() {
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    /// 常駐型のプラグインのメニューを差し替える。中身の後ろに区切りの「~~~」を書く
    /// (プラグインのシェルスクリプトにある useTrailingStreamSeparator)。
    public static func replaceMenu(with lines: [String]) {
        print(lines.joined(separator: "\n") + "\n~~~")
        fflush(stdout)
    }
}

/// OS の外観がダークモードか
public func isDarkAppearance() -> Bool {
    // 常駐していると UserDefaults の値が古いままになるので、読み直させる
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
}

/// 標準エラー出力にメッセージを書いて、終了コード 1 で終わる
public func exitWithError(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
