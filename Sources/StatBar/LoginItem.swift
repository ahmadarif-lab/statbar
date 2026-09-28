import AppKit
import Foundation
import ServiceManagement

/// Start-at-login via SMAppService (macOS 13+).
///
/// Replaces the hand-written LaunchAgent plist: the app registers itself,
/// which a Homebrew cask's sandboxed postflight cannot do (launchctl fails
/// with "Load failed: 5: Input/output error" there), and it shows up in
/// System Settings > General > Login Items where it can be switched off.
enum LoginItem {
    private static let autoEnabledKey = "loginItemAutoEnabled"

    /// Whether this launch came from the login item rather than the user.
    /// A login launch may or may not carry the "launched as login item"
    /// Apple event depending on how it was started, so a launch within the
    /// first few minutes after boot counts too. Read it during launch --
    /// the Apple event is gone afterwards.
    @MainActor
    static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == kAEOpenApplication,
           event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 180
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }

    /// Turns start-at-login on the first time the app ever runs, so a fresh
    /// `brew install` needs no follow-up command. Only once: if the user
    /// later switches it off, it stays off.
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: autoEnabledKey) else { return }
        defaults.set(true, forKey: autoEnabledKey)
        setEnabled(true)
    }
}
