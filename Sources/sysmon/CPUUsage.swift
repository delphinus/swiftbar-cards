import Foundation
import IOKit

/// CPU の使用率 (%)
struct CPUUsage {
    var user: Double = 0
    var system: Double = 0
    /// E コアと P コアの使用率。コアの種類が分からなければ nil
    var efficiencyCores: Double?
    var performanceCores: Double?

    var total: Double { user + system }
}

/// CPU の使用率を測る。
///
/// カーネルは、コアごとに「ユーザ・システム・nice・アイドルの状態で過ごした時間」
/// (ティック) を数え続けている。前回読んだ値との差分を取ると、その間の使用率が分かる。
/// 前回の値を覚えておく必要があるので class にする。
final class CPUUsageMeter {
    private var previous: [Ticks]
    /// 論理 CPU の番号 → コアの種類
    private let coreKinds: [Int: CoreKind]

    init() {
        previous = Self.readTicks()
        coreKinds = Self.readCoreKinds()
    }

    /// 前回呼んでからの使用率
    func measure() -> CPUUsage {
        let current = Self.readTicks()
        let diff = current.count == previous.count ? zip(current, previous).map { $0 - $1 } : []
        previous = current

        let all = diff.reduce(Ticks(), +)
        var usage = CPUUsage()
        if all.total > 0 {
            usage.user = (Double(all.user &+ all.nice) / all.total * 100).rounded()
            usage.system = (Double(all.system) / all.total * 100).rounded()
        }
        // 種類ごとに足し合わせる。その種類のコアが無ければ nil (その行を出さない)
        func coreUsage(_ kind: CoreKind) -> Double? {
            let ticks = diff.indices.filter { coreKinds[$0] == kind }.map { diff[$0] }.reduce(Ticks(), +)
            return ticks.total > 0 ? (ticks.busy / ticks.total * 100).rounded() : nil
        }
        usage.efficiencyCores = coreUsage(.efficiency)
        usage.performanceCores = coreUsage(.performance)
        return usage
    }

    // MARK: - ティック

    /// 1 つのコアのティック。`&+` `&-` は桁あふれしても止まらない足し算・引き算
    /// (数え続けた値が一周しても差分が正しく出る)。
    private struct Ticks {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        var busy: Double { Double(user &+ system &+ nice) }
        var total: Double { Double(user &+ system &+ nice &+ idle) }

        // 演算子 + と - を、この型どうしで使えるようにする
        static func + (a: Ticks, b: Ticks) -> Ticks {
            Ticks(user: a.user &+ b.user, system: a.system &+ b.system, idle: a.idle &+ b.idle, nice: a.nice &+ b.nice)
        }
        static func - (a: Ticks, b: Ticks) -> Ticks {
            Ticks(user: a.user &- b.user, system: a.system &- b.system, idle: a.idle &- b.idle, nice: a.nice &- b.nice)
        }
    }

    /// コアごとのティックを host_processor_info で読む
    private static func readTicks() -> [Ticks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            logger.error("host_processor_info に失敗: \(result)")
            return []
        }
        // カーネルが用意したメモリは、使い終わったら返す。defer の中身は関数を抜けるときに実行される
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        // info は「コア 0 の 4 つの値、コア 1 の 4 つの値、…」と並んだ配列
        func value(core: Int, state: Int32) -> UInt64 {
            UInt64(UInt32(bitPattern: info[Int(CPU_STATE_MAX) * core + Int(state)]))
        }
        return (0..<Int(cpuCount)).map { core in
            Ticks(user: value(core: core, state: CPU_STATE_USER), system: value(core: core, state: CPU_STATE_SYSTEM),
                  idle: value(core: core, state: CPU_STATE_IDLE), nice: value(core: core, state: CPU_STATE_NICE))
        }
    }

    // MARK: - コアの種類

    enum CoreKind: String {
        case efficiency = "E"
        case performance = "P"
    }

    /// 論理 CPU の番号ごとのコアの種類。IODeviceTree の cpus の子にある cluster-type で
    /// 見分ける。host_processor_info の並びは logical-cpu-id の順。Intel の Mac には
    /// cluster-type が無いので空になる。
    private static func readCoreKinds() -> [Int: CoreKind] {
        var kinds: [Int: CoreKind] = [:]
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return kinds }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return kinds }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, nil, 0)?.takeRetainedValue()
            }
            guard let type = property("cluster-type") as? Data,
                  let id = property("logical-cpu-id") as? NSNumber,
                  let name = String(data: type.prefix { $0 != 0 }, encoding: .ascii),
                  let kind = CoreKind(rawValue: name) else { continue }
            kinds[id.intValue] = kind
        }
        return kinds
    }
}
