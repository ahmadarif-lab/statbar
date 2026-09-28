import Foundation
import IOKit
import IOKit.ps

public struct BatteryInfo: Sendable, Equatable {
    /// Charge, 0...1.
    public var level: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    /// Minutes to empty (on battery) or to full (charging); nil while macOS
    /// is still estimating.
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// Full-charge capacity against design capacity, 0...1.
    public var health: Double?
    public var temperature: Double?
    /// Watts flowing out of (negative) or into (positive) the battery.
    public var power: Double?
    public var adapterWatts: Int?
}

public enum BatterySampler {
    public static func sample() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [AnyObject] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = description[minutesKey] as? Int

            var info = BatteryInfo(
                level: maximum > 0 ? Double(current) / Double(maximum) : 0,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                minutesRemaining: (minutes ?? -1) > 0 && !(isPluggedIn && !isCharging) ? minutes : nil
            )
            addSmartBatteryDetails(to: &info)
            if isPluggedIn,
               let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                info.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
            }
            return info
        }
        return nil
    }

    /// Cycle count, health, temperature and power draw live on the
    /// AppleSmartBattery registry entry rather than the power-source API.
    private static func addSmartBatteryDetails(to info: inout BatteryInfo) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return }

        // macOS 27 moved the capacity figures into a "BatteryData" sub-dictionary
        // and stopped publishing the temperature; older releases keep them
        // at the top level.
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> NSNumber? {
            (properties[key] ?? batteryData[key]) as? NSNumber
        }

        info.cycleCount = number("CycleCount")?.intValue
        // Nominal capacity is what System Settings reports as "Maximum Capacity".
        if let design = number("DesignCapacity")?.doubleValue, design > 0,
           let full = (number("NominalChargeCapacity") ?? number("AppleRawMaxCapacity"))?.doubleValue {
            info.health = min(full / design, 1)
        }
        if let centiCelsius = number("Temperature")?.doubleValue {
            info.temperature = centiCelsius / 100
        }
        if let millivolts = number("Voltage")?.doubleValue,
           let milliamps = number("Amperage")?.int64Value {
            info.power = millivolts * Double(milliamps) / 1_000_000
        }
    }
}
