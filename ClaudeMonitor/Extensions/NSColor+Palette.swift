import AppKit

/// The two accents the dropdown paints with.
///
/// Both exist because the system equivalents are tuned to catch the eye on a white sheet, and this
/// UI is a small dark panel the user has open all day: `systemBlue` on a grey bar and `systemGreen`
/// on a one-line status both read as neon against it. These sit a step back — same hues, lower
/// saturation, darker in light mode where the background stops doing the work.
extension NSColor {
    /// Fill of a usage bar that still has headroom.
    static let usageBar = dynamic(
        dark: NSColor(srgbRed: 0.353, green: 0.639, blue: 0.702, alpha: 1),
        light: NSColor(srgbRed: 0.196, green: 0.443, blue: 0.529, alpha: 1)
    )

    /// "All systems operational" — the only green in the menu.
    static let servicesHealthy = dynamic(
        dark: NSColor(srgbRed: 0.353, green: 0.667, blue: 0.475, alpha: 1),
        light: NSColor(srgbRed: 0.180, green: 0.455, blue: 0.290, alpha: 1)
    )

    /// Resolves per appearance rather than once at launch — the menu is rebuilt on every poll, but
    /// a colour captured as a plain sRGB value would keep the dark shade after a mid-session switch
    /// to light mode.
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
