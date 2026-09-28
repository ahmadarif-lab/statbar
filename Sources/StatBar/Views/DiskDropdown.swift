import StatKit
import SwiftUI

struct DiskDropdown: View {
    @EnvironmentObject var monitor: Monitor
    @Environment(\.panelTheme) private var theme

    var body: some View {
        let disk = monitor.disk
        VStack(spacing: 6) {
            if let volumes = disk?.volumes, !volumes.isEmpty {
                SectionBox {
                    VStack(spacing: 8) {
                        ForEach(volumes) { volume in
                            VolumeRow(volume: volume)
                        }
                    }
                }
            }

            SectionBox {
                HStack {
                    Headline(value: Format.rate(disk?.readPerSecond ?? 0), color: theme.primary, caption: "Read")
                    Headline(value: Format.rate(disk?.writePerSecond ?? 0), color: theme.secondary, caption: "Write")
                }
                MirroredBars(
                    up: monitor.diskReadHistory.values, down: monitor.diskWriteHistory.values,
                    upColor: theme.primary, downColor: theme.secondary
                )
                .frame(height: 72)
                HStack {
                    Text("Read").foregroundStyle(theme.header)
                    UnitText(text: Format.bytes(disk?.totalRead ?? 0))
                    Spacer()
                    Text("Written").foregroundStyle(theme.header)
                    UnitText(text: Format.bytes(disk?.totalWritten ?? 0))
                }
                .font(.system(size: 12))
            }

            ProcessTable(processes: monitor.top(.disk) { $0.diskRead + $0.diskWrite }, columns: ["R", "W"]) {
                [compact($0.diskRead), compact($0.diskWrite)]
            }
            ShortcutBar(apps: [AppPath.diskUtility, AppPath.activityMonitor, AppPath.systemInformation])
        }
    }

    private func compact(_ rate: Double) -> String {
        rate < 1 ? "–" : Format.rate(rate, compact: true)
    }
}

private struct VolumeRow: View {
    @Environment(\.panelTheme) private var theme
    let volume: Volume

    var body: some View {
        HStack(spacing: 10) {
            Ring(
                segments: [(volume.usedFraction, volume.usedFraction >= 0.9 ? theme.critical : theme.primary)],
                lineWidth: 3
            ) {
                Text("\(Int((volume.usedFraction * 100).rounded()))")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(Format.bytes(volume.free)) available of \(Format.bytes(volume.total))")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
        }
    }
}
