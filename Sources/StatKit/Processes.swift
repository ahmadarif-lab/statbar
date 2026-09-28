import Darwin

public struct ProcessUsage: Identifiable, Sendable, Equatable {
    public var pid: pid_t
    public var name: String
    /// Share of one core, so a process busy on two cores reads 2.0.
    public var cpu: Double
    /// Physical footprint in bytes, as Activity Monitor's "Memory" column.
    public var memory: UInt64
    /// Disk throughput in bytes per second.
    public var diskRead: Double
    public var diskWrite: Double

    public var id: pid_t { pid }
}

/// Per-process CPU and memory. Only processes this user may inspect are
/// listed -- root-owned daemons need a privileged helper, which StatBar
/// deliberately doesn't install.
public struct ProcessSampler {
    private struct Counters {
        var cpu: UInt64
        var read: UInt64
        var write: UInt64
    }

    private var previous: [pid_t: Counters] = [:]
    private var previousTime: Double?
    private var names: [pid_t: String] = [:]

    /// rusage CPU times are in Mach absolute-time units, which on Apple
    /// silicon are not nanoseconds (24 MHz ticks).
    private static let nanosPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    public init() {}

    public mutating func sample(now: Double) -> [ProcessUsage] {
        let elapsed = previousTime.map { now - $0 } ?? 0
        var counters: [pid_t: Counters] = [:]
        var liveNames: [pid_t: String] = [:]
        var result: [ProcessUsage] = []

        for pid in Self.allPIDs() where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { continue }

            let now = Counters(
                cpu: info.ri_user_time + info.ri_system_time,
                read: info.ri_diskio_bytesread,
                write: info.ri_diskio_byteswritten
            )
            counters[pid] = now
            var cpu = 0.0
            var read = 0.0
            var write = 0.0
            if elapsed > 0, let old = previous[pid] {
                func rate(_ new: UInt64, _ old: UInt64) -> Double { new >= old ? Double(new - old) / elapsed : 0 }
                cpu = rate(now.cpu, old.cpu) * Self.nanosPerTick / 1e9
                read = rate(now.read, old.read)
                write = rate(now.write, old.write)
            }
            let name = names[pid] ?? Self.name(of: pid)
            liveNames[pid] = name
            result.append(ProcessUsage(
                pid: pid, name: name, cpu: cpu, memory: info.ri_phys_footprint,
                diskRead: read, diskWrite: write
            ))
        }

        previous = counters
        previousTime = now
        names = liveNames
        return result
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(count, 0))))
    }

    static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "pid \(pid)" : name
    }
}
