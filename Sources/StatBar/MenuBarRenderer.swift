import AppKit
import StatKit

/// Draws every shown menu bar item into one template image, and remembers
/// where each slot landed so a click can be routed to its dropdown.
///
/// One status item holding all readouts, rather than a status item per
/// readout, keeps them together: macOS places separate status items on
/// their own, so other apps' items end up wedged between them, and puts
/// its own wide gap between them. A template image lets macOS tint it for
/// light/dark menu bars and the highlighted state.
@MainActor
enum MenuBarRenderer {
    struct Rendered {
        let image: NSImage
        /// Horizontal extent of each slot within the image.
        let frames: [ClosedRange<CGFloat>]
    }

    private static let height: CGFloat = 22
    /// Between the pieces of one item (CPU graph and CPU figure).
    private static let innerSpacing: CGFloat = 3

    private static let captionFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    private struct Segment {
        var width: CGFloat
        /// What the segment shows, for the image cache.
        var key: String
        var draw: (CGFloat) -> Void
    }

    /// Returning the same image while the figures are unchanged saves the
    /// status button a redraw and re-layout on quiet ticks. Keyed by content
    /// so the settings preview (a different item set) doesn't evict the
    /// menu bar's entry.
    private static var cache: [String: Rendered] = [:]

    /// `slots` are drawn left to right, `slotSpacing` apart; the items
    /// within one slot (CPU and GPU) sit `itemSpacing` apart.
    static func render(_ slots: [[StatItem]], monitor: Monitor, showCPUGraph: Bool, itemSpacing: CGFloat, slotSpacing: CGFloat) -> Rendered {
        let groups = slots.map { items in
            items.map { ($0, segments(for: $0, monitor: monitor, showCPUGraph: showCPUGraph)) }
        }
        let key = "\(itemSpacing),\(slotSpacing)#" + groups.map { items in
            items.map { item, segments in
                item.rawValue + ":" + segments.map(\.key).joined(separator: "|")
            }.joined(separator: "/")
        }.joined(separator: "//")
        if let cached = cache[key] { return cached }

        var frames: [ClosedRange<CGFloat>] = []
        var starts: [[CGFloat]] = []
        var x: CGFloat = 0
        for (slotIndex, items) in groups.enumerated() {
            if slotIndex > 0 { x += slotSpacing }
            let slotStart = x
            var itemStarts: [CGFloat] = []
            for (index, (_, segments)) in items.enumerated() {
                if index > 0 { x += itemSpacing }
                itemStarts.append(x)
                x += segments.map(\.width).reduce(0, +) + innerSpacing * CGFloat(max(segments.count - 1, 0))
            }
            frames.append(slotStart...x)
            starts.append(itemStarts)
        }

        let image = NSImage(size: NSSize(width: max(ceil(x), 1), height: height), flipped: false) { _ in
            for (items, itemStarts) in zip(groups, starts) {
                for ((_, segments), start) in zip(items, itemStarts) {
                    var x = start
                    for segment in segments {
                        segment.draw(x)
                        x += segment.width + innerSpacing
                    }
                }
            }
            return true
        }
        image.isTemplate = true
        let rendered = Rendered(image: image, frames: frames)
        // Figures change every tick, so old entries are never hit again.
        if cache.count > 8 { cache.removeAll() }
        cache[key] = rendered
        return rendered
    }

    private static func segments(for item: StatItem, monitor: Monitor, showCPUGraph: Bool) -> [Segment] {
        switch item {
        case .cpu:
            var segments: [Segment] = []
            if showCPUGraph {
                let totals = zip(monitor.userHistory.values, monitor.systemHistory.values).map { $0 + $1 }
                segments.append(graph(totals.suffix(12)))
            }
            segments.append(stacked("CPU", Format.percent(monitor.cpu?.total)))
            if UserDefaults.standard.bool(forKey: SettingsKey.cpuTemperature) {
                segments.append(stacked("TEMP", TemperatureFormat.string(monitor.sensors?.cpu), widest: "100°"))
            }
            return segments
        case .gpu:
            return [stacked("GPU", Format.percent(monitor.gpu?.device))]
        case .memory:
            return [stacked("MEM", Format.percent(monitor.memory?.usedFraction))]
        case .network:
            return [rates(up: monitor.network?.bytesOutPerSecond ?? 0, down: monitor.network?.bytesInPerSecond ?? 0)]
        case .disk:
            return [stacked("SSD", Format.percent(monitor.disk?.usedFraction))]
        case .battery:
            return [stacked("BAT", Format.percent(monitor.battery?.level))]
        }
    }

    // MARK: - Segments

    /// Small caption over a value, e.g. "CPU" / "12%". The width is fixed
    /// to the widest value so the menu bar doesn't jitter as numbers change.
    private static func stacked(_ caption: String, _ value: String, widest: String = "100%") -> Segment {
        let captionText = text(caption, captionFont, alpha: 0.65)
        let valueText = text(value, valueFont)
        let width = ceil(max(text(widest, valueFont).size().width, captionText.size().width))
        return Segment(width: width, key: caption + value) { x in
            draw(captionText, centeredIn: NSRect(x: x, y: 12, width: width, height: 10))
            draw(valueText, centeredIn: NSRect(x: x, y: 0, width: width, height: 13))
        }
    }

    /// Upload over download in three fixed columns -- arrow, number and
    /// unit, the last two right-aligned -- so "B/s" stays put whether a
    /// K, M or G sits in front of it, and nothing shifts as digits change.
    private static func rates(up: Double, down: Double) -> Segment {
        let rows = [("↑", up, CGFloat(10.5)), ("↓", down, CGFloat(-0.5))].map { arrow, rate, y in
            let (number, unit) = split(NetworkFormat.rate(rate))
            return (text(arrow, rateFont), text(number, rateFont), text(unit, rateFont), y)
        }
        let arrowWidth = ceil(text("↓", rateFont).size().width)
        // 100+ rounds to a whole number ("123"), so "99.9" is the widest
        // the number column ever needs to hold.
        let numberWidth = ceil(text("99.9", rateFont).size().width)
        let unitWidth = ceil(["KB/s", "MB/s", "GB/s", "Kb/s", "Mb/s", "Gb/s"].map { text($0, rateFont).size().width }.max() ?? 0)
        let gap: CGFloat = 1.5
        let key = rows.map { $0.1.string + $0.2.string }.joined(separator: ",")
        return Segment(width: arrowWidth + gap + numberWidth + gap + unitWidth, key: key) { x in
            for (arrow, number, unit, y) in rows {
                arrow.draw(at: NSPoint(x: x, y: y))
                let numberRight = x + arrowWidth + gap + numberWidth
                number.draw(at: NSPoint(x: numberRight - number.size().width, y: y))
                unit.draw(at: NSPoint(x: numberRight + gap + unitWidth - unit.size().width, y: y))
            }
        }
    }

    /// "951 B/s" -> ("951", "B/s").
    private static func split(_ rate: String) -> (String, String) {
        guard let space = rate.firstIndex(of: " ") else { return (rate, "") }
        return (String(rate[..<space]), String(rate[rate.index(after: space)...]))
    }

    /// Recent CPU load as thin bars; empty slots on the left until the
    /// history fills up.
    private static func graph(_ values: ArraySlice<Double>) -> Segment {
        let bars = 12
        let barWidth: CGFloat = 1.5
        let gap: CGFloat = 0.5
        let width = CGFloat(bars) * (barWidth + gap) - gap
        let graphHeight: CGFloat = 16
        let bottom: CGFloat = 3
        let samples = Array(values)
        // Bars are at most 16 pt tall, so whole-point heights are all that
        // can differ on screen.
        let key = samples.map { String(Int((min(max($0, 0), 1) * graphHeight).rounded())) }.joined(separator: ",")
        return Segment(width: width, key: key) { x in
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSRect(x: x, y: bottom - 1, width: width, height: 0.75).fill()
            NSColor.black.setFill()
            for (index, value) in samples.enumerated() {
                let slot = bars - samples.count + index
                let barHeight = max(0.75, graphHeight * CGFloat(min(max(value, 0), 1)))
                NSRect(x: x + CGFloat(slot) * (barWidth + gap), y: bottom, width: barWidth, height: barHeight).fill()
            }
        }
    }

    // MARK: - Text

    private static func text(_ string: String, _ font: NSFont, alpha: CGFloat = 1) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor.black.withAlphaComponent(alpha),
        ])
    }

    private static func draw(_ text: NSAttributedString, centeredIn rect: NSRect) {
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + (rect.height - size.height) / 2))
    }
}
