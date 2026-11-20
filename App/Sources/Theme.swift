import SwiftUI

/// Graphite / silver design tokens.
/// Quiet, low-saturation, cold accent. Orange is reserved for warnings only.
enum Theme {
    // Surfaces: deep silver-grey, not pure black.
    static let canvas      = Color(red: 0.105, green: 0.112, blue: 0.121)  // #1B1C1F
    static let surface     = Color(red: 0.145, green: 0.153, blue: 0.165)  // #25272A
    static let surfaceHi   = Color(red: 0.190, green: 0.199, blue: 0.214)  // #303338
    static let hairline    = Color.white.opacity(0.08)

    // Text: warm-neutral silver rather than pure white.
    static let text        = Color(red: 0.898, green: 0.906, blue: 0.918)
    static let textMuted   = Color(red: 0.616, green: 0.635, blue: 0.663)
    static let textFaint   = Color(red: 0.420, green: 0.439, blue: 0.467)

    // Accent: cold silver-blue, used sparingly.
    static let accent      = Color(red: 0.478, green: 0.651, blue: 0.851)  // #7AA6D9
    static let accentDim   = Color(red: 0.478, green: 0.651, blue: 0.851).opacity(0.16)

    // Semantic: only these carry color beyond the silver scale.
    static let warn        = Color(red: 0.914, green: 0.643, blue: 0.322)  // amber
    static let danger      = Color(red: 0.851, green: 0.435, blue: 0.412)
    static let ok          = Color(red: 0.494, green: 0.706, blue: 0.580)

    // Log levels.
    static let logGuest    = Color(red: 0.639, green: 0.596, blue: 0.831)
    static let logWarn     = warn
    static let logError    = danger

    // Icon accents: one per setting, like the iOS Settings app's tiles.
    // Muted so they sit inside graphite without shouting.
    static let iconMemory  = Color(red: 0.376, green: 0.545, blue: 0.780)
    static let iconCPU     = Color(red: 0.545, green: 0.478, blue: 0.800)
    static let iconVRAM    = Color(red: 0.616, green: 0.412, blue: 0.702)
    static let iconDisplay = Color(red: 0.298, green: 0.639, blue: 0.678)
    static let iconRes     = Color(red: 0.412, green: 0.561, blue: 0.663)
    static let iconBoot    = Color(red: 0.396, green: 0.443, blue: 0.502)
    static let iconName    = Color(red: 0.800, green: 0.596, blue: 0.318)
    static let iconJIT     = Color(red: 0.400, green: 0.667, blue: 0.471)
    static let iconFirmware = Color(red: 0.780, green: 0.545, blue: 0.290)
    static let iconDownload = Color(red: 0.322, green: 0.588, blue: 0.780)
    static let iconInfo    = Color(red: 0.478, green: 0.510, blue: 0.561)
}
