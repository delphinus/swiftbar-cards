import Foundation

/// CPU とメモリを使っているプロセスの上位 5 件。
///
/// root で動くプロセスは権限の無いプログラムからは libproc で読めないので、setuid root の
/// ps に頼る。ps の %CPU は直近の平均なので、全体の使用率と合計は一致しない。
func topProcesses() -> (byCPU: [ProcessUsage], byMemory: [ProcessUsage]) {
    guard let output = runCommand("/bin/ps", ["-Aceo", "pcpu=,rss=,comm="]) else { return ([], []) }

    // 1 行が「%CPU RSS(KB) 名前」。名前は空白を含むことがあるので、2 回だけ区切る
    var processes: [(cpu: Double, memory: Double, name: String)] = []
    for line in output.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let cpu = Double(fields[0]), let memory = Double(fields[1]) else { continue }
        processes.append((cpu, memory, String(fields[2])))
    }

    let byCPU = processes.sorted { $0.cpu > $1.cpu }.prefix(5).map { ProcessUsage(name: $0.name, value: $0.cpu) }
    let byMemory = processes.sorted { $0.memory > $1.memory }.prefix(5).map { ProcessUsage(name: $0.name, value: $0.memory) }
    return (byCPU, byMemory)
}
