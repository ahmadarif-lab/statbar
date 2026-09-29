import AppKit
import Combine
import SwiftUI

/// The menu bar items, like iStat Menus, each slot opening its own
/// dropdown anchored below it.
///
/// The items are plain NSStatusItems rather than SwiftUI MenuBarExtras:
/// MenuBarExtra's visibility binding looped on macOS 27, and its buttons
/// carry padding that can't be trimmed.
///
/// Grouped (the default), every slot is drawn side by side in one status
/// item: macOS places each status item on its own, so separate items drift
/// apart and other apps' items end up wedged between them. A click is mapped
/// back to the slot under it. Ungrouped, each slot gets its own status item.
///
/// macOS remembers where each status item sits, by name, and puts it back
/// there -- whatever order they're created in, and not always in the order
/// they were last left in once items come and go. So ungrouped items are
/// interchangeable: every refresh reads where each actually sits and gives
/// the leftmost the first slot in the Settings order, and so on.
@MainActor
final class StatusBarController: NSObject {
    private let monitor: Monitor
    /// Interchangeable NSStatusItems, not yet tied to a slot.
    private var statusItems: [NSStatusItem] = []
    /// Whether `statusItems` were built as one grouped item.
    private var itemsGrouped = false
    /// Status items as they sit in the menu bar, left to right; `itemSlots`
    /// and `itemSlotFrames` line up with this.
    private var orderedItems: [NSStatusItem] = []
    /// The slots each status item draws, left to right.
    private var itemSlots: [[MenuBarSlot]] = []
    /// Each slot's horizontal extent within its status item's image.
    private var itemSlotFrames: [[ClosedRange<CGFloat>]] = []
    private var subscriptions: Set<AnyCancellable> = []

    private var panel: DropdownPanel?
    private var openItem: MenuBarSlot?
    private var outsideClickMonitor: Any?
    /// When the open panel last closed. A click on a status item already
    /// closes the panel (as an outside click, or by taking its focus) before
    /// the click itself arrives; without this, clicking the open slot would
    /// reopen it instead of toggling it shut.
    private var lastDismissal: (item: MenuBarSlot, time: Date)?

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        // The monitor publishes several values per tick; one redraw covers them.
        monitor.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        refresh()
    }

    private func refresh() {
        let defaults = UserDefaults.standard
        let grouped = defaults.bool(forKey: SettingsKey.groupItems)
        let layout = defaults.menuBarSlots
        let groups = grouped ? (layout.isEmpty ? [] : [layout]) : layout.map { [$0] }
        if groups.count != statusItems.count || grouped != itemsGrouped {
            rebuildItems(count: groups.count, grouped: grouped)
        }
        let positioned = itemsLeftToRight()
        let slots = groups.map { $0.map(\.slot) }
        if slots != itemSlots || positioned != orderedItems { close() }
        orderedItems = positioned
        itemSlots = slots
        itemSlotFrames = []

        let showGraph = defaults.bool(forKey: SettingsKey.cpuGraph)
        let padding = CGFloat(defaults.double(forKey: SettingsKey.itemPadding))
        for (statusItem, group) in zip(orderedItems, groups) {
            // CPU and GPU share a slot, a small gap apart; grouped slots
            // stand further apart, the padding on either side standing in
            // for the gap macOS puts between separate status items.
            let rendered = MenuBarRenderer.render(
                group.map(\.items), monitor: monitor, showCPUGraph: showGraph,
                itemSpacing: 5, slotSpacing: 8 + padding * 2
            )
            itemSlotFrames.append(rendered.frames)
            guard let button = statusItem.button else { continue }
            if button.image !== rendered.image { button.image = rendered.image }
            button.setAccessibilityLabel("StatBar " + group.map(\.slot.title).joined(separator: ", "))
            // A fixed length trims the button's built-in side padding, so
            // neighbouring readouts sit close together.
            let length = ceil(rendered.image.size.width + padding * 2)
            if statusItem.length != length { statusItem.length = length }
        }
    }

    /// The status items in their on-screen order. Until macOS has placed
    /// them all (a zero-width window), creation order stands in.
    private func itemsLeftToRight() -> [NSStatusItem] {
        let frames = statusItems.map { $0.button?.window?.frame ?? .zero }
        guard frames.allSatisfy({ $0.width > 0 }) else { return statusItems }
        return statusItems.indices
            .sorted { (frames[$0].minX, $0) < (frames[$1].minX, $1) }
            .map { statusItems[$0] }
    }

    /// Recreates the status items when their number or the grouping
    /// changes. On first appearance macOS puts each new status item to the
    /// left of the existing ones, so they're created right to left. The
    /// grouped item reuses the first one's name, so it keeps where the user
    /// last put it.
    private func rebuildItems(count: Int, grouped: Bool) {
        close()
        for statusItem in statusItems {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        var created: [NSStatusItem] = []
        for index in (0..<count).reversed() {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = "StatBar.slot\(index)"
            statusItem.isVisible = true
            if let button = statusItem.button {
                button.target = self
                button.action = #selector(clicked(_:))
                button.sendAction(on: [.leftMouseDown, .rightMouseDown])
                button.imagePosition = .imageOnly
            }
            created.insert(statusItem, at: 0)
        }
        statusItems = created
        itemsGrouped = grouped
        orderedItems = []
        itemSlots = []
        itemSlotFrames = []
    }

    /// Where the image starts inside the button; the button centers it.
    private func imageOffset(in button: NSStatusBarButton) -> CGFloat {
        ((button.bounds.width - (button.image?.size.width ?? 0)) / 2).rounded(.down)
    }

    /// The slot under a click, snapping to the nearest one when the click
    /// lands in the gap between two (or the button's padding).
    private func slotIndex(at x: CGFloat, in frames: [ClosedRange<CGFloat>]) -> Int? {
        guard !frames.isEmpty else { return nil }
        func distance(_ frame: ClosedRange<CGFloat>) -> CGFloat {
            frame.contains(x) ? 0 : min(abs(x - frame.lowerBound), abs(x - frame.upperBound))
        }
        return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
    }

    // MARK: - Clicks

    @objc private func clicked(_ button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            showContextMenu(from: button)
            return
        }
        guard let position = orderedItems.firstIndex(where: { $0.button === button }),
              itemSlots.indices.contains(position), itemSlotFrames.indices.contains(position) else { return }
        let slots = itemSlots[position]
        let frames = itemSlotFrames[position]
        // The event's own location is the button's center, not where the
        // click landed, so read the cursor itself.
        let x = NSEvent.mouseLocation.x - (button.window?.frame.minX ?? 0) - imageOffset(in: button)
        guard let index = slotIndex(at: x, in: frames), slots.indices.contains(index) else { return }
        let item = slots[index]
        if openItem == item {
            close()
            return
        }
        if let lastDismissal, lastDismissal.item == item, Date().timeIntervalSince(lastDismissal.time) < 0.3 {
            return
        }
        open(item, at: frames[index].lowerBound, from: button)
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        close()
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit StatBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    // MARK: - Dropdown

    /// `slotX` is where the slot starts in the button's image.
    private func open(_ item: MenuBarSlot, at slotX: CGFloat, from button: NSStatusBarButton) {
        close()
        guard let window = button.window else { return }
        // Left edge lined up with the slot (the item's own edge for the
        // first one), top a few points below the bar.
        let anchorX = slotX > 0 ? window.frame.minX + imageOffset(in: button) + slotX : window.frame.minX
        let panel = DropdownPanel(
            content: Dropdown { Self.dropdown(for: item) }.environmentObject(monitor),
            anchor: NSPoint(x: anchorX, y: window.frame.minY - 3),
            screen: window.screen
        )
        panel.onResignKey = { [weak self] in
            guard let self, self.openItem == item else { return }
            self.close()
        }
        panel.onEscape = { [weak self] in self?.close() }
        panel.show()

        self.panel = panel
        openItem = item
        button.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        if let openItem {
            lastDismissal = (openItem, Date())
            for statusItem in statusItems { statusItem.button?.highlight(false) }
        }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        panel?.onResignKey = nil
        panel?.dismiss()
        panel = nil
        openItem = nil
    }

    @ViewBuilder
    static func dropdown(for slot: MenuBarSlot) -> some View {
        switch slot {
        case .cpuGPU: CPUDropdown()
        case .memory: MemoryDropdown()
        case .network: NetworkDropdown()
        case .disk: DiskDropdown()
        case .battery: BatteryDropdown()
        }
    }
}

/// Borderless panel hanging under the menu bar. It can take key status
/// (for Escape) without activating StatBar, so the app in front keeps focus.
final class DropdownPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onEscape: (() -> Void)?
    private let anchor: NSPoint
    private let visibleFrame: NSRect

    init<Content: View>(content: Content, anchor: NSPoint, screen: NSScreen?) {
        self.anchor = anchor
        visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false

        var resize: (CGSize) -> Void = { _ in }
        let hosting = NSHostingView(rootView:
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .fixedSize()
                // The process list fills in after opening; follow its height.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    DispatchQueue.main.async { resize(size) }
                }
        )
        contentView = hosting
        resize = { [weak self] size in self?.place(size) }
        place(hosting.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    func show() {
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
        // Tear the SwiftUI tree down so the dropdown's onDisappear runs.
        contentView = nil
    }

    /// Top edge pinned under the menu bar, kept inside the screen.
    private func place(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let x = min(max(anchor.x, visibleFrame.minX + 4), visibleFrame.maxX - size.width - 4)
        setFrame(NSRect(x: x, y: anchor.y - size.height, width: size.width, height: size.height), display: true)
        invalidateShadow()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}


