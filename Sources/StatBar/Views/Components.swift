import AppKit
import StatKit
import SwiftUI

// MARK: - Dropdown chrome

/// Wraps a dropdown's sections: themed background, fixed width, and the
/// bookkeeping that lets the monitor scan processes only while visible.
struct Dropdown<Content: View>: View {
    @EnvironmentObject var monitor: Monitor
    @AppStorage(SettingsKey.theme) private var themeID = PanelTheme.systemID
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    static var width: CGFloat { 300 }

    var body: some View {
        let theme = PanelTheme.resolve(themeID, colorScheme: colorScheme)
        VStack(spacing: 6) {
            content
        }
        .padding(6)
        .frame(width: Self.width)
        .background(theme.background)
        .foregroundStyle(theme.text)
        .environment(\.panelTheme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear { monitor.viewerAppeared() }
        .onDisappear { monitor.viewerDisappeared() }
    }
}

/// Rounded box with an optional uppercase header and a trailing figure.
struct SectionBox<Content: View>: View {
    @Environment(\.panelTheme) private var theme
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.header)
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                    }
                }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.section))
    }
}

/// A header-only section: "LOAD ........ 1.2 0.9 0.8".
struct InfoLine: View {
    var title: String
    var value: String

    var body: some View {
        SectionBox(title, trailing: value) { EmptyView() }
    }
}

// MARK: - Text

/// "4.6 GB" with the number at full size and the unit smaller, the way
/// iStat Menus sets its figures.
struct UnitText: View {
    var text: String
    var size: CGFloat = 12
    var weight: Font.Weight = .regular

    var body: some View {
        let (number, unit) = Self.split(text)
        (Text(number).font(.system(size: size, weight: weight))
            + Text(unit.isEmpty ? "" : (unit == "%" ? unit : "\u{2009}" + unit))
                .font(.system(size: size * 0.68, weight: weight)))
            .monospacedDigit()
            .lineLimit(1)
    }

    static func split(_ text: String) -> (String, String) {
        let numeric = Set("0123456789.,-–:")
        let number = String(text.prefix { numeric.contains($0) })
        let unit = text.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        return number.isEmpty ? (text, "") : (number, unit)
    }
}

struct LegendRow: View {
    @Environment(\.panelTheme) private var theme
    var color: Color?
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 5) {
            if let color {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 6)
            UnitText(text: value)
        }
    }
}

/// Two legend entries side by side: "● User 19%   ● System 4%".
struct LegendPair: View {
    var left: (color: Color, label: String, value: String)
    var right: (color: Color, label: String, value: String)

    var body: some View {
        HStack(spacing: 14) {
            LegendRow(color: left.color, label: left.label, value: left.value)
            LegendRow(color: right.color, label: right.label, value: right.value)
        }
    }
}

/// Big centred figure over a dot + caption, e.g. "8.8 MB/s" / "● Read".
struct Headline: View {
    var value: String
    var color: Color
    var caption: String

    var body: some View {
        VStack(spacing: 1) {
            UnitText(text: value, size: 22, weight: .regular)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(caption).font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Charts

/// Thin vertical bars, newest on the right, stacked when there's more than
/// one series. Empty slots show as a dotted baseline.
struct BarHistory: View {
    @Environment(\.panelTheme) private var theme
    var series: [[Double]]
    var colors: [Color]
    var maxValue: Double = 1
    var capacity = Monitor.historyLength

    var body: some View {
        Canvas { context, size in
            let slot = size.width / CGFloat(capacity)
            let barWidth = max(1, slot * 0.62)
            let count = series.map(\.count).min() ?? 0
            for index in 0..<capacity {
                let x = CGFloat(index) * slot + (slot - barWidth) / 2
                let sample = index - (capacity - count)
                guard sample >= 0 else {
                    context.fill(Path(CGRect(x: x, y: size.height - 1, width: barWidth, height: 1)), with: .color(theme.track))
                    continue
                }
                var top = size.height
                for (values, color) in zip(series, colors) {
                    let height = size.height * CGFloat(min(max(values[sample] / maxValue, 0), 1))
                    guard height > 0 else { continue }
                    let drawn = min(height, top)
                    context.fill(Path(CGRect(x: x, y: top - drawn, width: barWidth, height: drawn)), with: .color(color))
                    top -= drawn
                }
                if top == size.height {
                    context.fill(Path(CGRect(x: x, y: size.height - 1, width: barWidth, height: 1)), with: .color(theme.track))
                }
            }
        }
    }
}

/// Up series above a dashed centre line, down series below it -- the
/// network and disk activity graph.
struct MirroredBars: View {
    @Environment(\.panelTheme) private var theme
    var up: [Double]
    var down: [Double]
    var upColor: Color
    var downColor: Color
    var capacity = Monitor.historyLength

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let slot = size.width / CGFloat(capacity)
            let barWidth = max(1, slot * 0.62)
            // Shared scale so the two halves compare honestly; a floor keeps
            // idle noise from filling the graph.
            let peak = max(up.max() ?? 0, down.max() ?? 0, 16_384)

            var dash = Path()
            dash.move(to: CGPoint(x: 0, y: mid))
            dash.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(dash, with: .color(theme.track), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))

            func draw(_ values: [Double], _ color: Color, upward: Bool) {
                for (index, value) in values.suffix(capacity).enumerated() {
                    let slotIndex = capacity - min(values.count, capacity) + index
                    let height = (mid - 1) * CGFloat(min(value / peak, 1))
                    guard height >= 0.5 else { continue }
                    let x = CGFloat(slotIndex) * slot + (slot - barWidth) / 2
                    let rect = upward
                        ? CGRect(x: x, y: mid - height, width: barWidth, height: height)
                        : CGRect(x: x, y: mid, width: barWidth, height: height)
                    context.fill(Path(rect), with: .color(color))
                }
            }
            draw(up, upColor, upward: true)
            draw(down, downColor, upward: false)
        }
    }
}

/// Circular gauge made of coloured arcs over a track, with any view in the
/// middle.
struct Ring<Center: View>: View {
    @Environment(\.panelTheme) private var theme
    var segments: [(fraction: Double, color: Color)]
    var lineWidth: CGFloat
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: lineWidth)
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .padding(lineWidth / 2)
    }

    private var arcs: [(start: Double, end: Double, color: Color)] {
        var start = 0.0
        return segments.map { segment in
            let end = min(start + max(segment.fraction, 0), 1)
            defer { start = end }
            return (start, end, segment.color)
        }
    }
}

/// Big ring with a percentage and a caption inside, as on the memory and
/// battery dropdowns.
struct GaugeRing: View {
    @Environment(\.panelTheme) private var theme
    var segments: [(fraction: Double, color: Color)]
    var value: String
    var caption: String
    var size: CGFloat = 112

    var body: some View {
        Ring(segments: segments, lineWidth: size * 0.075) {
            VStack(spacing: 0) {
                UnitText(text: value, size: size * 0.26, weight: .regular)
                Text(caption.uppercased())
                    .font(.system(size: size * 0.1, weight: .medium))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Processes

struct ProcessTable: View {
    @Environment(\.panelTheme) private var theme
    var processes: [ProcessUsage]
    /// Column headers shown right-aligned in the section header, e.g. R / W.
    var columns: [String] = []
    var values: (ProcessUsage) -> [String]

    var body: some View {
        SectionBox {
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    Text("PROCESSES")
                    Spacer()
                    ForEach(columns, id: \.self) { column in
                        Text(column).frame(width: 52, alignment: .trailing)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.header)
                .padding(.bottom, 4)
                if processes.isEmpty {
                    Text("Measuring…")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(processes) { process in
                    let app = NSRunningApplication(processIdentifier: process.pid)
                    HStack(spacing: 6) {
                        Image(nsImage: app?.icon ?? NSWorkspace.shared.icon(for: .unixExecutable))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(app?.localizedName ?? process.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        HStack(spacing: 0) {
                            ForEach(Array(values(process).enumerated()), id: \.offset) { _, value in
                                UnitText(text: value)
                                    .frame(width: columns.isEmpty ? nil : 52, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shortcuts

/// Bottom row of app shortcuts, plus StatBar's own settings.
struct ShortcutBar: View {
    @EnvironmentObject var monitor: Monitor
    @Environment(\.panelTheme) private var theme
    var apps: [String]

    var body: some View {
        HStack {
            ForEach(apps, id: \.self) { path in
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(FileManager.default.displayName(atPath: path))
                .frame(maxWidth: .infinity)
            }
            Button {
                SettingsWindow.show()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.header)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("StatBar Settings")
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.section))
    }
}

enum AppPath {
    static let activityMonitor = "/System/Applications/Utilities/Activity Monitor.app"
    static let console = "/System/Applications/Utilities/Console.app"
    static let terminal = "/System/Applications/Utilities/Terminal.app"
    static let diskUtility = "/System/Applications/Utilities/Disk Utility.app"
    static let systemInformation = "/System/Applications/Utilities/System Information.app"
    static let systemSettings = "/System/Applications/System Settings.app"
}
