import Foundation

public enum Format {
    /// 0...1 fraction as a whole percentage; "–" when unknown.
    public static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "–" }
        return "\(Int((max(fraction, 0) * 100).rounded()))%"
    }

    /// Binary units, labelled the way macOS does ("16 GB" of RAM).
    public static func bytes(_ bytes: UInt64) -> String {
        scaled(Double(bytes), units: ["B", "KB", "MB", "GB", "TB"], separator: " ")
    }

    /// "1.2 MB/s", or "1.2M" when `compact`. `oneDecimal` rounds to one
    /// decimal and drops it when it's zero ("41.4 KB/s", "70 KB/s");
    /// otherwise there's a decimal only below 10. `bits` reports network
    /// style: "12.5 Mb/s" in powers of 1000.
    public static func rate(_ bytesPerSecond: Double, compact: Bool = false, oneDecimal: Bool = false, bits: Bool = false) -> String {
        var value = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        let base: Double = bits ? 1000 : 1024
        if bits { value *= 8 }
        let unit = bits ? "b" : "B"
        if compact {
            return scaled(value, units: ["B", "K", "M", "G", "T"].map { $0 == "B" ? unit : $0 }, separator: "", oneDecimal: oneDecimal, base: base)
        }
        let units = ["", "K", "M", "G", "T"].map { $0 + unit }
        return scaled(value, units: units, separator: " ", oneDecimal: oneDecimal, base: base) + "/s"
    }

    /// "3d 4h", "5h 12m" or "12m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0)) / 60
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// "2 days, 3 hours", "3 hours, 5 minutes" -- the long form for uptime.
    public static func longDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0)) / 60
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        if days > 0 { return unit(days, "day") + ", " + unit(hours, "hour") }
        return unit(hours, "hour") + ", " + unit(minutes % 60, "minute")
    }

    /// One decimal below 10 of a unit, whole numbers above -- keeps the
    /// string short enough for the menu bar ("9.8 MB", "128 MB"). The base
    /// unit (bytes) is always a whole number.
    private static func scaled(_ value: Double, units: [String], separator: String,
                               oneDecimal: Bool = false, base: Double = 1024) -> String {
        var value = value
        var index = 0
        // Compare the value as it will print, so 999.96 rolls over instead
        // of showing a four-digit "1000.0".
        func printed(_ v: Double) -> Double {
            index == 0 ? v.rounded() : oneDecimal ? (v * 10).rounded() / 10 : v
        }
        while printed(value) >= 1000 && index < units.count - 1 {
            value /= base
            index += 1
        }
        if index == 0 { return "\(Int(value.rounded()))\(separator)\(units[0])" }
        let tenths = (value * 10).rounded()
        let text: String
        if oneDecimal {
            text = tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10))" : String(format: "%.1f", tenths / 10)
        } else {
            text = value < 10 ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
        }
        return text + separator + units[index]
    }
}
