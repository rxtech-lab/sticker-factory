import Foundation
import SwiftUI
import TelegramStickersImport
import UIKit
import WASticker

/// A messenger that accepts a sticker pack handed over from another app.
///
/// Both work the same way — the pack goes onto the pasteboard under the messenger's own type and
/// the messenger is opened on a URL that tells it to look there — and both have rules a pack has
/// to meet first. Those rules are what this type carries; the hand-off itself lives in the
/// messenger's own module.
nonisolated enum MessengerDestination: String, CaseIterable, Identifiable, Sendable {
    case whatsapp
    case telegram

    var id: Self { self }

    var label: String {
        switch self {
        case .whatsapp: "WhatsApp"
        case .telegram: "Telegram"
        }
    }

    /// The poster palette's crayon for this messenger.
    @MainActor
    var accent: Color {
        switch self {
        case .whatsapp: AppColors.mint
        case .telegram: AppColors.sky
        }
    }

    /// Official vector artwork, rendered in its original brand colors.
    var logoAsset: String {
        switch self {
        case .whatsapp: "WhatsAppLogo"
        case .telegram: "TelegramLogo"
        }
    }

    var limits: MessengerPackLimits {
        switch self {
        case .whatsapp: .whatsapp
        case .telegram: .telegram
        }
    }

    /// Whether the messenger is on this phone. Needs its scheme in `LSApplicationQueriesSchemes`.
    @MainActor
    var isInstalled: Bool {
        switch self {
        case .whatsapp: WAStickerInteroperability.isWhatsAppInstalled
        case .telegram: TelegramApp.isInstalled()
        }
    }

    /// Where a pack's name is decided. WhatsApp reads it from the payload; Telegram asks for it in
    /// its own import flow, so the name shown here is only a label.
    var namesPackInApp: Bool {
        switch self {
        case .whatsapp: false
        case .telegram: true
        }
    }
}

/// What a messenger enforces on a pack it is handed.
///
/// WhatsApp: https://github.com/WhatsApp/stickers/blob/main/iOS/README.md
/// Telegram: https://core.telegram.org/import-stickers
nonisolated struct MessengerPackLimits: Equatable, Sendable {
    var minimumStickers: Int
    var maximumStickers: Int
    /// Every sticker is a square of this many pixels.
    var dimension: Int
    var staticByteLimit: Int
    var animatedByteLimit: Int
    var maximumDurationMilliseconds: Int
    /// The most frames a second the export writes. WhatsApp allows down to 8 ms a frame, but a
    /// 512² animated WebP has 500 KB to fit into and frames are what that budget is spent on.
    var maximumFramesPerSecond: Int
    var minimumFrameDurationMilliseconds: Int

    static let whatsapp = MessengerPackLimits(
        minimumStickers: WAStickerLimits.minStickersPerPack,
        maximumStickers: WAStickerLimits.maxStickersPerPack,
        dimension: WAStickerLimits.imageSide,
        staticByteLimit: WAStickerLimits.maxStaticStickerFileSize,
        animatedByteLimit: WAStickerLimits.maxAnimatedStickerFileSize,
        maximumDurationMilliseconds: WAStickerLimits.maxAnimatedStickerTotalDurationMilliseconds,
        maximumFramesPerSecond: 24,
        minimumFrameDurationMilliseconds: WAStickerLimits.minAnimatedStickerFrameDurationMilliseconds
    )

    static let telegram = MessengerPackLimits(
        minimumStickers: 1,
        maximumStickers: 120,
        dimension: 512,
        staticByteLimit: 512 * 1024,
        animatedByteLimit: 256 * 1024,
        maximumDurationMilliseconds: 3_000,
        maximumFramesPerSecond: 30,
        minimumFrameDurationMilliseconds: 33
    )

    func byteLimit(animated: Bool) -> Int {
        animated ? animatedByteLimit : staticByteLimit
    }
}

nonisolated extension Sticker {
    /// The rendition this messenger takes, or nil when the sticker has none for it.
    ///
    /// Nil is the whole story the pack screen needs: since the export sheet stopped encoding, a
    /// sticker without this file cannot be sent to that messenger at all, and is shown grayed
    /// rather than offered. A sticker added to a pack before this app stored renditions is nil for
    /// both, and so is one whose artwork could not be squeezed under a messenger's ceiling.
    func messengerAsset(for destination: MessengerDestination) -> AssetRecord? {
        switch destination {
        case .whatsapp: whatsappAsset
        case .telegram: telegramAsset
        }
    }

    /// Whether this sticker can be handed to `destination` as it stands.
    func supports(_ destination: MessengerDestination) -> Bool {
        status == .published && messengerAsset(for: destination) != nil
    }

    /// The destinations this sticker still needs encoding for. Empty means there is nothing to do,
    /// which is what makes re-adding a sticker to a second pack free.
    var missingMessengerDestinations: [MessengerDestination] {
        MessengerDestination.allCases.filter { messengerAsset(for: $0) == nil }
    }
}

/// The emoji each sticker is filed under in the messenger, remembered per sticker on this device.
///
/// Both messengers index stickers by emoji, and neither can be told later. Kept in `UserDefaults`
/// under the sticker's id, so the choice survives re-exports and travels with the sticker into
/// every pack it is in — and, being device-local, needs no backend.
@MainActor
final class MessengerEmojiStore {
    static let defaultEmoji = "🙂"
    private static let keyPrefix = "messenger.emoji.v1."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func emoji(for stickerID: String) -> String {
        storedEmoji(for: stickerID) ?? Self.defaultEmoji
    }

    /// The choice made on *this* device, or nil when none was.
    ///
    /// Separate from `emoji(for:)` because that one bakes in the default, which would leave the
    /// creator's own choice — carried on the sticker since it started travelling with the pack —
    /// with no way to be reached. Nil here is what lets the server's value be the next thing tried.
    func storedEmoji(for stickerID: String) -> String? {
        defaults.string(forKey: Self.keyPrefix + stickerID).flatMap(Self.singleEmoji)
    }

    /// The emoji to send with this sticker: this device's choice, then the creator's, then the
    /// default. A pack installed from someone else arrives labelled the way they labelled it, and a
    /// reader who changes one here still overrides it.
    func emoji(for sticker: Sticker) -> String {
        storedEmoji(for: sticker.id)
            ?? sticker.messengerEmoji.flatMap(Self.singleEmoji)
            ?? Self.defaultEmoji
    }

    func setEmoji(_ emoji: String, for stickerID: String) {
        guard let single = Self.singleEmoji(emoji) else {
            defaults.removeObject(forKey: Self.keyPrefix + stickerID)
            return
        }
        defaults.set(single, forKey: Self.keyPrefix + stickerID)
    }

    /// The first emoji in the text, or nil when there is none. Both messengers want exactly one
    /// emoji per entry, and a text field cannot be trusted to hold exactly one.
    nonisolated static func singleEmoji(_ text: String) -> String? {
        for character in text where character.isEmoji {
            return String(character)
        }
        return nil
    }
}

nonisolated private extension Character {
    /// A grapheme that renders as an emoji — including keycaps, flags and joined sequences, and
    /// excluding the digits and symbols that merely *could* be presented as one.
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        if unicodeScalars.count > 1, first.properties.isEmoji { return true }
        return first.properties.isEmojiModifierBase
    }
}
