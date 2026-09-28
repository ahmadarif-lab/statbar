import Foundation

public struct Fan: Sendable, Equatable {
    public var rpm: Double
    public var minimum: Double?
    public var maximum: Double?

    /// Speed within the fan's range, 0...1.
    public var fraction: Double? {
        guard let minimum, let maximum, maximum > minimum else { return nil }
        return min(max((rpm - minimum) / (maximum - minimum), 0), 1)
    }
}

/// Temperatures in °C, each averaged over the sensors in its group.
public struct SensorReadings: Sendable, Equatable {
    public var cpu: Double?
    public var gpu: Double?
    public var ssd: Double?
    public var battery: Double?
    public var fans: [Fan] = []
}

/// Temperature and fan sensors, from the SMC plus (for the SSD) the HID
/// sensor hub. Key lists follow the open-source Stats app
/// (github.com/exelban/stats); each Mac has only some of them, so the
/// first read finds which exist and later reads skip the rest.
public struct SensorSampler {
    /// Apple silicon M1–M4 CPU cluster sensors, and Intel's CPU proximity.
    static let cpuKeys = [
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp0V", "Tp0Y", "Tp0e",
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Te05", "Te0L", "Te0P", "Te0S", "Te09", "Te0H",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        "TC0P", "TC0D", "TC0E", "TC0F",
    ]
    static let gpuKeys = [
        "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
        "Tg0G", "Tg0H", "Tg0K", "Tg0d", "Tg0e", "Tg0k", "Tg1U", "Tg1k",
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
        "TG0P", "TG0D",
    ]
    static let batteryKeys = ["TB1T", "TB2T", "TB0T"]

    private var present: (cpu: [String], gpu: [String], battery: [String], fans: Int)?

    public init() {}

    public mutating func sample() -> SensorReadings {
        let smc = SMC.shared
        if present == nil {
            present = (
                Self.cpuKeys.filter { smc.read($0) != nil },
                Self.gpuKeys.filter { smc.read($0) != nil },
                Self.batteryKeys.filter { smc.read($0) != nil },
                Int(smc.read("FNum") ?? 0)
            )
        }
        guard let present else { return SensorReadings() }

        func average(_ keys: [String]) -> Double? {
            // Unplugged or idle sensors read 0 (or nonsense); leave them out.
            let values = keys.compactMap { smc.read($0) }.filter { $0 > 1 && $0 < 130 }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        return SensorReadings(
            cpu: average(present.cpu),
            gpu: average(present.gpu),
            ssd: HIDTemperatures.average(matching: "NAND"),
            battery: average(present.battery),
            fans: (0..<present.fans).compactMap { index in
                guard let rpm = smc.read("F\(index)Ac") else { return nil }
                return Fan(rpm: rpm, minimum: smc.read("F\(index)Mn"), maximum: smc.read("F\(index)Mx"))
            }
        )
    }
}

/// Apple silicon's HID temperature sensors, reached through private
/// IOHIDEventSystemClient calls looked up at run time. Only the SSD's
/// "NAND" sensor is used: it isn't exposed through the SMC.
enum HIDTemperatures {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatValue = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15

    private struct API {
        let copyServices: CopyServices
        let copyProperty: CopyProperty
        let copyEvent: CopyEvent
        let getFloatValue: GetFloatValue
        let client: AnyObject
    }

    /// Nil when the private symbols aren't there (a future macOS).
    private static let api: API? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(iokit, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let getFloatValue = symbol("IOHIDEventGetFloatValue", as: GetFloatValue.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Usage page 0xff00, usage 5: the temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        return API(copyServices: copyServices, copyProperty: copyProperty, copyEvent: copyEvent,
                   getFloatValue: getFloatValue, client: client)
    }()

    static func average(matching name: String) -> Double? {
        guard let api, let services = api.copyServices(api.client)?.takeRetainedValue() as? [AnyObject] else { return nil }
        let values = services.compactMap { service -> Double? in
            guard let product = api.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  product.contains(name),
                  let event = api.copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return api.getFloatValue(event, Int32(temperatureEvent << 16))
        }
        .filter { $0 > 1 && $0 < 130 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
