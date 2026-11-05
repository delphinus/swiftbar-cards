import Foundation
#if canImport(Shared)
import Shared
#endif

// ある時点のシステムの状態。値を集める側 (SystemMonitor) が作り、描く側 (SystemCard・
// SystemMenuBar) が読む。
//
// `--render` で JSON (samples/sysmon.json) から読むので `Decodable` にしている。
// JSON のキーはプロパティの名前と同じ。

struct Snapshot: Decodable {
    /// 履歴の 1 回分の秒数
    let interval: Double
    let cpu: CPUStats
    let mem: MemoryStats
    /// CPU を使っているプロセスの上位。値は ps の %CPU
    let procCpu: [ProcessUsage]
    /// メモリを使っているプロセスの上位。値は KB
    let procMem: [ProcessUsage]
    let battery: [Battery]

    /// メモリの使用率 (%)
    var memoryPercent: Double { mem.used / mem.total * 100 }
}

struct CPUStats: Decodable {
    /// 使用率 (%)。user + sys
    let total: Double
    let user: Double
    let sys: Double
    /// E コア (高効率コア) と P コア (高性能コア) の使用率。コアの種類が分からなければ nil
    let e: Double?
    let p: Double?
    /// 負荷 (load average) の 1・5・15 分の値を「 / 」でつないだもの
    let load: String
    /// CPU と GPU の温度 (°C)。読めなければ nil
    let temp: Double?
    let gpu: Double?
    /// 使用率の履歴。古い順で、最後が今
    let hist: [Double]
}

struct MemoryStats: Decodable {
    /// 使用済み (バイト)
    let used: Double
    let total: Double
    let compressed: Double
    /// スワップの使用量を表示用に書いたもの。例: "512 MB"
    let swap: String
    /// メモリプレッシャー。1 が正常、2 が警告、4 が危険
    let pressure: Int
}

struct ProcessUsage: Decodable {
    let name: String
    let value: Double

    /// 表示用の名前。com.apple.WebKit.WebContent のような名前は先頭が同じで、切り詰めると
    /// 区別が付かなくなるので com.apple. を省く
    var shownName: String {
        name.hasPrefix("com.apple.") ? String(name.dropFirst("com.apple.".count)) : name
    }
}

struct Battery: Decodable {
    let name: String
    let percent: Double
    // 以下は Mac 本体のバッテリーのときだけ
    var `internal`: Bool? = nil
    /// 電源につながっている
    var external: Bool? = nil
    var charging: Bool? = nil
    var charged: Bool? = nil
    /// 残り時間 (電源につながっていないとき) か満充電までの時間 (分)。分からなければ nil
    var minutes: Int? = nil

    var isInternal: Bool { `internal` == true }

    /// 本体のバッテリーの状態の文。例: 「充電中・満充電まで 1:25」。本体のものでなければ nil
    var statusText: String? {
        guard isInternal else { return nil }
        let time = minutes.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
        let separator = L("・", " · ")
        let calculating = L("計算中…", "Calculating…")
        if external != true {
            return L("バッテリー駆動", "On battery") + separator
                + (time.map { L("残り \($0)", "\($0) remaining") } ?? calculating)
        }
        if charged == true || percent >= 100 {
            return L("電源に接続", "On power") + separator + L("充電済み", "Fully charged")
        }
        if charging == true {
            return L("充電中", "Charging") + separator
                + (time.map { L("満充電まで \($0)", "\($0) until full") } ?? calculating)
        }
        // 電源につながっているが充電していない (バッテリー充電の最適化で止めているときなど)
        return L("電源に接続", "On power") + separator + L("充電していない", "Not charging")
    }
}
