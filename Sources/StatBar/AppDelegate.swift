import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherCopyIsRunning() else {
            NSApp.terminate(nil)
            return
        }
        UserDefaults.registerStatBarDefaults()
        // With every item hidden there'd be nothing to click in the menu bar.
        if !StatItem.allCases.contains(where: UserDefaults.standard.isShown) {
            UserDefaults.standard.set(true, forKey: StatItem.cpu.showKey)
        }

        let monitor = Monitor()
        self.monitor = monitor
        SettingsWindow.monitor = monitor
        statusBar = StatusBarController(monitor: monitor)
        NSApp.mainMenu = Self.mainMenu()
        SettingsWindow.applyDockPolicy()
        _ = Updater.shared

        // Opened by hand (Finder, Launchpad, Spotlight) rather than at login:
        // show the settings window, the way iStat Menus does.
        if !LoginItem.launchedAtLogin {
            SettingsWindow.show()
        }
        LoginItem.enableOnFirstLaunch()
    }

    /// Opening the app again while it runs brings the settings window up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    /// launchd starts the binary directly while a double-click goes through
    /// LaunchServices, so both can run at once. The younger one steps aside.
    private func anotherCopyIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
            .contains { other in
                guard let otherDate = other.launchDate, let myDate = me.launchDate else { return false }
                return otherDate < myDate
            }
    }

    /// Shown only while the settings window makes StatBar a regular app:
    /// enough for ⌘W, ⌘Q and ⌘M to behave.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit StatBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }
}
