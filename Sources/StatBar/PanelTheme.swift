import SwiftUI

/// Colours for the dropdowns. Every chart draws from the same small palette
/// (primary / secondary / accent) so a theme recolours everything at once.
struct PanelTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let background: Color
    let section: Color
    let header: Color
    let text: Color
    let secondaryText: Color
    /// Main series: user CPU, performance cores, wired memory, upload, read.
    let primary: Color
    /// Second series: download, write, app memory.
    let secondary: Color
    /// Third series: system CPU, efficiency cores, compressed memory.
    let accent: Color
    let track: Color
    let critical: Color

    static let systemID = "system"

    static let dark = PanelTheme(
        id: "dark", name: "Dark", isDark: true,
        background: Color(hex: 0x1C1C1E), section: Color(hex: 0x2A2A2D),
        header: Color(hex: 0x8E8E93), text: .white, secondaryText: Color(hex: 0xA1A1A6),
        primary: Color(hex: 0x2F7BF6), secondary: Color(hex: 0x8E8E93), accent: Color(hex: 0xF0468C),
        track: Color.white.opacity(0.12), critical: Color(hex: 0xFF453A)
    )

    static let light = PanelTheme(
        id: "light", name: "Light", isDark: false,
        background: Color(hex: 0xECECEF), section: .white,
        header: Color(hex: 0x86868B), text: Color(hex: 0x1D1D1F), secondaryText: Color(hex: 0x6E6E73),
        primary: Color(hex: 0x0A7AFF), secondary: Color(hex: 0xAEAEB2), accent: Color(hex: 0xFF2D78),
        track: Color.black.opacity(0.09), critical: Color(hex: 0xFF3B30)
    )

    static let presets: [PanelTheme] = [
        dark,
        light,
        PanelTheme(
            id: "midnight", name: "Midnight", isDark: true,
            background: Color(hex: 0x0E1533), section: Color(hex: 0x19224A),
            header: Color(hex: 0x4A86FF), text: .white, secondaryText: Color(hex: 0x9AA6D0),
            primary: Color(hex: 0x2F6BFF), secondary: Color(hex: 0x6B78A8), accent: Color(hex: 0xFF2E8A),
            track: Color.white.opacity(0.12), critical: Color(hex: 0xFF453A)
        ),
        PanelTheme(
            id: "graphite", name: "Graphite", isDark: true,
            background: Color(hex: 0x141414), section: Color(hex: 0x222222),
            header: Color(hex: 0x9A9A9A), text: Color(hex: 0xF2F2F2), secondaryText: Color(hex: 0x9A9A9A),
            primary: Color(hex: 0xE8E8E8), secondary: Color(hex: 0x6A6A6A), accent: Color(hex: 0xB4B4B4),
            track: Color.white.opacity(0.1), critical: Color(hex: 0xFF6961)
        ),
        PanelTheme(
            id: "ocean", name: "Ocean", isDark: true,
            background: Color(hex: 0x071F2A), section: Color(hex: 0x0D3040),
            header: Color(hex: 0x3CCFE0), text: .white, secondaryText: Color(hex: 0x8FB8C6),
            primary: Color(hex: 0x32D1E8), secondary: Color(hex: 0x5A7F8E), accent: Color(hex: 0x8B6BFF),
            track: Color.white.opacity(0.12), critical: Color(hex: 0xFF6B6B)
        ),
        PanelTheme(
            id: "forest", name: "Forest", isDark: true,
            background: Color(hex: 0x0E1C16), section: Color(hex: 0x172E24),
            header: Color(hex: 0x5BD69A), text: .white, secondaryText: Color(hex: 0x93B8A5),
            primary: Color(hex: 0x34C759), secondary: Color(hex: 0x5E7D6D), accent: Color(hex: 0xFFD60A),
            track: Color.white.opacity(0.12), critical: Color(hex: 0xFF6B5E)
        ),
        PanelTheme(
            id: "sunset", name: "Sunset", isDark: true,
            background: Color(hex: 0x200F1A), section: Color(hex: 0x331A2A),
            header: Color(hex: 0xFF8A65), text: .white, secondaryText: Color(hex: 0xC99AAE),
            primary: Color(hex: 0xFF9F0A), secondary: Color(hex: 0x8A5F74), accent: Color(hex: 0xFF375F),
            track: Color.white.opacity(0.12), critical: Color(hex: 0xFF453A)
        ),
    ]

    /// "system" follows the Mac's appearance; anything else is a preset.
    static func resolve(_ id: String, colorScheme: ColorScheme) -> PanelTheme {
        if let preset = presets.first(where: { $0.id == id }) { return preset }
        return colorScheme == .dark ? dark : light
    }
}

private struct PanelThemeKey: EnvironmentKey {
    static let defaultValue = PanelTheme.dark
}

extension EnvironmentValues {
    var panelTheme: PanelTheme {
        get { self[PanelThemeKey.self] }
        set { self[PanelThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
