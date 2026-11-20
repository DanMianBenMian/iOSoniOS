import SwiftUI

/// Two palettes, one app.
///
/// `Theme`            — light, used before Start (setup, config, downloads).
/// `Theme.VM`         — pure black, used once the guest is "running".
///
/// The split is deliberate: the configuration surface should feel like an
/// ordinary iOS app, while the VM surface should disappear entirely so the
/// guest's own pixels are the only thing on screen.
enum Theme {

    // MARK: - Light (pre-Start)

    static let canvas      = Color(red: 0.961, green: 0.965, blue: 0.973)  // #F5F6F8
    static let surface     = Color.white
    static let surfaceHi   = Color(red: 0.914, green: 0.918, blue: 0.929)  // #E9EAED
    static let hairline    = Color.black.opacity(0.08)

    static let text        = Color(red: 0.114, green: 0.118, blue: 0.129)  // #1D1E21
    static let textMuted   = Color(red: 0.431, green: 0.443, blue: 0.463)  // #6E7176
    static let textFaint   = Color(red: 0.639, green: 0.651, blue: 0.671)  // #A3A6AB

    static let accent      = Color(red: 0.000, green: 0.443, blue: 0.890)  // #0071E3
    static let accentDim   = Color(red: 0.000, green: 0.443, blue: 0.890).opacity(0.12)

    static let warn        = Color(red: 0.788, green: 0.478, blue: 0.106)  // #C97A1B
    static let danger      = Color(red: 0.769, green: 0.216, blue: 0.188)  // #C43730
    static let ok          = Color(red: 0.184, green: 0.545, blue: 0.353)  // #2F8B5A

    static let logGuest    = Color(red: 0.400, green: 0.310, blue: 0.690)
    static let logWarn     = warn
    static let logError    = danger

    // MARK: - Icon accents (light tiles read better a little deeper)

    static let iconMemory   = Color(red: 0.192, green: 0.420, blue: 0.741)
    static let iconCPU      = Color(red: 0.396, green: 0.318, blue: 0.729)
    static let iconVRAM     = Color(red: 0.514, green: 0.278, blue: 0.635)
    static let iconDisplay  = Color(red: 0.129, green: 0.522, blue: 0.580)
    static let iconRes      = Color(red: 0.251, green: 0.435, blue: 0.576)
    static let iconBoot     = Color(red: 0.278, green: 0.322, blue: 0.384)
    static let iconName     = Color(red: 0.769, green: 0.514, blue: 0.184)
    static let iconJIT      = Color(red: 0.216, green: 0.573, blue: 0.365)
    static let iconFirmware = Color(red: 0.706, green: 0.435, blue: 0.169)
    static let iconDownload = Color(red: 0.129, green: 0.478, blue: 0.722)
    static let iconInfo     = Color(red: 0.400, green: 0.435, blue: 0.482)

    /// Palette for the VM surface: pure black, no chrome.
    enum VM {
        static let canvas   = Color.black
        static let text     = Color(red: 0.878, green: 0.886, blue: 0.898)
        static let textDim  = Color(red: 0.545, green: 0.565, blue: 0.596)
        static let textFaint = Color(red: 0.353, green: 0.369, blue: 0.392)
        static let accent   = Color(red: 0.431, green: 0.616, blue: 0.839)
        static let warn     = Color(red: 0.898, green: 0.616, blue: 0.286)
        static let danger   = Color(red: 0.839, green: 0.396, blue: 0.365)
        static let ok       = Color(red: 0.427, green: 0.678, blue: 0.525)
        static let keyFill  = Color.white.opacity(0.10)
        static let keyStroke = Color.white.opacity(0.16)
    }
}
