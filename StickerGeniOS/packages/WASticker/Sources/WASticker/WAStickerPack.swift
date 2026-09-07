//
// Copyright (c) Meta Platforms, Inc. and affiliates.
// All rights reserved.
//
// This source code is licensed under the BSD-style license found in the
// LICENSE file in the root directory of this source tree.
//
// Adapted from WAStickersThirdParty/StickerPack.swift and Sticker.swift.

import Foundation

public enum WAStickerPackError: Error, Equatable, Sendable {
    case emptyString
    case stringTooLong
    case invalidImage
    case imageTooBig(Int, animated: Bool)
    case incorrectImageSize(width: Int, height: Int)
    case animatedImagesNotSupported
    case stickersNumOutsideAllowableRange
    case tooManyEmojis
    case minFrameDurationTooShort(Int)
    case totalAnimationDurationTooLong(Int)
    case animatedStickerPackWithStaticStickers
    case staticStickerPackWithAnimatedStickers
    case accessibilityTextTooLong
}

/// One sticker: its image and the emojis WhatsApp indexes it under.
public struct WASticker: Sendable, Equatable {
    public let image: WAStickerImage
    public let emojis: [String]
    public let accessibilityText: String?

    public init(image: WAStickerImage, emojis: [String], accessibilityText: String? = nil) throws {
        try image.validate(asTray: false)
        guard emojis.count <= WAStickerLimits.maxEmojisCount else { throw WAStickerPackError.tooManyEmojis }
        if let accessibilityText {
            let limit = image.isAnimated
                ? WAStickerLimits.maxAnimatedStickerAccessibilityTextLength
                : WAStickerLimits.maxStaticStickerAccessibilityTextLength
            guard accessibilityText.count <= limit else { throw WAStickerPackError.accessibilityTextTooLong }
        }
        self.image = image
        self.emojis = emojis.map(Self.canonicalized)
        self.accessibilityText = accessibilityText
    }

    /// The sample's `StickerEmojis.canonicalizedEmoji`: strips skin-tone and variation selectors
    /// so WhatsApp's index matches. Falls back to the original when nothing survives.
    static func canonicalized(_ emoji: String) -> String {
        var kept = ""
        for scalar in emoji.unicodeScalars {
            switch scalar.value {
            case 0x1F600...0x1F64F, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF, 0x2600...0x26FF,
                 0x2700...0x27BF, 0x1F1E6...0x1F1FF, 0x1F900...0x1F9FF, 0x200D:
                kept.unicodeScalars.append(scalar)
            default:
                continue
            }
        }
        return kept.isEmpty ? emoji : kept
    }
}

/// A pack WhatsApp will accept, validated the way the sample validated it.
public struct WAStickerPack: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let publisher: String
    public let trayImage: WAStickerImage
    public let isAnimated: Bool
    public private(set) var stickers: [WASticker]
    public var publisherWebsite: String?
    public var privacyPolicyWebsite: String?
    public var licenseAgreementWebsite: String?

    public init(
        identifier: String,
        name: String,
        publisher: String,
        trayImage: WAStickerImage,
        isAnimated: Bool,
        publisherWebsite: String? = nil,
        privacyPolicyWebsite: String? = nil,
        licenseAgreementWebsite: String? = nil
    ) throws {
        guard !name.isEmpty, !publisher.isEmpty, !identifier.isEmpty else { throw WAStickerPackError.emptyString }
        guard name.count <= WAStickerLimits.maxCharLimit128,
              publisher.count <= WAStickerLimits.maxCharLimit128,
              identifier.count <= WAStickerLimits.maxCharLimit128
        else { throw WAStickerPackError.stringTooLong }
        try trayImage.validate(asTray: true)
        self.identifier = identifier
        self.name = name
        self.publisher = publisher
        self.trayImage = trayImage
        self.isAnimated = isAnimated
        self.publisherWebsite = publisherWebsite
        self.privacyPolicyWebsite = privacyPolicyWebsite
        self.licenseAgreementWebsite = licenseAgreementWebsite
        stickers = []
    }

    public mutating func add(_ sticker: WASticker) throws {
        guard stickers.count < WAStickerLimits.maxStickersPerPack else {
            throw WAStickerPackError.stickersNumOutsideAllowableRange
        }
        guard sticker.image.isAnimated == isAnimated else {
            throw isAnimated
                ? WAStickerPackError.animatedStickerPackWithStaticStickers
                : WAStickerPackError.staticStickerPackWithAnimatedStickers
        }
        stickers.append(sticker)
    }

    /// Whether the pack can be sent at all: WhatsApp refuses fewer than three stickers.
    public var isSendable: Bool {
        stickers.count >= WAStickerLimits.minStickersPerPack && stickers.count <= WAStickerLimits.maxStickersPerPack
    }

    /// The JSON WhatsApp reads off the pasteboard. Sticker images must already be WebP; a PNG is
    /// skipped here exactly as the sample skipped an image it could not convert.
    public func payload() -> [String: Any] {
        var json: [String: Any] = [:]
        json["identifier"] = identifier
        json["name"] = name
        json["publisher"] = publisher
        json["tray_image"] = trayImage.data.base64EncodedString()
        if isAnimated { json["animated_sticker_pack"] = true }
        if let publisherWebsite { json["publisher_website"] = publisherWebsite }
        if let privacyPolicyWebsite { json["privacy_policy_website"] = privacyPolicyWebsite }
        if let licenseAgreementWebsite { json["license_agreement_website"] = licenseAgreementWebsite }
        json["stickers"] = stickers.compactMap { sticker -> [String: Any]? in
            guard sticker.image.format == .webp else { return nil }
            var entry: [String: Any] = ["image_data": sticker.image.data.base64EncodedString()]
            entry["emojis"] = sticker.emojis
            if let text = sticker.accessibilityText { entry["accessibility_text"] = text }
            return entry
        }
        return json
    }
}
