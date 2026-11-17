// プラグインがメニューバーの項目を縮めて描くか (Sources/Shared/MenuBarDensity.swift) を
// 決める、常駐するプログラム。
//
// MacBook のノッチの右にメニューバーの項目が収まらないと、macOS は収まらない分を隠し、
// 代わりに「非表示のメニューバー項目を表示」のボタンを出す (MenuBarAgent の項目で、
// AXIdentifier が menu-bar-overflow-indicator)。このボタンがあるかと、項目が並んでいる
// 位置をアクセシビリティ API で読み、縮めるか戻すかを決めてキャッシュのフォルダに書く。
//
// アクセシビリティの許可は、ほかのアプリを操作できる強い許可。このプログラムは
// メニューバーの項目の属性 (位置・大きさ・識別子) を読むだけで、操作 (クリック・
// 値の書き換え・キーの送信) は一切しない。
//
// 位置情報の Locate.app (Sources/locate/) と同じく、SwiftBar から起動したプログラムには
// 自分の許可を持たせられないので .app の形にし (scripts/lib.sh の build_app)、
// `open` で起動してもらう。プラグインは、このプログラムが動いていなければ起動する。
//
//   open -g -a <.app> --args <キャッシュのフォルダ>
//
// キャッシュのフォルダ (~/Library/Caches/swiftbar-cards) のファイル:
// - menubar-state          ここが書く。「pid compact|full|unknown 理由」の 1 行。
//                          unknown のとき、プラグインはディスプレイの構成で決める
// - menubar-extra-<名前>   プラグインが書く。「今の描き方 (compact|full) 戻したときに
//                          増える幅 (pt)」の 1 行
// - menubar-asked          許可を求めたら置く。起動のたびにダイアログを出さない (ビルドし
//                          直して、これより .app が新しくなったら、もう一度求める)
//
// 決め方:
// - ボタンが出ていたら (隠れている項目があれば) 縮める。
// - 縮めているときは、ボタンが無く、空いている幅が、縮めて描いているプラグインを
//   戻したときに増える幅の合計より広い状態が 6 秒続いたら戻す。縮めてから 60 秒は
//   戻さない (見積もりが外れて、縮める・戻すを繰り返さないように)。項目を読めなかった
//   アプリがあった回は、判断しない。
// - 空いている幅は、いちばん左の項目の x から、ノッチの右端に余白を足した位置を
//   引いたもの。余白は、全部が収まっていたときにいちばん左の項目が置かれた位置から
//   測った (ノッチの右端 848.5、項目 891)。

import AppKit
import os

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: menubar <キャッシュのフォルダ>\n".data(using: .utf8)!)
    exit(2)
}
let cacheDir = URL(fileURLWithPath: args[1], isDirectory: true)
let stateFile = cacheDir.appendingPathComponent("menubar-state")
let askedFile = cacheDir.appendingPathComponent("menubar-asked")

/// 失敗したときの記録。Shared を使わないので、Shared の makeLogger と同じ subsystem で作る
let logger = Logger(subsystem: "dev.delphinus.swiftbar-cards", category: "menubar")

/// メニューバーの項目のうち、判定に使う属性
struct MenuBarItem {
    let frame: CGRect
    let identifier: String
}

final class Watcher {
    /// 何秒ごとに読むか
    let interval: TimeInterval = 2
    /// 縮めてから戻すまで、最低限空ける秒数
    let holdAfterCompact: TimeInterval = 60
    /// ノッチの右端から、いちばん左の項目までの余白
    let notchMargin: CGFloat = 42.5
    /// 戻すときに、増える幅に足しておく余裕
    let slack: CGFloat = 4
    /// 戻すのは、空きが足りる状態がこの秒数続いてから。1 回だけ読み違えた値で戻さない
    /// (SwiftBar の項目が一瞬読めず、空きを 435pt と見積もって戻し、2 秒後に溢れて
    /// 縮め直したことがあった)
    let fitsFor: TimeInterval = 6

    private var mode = ""
    private var compactedAt = Date.distantPast
    /// 空きが足りると見え始めた時刻。足りなくなったら nil に戻す
    private var fitsSince: Date?
    private var lastWritten = ""
    /// メニューバーに項目を出しているアプリ。全部のアプリを毎回調べると、応答しない
    /// プロセスの打ち切り (0.5 秒) を待つことがあるので、調べ直すのは間を空ける
    private var appsWithItems: [pid_t] = []
    private var scannedAt = Date.distantPast
    private let executableDate = Watcher.modificationDate(Bundle.main.executableURL)

    func start() {
        // 許可を求めるダイアログ (システム設定の「デバイスの制御とデータへのアクセス」へ案内される) は、初回と、
        // ビルドし直したあとの最初の起動でだけ出す。アドホック署名なので、ビルドし直すと
        // 前の許可は通らなくなる (設定には ON のまま出る。一度外して付け直す)
        let askedDate = Watcher.modificationDate(askedFile) ?? .distantPast
        if !AXIsProcessTrusted(), askedDate < executableDate ?? .distantPast {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            FileManager.default.createFile(atPath: askedFile.path, contents: Data())
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scannedAt = .distantPast
            }
        }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() {
        // ビルドし直されたら終わる。次にプラグインが新しいほうを起動する
        if Watcher.modificationDate(Bundle.main.executableURL) != executableDate { exit(0) }
        guard AXIsProcessTrusted() else { return write("unknown", "untrusted") }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first != nil else {
            return write("unknown", "no-menubar-agent")
        }
        if Date().timeIntervalSince(scannedAt) > 60 { scanApps() }

        // 項目を読めなかったアプリが 1 つでもあれば、その回は判断しない (空きを広く
        // 見積もってしまう)。アプリが終わっていたときは、次に調べ直すときに外れる
        let perApp = appsWithItems.map(Watcher.items(of:))
        guard !perApp.contains(where: { $0 == nil }) else {
            scannedAt = .distantPast
            return
        }
        let items = perApp.flatMap { $0 ?? [] }
        let overflowing = items.contains { $0.identifier.hasPrefix("menu-bar-overflow-indicator") }
        let reports = readReports()
        if mode.isEmpty {
            // 起動したときは、プラグインの今の描き方から始める
            mode = reports.contains { $0.compact } ? "compact" : "full"
        }

        if overflowing {
            fitsSince = nil
            if mode != "compact" { compactedAt = Date() }
            mode = "compact"
            return write(mode, "overflow")
        }
        guard mode == "compact" else { return write(mode, "fits") }
        let needed = reports.filter(\.compact).reduce(0) { $0 + $1.extra }
        let free = freeWidth(items)
        guard free >= needed + slack else {
            fitsSince = nil
            return write(mode, String(format: "free=%.0f needed=%.0f", free, needed))
        }
        let since = fitsSince ?? Date()
        fitsSince = since
        if Date().timeIntervalSince(since) >= fitsFor, Date().timeIntervalSince(compactedAt) >= holdAfterCompact {
            mode = "full"
            fitsSince = nil
            return write(mode, String(format: "free=%.0f needed=%.0f", free, needed))
        }
        write(mode, String(format: "free=%.0f needed=%.0f", free, needed))
    }

    /// 項目のある画面のノッチの右端から、いちばん左の項目までの幅。ノッチの無い画面
    /// (外部のディスプレイ) では、左側はアプリのメニューで、どこまで使えるか分からない
    /// ので、十分に空いているとみなす
    private func freeWidth(_ items: [MenuBarItem]) -> CGFloat {
        guard let leftmost = items.map(\.frame.minX).min() else { return .greatestFiniteMagnitude }
        let screen = NSScreen.screens.first { $0.frame.minX <= leftmost && leftmost < $0.frame.maxX }
        guard let notch = screen?.auxiliaryTopRightArea else { return .greatestFiniteMagnitude }
        return leftmost - (notch.minX + notchMargin)
    }

    /// 全部のアプリから、メニューバーに項目を出しているものを探し直す
    private func scanApps() {
        scannedAt = Date()
        appsWithItems = NSWorkspace.shared.runningApplications.map(\.processIdentifier).filter { pid in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            return Watcher.attribute(app, "AXExtrasMenuBar") != nil
        }
    }

    /// アプリがメニューバーに出している項目。読めなければ nil
    private static func items(of pid: pid_t) -> [MenuBarItem]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = attribute(app, "AXExtrasMenuBar"),
              let children = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        return children.map { child in
            var origin = CGPoint.zero, size = CGSize.zero
            if let value = attribute(child, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
            if let value = attribute(child, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
            return MenuBarItem(frame: CGRect(origin: origin, size: size),
                               identifier: attribute(child, "AXIdentifier") as? String ?? "")
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// プラグインが書いた描き方と増える幅。1 時間より古いもの (止めたプラグイン) は使わない
    private func readReports() -> [(compact: Bool, extra: CGFloat)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("menubar-extra-") }.compactMap { file in
            guard let date = Watcher.modificationDate(file), Date().timeIntervalSince(date) < 3600,
                  let fields = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: " "),
                  fields.count >= 2, let extra = Double(fields[1].trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            return (fields[0] == "compact", CGFloat(extra))
        }
    }

    /// 決めた描き方を書く。プラグインはフォルダの変化で気付くので、描き方か理由の種類が
    /// 変わったときだけ書く (理由の数字の空いている幅は、変わっても書き直さない)
    private func write(_ mode: String, _ reason: String) {
        let key = "\(mode) \(reason.prefix { $0 != "=" })"
        guard key != lastWritten else { return }
        lastWritten = key
        let line = "\(getpid()) \(mode) \(reason)"
        logger.notice("\(line, privacy: .public)")
        do {
            try (line + "\n").write(to: stateFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("書けない: \(stateFile.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func modificationDate(_ url: URL?) -> Date? {
        url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    }
}

// 二重に動かさない (プラグインが 3 つとも起動しようとする)
let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .filter { $0.processIdentifier != getpid() }
if !others.isEmpty { exit(0) }

try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

// .app として起動されるので、NSApplication の run loop の上で動かす。Dock にも
// メニューバーにも出さない (Info.plist の LSUIElement)。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let watcher = Watcher()
watcher.start()
app.run()
