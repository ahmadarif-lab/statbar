import Darwin

public enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

public struct MemoryUsage: Sendable, Equatable {
    public var total: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File-backed and purgeable pages the system can drop at any time.
    public var cached: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure
    /// How hard the system is working to find free memory, 0...1 -- the
    /// complement of the kernel's "memory available" level.
    public var pressureFraction: Double

    /// Same definition as Activity Monitor's "Memory Used".
    public var used: UInt64 { app + wired + compressed }
    public var free: UInt64 { total > used ? total - used : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

public enum MemorySampler {
    public static func sample() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHost, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let swap = sysctlValue("vm.swapusage", initial: xsw_usage())
        let level = sysctlValue("kern.memorystatus_vm_pressure_level", initial: Int32(1)) ?? 1
        let available = sysctlValue("kern.memorystatus_level", initial: Int32(100)) ?? 100

        return MemoryUsage(
            total: ProcessInfoMemory.physical,
            app: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            swapUsed: swap?.xsu_used ?? 0,
            swapTotal: swap?.xsu_total ?? 0,
            pressure: MemoryPressure(rawValue: Int(level)) ?? .normal,
            pressureFraction: 1 - Double(min(max(available, 0), 100)) / 100
        )
    }
}

enum ProcessInfoMemory {
    static let physical: UInt64 = sysctlValue("hw.memsize", initial: UInt64(0)) ?? 0
}
