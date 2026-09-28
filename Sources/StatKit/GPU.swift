import Foundation
import IOKit

public struct GPUUsage: Sendable, Equatable {
    /// Fractions, 0...1.
    public var device: Double
    public var renderer: Double
    public var tiler: Double
    /// System memory the GPU driver currently has in use.
    public var memoryInUse: UInt64
}

public enum GPUSampler {
    /// The busiest accelerator's statistics, or nil when none reports them.
    public static func sample() -> GPUUsage? {
        var busiest: GPUUsage?
        forEachService("IOAccelerator") { accelerator in
            guard let stats = registryProperty(accelerator, "PerformanceStatistics") as? [String: Any],
                  let device = fraction(stats["Device Utilization %"]) else { return }
            let usage = GPUUsage(
                device: device,
                renderer: fraction(stats["Renderer Utilization %"]) ?? 0,
                tiler: fraction(stats["Tiler Utilization %"]) ?? 0,
                memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            )
            if usage.device >= busiest?.device ?? -1 { busiest = usage }
        }
        return busiest
    }

    private static func fraction(_ value: Any?) -> Double? {
        (value as? NSNumber).map { min(max($0.doubleValue, 0), 100) / 100 }
    }
}
