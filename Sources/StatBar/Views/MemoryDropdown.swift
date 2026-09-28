import StatKit
import SwiftUI

struct MemoryDropdown: View {
    @EnvironmentObject var monitor: Monitor
    @Environment(\.panelTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            if let memory = monitor.memory {
                let total = Double(max(memory.total, 1))
                SectionBox {
                    HStack {
                        GaugeRing(
                            segments: [(memory.pressureFraction, pressureColor(memory.pressure))],
                            value: Format.percent(memory.pressureFraction), caption: "Pressure"
                        )
                        .frame(maxWidth: .infinity)
                        GaugeRing(
                            segments: [
                                (Double(memory.app) / total, theme.secondary),
                                (Double(memory.wired) / total, theme.primary),
                                (Double(memory.compressed) / total, theme.accent),
                            ],
                            value: Format.percent(memory.usedFraction), caption: "Memory"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                }

                SectionBox {
                    VStack(spacing: 4) {
                        LegendRow(color: theme.secondary, label: "App", value: Format.bytes(memory.app))
                        LegendRow(color: theme.primary, label: "Wired", value: Format.bytes(memory.wired))
                        LegendRow(color: theme.accent, label: "Compressed", value: Format.bytes(memory.compressed))
                        LegendRow(color: theme.header.opacity(0.5), label: "Free", value: Format.bytes(memory.free))
                    }
                }

                SectionBox {
                    VStack(spacing: 4) {
                        LegendRow(label: "Cached Files", value: Format.bytes(memory.cached))
                        LegendRow(label: "Swap Used", value: memory.swapTotal > 0 ? Format.bytes(memory.swapUsed) : "None")
                        LegendRow(label: "Total", value: Format.bytes(memory.total))
                    }
                }
            }

            ProcessTable(processes: monitor.top(.memory) { Double($0.memory) }) { [Format.bytes($0.memory)] }
            ShortcutBar(apps: [AppPath.activityMonitor, AppPath.terminal, AppPath.console])
        }
    }

    private func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return theme.secondary
        case .warning: return Color(hex: 0xFFD60A)
        case .critical: return theme.critical
        }
    }
}
