import Foundation
import IOKit

public struct Volume: Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String
    public var total: UInt64
    /// Space available for "important" use, which counts purgeable space
    /// as free -- the figure Finder shows.
    public var free: UInt64

    public var id: String { path }
    public var used: UInt64 { total > free ? total - free : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

public struct DiskUsage: Sendable, Equatable {
    /// The startup volume first, then any other browsable volumes.
    public var volumes: [Volume]
    public var readPerSecond: Double
    public var writePerSecond: Double
    /// Bytes moved since boot, over every block device.
    public var totalRead: UInt64
    public var totalWritten: UInt64

    public var startup: Volume? { volumes.first }
    public var usedFraction: Double? { startup?.usedFraction }
}

public struct DiskSampler {
    private var previous: (read: UInt64, write: UInt64, time: Double)?
    private var volumes: [Volume] = []
    private var volumesCheckedAt: Double = -.infinity

    public init() {}

    public mutating func sample(now: Double) -> DiskUsage {
        // Free space barely moves and the lookup touches the file system,
        // so it's refreshed every 30 s rather than every tick.
        if now - volumesCheckedAt >= 30 {
            volumes = Self.readVolumes()
            volumesCheckedAt = now
        }
        let io = Self.readIO()
        defer { previous = (io.read, io.write, now) }

        var usage = DiskUsage(
            volumes: volumes, readPerSecond: 0, writePerSecond: 0,
            totalRead: io.read, totalWritten: io.write
        )
        if let previous, now > previous.time {
            let elapsed = now - previous.time
            usage.readPerSecond = Double(io.read >= previous.read ? io.read - previous.read : 0) / elapsed
            usage.writePerSecond = Double(io.write >= previous.write ? io.write - previous.write : 0) / elapsed
        }
        return usage
    }

    static func readVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
            .volumeIsReadOnlyKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var root: Volume?
        var others: [Volume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  // Mounted .dmg installers are read-only and always "full".
                  values.volumeIsReadOnly != true || values.volumeIsRootFileSystem == true,
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            // Important-usage capacity is APFS-only; fall back for FAT/exFAT drives.
            let free = values.volumeAvailableCapacityForImportantUsage.map(Int.init) ?? values.volumeAvailableCapacity ?? 0
            let volume = Volume(
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                path: url.path, total: UInt64(total), free: UInt64(max(free, 0))
            )
            if values.volumeIsRootFileSystem == true { root = volume } else { others.append(volume) }
        }
        return (root.map { [$0] } ?? []) + others
    }

    /// Bytes read and written since boot, summed over every block device.
    static func readIO() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0
        var write: UInt64 = 0
        forEachService("IOBlockStorageDriver") { driver in
            guard let stats = registryProperty(driver, "Statistics") as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}
