import SwiftUI

/// The app's shared brand palette.
///
/// The light colors mirror `icon.icon`; the stronger variants keep controls and
/// text legible while staying in the same lavender-and-blush color family.
enum AppColors {
    /// The exact automatic-gradient fill from `icon.icon/icon.json`.
    static let iconLavender = Color(
        .displayP3,
        red: 0.87286,
        green: 0.83196,
        blue: 0.98096
    )

    /// The mascot's main fill from `whole body.svg` (`#FFC8C8`).
    static let iconBlush = Color(
        .sRGB,
        red: 1,
        green: 200 / 255,
        blue: 200 / 255
    )

    /// The mascot's shadow fill from `whole body.svg` (`#FFB8B8`).
    static let iconBlushShadow = Color(
        .sRGB,
        red: 1,
        green: 184 / 255,
        blue: 184 / 255
    )

    /// A deeper pink relative for buttons, links, and selected states.
    static let accent = Color(
        .sRGB,
        red: 0.77,
        green: 0.24,
        blue: 0.39
    )

    /// The icon's blush used for subtle fills, badges, and message bubbles.
    static let accentSoft = iconBlush

    /// Lavender remains the supporting accent from the icon background.
    static let secondaryAccent = Color(
        .displayP3,
        red: 0.39,
        green: 0.24,
        blue: 0.64
    )

    static let secondaryAccentSoft = iconLavender
}
