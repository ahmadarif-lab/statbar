import AppKit
import Combine
import SwiftUI

/// One status item per shown readout, like iStat Menus, each opening its
/// own dropdown anchored below it.
///
/// The items are plain NSStatusItems rather than SwiftUI MenuBarExtras:
/// MenuBarExtra's visibility binding looped on macOS 27, and its buttons
/// carry padding that can't be trimmed.
///
/// macOS remembers where each status item sits, by name, and puts it back
/// there -- whatever order they're created in, and not always in the order
/// they were last left in once slots come and go. So the status items are
/// interchangeable slots: every refresh reads where each actually sits and
/// gives the leftmost the first readout in the Settings order, and so on.
@MainActor
final class StatusBarController: NSObject {
    private let monitor: Monitor
    /// Left to right.
    private var slots: [NSStatusItem] = []
    /// The readout each slot shows, left to right.
    /// Slots as they sit in the menu bar, left to right; `slotKinds` and
    /// `slotItems` line up with this.
    private var orderedSlots: [NSStatusItem] = []
    private var slotKinds: [MenuBarSlot] = []
    /// The items each slot draws, left to right.
    private var slotItems: [[StatItem]] = []
    private var subscriptions: Set<AnyCancellable> = []

    private var panel: DropdownPanel?
    private var openItem: MenuBarSlot?
    private var outsideClickMonitor: Any?
    /// When the open panel last closed. A click on a status item already
    /// closes the panel (as an outside click, or by taking its focus) before
    /// the click itself arrives; without this, clicking the open item would
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
        let layout = defaults.menuBarSlots
        let kinds = layout.map(\.slot)
        let items = layout.map(\.items)
        if kinds.count != slots.count { rebuildSlots(count: kinds.count) }
        let positioned = slotsLeftToRight()
        if kinds != slotKinds || positioned != orderedSlots { close() }
        orderedSlots = positioned
        slotKinds = kinds
        slotItems = items

        let showGraph = defaults.bool(forKey: SettingsKey.cpuGraph)
        let padding = CGFloat(defaults.double(forKey: SettingsKey.itemPadding))
        for (index, slot) in orderedSlots.enumerated() where index < slotItems.count {
            // CPU and GPU share a slot, a small gap apart.
            let image = MenuBarRenderer.render(slotItems[index], monitor: monitor, showCPUGraph: showGraph, itemSpacing: 5).image
            guard let button = slot.button else { continue }
            if button.image !== image { button.image = image }
            button.tag = index
            button.setAccessibilityLabel("StatBar \(slotKinds[index].title)")
            // A fixed length trims the button's built-in side padding, so
            // neighbouring readouts sit close together.
            let length = ceil(image.size.width + padding * 2)
            if slot.length != length { slot.length = length }
        }
    }

    /// The slots in their on-screen order. Until macOS has placed them all
    /// (a zero-width window), creation order stands in.
    private func slotsLeftToRight() -> [NSStatusItem] {
        let frames = slots.map { $0.button?.window?.frame ?? .zero }
        guard frames.allSatisfy({ $0.width > 0 }) else { return slots }
        return slots.indices
            .sorted { (frames[$0].minX, $0) < (frames[$1].minX, $1) }
            .map { slots[$0] }
    }

    /// Recreates the slots when the number of shown readouts changes. On
    /// first appearance macOS puts each new status item to the left of the
    /// existing ones, so they're created right to left.
    private func rebuildSlots(count: Int) {
        close()
        for slot in slots {
            NSStatusBar.system.removeStatusItem(slot)
        }
        var created: [NSStatusItem] = []
        for index in (0..<count).reversed() {
            let slot = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            slot.autosaveName = "StatBar.slot\(index)"
            slot.isVisible = true
            if let button = slot.button {
                button.target = self
                button.action = #selector(clicked(_:))
                button.sendAction(on: [.leftMouseDown, .rightMouseDown])
                button.imagePosition = .imageOnly
                button.tag = index
            }
            created.insert(slot, at: 0)
        }
        slots = created
        orderedSlots = []
        slotKinds = []
        slotItems = []
    }

    // MARK: - Clicks

    @objc private func clicked(_ button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, slotKinds.indices.contains(button.tag) else { return }
        let item = slotKinds[button.tag]
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            showContextMenu(from: button)
            return
        }
        if openItem == item {
            close()
            return
        }
        if let lastDismissal, lastDismissal.item == item, Date().timeIntervalSince(lastDismissal.time) < 0.3 {
            return
        }
        open(item, from: button)
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

    private func open(_ item: MenuBarSlot, from button: NSStatusBarButton) {
        close()
        guard let window = button.window else { return }
        let panel = DropdownPanel(
            content: Dropdown { Self.dropdown(for: item) }.environmentObject(monitor),
            // Left edge lined up with the item, top a few points below the bar.
            anchor: NSPoint(x: window.frame.minX, y: window.frame.minY - 3),
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
            if let index = slotKinds.firstIndex(of: openItem), orderedSlots.indices.contains(index) {
                orderedSlots[index].button?.highlight(false)
            }
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


