// nowplaying.sh が起動する、Music.app で再生中の曲をメニューバーに出す常駐型のプログラム。
//
// SwiftBar の常駐型 (streamable) プラグインとして動き、メニューの中身を標準出力に
// 書く。中身の後ろに「~~~」の行を書くと、SwiftBar がメニューを差し替える
// (nowplaying.sh の useTrailingStreamSeparator)。
//
// 更新のきっかけ:
// - Music.app が再生・一時停止・曲の切り替えのたびに出す通知
//   (com.apple.Music.playerInfo)。受けたらすぐに更新する。
// - 再生中は、再生位置のバーのために 5 秒ごとに再生位置を問い合わせる。
//   一時停止中・停止中は問い合わせず、通知が来るまで何もしない。
// - Music.app の起動・終了、外観 (ダーク / ライト) の切り替え。
// 問い合わせは NSAppleScript でこのプログラムの中から行い、osascript などの
// プロセスは起動しない。SwiftBar から起動されるので、Music を操作する許可は
// SwiftBar のものが使われる。
//
// 以前は 5 秒ごとにシェルのスクリプトを起動し、osascript・jq・描画のプログラムを
// 毎回起動していたので、再生していなくても平均して 1 コアの 3% ほどを使っていた。
//
// 再生中のメニューバー: 角を丸めたアートワークと曲名。一時停止中・停止中は音符の
// アイコンだけ。メニュー: アートワーク・曲名・アーティスト・アルバム・再生位置の
// カードと、操作の項目 (操作は画像の中ではクリックした位置を区別できないので文字の
// 項目にする)。
//
// SwiftBar のプラグインのフォルダには置かない (実行できるファイルは
// プラグインとして読まれる)。nowplaying.sh が初回 (とソースを変えたとき) にコンパイルする。

import AppKit

let musicID = "com.apple.Music"
let scale: CGFloat = 2

struct Track {
    var state = "stopped" // playing / paused / stopped
    var id = ""
    var name = "", artist = "", album = ""
    var position: Double?
    var duration: Double?
}

var track = Track()
var art: NSImage?
var artID = ""

func musicRunning() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: musicID).isEmpty }

// AppleScript を実行して結果を返す。Music が起動していなければ実行しない
// (tell application "Music" は Music を起動してしまう)。
func script(_ src: String) -> NSAppleEventDescriptor? {
    guard musicRunning() else { return nil }
    var err: NSDictionary?
    return NSAppleScript(source: src)?.executeAndReturnError(&err)
}

// 状態と曲の情報をまとめて問い合わせる。US (0x1f) で区切って返す。
func queryAll() {
    guard let d = script("""
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
        """), let s = d.stringValue else {
        track = Track()
        return
    }
    let f = s.components(separatedBy: "\u{1f}")
    var t = Track()
    t.state = f[0]
    if f.count >= 7 {
        t.id = f[1]
        // ロケールによって小数点が「,」になる
        t.position = Double(f[2].replacingOccurrences(of: ",", with: "."))
        t.duration = Double(f[3].replacingOccurrences(of: ",", with: "."))
        t.name = f[4]; t.artist = f[5]; t.album = f[6]
    }
    track = t
}

func queryPosition() {
    if let d = script("tell application \"Music\" to player position"), d.descriptorType != typeNull {
        track.position = d.doubleValue
    }
}

// アートワークは曲が変わったときだけ取り直す
func refreshArt() {
    guard track.id != artID else { return }
    artID = track.id
    art = nil
    guard !track.id.isEmpty,
          let d = script("tell application \"Music\" to get raw data of artwork 1 of current track") else { return }
    art = NSImage(data: d.data)
}

func isDark() -> Bool {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
}

// ---- 描画 ----

// 上から下へ座標を取る (y は上端からの距離) 描画先を作り、body で描いて PNG にする
func render(_ w: CGFloat, _ h: CGFloat, _ body: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: h)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    body(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// 角を丸めたアートワーク。無ければ音符のアイコンを置いた四角を描く。
func drawArt(_ cg: CGContext, _ r: CGRect, radius: CGFloat, placeholder: NSColor, shadow: Bool) {
    if shadow {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: 0.35).cgColor)
        cg.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
        cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.fillPath()
        cg.restoreGState()
    }
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.clip()
    if let art {
        art.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    } else {
        cg.setFillColor(placeholder.withAlphaComponent(0.25).cgColor)
        cg.fill(r)
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height * 0.45, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [placeholder]))
        if let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = img.size
            img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
    cg.restoreGState()
}

// 文字を矩形の中に描く。はみ出す分は末尾を「…」で切る。
func draw(_ s: String, in r: CGRect, font: NSFont, color: NSColor, lines: Int = 1) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    str.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

// メニューバー: アートワーク (18pt) と曲名。曲名は 220pt で切る。
func menuBar(dark: Bool) -> (Data, CGSize) {
    let barH: CGFloat = 22
    let font = NSFont.systemFont(ofSize: 13)
    let titleW = min(ceil(NSAttributedString(string: track.name, attributes: [.font: font]).size().width), 220)
    let w = 18 + 5 + titleW + 1
    let fg = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
    let data = render(w, barH) { cg in
        drawArt(cg, CGRect(x: 0, y: (barH - 18) / 2, width: 18, height: 18), radius: 3, placeholder: fg, shadow: false)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        draw(track.name, in: CGRect(x: 23, y: (barH - lineH) / 2, width: titleW, height: lineH), font: font, color: fg)
    }
    return (data, CGSize(width: ceil(w), height: barH))
}

// カード: 左にアートワーク (96pt)、右に曲名 (2 行まで)・アーティスト・アルバム、下に再生位置
func card(dark: Bool) -> (Data, CGSize) {
    let cardW: CGFloat = 320, artSize: CGFloat = 96
    let hasProgress = (track.duration ?? 0) > 0
    let cardH: CGFloat = artSize + (hasProgress ? 34 : 4)
    let data = render(cardW, cardH) { cg in
        // 明るい外観の色は、背後が透けて灰色に見えるポップアップでも読めるように濃くする
        // (sysmon.swift の renderAll に経緯を書いた)
        let fg = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.05, alpha: 1)
        let sub = dark ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.2, alpha: 1)
        let trackColor = dark ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 0, alpha: 0.18)
        drawArt(cg, CGRect(x: 2, y: 2, width: artSize, height: artSize), radius: 8, placeholder: sub, shadow: true)
        let tx: CGFloat = artSize + 16, tw = cardW - tx - 2
        let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        draw(track.name, in: CGRect(x: tx, y: 6, width: tw, height: 40), font: titleFont, color: fg, lines: 2)
        // 曲名が 1 行に収まるときは、アーティストとアルバムを上に詰める
        let titleH = NSAttributedString(string: track.name, attributes: [.font: titleFont])
            .boundingRect(with: CGSize(width: tw, height: 40), options: [.usesLineFragmentOrigin]).height
        var y = 6 + min(ceil(titleH), 40) + 6
        draw(track.artist, in: CGRect(x: tx, y: y, width: tw, height: 18), font: .systemFont(ofSize: 13), color: fg)
        y += 19
        if !track.album.isEmpty {
            draw(track.album, in: CGRect(x: tx, y: y, width: tw, height: 18), font: .systemFont(ofSize: 12), color: sub)
        }
        if track.state != "playing" {
            draw("一時停止中", in: CGRect(x: tx, y: artSize - 14, width: tw, height: 16), font: .systemFont(ofSize: 11), color: sub)
        }
        if hasProgress, let dur = track.duration {
            let pos = min(max(track.position ?? 0, 0), dur)
            let by = artSize + 14
            let r = CGRect(x: 2, y: by, width: cardW - 4, height: 4)
            cg.setFillColor(trackColor.cgColor)
            cg.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
            cg.fillPath()
            cg.setFillColor(fg.cgColor)
            cg.addPath(CGPath(roundedRect: CGRect(x: r.minX, y: r.minY, width: max(4, r.width * CGFloat(pos / dur)), height: 4),
                              cornerWidth: 2, cornerHeight: 2, transform: nil))
            cg.fillPath()
            func mmss(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
            let tf = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            draw(mmss(pos), in: CGRect(x: 2, y: by + 6, width: 60, height: 14), font: tf, color: sub)
            let rest = "-" + mmss(dur - pos)
            let rw = ceil(NSAttributedString(string: rest, attributes: [.font: tf]).size().width)
            draw(rest, in: CGRect(x: cardW - 2 - rw, y: by + 6, width: rw + 1, height: 14), font: tf, color: sub)
        }
    }
    return (data, CGSize(width: cardW, height: cardH))
}

// ---- 出力 ----

setvbuf(stdout, nil, _IOLBF, 0)
var lastOutput = ""

// メニューのアイコンは幅 15pt のもの (円で囲んだ系統など) で揃える。SF Symbols は
// アイコンごとに幅が違い、その差だけ文字の書き出し位置がずれる。
let openMusic = "Music を開く | sfimage=arrow.up.forward.circle bash=/usr/bin/open param1=-a param2=Music terminal=false"
func ctl(_ title: String, _ icon: String, _ cmd: String, _ extra: String = "") -> String {
    "\(title) | sfimage=\(icon) bash=/usr/bin/osascript param1=-e param2='tell application \"Music\" to \(cmd)' terminal=false\(extra)"
}

func emit() {
    var lines: [String] = []
    if !musicRunning() {
        lines = [" | sfimage=music.note", "---", openMusic]
    } else if track.id.isEmpty {
        lines = [" | sfimage=music.note", "---"]
    } else {
        let dark = isDark()
        if track.state == "playing" {
            let (l, sz) = menuBar(dark: false)
            let (d, _) = menuBar(dark: true)
            lines.append(" | image=\(l.base64EncodedString()),\(d.base64EncodedString()) width=\(Int(sz.width)) height=\(Int(sz.height))")
        } else {
            // 一時停止中のメニューバーは、音符のアイコンだけにする
            lines.append(" | sfimage=music.note")
        }
        lines.append("---")
        // カードの行には動作を付けない (無効な項目にする)。動作を付けると、マウスを
        // 載せたときにカード全体が選択の色で塗られる。画像は無効な項目でも薄くならない。
        let (c, csz) = card(dark: dark)
        lines.append(" | image=\(c.base64EncodedString()) width=\(Int(csz.width)) height=\(Int(csz.height))")
        lines.append("---")
    }
    if musicRunning() {
        // 操作は 3 行にまとめる。前の曲に戻る操作は頻度が低いので、⌥ を押している
        // 間だけ「次の曲」と差し替える (SwiftBar の alternate)。
        lines.append(track.state == "playing" ? ctl("一時停止", "pause.circle", "playpause") : ctl("再生", "play.circle", "play"))
        lines.append(ctl("次の曲", "forward.end.circle", "next track"))
        lines.append(ctl("前の曲", "backward.end.circle", "previous track", " alternate=true"))
        lines.append(openMusic)
    }
    let out = lines.joined(separator: "\n")
    guard out != lastOutput else { return } // 前回と同じなら出さない
    lastOutput = out
    // 中身の後ろに区切りを出す (nowplaying.sh の useTrailingStreamSeparator)
    print(out + "\n~~~")
    fflush(stdout)
}

func update() {
    queryAll()
    refreshArt()
    emit()
}

// ---- 与えた曲で 1 回だけ描く (テストと README の画像用) ----
//   nowplaying --render <曲の JSON> <出力先>
// 曲の JSON: {"state": "playing", "name": ..., "artist": ..., "album": ...,
//            "position": 秒, "duration": 秒, "artwork": "画像のパス (任意)"}
// 出力先に menubar-light.png・menubar-dark.png・card-light.png・card-dark.png を書く。
let args = CommandLine.arguments
if args.count == 4, args[1] == "--render" {
    guard let data = FileManager.default.contents(atPath: args[2]),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        FileHandle.standardError.write("曲の JSON を読めない: \(args[2])\n".data(using: .utf8)!)
        exit(1)
    }
    track = Track(state: j["state"] as? String ?? "playing", id: "sample",
                  name: j["name"] as? String ?? "", artist: j["artist"] as? String ?? "", album: j["album"] as? String ?? "",
                  position: j["position"] as? Double, duration: j["duration"] as? Double)
    if let path = j["artwork"] as? String {
        let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: args[2]).deletingLastPathComponent())
        art = NSImage(contentsOf: url)
    }
    let dir = URL(fileURLWithPath: args[3], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for dark in [false, true] {
        let suffix = dark ? "dark" : "light"
        try menuBar(dark: dark).0.write(to: dir.appendingPathComponent("menubar-\(suffix).png"))
        try card(dark: dark).0.write(to: dir.appendingPathComponent("card-\(suffix).png"))
    }
    exit(0)
}

// ---- きっかけ ----

let dnc = DistributedNotificationCenter.default()
// 再生・一時停止・曲の切り替え
dnc.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { _ in update() }
// 外観の切り替え
dnc.addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
    lastOutput = ""
    emit()
}
// Music の起動・終了
let wnc = NSWorkspace.shared.notificationCenter
for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
    wnc.addObserver(forName: name, object: nil, queue: .main) { n in
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == musicID else { return }
        if name == NSWorkspace.didTerminateApplicationNotification { track = Track(); art = nil; artID = "" }
        update()
    }
}
// 再生中だけ、再生位置のバーのために 5 秒ごとに問い合わせる
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
    guard track.state == "playing" else { return }
    queryPosition()
    emit()
}

update()
RunLoop.main.run()
