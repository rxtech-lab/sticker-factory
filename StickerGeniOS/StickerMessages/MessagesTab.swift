import Foundation

/// The two top-level pages of the full-size (Messages app drawer) surface: the sticker grid, and
/// the user's pet.
///
/// A tab rather than a section of the grid because the two do different things with a tap — a
/// sticker tap sends that sticker, while the pet page is a card with stats and one deliberate Send
/// button. Mixing them would put two meanings on one gesture. The Stickers drawer (`.media`) never
/// shows this: it is a sticker picker hosted by the system, and a pet card is an `MSMessage`, which
/// that context cannot insert.
enum MessagesTab: String, CaseIterable, Sendable {
    case stickers
    case pet

    /// Stickers, because that is what most people open the drawer for.
    static let `default` = MessagesTab.stickers

    var label: String {
        switch self {
        case .stickers: String(localized: "Stickers")
        case .pet: String(localized: "Pet")
        }
    }

    // MARK: - Persistence

    /// In the app group for the same reason as `StickerSendMode`: Messages tears the extension
    /// down between activations, and someone who sends their pet every morning should land on it.
    private static let preferenceKey = "StickerFactoryMessagesTab"

    static func preferred(
        defaults: UserDefaults? = UserDefaults(suiteName: SharedAuthConfiguration.appGroupIdentifier)
    ) -> MessagesTab {
        guard let raw = defaults?.string(forKey: preferenceKey), let tab = Self(rawValue: raw) else {
            return .default
        }
        return tab
    }

    func remember(
        in defaults: UserDefaults? = UserDefaults(suiteName: SharedAuthConfiguration.appGroupIdentifier)
    ) {
        defaults?.set(rawValue, forKey: Self.preferenceKey)
    }
}
