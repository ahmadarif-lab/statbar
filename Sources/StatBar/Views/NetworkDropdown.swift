import StatKit
import SwiftUI

struct NetworkDropdown: View {
    @EnvironmentObject var monitor: Monitor
    @Environment(\.panelTheme) private var theme
    @AppStorage(SettingsKey.publicIP) private var showPublicIP = true
    @AppStorage(SettingsKey.ping) private var showPing = true
    @AppStorage(SettingsKey.pingHost) private var pingHost = "1.1.1.1"
    // Re-render when the units change.
    @AppStorage(SettingsKey.networkUnits) private var units = "bytes"

    private func rate(_ value: Double) -> String { NetworkFormat.rate(value) }

    var body: some View {
        let network = monitor.network
        VStack(spacing: 6) {
            SectionBox {
                HStack {
                    Headline(value: rate(network?.bytesOutPerSecond ?? 0), color: theme.primary, caption: "Upload")
                    Headline(value: rate(network?.bytesInPerSecond ?? 0), color: theme.secondary, caption: "Download")
                }
                MirroredBars(
                    up: monitor.networkOutHistory.values, down: monitor.networkInHistory.values,
                    upColor: theme.primary, downColor: theme.secondary
                )
                .frame(height: 84)
                // Peaks over the graph's span, as iStat Menus shows them.
                HStack(spacing: 4) {
                    Text("Upload").foregroundStyle(theme.secondaryText)
                    UnitText(text: rate(monitor.networkOutHistory.peak))
                    Spacer()
                    Text("Download").foregroundStyle(theme.secondaryText)
                    UnitText(text: rate(monitor.networkInHistory.peak))
                }
                .font(.system(size: 12))
            }

            SectionBox {
                HStack(spacing: 6) {
                    Image(systemName: network?.isWiFi == true ? "wifi" : "cable.connector.horizontal")
                        .frame(width: 18)
                    Text(network?.interfaceName ?? (network?.interface == nil ? "Not Connected" : "Network"))
                        .font(.system(size: 12.5))
                    Spacer()
                    Text(network?.interface ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            if showPublicIP {
                PublicIPSection()
            }

            SectionBox("IP Address") {
                Text(network?.address ?? "–")
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }

            if showPing {
                InfoLine(title: "Ping \(pingHost)", value: pingText)
            }

            SectionBox("Since Boot") {
                VStack(spacing: 4) {
                    LegendRow(color: theme.primary, label: "Uploaded", value: Format.bytes(network?.totalOut ?? 0))
                    LegendRow(color: theme.secondary, label: "Downloaded", value: Format.bytes(network?.totalIn ?? 0))
                }
            }

            ShortcutBar(apps: [AppPath.activityMonitor, AppPath.systemSettings, AppPath.terminal])
        }
    }

    private var pingText: String {
        if let latency = monitor.latency { return "\(Int((latency * 1000).rounded())) ms" }
        return monitor.latencyFailed ? "Unreachable" : "…"
    }
}

/// Public address with the country's flag, where it appears to be, and a
/// button to look it up again.
private struct PublicIPSection: View {
    @EnvironmentObject var monitor: Monitor
    @Environment(\.panelTheme) private var theme

    var body: some View {
        let info = monitor.publicIP
        SectionBox("Public IP Address", trailing: info?.flag) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info?.address ?? placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(info == nil ? theme.secondaryText : theme.text)
                        .textSelection(.enabled)
                    if let location = info?.location {
                        Text(location)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.secondaryText)
                    }
                    if let organization = info?.organization {
                        Text(organization)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                Button {
                    monitor.refreshPublicIP()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.header)
                        .rotationEffect(.degrees(monitor.isFetchingPublicIP ? 180 : 0))
                        .animation(.easeInOut(duration: 0.4), value: monitor.isFetchingPublicIP)
                }
                .buttonStyle(.plain)
                .disabled(monitor.isFetchingPublicIP)
                .help("Look up the public address again")
            }
        }
    }

    private var placeholder: String {
        if monitor.network?.address == nil { return "Not connected" }
        return monitor.publicIPFailed ? "Couldn't look it up" : "Looking up…"
    }
}
