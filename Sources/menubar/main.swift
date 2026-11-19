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
// - menubar-state          ここが書く。「pid 描き方 理由」の 1 行。描き方はプラグインごとの
//                          描き方を `,` で並べたもの (sysmon=full,weather=compact,*=compact)。
//                          `*` はまだ幅を報告していないプラグインの描き方。決められない
//                          ときは unknown で、プラグインはディスプレイの構成で決める
// - menubar-extra-<名前>   プラグインが書く。「今の描き方 (compact|full) 戻したときに
//                          増える幅 (pt)」の 1 行
// - menubar-asked          許可を求めたら置く。起動のたびにダイアログを出さない (ビルドし
//                          直して、これより .app が新しくなったら、もう一度求める)
//
// 決め方 (プラグインごとに決める。優先順は sysmon、weather、nowplaying):
// - ボタンが出ていたら (隠れている項目があれば)、縮めていないプラグインのうち、優先順の
//   いちばん低いものを縮める。
// - ボタンが無ければ、縮めているプラグインのうち、戻したときに増える幅が空いている幅に
//   収まるもので、優先順のいちばん高いものを戻す。上が収まらなければ、下だけでも戻す。
//   収まる状態が 6 秒続き、そのプラグインを縮めてから 60 秒たっていたら戻す (見積もりが
//   外れて、縮める・戻すを繰り返さないように)。60 秒たつのを待っている間は、それより
//   優先順の低いプラグインも戻さない。
// - 縮めているプラグインが収まらなくても、それより優先順の低い、戻しているプラグインを
//   縮めれば収まるなら、下を縮めて空きを上に回す (下が先に戻って空きを使ったときに、
//   上が戻れなくならないように)。縮めれば収まる状態が 6 秒続いたら縮める。縮めた下の
//   プラグインは 60 秒戻さないので、その間に上が戻る。
// - 1 回に動かすのは 1 つだけ。動かしたら、そのプラグインが描き直した (報告の描き方が
//   変わった) のを見届けてから、次の判断をする (描き直す前のメニューバーの幅で、
//   もう 1 つ動かしてしまわないように)。
// - 項目を読めなかったアプリがあった回は、判断しない。
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

    /// 戻す優先順。ここに無いプラグインは、これらの後に名前の順で並べる
    let priority = ["sysmon", "weather", "nowplaying"]
    /// 動かしたプラグインが描き直すのを待つ秒数。過ぎたら待たずに次の判断をする
    let redrawTimeout: TimeInterval = 10

    /// プラグインごとの描き方 (true なら縮める)
    private var modes: [String: Bool] = [:]
    /// プラグインごとの、最後に縮めた時刻
    private var compactedAt: [String: Date] = [:]
    /// 戻す候補と、空きが足りると見え始めた時刻。足りなくなったら nil に戻す
    private var fitsSince: (plugin: String, date: Date)?
    /// 縮めて空きを譲る候補と、譲れば上が収まると見え始めた時刻
    private var yieldSince: (plugin: String, date: Date)?
    /// 動かしたプラグインと、そのときの描き方。描き直すまで次の判断をしない
    private var waiting: (plugin: String, compact: Bool, date: Date)?
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
        guard AXIsProcessTrusted() else { return writeUnknown("untrusted") }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first != nil else {
            return writeUnknown("no-menubar-agent")
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
        // 初めて見たプラグイン (起動したときは全部) は、今の描き方から始める
        for (plugin, report) in reports where modes[plugin] == nil {
            modes[plugin] = report.compact
        }

        // 動かしたプラグインが描き直すのを待つ。描き直したのを見たら、メニューバーに
        // 並び直すのを待って、次の回から判断する
        if let waiting {
            if reports[waiting.plugin]?.compact == waiting.compact || Date().timeIntervalSince(waiting.date) > redrawTimeout {
                self.waiting = nil
            }
            return
        }

        // 判断するのは、幅を報告しているプラグインだけ
        let ordered = reports.keys.sorted { a, b in
            let (ia, ib) = (priority.firstIndex(of: a) ?? priority.count, priority.firstIndex(of: b) ?? priority.count)
            return ia != ib ? ia < ib : a < b
        }

        if overflowing {
            fitsSince = nil
            if let plugin = ordered.last(where: { modes[$0] == false }) {
                set(plugin, compact: true)
                return write("overflow \(plugin)")
            }
            return write("overflow")
        }

        let free = freeWidth(items)

        // 縮めているプラグインが空きに収まらなくても、それより優先順の低いプラグインを
        // 縮めれば収まるなら、下を縮めて空きを上に回す (下が先に戻って空きを使い、上が
        // 戻れなくなった状態を直す)
        if let (plugin, beneficiary) = yieldTarget(ordered, reports, free) {
            fitsSince = nil
            if yieldSince?.plugin != plugin { yieldSince = (plugin, Date()) }
            if let since = yieldSince?.date, Date().timeIntervalSince(since) >= fitsFor {
                yieldSince = nil
                set(plugin, compact: true)
            }
            return write(String(format: "yield=%@>%@ free=%.0f", plugin, beneficiary, free))
        }
        yieldSince = nil

        // 戻すのは、収まるもののうち優先順のいちばん高いもの。上が収まらなければ、下だけでも戻す
        guard let candidate = ordered.first(where: { modes[$0] == true && free >= reports[$0]!.extra + slack }) else {
            fitsSince = nil
            return write(String(format: "free=%.0f", free))
        }
        let reason = String(format: "free=%.0f next=%@+%.0f", free, candidate, reports[candidate]!.extra)
        if fitsSince?.plugin != candidate { fitsSince = (candidate, Date()) }
        if let since = fitsSince?.date, Date().timeIntervalSince(since) >= fitsFor,
           Date().timeIntervalSince(compactedAt[candidate] ?? .distantPast) >= holdAfterCompact {
            fitsSince = nil
            set(candidate, compact: false)
        }
        write(reason)
    }

    /// 空きを譲るために縮めるプラグインと、譲られるプラグイン。縮めているプラグインを
    /// 優先順の高いものから見て、空きに収まるものがあればそれを戻せばよいので譲らない。
    /// 収まらないものは、それより優先順の低い、戻しているプラグインを低いほうから縮めて
    /// いったときに収まるなら、いちばん低いものを縮める (1 回に縮めるのは 1 つ。足りなければ
    /// 描き直したあとに次を縮める)
    private func yieldTarget(_ ordered: [String], _ reports: [String: (compact: Bool, extra: CGFloat)],
                             _ free: CGFloat) -> (plugin: String, beneficiary: String)? {
        for (index, plugin) in ordered.enumerated() where modes[plugin] == true {
            let need = reports[plugin]!.extra + slack
            if free >= need { return nil }
            let lower = ordered[(index + 1)...].reversed().filter { modes[$0] == false && reports[$0]!.extra > 0 }
            var gained: CGFloat = 0
            for other in lower {
                gained += reports[other]!.extra
                if free + gained >= need { return (lower[0], plugin) }
            }
        }
        return nil
    }

    /// `plugin` の描き方を変え、描き直すのを待つ
    private func set(_ plugin: String, compact: Bool) {
        modes[plugin] = compact
        if compact { compactedAt[plugin] = Date() }
        waiting = (plugin, compact, Date())
    }

    /// 状態ファイルの描き方の欄。`*` (まだ報告していないプラグイン) は、どれかを
    /// 縮めていれば縮める
    private var modesField: String {
        let pairs = modes.keys.sorted().map { "\($0)=\(modes[$0]! ? "compact" : "full")" }
        let fallback = modes.values.contains(true) ? "compact" : "full"
        return (pairs + ["*=\(fallback)"]).joined(separator: ",")
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

    /// プラグインごとの、今の描き方と戻したときに増える幅。1 時間より古いもの (止めた
    /// プラグイン) は使わない。ただし描き方 (`modes`) は覚えておき、状態ファイルにも書き続ける
    /// (曲を止めたままの nowplaying のように、書き直さずに動いているものがある)
    private func readReports() -> [String: (compact: Bool, extra: CGFloat)] {
        let prefix = "menubar-extra-"
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var reports: [String: (compact: Bool, extra: CGFloat)] = [:]
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            guard let date = Watcher.modificationDate(file), Date().timeIntervalSince(date) < 3600,
                  let fields = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: " "),
                  fields.count >= 2, let extra = Double(fields[1].trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            reports[String(file.lastPathComponent.dropFirst(prefix.count))] = (fields[0] == "compact", CGFloat(extra))
        }
        return reports
    }

    /// 決めた描き方を書く
    private func write(_ reason: String) { write(modesField, reason) }

    /// 決められないことを書く。次に決められたときは、プラグインの今の描き方から始める
    private func writeUnknown(_ reason: String) {
        modes = [:]
        fitsSince = nil
        yieldSince = nil
        waiting = nil
        write("unknown", reason)
    }

    /// 状態ファイルを書く。プラグインはフォルダの変化で気付くので、描き方か理由の種類が
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
