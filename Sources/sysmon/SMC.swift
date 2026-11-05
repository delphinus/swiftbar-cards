import Foundation
import IOKit

/// SMC (System Management Controller) の温度センサー。読み方は macmon
/// (https://github.com/vladkens/macmon、MIT) の src/sources.rs と src/metrics.rs に倣った。
///
/// キーの意味は公開されていないので、macmon と同じく名前が Tp / Te / Ts で始まるものを
/// CPU、Tg で始まるものを GPU とみなし、4 バイトの浮動小数点数 (flt ) として読めるものの
/// 平均を取る。チップごとの対応表を持たずに済む。
///
/// 仮想マシンなど SMC が無い環境では、`init?` が nil を返す (失敗できるイニシャライザ)。
final class SMC {
    private let connection: io_connect_t
    /// キーごとの値の大きさと型。読むたびに問い合わせずに済むよう覚えておく
    private var keyInfoCache: [UInt32: KeyInfo] = [:]
    private var cpuKeys: [UInt32] = []
    private var gpuKeys: [UInt32] = []

    private struct KeyInfo {
        let size: UInt32
        let type: UInt32
    }

    init?() {
        guard let connection = Self.openConnection() else { return nil }
        self.connection = connection
        for name in allKeyNames() {
            let isCPU = name.hasPrefix("Tp") || name.hasPrefix("Te") || name.hasPrefix("Ts")
            let isGPU = name.hasPrefix("Tg")
            // 温度のキーのうち、浮動小数点数として読めるものだけを使う
            guard isCPU || isGPU, readFloat(Self.key(name)) != nil else { continue }
            if isCPU {
                cpuKeys.append(Self.key(name))
            } else {
                gpuKeys.append(Self.key(name))
            }
        }
    }

    deinit { IOServiceClose(connection) }

    /// CPU の温度 (°C)。読めなければ nil
    var cpuTemperature: Double? { average(of: cpuKeys) }
    /// GPU の温度 (°C)。読めなければ nil
    var gpuTemperature: Double? { average(of: gpuKeys) }

    /// 有効な値 (0〜150°C) の平均
    private func average(of keys: [UInt32]) -> Double? {
        let values = keys.compactMap { readFloat($0) }.filter { $0 > 0 && $0 <= 150 }
        return values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
    }

    // MARK: - AppleSMC とのやり取り

    private static func openConnection() -> io_connect_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var connection: io_connect_t = 0
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(device, &name)
            if String(cString: name) == "AppleSMCKeysEndpoint" {
                IOServiceOpen(device, mach_task_self_, 0, &connection)
            }
        }
        return connection != 0 ? connection : nil
    }

    /// SMC への命令 (構造体の data8 に入れる値)
    private enum Command: UInt8 {
        case readValue = 5
        case keyAtIndex = 8
        case readKeyInfo = 9
    }

    /// AppleSMC とやり取りする構造体 (C で 80 バイト) を、C の配置どおりのバイト列で組む。
    /// key @0、keyInfo の dataSize @28 と dataType @32、result @40、data8 (命令) @42、
    /// data32 @44、bytes (値) @48。`fill` で入力のバイト列を埋め、出力のバイト列を返す。
    private func call(_ fill: (UnsafeMutableRawPointer) -> Void) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes { fill($0.baseAddress!) }
        var outputSize = 80
        let result = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                IOConnectCallStructMethod(connection, 2, inputBytes.baseAddress, 80, outputBytes.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }

    /// 4 文字のキーの名前を、SMC が使う 32 ビットの数にする。例: "TC0P"
    private static func key(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func keyInfo(_ key: UInt32) -> KeyInfo? {
        if let cached = keyInfoCache[key] { return cached }
        guard let output = call({ input in
            input.storeBytes(of: key, as: UInt32.self)
            input.storeBytes(of: Command.readKeyInfo.rawValue, toByteOffset: 42, as: UInt8.self)
        }) else { return nil }
        let info = output.withUnsafeBytes {
            KeyInfo(size: $0.load(fromByteOffset: 28, as: UInt32.self), type: $0.load(fromByteOffset: 32, as: UInt32.self))
        }
        keyInfoCache[key] = info
        return info
    }

    private func readBytes(_ key: UInt32) -> [UInt8]? {
        guard let info = keyInfo(key), let output = call({ input in
            input.storeBytes(of: key, as: UInt32.self)
            input.storeBytes(of: info.size, toByteOffset: 28, as: UInt32.self)
            input.storeBytes(of: info.type, toByteOffset: 32, as: UInt32.self)
            input.storeBytes(of: Command.readValue.rawValue, toByteOffset: 42, as: UInt8.self)
        }) else { return nil }
        return Array(output[48..<48 + Int(min(info.size, 32))])
    }

    private func readFloat(_ key: UInt32) -> Float? {
        guard let info = keyInfo(key), info.size == 4, info.type == Self.key("flt "),
              let bytes = readBytes(key) else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    /// SMC にあるすべてのキーの名前。キーの数は "#KEY" で読め、番号からキーを引ける
    private func allKeyNames() -> [String] {
        guard let bytes = readBytes(Self.key("#KEY")), bytes.count >= 4 else { return [] }
        let count = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (0..<count).compactMap { index in
            guard let output = call({ input in
                input.storeBytes(of: Command.keyAtIndex.rawValue, toByteOffset: 42, as: UInt8.self)
                input.storeBytes(of: index, toByteOffset: 44, as: UInt32.self)
            }) else { return nil }
            let key = output.withUnsafeBytes { $0.load(as: UInt32.self) }
            return String(bytes: [24, 16, 8, 0].map { UInt8((key >> $0) & 0xff) }, encoding: .ascii)
        }
    }
}
