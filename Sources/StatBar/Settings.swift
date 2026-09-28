import Foundation
import StatKit

/// One menu bar item. Each is its own status item with its own dropdown,
/// shown or hidden independently.
enum StatItem: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, network, disk, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .disk: return "Disks"
        case .battery: return "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .disk: return "internaldrive"
        case .battery: return "battery.75"
        }
    }

    /// UserDefaults key for "show in menu bar".
    var showKey: String { "show.\(rawValue)" }

    /// Parses a stored order. Unknown names are dropped and items missing
    /// from it (added in a later version) go on the end.
    static func decode(_ stored: String) -> [StatItem] {
        var order: [StatItem] = []
        for name in stored.split(separator: ",") {
            if let item = StatItem(rawValue: String(name)), !order.contains(item) { order.append(item) }
        }
        return order + allCases.filter { !order.contains($0) }
    }

    static func encode(_ items: [StatItem]) -> String {
        items.map(\.rawValue).joined(separator: ",")
    }

    var shownByDefault: Bool {
        switch self {
        case .cpu, .memory, .network: return true
        case .gpu, .disk, .battery: return false
        }
    }
}

/// A place in the menu bar. CPU and GPU share one: they open the same
/// dropdown, so their figures sit side by side in a single status item.
enum MenuBarSlot: String, CaseIterable, Identifiable {
    case cpuGPU, memory, network, disk, battery

    var id: String { rawValue }

    var items: [StatItem] {
        switch self {
        case .cpuGPU: return [.cpu, .gpu]
        case .memory: return [.memory]
        case .network: return [.network]
        case .disk: return [.disk]
        case .battery: return [.battery]
        }
    }

    var title: String {
        self == .cpuGPU ? "CPU & GPU" : items[0].title
    }

    var symbol: String { items[0].symbol }

    static func of(_ item: StatItem) -> MenuBarSlot {
        allCases.first { $0.items.contains(item) }!
    }

    /// Slots in the stored order; a slot sits where its first item does.
    static func decode(_ stored: String) -> [MenuBarSlot] {
        var slots: [MenuBarSlot] = []
        for item in StatItem.decode(stored) where !slots.contains(of(item)) {
            slots.append(of(item))
        }
        return slots
    }

    static func encode(_ slots: [MenuBarSlot]) -> String {
        StatItem.encode(slots.flatMap(\.items))
    }
}

enum SettingsKey {
    static let theme = "theme"
    static let cpuGraph = "cpu.menuBarGraph"
    static let cpuTemperature = "cpu.menuBarTemperature"
    /// A dropdown's own process count.
    static func processCount(for list: ProcessList) -> String { "processCount.\(list.rawValue)" }
    /// Points of padding on each side of a menu bar item.
    static let itemPadding = "menuBarItemPadding"
    /// Menu bar order, left to right, as "cpu,gpu,memory,...".
    static let itemOrder = "menuBarItemOrder"

    static let showInDock = "showInDock"
    static let autoCheckUpdates = "autoCheckUpdates"

    static let publicIP = "network.publicIP"
    /// "change", "10m" or "1h" -- see PublicIPRefresh.
    static let publicIPRefresh = "network.publicIPRefresh"
    /// "bytes" or "bits".
    static let networkUnits = "network.units"
    /// A BSD name, or "" to measure every interface.
    static let networkInterface = "network.interface"
    static let ping = "network.ping"
    static let pingHost = "network.pingHost"
}

enum TemperatureFormat {
    /// "50°".
    static func string(_ celsius: Double?) -> String {
        celsius.map { "\(Int($0.rounded()))°" } ?? "–"
    }
}

/// Metrics sampled together on one schedule, each with its own update
/// interval. GPU rides along with CPU, as they share a dropdown.
enum SampleGroup: String, CaseIterable {
    case cpu, memory, network, disk, battery

    var intervalKey: String { "updateInterval.\(rawValue)" }

    static let choices: [Double] = [1, 2, 5, 10]

    /// Seconds between samples, as set on the item's page.
    var interval: Double {
        max(UserDefaults.standard.double(forKey: intervalKey), 0.5)
    }
}

/// The dropdowns that list top processes.
enum ProcessList: String, CaseIterable {
    case cpu, memory, disk

    static let choices = [3, 5, 8, 10]
}

enum PublicIPRefresh: String, CaseIterable, Identifiable {
    case onChange = "change"
    case tenMinutes = "10m"
    case hourly = "1h"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onChange: return "When the network changes"
        case .tenMinutes: return "Every 10 minutes"
        case .hourly: return "Every hour"
        }
    }

    /// On top of refreshing whenever the local address changes.
    var interval: TimeInterval? {
        switch self {
        case .onChange: return nil
        case .tenMinutes: return 600
        case .hourly: return 3600
        }
    }
}

/// Network rates the way the user set them up: bytes or bits, always one
/// decimal so the readout keeps its shape.
enum NetworkFormat {
    static var usesBits: Bool {
        UserDefaults.standard.string(forKey: SettingsKey.networkUnits) == "bits"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        Format.rate(bytesPerSecond, oneDecimal: true, bits: usesBits)
    }
}

extension UserDefaults {
    /// Declares every default in one place so @AppStorage readers and
    /// plain UserDefaults reads agree before the user changes anything.
    static func registerStatBarDefaults() {
        var defaults: [String: Any] = [
            SettingsKey.theme: PanelTheme.systemID,
            SettingsKey.cpuGraph: false,
            SettingsKey.cpuTemperature: false,
            SettingsKey.processCount(for: .cpu): 5,
            SettingsKey.processCount(for: .memory): 5,
            SettingsKey.processCount(for: .disk): 5,
            SettingsKey.itemPadding: 2.0,
            SettingsKey.itemOrder: StatItem.encode(StatItem.allCases),
            SettingsKey.showInDock: false,
            SettingsKey.autoCheckUpdates: true,
            SettingsKey.publicIP: true,
            SettingsKey.publicIPRefresh: PublicIPRefresh.onChange.rawValue,
            SettingsKey.networkUnits: "bytes",
            SettingsKey.networkInterface: "",
            SettingsKey.ping: true,
            SettingsKey.pingHost: "1.1.1.1",
            SampleGroup.cpu.intervalKey: 1.0,
            SampleGroup.memory.intervalKey: 1.0,
            SampleGroup.network.intervalKey: 1.0,
            SampleGroup.disk.intervalKey: 1.0,
            SampleGroup.battery.intervalKey: 1.0,
        ]
        for item in StatItem.allCases {
            defaults[item.showKey] = item.shownByDefault
        }
        standard.register(defaults: defaults)
    }

    func isShown(_ item: StatItem) -> Bool { bool(forKey: item.showKey) }

    /// Every item, in the user's menu bar order.
    var itemOrder: [StatItem] { StatItem.decode(string(forKey: SettingsKey.itemOrder) ?? "") }

    /// The slots that have something shown, left to right, with the items
    /// each shows.
    var menuBarSlots: [(slot: MenuBarSlot, items: [StatItem])] {
        MenuBarSlot.decode(string(forKey: SettingsKey.itemOrder) ?? "").compactMap { slot in
            let items = slot.items.filter(isShown)
            return items.isEmpty ? nil : (slot, items)
        }
    }
}
