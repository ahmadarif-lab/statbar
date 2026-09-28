import AppKit
import StatKit
import SwiftUI

/// Settings in a real NSWindow: a menu bar app has no main window for a
/// SwiftUI `Settings` scene to hang off, and the dropdown closes itself on
/// the same click that would present a sheet.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    /// The app's one monitor, handed over at launch so the app delegate can
    /// open settings too.
    static weak var monitor: Monitor?

    static func show() {
        guard let monitor else { return }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "StatBar Settings"
            // The centred title would straddle the preview and the options;
            // every page carries its own heading instead.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(monitor))
            window.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { close() }
            }
            self.window = window
        }
        applyDockPolicy()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drops the whole view tree so the preview's dropdown stops counting
    /// as open (and the process scan stops with it).
    private static func close() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window?.contentView = nil
        window = nil
        applyDockPolicy()
    }

    /// StatBar lives in the menu bar. With "Show icon in Dock" on it takes
    /// a Dock icon while this window is open, and drops it again when the
    /// window closes; with it off, never.
    static func applyDockPolicy() {
        let showInDock = UserDefaults.standard.bool(forKey: SettingsKey.showInDock)
        NSApp.setActivationPolicy(showInDock && window != nil ? .regular : .accessory)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, cpu, memory, network, disk, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .cpu: return "CPU & GPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .disk: return "Disks"
        case .battery: return "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .cpu: return StatItem.cpu.symbol
        case .memory: return StatItem.memory.symbol
        case .network: return StatItem.network.symbol
        case .disk: return StatItem.disk.symbol
        case .battery: return StatItem.battery.symbol
        }
    }

    var sampleGroup: SampleGroup? {
        switch self {
        case .general: return nil
        case .cpu: return .cpu
        case .memory: return .memory
        case .network: return .network
        case .disk: return .disk
        case .battery: return .battery
        }
    }

    /// The dropdown process list this page configures, if any.
    var processList: ProcessList? {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .disk: return .disk
        case .general, .network, .battery: return nil
        }
    }

    var items: [StatItem] {
        switch self {
        case .general: return []
        case .cpu: return [.cpu, .gpu]
        case .memory: return [.memory]
        case .network: return [.network]
        case .disk: return [.disk]
        case .battery: return [.battery]
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var monitor: Monitor
    @AppStorage(SettingsKey.theme) private var themeID = PanelTheme.systemID
    @Environment(\.colorScheme) private var colorScheme
    @State private var page = SettingsPage.general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            preview
            SettingsOptions(page: page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 640)
    }

    private var sidebar: some View {
        VStack(spacing: 6) {
            ForEach(SettingsPage.allCases) { item in
                Button {
                    page = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 19))
                            .frame(height: 24)
                        Text(item.title)
                            .font(.system(size: 10))
                    }
                    .frame(width: 70, height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(page == item ? Color.accentColor : Color.clear)
                    )
                    .foregroundStyle(page == item ? Color.white : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 40)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    /// The real dropdown for this page, live, in the chosen theme.
    private var preview: some View {
        let theme = PanelTheme.resolve(themeID, colorScheme: colorScheme)
        return ScrollView {
            Dropdown {
                switch page {
                case .general, .cpu: CPUDropdown()
                case .memory: MemoryDropdown()
                case .network: NetworkDropdown()
                case .disk: DiskDropdown()
                case .battery: BatteryDropdown()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
            .id(page)
        }
        .scrollIndicators(.never)
        .frame(width: Dropdown<EmptyView>.width + 48)
        .background(
            LinearGradient(
                colors: [theme.primary.opacity(0.55), theme.accent.opacity(0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}

private struct SettingsOptions: View {
    @EnvironmentObject var monitor: Monitor
    let page: SettingsPage

    @AppStorage(SettingsKey.theme) private var themeID = PanelTheme.systemID
    @AppStorage(SettingsKey.cpuGraph) private var cpuGraph = false
    @AppStorage(SettingsKey.cpuTemperature) private var cpuTemperature = false
    @AppStorage(SettingsKey.itemPadding) private var itemPadding = 2.0
    @AppStorage(SettingsKey.itemOrder) private var itemOrder = StatItem.encode(StatItem.allCases)
    @State private var compactSystemSpacing = SystemMenuBarSpacing.isCompact
    @AppStorage(StatItem.cpu.showKey) private var showCPU = StatItem.cpu.shownByDefault
    @AppStorage(StatItem.gpu.showKey) private var showGPU = StatItem.gpu.shownByDefault
    @AppStorage(StatItem.memory.showKey) private var showMemory = StatItem.memory.shownByDefault
    @AppStorage(StatItem.network.showKey) private var showNetwork = StatItem.network.shownByDefault
    @AppStorage(StatItem.disk.showKey) private var showDisk = StatItem.disk.shownByDefault
    @AppStorage(StatItem.battery.showKey) private var showBattery = StatItem.battery.shownByDefault
    @State private var startsAtLogin = LoginItem.isEnabled
    @AppStorage(SettingsKey.showInDock) private var showInDock = false
    @AppStorage(SettingsKey.autoCheckUpdates) private var autoCheckUpdates = true

    var body: some View {
        Form {
            if page == .general {
                generalSections
            } else {
                Section {
                    ForEach(page.items) { item in
                        Toggle("Show \(item.title)", isOn: shown(item))
                            .disabled(isLastShown(item))
                    }
                    if page == .cpu {
                        Toggle("History graph next to CPU", isOn: $cpuGraph)
                            .disabled(!showCPU)
                        Toggle("Temperature next to CPU", isOn: $cpuTemperature)
                            .disabled(!showCPU)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(page.title).font(.title2.bold()).foregroundStyle(.primary)
                        Text("Menu Bar")
                    }
                } footer: {
                    if page.items.contains(where: isLastShown) {
                        Text("One item always stays in the menu bar so StatBar can be reached.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Readings") {
                    if let group = page.sampleGroup {
                        UpdateIntervalPicker(group: group)
                    }
                    if let list = page.processList {
                        ItemProcessCountPicker(list: list)
                    }
                    if page == .network {
                        NetworkMeasurementRows()
                    }
                }
                if page == .network {
                    NetworkSettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 28)
    }

    @ViewBuilder
    private var generalSections: some View {
        Section {
            AboutHeader()
        }
        Section("Appearance") {
            ThemeGrid(selection: $themeID)
        }
        Section {
            ReorderList(order: order) { slot in
                HStack(spacing: 10) {
                    Image(systemName: slot.symbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(slot.title)
                    Spacer()
                    // CPU & GPU get a switch each, labelled; the others one.
                    ForEach(slot.items) { item in
                        HStack(spacing: 4) {
                            if slot.items.count > 1 {
                                Text(item.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Toggle(item.title, isOn: shown(item))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(isLastShown(item))
                        }
                    }
                }
            }
            Picker("Item padding", selection: $itemPadding) {
                Text("None").tag(0.0)
                Text("Tight").tag(2.0)
                Text("Normal").tag(5.0)
            }
            Toggle("Compact spacing for all apps' icons", isOn: $compactSystemSpacing)
                .onChange(of: compactSystemSpacing) { _, compact in
                    SystemMenuBarSpacing.set(compact: compact)
                }
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("Drag ≡ to change the order. Compact spacing is a macOS setting for every app's icons and applies after you log out.")
                .foregroundStyle(.secondary)
        }
        Section("Behaviour") {
            Toggle("Start at login", isOn: $startsAtLogin)
                .onChange(of: startsAtLogin) { _, enabled in
                    LoginItem.setEnabled(enabled)
                    startsAtLogin = LoginItem.isEnabled
                }
            Toggle("Show icon in Dock while Settings is open", isOn: $showInDock)
                .onChange(of: showInDock) { _, _ in SettingsWindow.applyDockPolicy() }
            Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
        }
        SettingsTransferSection()
    }

    private var order: Binding<[MenuBarSlot]> {
        Binding {
            MenuBarSlot.decode(itemOrder)
        } set: {
            itemOrder = MenuBarSlot.encode($0)
        }
    }

    private func shown(_ item: StatItem) -> Binding<Bool> {
        switch item {
        case .cpu: return $showCPU
        case .gpu: return $showGPU
        case .memory: return $showMemory
        case .network: return $showNetwork
        case .disk: return $showDisk
        case .battery: return $showBattery
        }
    }

    private func isShown(_ item: StatItem) -> Bool { shown(item).wrappedValue }

    private func isLastShown(_ item: StatItem) -> Bool {
        isShown(item) && StatItem.allCases.filter(isShown).count == 1
    }
}

private struct ThemeGrid: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            swatch(id: PanelTheme.systemID, name: "System", themes: [.light, .dark])
            ForEach(PanelTheme.presets) { theme in
                swatch(id: theme.id, name: theme.name, themes: [theme])
            }
        }
        .padding(.vertical, 4)
    }

    private func swatch(id: String, name: String, themes: [PanelTheme]) -> some View {
        Button {
            selection = id
        } label: {
            VStack(spacing: 5) {
                // The thumbnails go in an overlay so they take the column's
                // width instead of setting it. System layers Dark over Light
                // with only its right half showing, like macOS's "Auto".
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .overlay {
                        ZStack {
                            ForEach(Array(themes.enumerated()), id: \.offset) { index, theme in
                                ThemeThumbnail(theme: theme)
                                    .mask {
                                        HStack(spacing: 0) {
                                            Color.black.opacity(index == 0 ? 1 : 0)
                                            Color.black
                                        }
                                    }
                            }
                        }
                    }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selection == id ? Color.accentColor : Color.primary.opacity(0.15),
                                      lineWidth: selection == id ? 2.5 : 1)
                )
                Text(name).font(.system(size: 11))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A tiny dropdown: background, one section, and the three chart colours.
private struct ThemeThumbnail: View {
    let theme: PanelTheme

    var body: some View {
        ZStack {
            theme.background
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 1).fill(theme.header).frame(width: 18, height: 3)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach([0.5, 0.8, 0.35, 0.65, 0.9, 0.45], id: \.self) { height in
                        Rectangle().fill(theme.primary).frame(width: 3, height: 18 * height)
                    }
                    Rectangle().fill(theme.accent).frame(width: 3, height: 12)
                    Rectangle().fill(theme.secondary).frame(width: 3, height: 8)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.section))
            .padding(5)
        }
    }
}

/// Rows reordered by dragging their ≡ handle. A hand-rolled gesture: the
/// pasteboard-based draggable/dropDestination never delivered the drop
/// inside a grouped Form, so rows snapped back.
private struct ReorderList<Row: View>: View {
    @Binding var order: [MenuBarSlot]
    @ViewBuilder var row: (MenuBarSlot) -> Row

    @State private var dragging: MenuBarSlot?
    @State private var offset: CGFloat = 0
    private let rowHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            ForEach(order) { item in
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(dragging == item ? .primary : .tertiary)
                        .frame(width: 22, height: rowHeight)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                        }
                        .gesture(drag(item))
                    row(item)
                }
                .frame(height: rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(dragging == item ? Color.primary.opacity(0.08) : Color.clear)
                )
                .offset(y: dragging == item ? offset : shift(for: item))
                .zIndex(dragging == item ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: target)
    }

    private var target: Int? {
        guard let dragging, let from = order.firstIndex(of: dragging) else { return nil }
        return min(max(from + Int((offset / rowHeight).rounded()), 0), order.count - 1)
    }

    /// Rows between the dragged row's old and new place slide over to make room.
    private func shift(for item: MenuBarSlot) -> CGFloat {
        guard let dragging, let from = order.firstIndex(of: dragging), let to = target,
              let index = order.firstIndex(of: item) else { return 0 }
        if from < to, index > from, index <= to { return -rowHeight }
        if from > to, index >= to, index < from { return rowHeight }
        return 0
    }

    private func drag(_ item: MenuBarSlot) -> some Gesture {
        // Global coordinates: the row itself moves while being dragged.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                dragging = item
                offset = value.translation.height
            }
            .onEnded { _ in
                if let from = order.firstIndex(of: item), let to = target, from != to {
                    var reordered = order
                    reordered.remove(at: from)
                    reordered.insert(item, at: to)
                    order = reordered
                }
                dragging = nil
                offset = 0
            }
    }
}

/// macOS's own gap between menu bar icons, set for every app via the
/// current-host global preferences. Read by apps as they launch, so it
/// takes a log out to apply everywhere.
enum SystemMenuBarSpacing {
    private static let values: [(key: String, compact: Int)] = [
        ("NSStatusItemSpacing", 6),
        ("NSStatusItemSelectionPadding", 8),
    ]

    static var isCompact: Bool {
        CFPreferencesCopyValue(values[0].key as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) != nil
    }

    static func set(compact: Bool) {
        for (key, value) in values {
            CFPreferencesSetValue(key as CFString, compact ? value as CFNumber : nil, kCFPreferencesAnyApplication,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
}



/// App icon, name, version and the update check, as at the top of iStat
/// Menus' and Stats' settings.
private struct AboutHeader: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("StatBar")
                .font(.system(size: 17, weight: .semibold))
            if let version = Updater.currentVersion {
                Text("Version \(version)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Development build")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            HStack {
                updateControl
                Button("Quit StatBar") { NSApp.terminate(nil) }
            }
            .padding(.top, 4)
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Divider()
                .padding(.vertical, 6)
            Link(destination: URL(string: "https://github.com/ahmadarif-lab/statbar")!) {
                Label("github.com/ahmadarif-lab/statbar", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12))
            }
            Text("StatBar is free and open source. If it helps you, a prayer for its developer is all the support asked. 🤲")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var updateControl: some View {
        if let release = updater.availableUpdate {
            Button(updater.progressText ?? "Install v\(release.version)") {
                Task { await updater.update() }
            }
            .disabled(updater.isUpdating)
        } else if Updater.currentVersion != nil {
            Button(updater.isChecking ? "Checking…" : "Check for Updates") {
                Task { await updater.check() }
            }
            .disabled(updater.isChecking)
        }
    }

    private var status: String {
        if let error = updater.errorMessage { return error }
        if Updater.currentVersion == nil { return " " }
        if updater.availableUpdate != nil { return "A new version is available." }
        if updater.checkFailed { return "Couldn't reach GitHub." }
        if updater.noReleases { return "No releases have been published yet." }
        guard let checked = updater.lastChecked else { return " " }
        return "Up to date · checked \(checked.formatted(.relative(presentation: .named)))"
    }
}

/// Export, import and reset of StatBar's own preferences.
private struct SettingsTransferSection: View {
    @State private var message: String?
    @State private var confirmingReset = false

    private var domain: String { Bundle.main.bundleIdentifier ?? "StatBar" }

    var body: some View {
        Section {
            LabeledContent("Export settings") {
                Button("Save…", action: export)
            }
            LabeledContent("Import settings") {
                Button("Choose File…", action: importSettings)
            }
            LabeledContent("Reset settings") {
                if confirmingReset {
                    HStack {
                        Button("Cancel") { confirmingReset = false }
                        Button("Reset", role: .destructive, action: reset)
                    }
                } else {
                    Button("Reset…") { confirmingReset = true }
                }
            }
        } header: {
            Text("Backup")
        } footer: {
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
    }

    /// Only StatBar's own keys: its domain also holds AppKit's window and
    /// status item state, which mean nothing on another Mac.
    private var exportable: [String: Any] {
        (UserDefaults.standard.persistentDomain(forName: domain) ?? [:])
            .filter { !$0.key.hasPrefix("NS") }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StatBar Settings.plist"
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: exportable, format: .xml, options: 0)
            try data.write(to: url)
            message = "Saved to \(url.lastPathComponent)."
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                message = "That file isn't a StatBar settings file."
                return
            }
            for (key, value) in values where !key.hasPrefix("NS") {
                UserDefaults.standard.set(value, forKey: key)
            }
            message = "Imported \(url.lastPathComponent)."
        } catch {
            message = "Couldn't import: \(error.localizedDescription)"
        }
    }

    private func reset() {
        for key in exportable.keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        confirmingReset = false
        message = "Settings are back to their defaults."
    }
}

/// Which interface to measure, and in what units.
private struct NetworkMeasurementRows: View {
    @AppStorage(SettingsKey.networkInterface) private var interface = ""
    @AppStorage(SettingsKey.networkUnits) private var units = "bytes"
    @State private var interfaces = NetworkSampler.availableInterfaces()

    var body: some View {
        Picker("Interface", selection: $interface) {
            Text("All (automatic)").tag("")
            ForEach(interfaces) { interface in
                Text("\(interface.name) (\(interface.id))").tag(interface.id)
            }
        }
        Picker("Units", selection: $units) {
            Text("Bytes (KB/s)").tag("bytes")
            Text("Bits (Kb/s)").tag("bits")
        }
    }
}

/// Network page: public IP and ping.
private struct NetworkSettings: View {
    @AppStorage(SettingsKey.publicIP) private var publicIP = true
    @AppStorage(SettingsKey.publicIPRefresh) private var publicIPRefresh = PublicIPRefresh.onChange.rawValue
    @AppStorage(SettingsKey.ping) private var ping = true
    @AppStorage(SettingsKey.pingHost) private var pingHost = "1.1.1.1"

    var body: some View {
        Section {
            Toggle("Show public IP address", isOn: $publicIP)
            Picker("Refresh", selection: $publicIPRefresh) {
                ForEach(PublicIPRefresh.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(!publicIP)
        } header: {
            Text("Public IP")
        } footer: {
            Text("Looked up from ipinfo.io, along with its country and city.")
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Show ping", isOn: $ping)
            TextField("Host", text: $pingHost, prompt: Text("1.1.1.1"))
                .disabled(!ping)
        } header: {
            Text("Ping")
        } footer: {
            Text("A TCP handshake to the host on port 443, every 5 seconds.")
                .foregroundStyle(.secondary)
        }
    }
}

/// A dropdown's own process count.
private struct ItemProcessCountPicker: View {
    @AppStorage private var count: Int

    init(list: ProcessList) {
        _count = AppStorage(wrappedValue: 5, SettingsKey.processCount(for: list))
    }

    var body: some View {
        Picker("Processes shown", selection: $count) {
            ForEach(ProcessList.choices, id: \.self) { Text("\($0)").tag($0) }
        }
    }
}

/// How often an item's readings refresh.
private struct UpdateIntervalPicker: View {
    @AppStorage private var interval: Double

    init(group: SampleGroup) {
        _interval = AppStorage(wrappedValue: 1, group.intervalKey)
    }

    var body: some View {
        Picker("Update every", selection: $interval) {
            ForEach(SampleGroup.choices, id: \.self) { seconds in
                Text(seconds == 1 ? "1 second" : "\(Int(seconds)) seconds").tag(seconds)
            }
        }
    }
}
