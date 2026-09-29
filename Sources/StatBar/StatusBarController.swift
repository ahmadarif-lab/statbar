import AppKit
import Combine
import SwiftUI

/// A single status item showing every readout side by side, like iStat
/// Menus, each slot opening its own dropdown anchored below it.
///
/// It's a plain NSStatusItem rather than a SwiftUI MenuBarExtra:
/// MenuBarExtra's visibility binding looped on macOS 27, and its buttons
/// carry padding that can't be trimmed.
///
/// One item rather than one per slot: macOS places each status item on its
/// own, so separate items drift apart and other apps' items end up wedged
/// between them. Drawn as one strip, the readouts always stay together, in
/// Settings order; a click is mapped back to its slot.
@MainActor
final class StatusBarController: NSObject {
    private let monitor: Monitor
    private let statusItem: NSStatusItem
    /// The slots drawn, left to right; lines up with `slotFrames`.
    private var slotKinds: [MenuBarSlot] = []
    /// Each slot's horizontal extent within the item's image.
    private var slotFrames: [ClosedRange<CGFloat>] = []
    private var subscriptions: Set<AnyCancellable> = []

    private var panel: DropdownPanel?
    private var openItem: MenuBarSlot?
    private var outsideClickMonitor: Any?
    /// When the open panel last closed. A click on the status item already
    /// closes the panel (as an outside click, or by taking its focus) before
    /// the click itself arrives; without this, clicking the open slot would
    /// reopen it instead of toggling it shut.
    private var lastDismissal: (item: MenuBarSlot, time: Date)?

    init(monitor: Monitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Reuses the first per-slot item's name so the item keeps where the
        // user last put it.
        statusItem.autosaveName = "StatBar.slot0"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
        }
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
        guard let button = statusItem.button else { return }
        let defaults = UserDefaults.standard
        let layout = defaults.menuBarSlots
        let kinds = layout.map(\.slot)
        if kinds != slotKinds { close() }
        slotKinds = kinds

        let padding = CGFloat(defaults.double(forKey: SettingsKey.itemPadding))
        // CPU and GPU share a slot, a small gap apart; slots stand further
        // apart, the padding on either side standing in for the gap macOS
        // used to put between separate status items.
        let rendered = MenuBarRenderer.render(
            layout.map(\.items), monitor: monitor,
            showCPUGraph: defaults.bool(forKey: SettingsKey.cpuGraph),
            itemSpacing: 5, slotSpacing: 8 + padding * 2
        )
        slotFrames = rendered.frames
        if button.image !== rendered.image { button.image = rendered.image }
        button.setAccessibilityLabel("StatBar " + kinds.map(\.title).joined(separator: ", "))
        // A fixed length trims the button's built-in side padding.
        let length = ceil(rendered.image.size.width + padding * 2)
        if statusItem.length != length { statusItem.length = length }
    }

    /// Where the image starts inside the button; the button centers it.
    private func imageOffset(in button: NSStatusBarButton) -> CGFloat {
        ((button.bounds.width - (button.image?.size.width ?? 0)) / 2).rounded(.down)
    }

    /// The slot under a click, snapping to the nearest one when the click
    /// lands in the gap between two (or the button's padding).
    private func slotIndex(at x: CGFloat) -> Int? {
        guard !slotFrames.isEmpty else { return nil }
        func distance(_ frame: ClosedRange<CGFloat>) -> CGFloat {
            frame.contains(x) ? 0 : min(abs(x - frame.lowerBound), abs(x - frame.upperBound))
        }
        return slotFrames.indices.min { distance(slotFrames[$0]) < distance(slotFrames[$1]) }
    }

    // MARK: - Clicks

    @objc private func clicked(_ button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            showContextMenu(from: button)
            return
        }
        // The event's own location is the button's center, not where the
        // click landed, so read the cursor itself.
        let x = NSEvent.mouseLocation.x - (button.window?.frame.minX ?? 0) - imageOffset(in: button)
        guard let index = slotIndex(at: x), slotKinds.indices.contains(index) else { return }
        let item = slotKinds[index]
        if openItem == item {
            close()
            return
        }
        if let lastDismissal, lastDismissal.item == item, Date().timeIntervalSince(lastDismissal.time) < 0.3 {
            return
        }
        open(item, at: index, from: button)
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

    private func open(_ item: MenuBarSlot, at index: Int, from button: NSStatusBarButton) {
        close()
        guard let window = button.window else { return }
        // Left edge lined up with the slot, top a few points below the bar.
        let slotX = slotFrames.indices.contains(index) && index > 0
            ? window.frame.minX + imageOffset(in: button) + slotFrames[index].lowerBound
            : window.frame.minX
        let panel = DropdownPanel(
            content: Dropdown { Self.dropdown(for: item) }.environmentObject(monitor),
            anchor: NSPoint(x: slotX, y: window.frame.minY - 3),
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
            statusItem.button?.highlight(false)
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


