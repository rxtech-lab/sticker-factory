import SwiftUI

/// The app's shared brand palette — the same poster palette the web app uses.
///
/// Cream paper, near-black ink, and a small set of loud, flat accents. Every colour here has a
/// twin in `server/app/globals.css`, so a sticker card looks the same whether it is seen in a
/// browser or on a phone. Nothing is translucent and nothing is a gradient: the look is printed
/// paper, and depth comes from a hard offset shadow rather than from blur.
enum AppColors {
    /// Page background. `--paper`.
    static let paper = Color(hex: 0xF7F3EA)
    /// Card and control background. `--card`.
    static let card = Color(hex: 0xFFFDF8)
    /// Text, outlines, and every hard shadow. `--ink`.
    static let ink = Color(hex: 0x191816)
    /// Secondary copy. `--muted`.
    static let muted = Color(hex: 0x615F59)
    /// Tertiary copy and disabled fills. `--faint`.
    static let faint = Color(hex: 0x8E8A81)
    /// Hairlines that should not read as an outline. `--line`.
    static let line = Color(hex: 0x191816).opacity(0.13)

    static let sky = Color(hex: 0x78D7FF)
    static let lime = Color(hex: 0xD8FF55)
    static let indigo = Color(hex: 0x4E5CFF)
    static let coral = Color(hex: 0xF45B36)
    static let peach = Color(hex: 0xFFC97D)
    /// The marker-pen highlight behind an emphasised word. `--hl`.
    static let highlight = Color(hex: 0xFFD5A4)
    static let mint = Color(hex: 0x7BE0A8)

    // MARK: - Roles
    //
    // Named for the job rather than the hue, so a screen asks for "the accent" and the palette
    // decides which crayon that is.

    /// Buttons, links, selected states, and the shadow under a primary control.
    static let accent = coral
    /// Soft fills, badges, and the user's own message bubbles.
    static let accentSoft = highlight
    /// The supporting accent — plan cards, informational chrome.
    static let secondaryAccent = indigo
    static let secondaryAccentSoft = sky
}

extension Color {
    /// `0xRRGGBB`, the way the palette is written in CSS.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
