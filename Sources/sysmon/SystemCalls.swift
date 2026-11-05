import Foundation

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
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
}
