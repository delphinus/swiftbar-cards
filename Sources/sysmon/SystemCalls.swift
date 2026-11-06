import Foundation
#if canImport(Shared)
import Shared
#endif

/// 失敗したときの記録 (Shared の makeLogger)
let logger = makeLogger("sysmon")

/// sysctl の値を読む。`initial` は値の型を決めるためのもので、中身は使わない。
/// 例: `sysctlValue("hw.memsize", UInt64(0))`
///
/// `<T>` はジェネリクス。呼ぶ側が渡した型 (UInt64・Int32・構造体など) で、同じ関数を使える。
func sysctlValue<T>(_ name: String, _ initial: T) -> T? {
    var value = initial
    var size = MemoryLayout<T>.size
    let result = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
    return result == 0 ? value : nil
}

/// 外部のコマンドを起動して、標準出力を文字列で返す。起動できなければ nil
func runCommand(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        logger.error("起動に失敗: \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        logger.error("終了コード \(process.terminationStatus): \(path, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")
    }
    return String(data: data, encoding: .utf8)
}
