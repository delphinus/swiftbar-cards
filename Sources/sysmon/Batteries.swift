import Foundation
import IOKit.ps

/// Mac 本体のバッテリー (MacBook)。デスクトップには無いので nil。
func readInternalBattery() -> Battery? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        let external = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        // 時間は分で、計算中は -1
        let minutes = (external ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
        return Battery(name: "", percent: (Double(current) / Double(max) * 100).rounded(),
                       internal: true, external: external,
                       charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                       charged: description[kIOPSIsChargedKey] as? Bool,
                       minutes: minutes.flatMap { $0 > 0 ? $0 : nil })
    }
    return nil
}

/// Bluetooth 機器のバッテリー。ioreg の出力から、機器のアドレスと残量を拾う。
/// `names` はアドレス → 名前 (`readBluetoothNames`)。名前が分からなければアドレスを出す。
func readBluetoothBatteries(names: [String: String]) -> [Battery] {
    guard let output = runCommand("/usr/sbin/ioreg", ["-r", "-k", "BatteryPercent", "-l"]) else { return [] }
    // ioreg の値の部分。例: `"BatteryPercent" = 80` の 80
    func value(of line: Substring) -> String {
        line.components(separatedBy: " = ").last ?? ""
    }

    var batteries: [Battery] = []
    var address = ""
    for line in output.split(separator: "\n") {
        if line.contains("\"DeviceAddress\" = ") {
            // "aa-bb-cc-dd-ee-ff" → AA:BB:CC:DD:EE:FF (system_profiler の書き方にそろえる)
            address = value(of: line).replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "-", with: ":").uppercased()
        } else if line.contains("\"BatteryPercent\" = "), let percent = Double(value(of: line)) {
            batteries.append(Battery(name: names[address] ?? address, percent: percent))
            address = ""
        }
    }
    return batteries
}

/// Bluetooth 機器の名前 (アドレス → 名前)。ioreg の Product は空になる機器があるので
/// system_profiler から取る。
func readBluetoothNames() -> [String: String] {
    guard let output = runCommand("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
          let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
          let bluetooth = (json["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [:] }
    // 形は {"device_connected": [{"名前": {"device_address": "AA:BB:…", …}}, …], …}
    var names: [String: String] = [:]
    for key in ["device_connected", "device_not_connected"] {
        for entry in bluetooth[key] as? [[String: Any]] ?? [] {
            for (name, properties) in entry {
                if let address = (properties as? [String: Any])?["device_address"] as? String {
                    names[address.uppercased()] = name
                }
            }
        }
    }
    return names
}
