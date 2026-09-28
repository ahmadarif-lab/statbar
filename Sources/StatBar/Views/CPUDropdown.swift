import StatKit
import SwiftUI

/// CPU & GPU dropdown, opened from either the CPU or the GPU item.
struct CPUDropdown: View {
    @EnvironmentObject var monitor: Monitor
    @Environment(\.panelTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            SectionBox("CPU", trailing: cpuTrailing) {
                BarHistory(
                    series: [monitor.userHistory.values, monitor.systemHistory.values],
                    colors: [theme.primary, theme.accent]
                )
                .frame(height: 72)
                LegendPair(
                    left: (theme.primary, "User", Format.percent(monitor.cpu?.user)),
                    right: (theme.accent, "System", Format.percent(monitor.cpu?.system))
                )
            }

            if let cores = monitor.cpu?.cores, !cores.isEmpty {
                CoresSection(cores: cores)
            }

            ProcessTable(processes: monitor.top(.cpu) { $0.cpu }) { [Format.percent($0.cpu)] }

            if let gpu = monitor.gpu {
                SectionBox("GPU") {
                    HStack(spacing: 0) {
                        gauge(gpu.device, "GPU")
                        gauge(gpu.renderer, "Render")
                        GaugeRing(
                            segments: [(Double(gpu.memoryInUse) / Double(max(SystemInfo.physicalMemory, 1)), theme.accent)],
                            value: Format.bytes(gpu.memoryInUse), caption: "Mem", size: 60
                        )
                        .frame(maxWidth: .infinity)
                        if let temperature = monitor.sensors?.gpu {
                            temperatureGauge(temperature)
                        } else {
                            gauge(gpu.tiler, "Tiler")
                        }
                    }
                }
            }

            if let sensors = monitor.sensors, sensors.cpu != nil || sensors.gpu != nil {
                SensorsSection(sensors: sensors)
            }

            if monitor.loadAverage.count == 3 {
                InfoLine(title: "Load", value: monitor.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            }
            if let uptime = monitor.uptime {
                InfoLine(title: "Uptime", value: Format.longDuration(uptime))
            }
            ShortcutBar(apps: [AppPath.activityMonitor, AppPath.console, AppPath.terminal, AppPath.systemInformation])
        }
    }

    /// "26% · 50°", like iStat Menus' "3.85 GHz, 89°".
    private var cpuTrailing: String {
        let usage = Format.percent(monitor.cpu?.total)
        guard let temperature = monitor.sensors?.cpu else { return usage }
        return usage + " · " + TemperatureFormat.string(temperature)
    }

    /// Filled against 100 °C, warming from the theme colour to red.
    private func temperatureGauge(_ celsius: Double) -> some View {
        GaugeRing(
            segments: [(celsius / 100, celsius >= 85 ? theme.critical : celsius >= 70 ? Color(hex: 0xFFB020) : theme.primary)],
            value: TemperatureFormat.string(celsius), caption: "Temp", size: 60
        )
        .frame(maxWidth: .infinity)
    }

    private func gauge(_ fraction: Double, _ caption: String) -> some View {
        GaugeRing(segments: [(fraction, theme.primary)], value: Format.percent(fraction), caption: caption, size: 60)
            .frame(maxWidth: .infinity)
    }
}

/// One small ring per core, coloured by cluster, with the average load of
/// each cluster underneath.
private struct CoresSection: View {
    @Environment(\.panelTheme) private var theme
    let cores: [Double]

    private var kinds: [CoreKind]? {
        guard let kinds = SystemInfo.coreKinds, kinds.count == cores.count else { return nil }
        return kinds
    }

    private func color(_ index: Int) -> Color {
        kinds?[index] == .efficiency ? theme.accent : theme.primary
    }

    private func average(_ kind: CoreKind) -> Double? {
        guard let kinds else { return nil }
        let loads = zip(cores, kinds).filter { $0.1 == kind }.map(\.0)
        return loads.isEmpty ? nil : loads.reduce(0, +) / Double(loads.count)
    }

    var body: some View {
        SectionBox {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(cores.count, 7)), spacing: 8) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, load in
                    Ring(segments: [(load, color(index))], lineWidth: 3.5) { EmptyView() }
                        .frame(width: 28, height: 28)
                        .help("Core \(index + 1): \(Format.percent(load))")
                }
            }
            if let efficiency = average(.efficiency), let performance = average(.performance) {
                VStack(spacing: 3) {
                    LegendRow(color: theme.accent, label: "Efficiency Cores", value: Format.percent(efficiency))
                    LegendRow(color: theme.primary, label: "Performance Cores", value: Format.percent(performance))
                }
            }
        }
    }
}

/// Temperatures (and fans, on Macs that have them).
private struct SensorsSection: View {
    @Environment(\.panelTheme) private var theme
    let sensors: SensorReadings

    var body: some View {
        SectionBox("Sensors") {
            VStack(spacing: 4) {
                row("CPU", sensors.cpu)
                row("GPU", sensors.gpu)
                row("SSD", sensors.ssd)
                row("Battery", sensors.battery)
                ForEach(Array(sensors.fans.enumerated()), id: \.offset) { index, fan in
                    LegendRow(label: sensors.fans.count == 1 ? "Fan" : "Fan \(index + 1)",
                              value: fan.rpm < 1 ? "Off" : "\(Int(fan.rpm.rounded())) rpm")
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ celsius: Double?) -> some View {
        if let celsius {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12))
                Spacer()
                Text(TemperatureFormat.string(celsius))
                    .font(.system(size: 12))
                    .monospacedDigit()
                // A small bar against 100 °C.
                Capsule()
                    .fill(theme.track)
                    .frame(width: 44, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(celsius >= 85 ? theme.critical : celsius >= 70 ? Color(hex: 0xFFB020) : theme.primary)
                            .frame(width: 44 * min(max(celsius / 100, 0), 1), height: 4)
                    }
            }
        }
    }
}
