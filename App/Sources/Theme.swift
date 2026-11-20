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
}
