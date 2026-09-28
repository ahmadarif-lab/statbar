import Foundation
import IOKit

public enum CoreKind: Sendable {
    case efficiency, performance
}

public enum SystemInfo {
    public static let chipName: String = sysctlString("machdep.cpu.brand_string") ?? "Unknown CPU"
    public static let physicalMemory: UInt64 = ProcessInfoMemory.physical
    public static let performanceCores: Int? = sysctlValue("hw.perflevel0.logicalcpu", initial: Int32(0)).map(Int.init)
    public static let efficiencyCores: Int? = sysctlValue("hw.perflevel1.logicalcpu", initial: Int32(0)).map(Int.init)

    /// Efficiency/performance type of each logical core, in core order,
    /// from the device tree's `cluster-type`. Nil on Intel Macs.
    public static let coreKinds: [CoreKind]? = {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var kinds: [Int: CoreKind] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let id = (registryProperty(entry, "logical-cpu-id") as? NSNumber)?.intValue,
               let type = (registryProperty(entry, "cluster-type") as? Data)?.first {
                kinds[id] = type == UInt8(ascii: "P") ? .performance : .efficiency
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        guard !kinds.isEmpty, Set(kinds.keys) == Set(0..<kinds.count) else { return nil }
        return (0..<kinds.count).compactMap { kinds[$0] }
    }()

    public static var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    public static func bootTime() -> Date? {
        guard let time = sysctlValue("kern.boottime", initial: timeval()) else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    /// 1, 5 and 15 minute load averages.
    public static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }
}
