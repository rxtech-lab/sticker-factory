import Foundation

/// What a tap sends: a Messages sticker, or a full-size image.
///
/// Two genuinely different things, which is why this is a choice rather than a size slider. A
/// *sticker* goes through `MSConversation.insert(_ sticker:)` — it lands small, it can be peeled and
/// dropped onto another message, and Apple caps it at 500 KB. An *image* goes through
/// `insertAttachment` — it fills the bubble, carries the full-resolution rendition, and is an
/// ordinary attachment that can be saved.
///
/// A three-rung Small/Medium/Large size control stood here first and was the wrong idea twice over.
/// It could not work as published sizes, because `insertAttachment` scales an image attachment to a
/// fixed bubble width and ignores its pixel dimensions — all three arrived identical. Padding the
/// artwork inside a fixed canvas did change the size, but it made every send an attachment, so the
/// one thing this surface could not do was send an actual sticker. This is the axis that was
/// actually missing.
enum StickerSendMode: String, CaseIterable, Sendable {
    case sticker
    case image

    /// Sticker, because it is the cheaper and more reversible of the two: it needs no download, and
    /// someone who wanted the big version will find it in one tap.
    static let `default` = StickerSendMode.sticker

    var label: String {
        switch self {
        case .sticker: String(localized: "Sticker")
        case .image: String(localized: "Image")
        }
    }

    // MARK: - Persistence

    /// Remembered in the app group rather than the extension's own defaults.
    ///
    /// An appex gets its own `UserDefaults.standard` container, and Messages is free to tear this
    /// extension down between sends — so the group suite is what makes the choice survive closing
    /// the drawer, which is the only thing a person would notice.
    ///
    /// A key of its own rather than the size control's: a stored `large`/`medium`/`small` means
    /// nothing here, and reading one back would land on `default` anyway.
    private static let preferenceKey = "StickerFactoryPreferredSendMode"

    static func preferred(
        defaults: UserDefaults? = UserDefaults(suiteName: SharedAuthConfiguration.appGroupIdentifier)
    ) -> StickerSendMode {
        guard let raw = defaults?.string(forKey: preferenceKey), let mode = Self(rawValue: raw) else {
            return .default
        }
        return mode
    }

    func remember(
        in defaults: UserDefaults? = UserDefaults(suiteName: SharedAuthConfiguration.appGroupIdentifier)
    ) {
        defaults?.set(rawValue, forKey: Self.preferenceKey)
    }
}
