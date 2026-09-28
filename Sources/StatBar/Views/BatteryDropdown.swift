import StatKit
import SwiftUI

struct BatteryDropdown: View {
    @EnvironmentObject var monitor: Monitor
    @Environment(\.panelTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            if let battery = monitor.battery {
                SectionBox {
                    HStack {
                        GaugeRing(
                            segments: [(battery.level, battery.level < 0.2 && !battery.isPluggedIn ? theme.critical : theme.primary)],
                            value: Format.percent(battery.level), caption: timeCaption(battery)
                        )
                        .frame(maxWidth: .infinity)
                        if let health = battery.health {
                            GaugeRing(segments: [(health, theme.accent)], value: Format.percent(health), caption: "Health")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 4)
                }

                SectionBox {
                    VStack(spacing: 4) {
                        LegendRow(label: "Power Source", value: battery.isPluggedIn ? "Power Adapter" : "Battery")
                        LegendRow(label: "State", value: state(battery))
                        if let power = battery.power, abs(power) >= 0.05 {
                            LegendRow(label: power < 0 ? "Drawing" : "Charging At", value: String(format: "%.1f W", abs(power)))
                        }
                        if let watts = battery.adapterWatts {
                            LegendRow(label: "Adapter", value: "\(watts) W")
                        }
                        if let cycles = battery.cycleCount {
                            LegendRow(label: "Cycles", value: "\(cycles)")
                        }
                        if let temperature = battery.temperature {
                            LegendRow(label: "Temperature", value: String(format: "%.1f °C", temperature))
                        }
                    }
                }

                InfoLine(title: "Low Power Mode", value: SystemInfo.isLowPowerMode ? "On" : "Off")
            } else {
                SectionBox("Battery") {
                    Text("This Mac has no battery.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            ShortcutBar(apps: [AppPath.systemSettings, AppPath.activityMonitor])
        }
    }

    /// Time left as "6:16" -- to empty on battery, to full when charging.
    private func timeCaption(_ battery: BatteryInfo) -> String {
        if let minutes = battery.minutesRemaining {
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
        if battery.isCharging { return "Charging" }
        return battery.isPluggedIn ? "Plugged In" : "Battery"
    }

    private func state(_ battery: BatteryInfo) -> String {
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return battery.level >= 0.99 ? "Charged" : "Not Charging" }
        return "Discharging"
    }
}
