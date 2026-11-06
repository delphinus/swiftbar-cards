import Foundation
import IOKit
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

/// Bluetooth 機器のバッテリー。IOKit のレジストリから、残量 (BatteryPercent) を持つ
/// エントリを探し、機器のアドレスと残量を拾う (`ioreg -r -k BatteryPercent` と同じ探し方)。
/// `names` はアドレス → 名前 (`readBluetoothNames`)。名前が分からなければアドレスを出す。
func readBluetoothBatteries(names: [String: String]) -> [Battery] {
    // 「BatteryPercent というプロパティを持つもの」という条件でサービスを探す
    let matching = IOServiceMatching("IOService") as NSMutableDictionary
    matching["IOPropertyExistsMatch"] = "BatteryPercent"
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }

    var batteries: [Battery] = []
    var seen: Set<String> = []
    while true {
        // IOIteratorNext は、尽きると 0 を返す
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { break }
        defer { IOObjectRelease(entry) }
        guard let percent = registryProperty(entry, "BatteryPercent") as? Int else { continue }
        // アドレスは機器のエントリか、その親にある。"aa-bb-cc-dd-ee-ff" の形なので、
        // system_profiler の書き方 (AA:BB:CC:DD:EE:FF) にそろえる
        let address = (registryProperty(entry, "DeviceAddress", searchingParents: true) as? String ?? "")
            .replacingOccurrences(of: "-", with: ":").uppercased()
        // 1 つの機器の下に、残量を持つエントリが入れ子で 2 つあることがある
        guard address.isEmpty || seen.insert(address).inserted else { continue }
        batteries.append(Battery(name: names[address] ?? address, percent: Double(percent)))
    }
    return batteries
}

/// レジストリのエントリのプロパティを読む。`searchingParents` なら、エントリに無ければ親をたどって探す
private func registryProperty(_ entry: io_registry_entry_t, _ key: String, searchingParents: Bool = false) -> Any? {
    let options = searchingParents ? IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents) : 0
    return IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
}

/// Bluetooth 機器の名前 (アドレス → 名前)。レジストリの Product は空になる機器があるので
/// system_profiler から取る。名前を読める API の IOBluetooth は Bluetooth の利用の許可が要り、
/// その許可は親の SwiftBar の Info.plist に利用目的 (NSBluetoothAlwaysUsageDescription) が
/// 無いと得られないので使えない。重いので 1 時間ごとにしか呼ばない。
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
