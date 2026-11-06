import Foundation

/// 値を集めて `Snapshot` を作る。前回の値 (CPU のティック・履歴・重い値の取り置き) を
/// 持ち続けるので class にする。
///
/// - CPU の使用率: host_processor_info のティックの差分 (CPUUsageMeter)
/// - メモリ: host_statistics64 (readMemoryStats)
/// - 負荷: getloadavg
/// - プロセスごとの CPU とメモリ: ps (20 秒ごと)
/// - 温度: SMC のセンサーの平均
/// - 本体のバッテリー: IOKit の電源の情報 (毎回。API を呼ぶだけで軽い)
/// - Bluetooth 機器のバッテリー: IOKit のレジストリ (60 秒ごと)。名前は system_profiler (1 時間ごと)
final class SystemMonitor {
    /// 何秒ごとに集めるか
    let interval: TimeInterval

    private let cpuMeter = CPUUsageMeter()
    private let cpuHistory: CPUHistory
    private let smc = SMC()
    // 重い値 (外部のコマンドを起動する・レジストリを探す) は、間隔を空けて取り直す
    private var processes = Throttled<(byCPU: [ProcessUsage], byMemory: [ProcessUsage])>(interval: 20, initial: ([], []))
    private var bluetoothNames = Throttled<[String: String]>(interval: 3600, initial: [:])
    private var bluetoothBatteries = Throttled<[Battery]>(interval: 60, initial: [])

    init(interval: TimeInterval, historyFile: String) {
        self.interval = interval
        self.cpuHistory = CPUHistory(file: historyFile, capacity: 60)
    }

    func takeSnapshot() -> Snapshot {
        let now = Date().timeIntervalSince1970
        let usage = cpuMeter.measure()
        cpuHistory.append(usage.total)

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        let top = processes.value(at: now, refresh: topProcesses)
        let names = bluetoothNames.value(at: now, refresh: readBluetoothNames)
        let bluetooth = bluetoothBatteries.value(at: now) { readBluetoothBatteries(names: names) }
        let internalBattery = readInternalBattery().map { [$0] } ?? []

        return Snapshot(
            interval: interval,
            cpu: CPUStats(total: usage.total, user: usage.user, sys: usage.system,
                          e: usage.efficiencyCores, p: usage.performanceCores,
                          load: String(format: "%.2f / %.2f / %.2f", load[0], load[1], load[2]),
                          temp: smc?.cpuTemperature?.rounded(), gpu: smc?.gpuTemperature?.rounded(),
                          hist: cpuHistory.values),
            mem: readMemoryStats(),
            procCpu: top.byCPU,
            procMem: top.byMemory,
            battery: internalBattery + bluetooth)
    }
}

/// 重い値を、決めた間隔より短い間は取り直さずに使い回す。
///
/// `<Value>` はジェネリクスで、取り置く値の型を使う側が決める。値型 (struct) なので、
/// 中身を書き換えるメソッドには `mutating` を付ける。
struct Throttled<Value> {
    let interval: TimeInterval
    private var value: Value
    private var refreshedAt: TimeInterval = 0

    init(interval: TimeInterval, initial: Value) {
        self.interval = interval
        self.value = initial
    }

    /// 前回取ってから `interval` 秒以上たっていれば `refresh` で取り直し、値を返す
    mutating func value(at now: TimeInterval, refresh: () -> Value) -> Value {
        if now - refreshedAt >= interval {
            value = refresh()
            refreshedAt = now
        }
        return value
    }
}

/// CPU の使用率の履歴 (古い順)。プログラムを起動し直しても続きから描けるよう、ファイルにも書く。
final class CPUHistory {
    private let file: String
    private let capacity: Int
    private(set) var values: [Double]

    init(file: String, capacity: Int) {
        self.file = file
        self.capacity = capacity
        let saved = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        values = Array(saved.split(separator: "\n").compactMap { Double($0) }.suffix(capacity))
    }

    func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
        do {
            try values.map { String(Int($0)) }.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        } catch {
            logger.error("履歴を書けない: \(self.file, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
