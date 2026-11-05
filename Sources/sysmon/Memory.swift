import Foundation

/// メモリの使用量。Activity Monitor の「使用済みメモリ」と同じく、アプリ (internal から
/// purgeable を除く) + wired + 圧縮で数える。
func readMemoryStats() -> MemoryStats {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    // host_statistics64 は integer_t の配列として書き込むので、その型のポインタとして渡す
    _ = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    let pageSize = Double(vm_kernel_page_size)
    let compressed = Double(stats.compressor_page_count) * pageSize
    let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
    let used = (app + Double(stats.wire_count)) * pageSize + compressed
    let total = Double(sysctlValue("hw.memsize", UInt64(0)) ?? 0)

    let swapUsed = sysctlValue("vm.swapusage", xsw_usage()).map { Double($0.xsu_used) } ?? 0
    let swap = swapUsed >= 1_073_741_824
        ? String(format: "%.1f GB", swapUsed / 1_073_741_824)
        : String(format: "%.0f MB", swapUsed / 1_048_576)
    let pressure = Int(sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0)) ?? 0)
    return MemoryStats(used: used, total: total, compressed: compressed, swap: swap, pressure: pressure)
}
