import Darwin

public struct CPUUsage: Sendable, Equatable {
    /// Fractions of all cores' time, 0...1.
    public var user: Double
    public var system: Double
    /// Busy fraction of each logical core, 0...1.
    public var cores: [Double]

    public var total: Double { user + system }
    public var idle: Double { max(0, 1 - total) }
}

/// CPU load from the per-core tick counters. Usage is the delta between two
/// samples, so the first call only records a baseline and returns nil.
public struct CPUSampler {
    struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private var previous: [Ticks] = []

    public init() {}

    public mutating func sample() -> CPUUsage? {
        guard let current = Self.readTicks() else { return nil }
        defer { previous = current }
        guard previous.count == current.count else { return nil }
        return Self.usage(from: previous, to: current)
    }

    static func usage(from old: [Ticks], to new: [Ticks]) -> CPUUsage {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var all: UInt64 = 0
        var cores: [Double] = []
        for (a, b) in zip(old, new) {
            // The counters are 32-bit and wrap; wrapping subtraction still
            // yields the right delta across a single wrap.
            let u = UInt64(b.user &- a.user) + UInt64(b.nice &- a.nice)
            let s = UInt64(b.system &- a.system)
            let i = UInt64(b.idle &- a.idle)
            let t = u + s + i
            cores.append(t == 0 ? 0 : Double(u + s) / Double(t))
            user += u
            system += s
            all += t
        }
        guard all > 0 else { return CPUUsage(user: 0, system: 0, cores: cores) }
        return CPUUsage(user: Double(user) / Double(all), system: Double(system) / Double(all), cores: cores)
    }

    static func readTicks() -> [Ticks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(machHost, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        return (0..<Int(cpuCount)).map { cpu in
            let base = Int(CPU_STATE_MAX) * cpu
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return Ticks(
                user: tick(CPU_STATE_USER),
                system: tick(CPU_STATE_SYSTEM),
                idle: tick(CPU_STATE_IDLE),
                nice: tick(CPU_STATE_NICE)
            )
        }
    }
}
