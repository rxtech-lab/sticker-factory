//
// Copyright (c) Meta Platforms, Inc. and affiliates.
// All rights reserved.
//
// This source code is licensed under the BSD-style license found in the
// LICENSE file in the root directory of this source tree.
//
// Adapted from WAStickersThirdParty/Interoperability.swift.

import UIKit

/// The hand-off itself: the pack goes onto the general pasteboard under WhatsApp's type, local
/// only and expiring in a minute, and WhatsApp is opened on its sticker-pack URL to collect it.
///
/// `LSApplicationQueriesSchemes` in the host app's Info.plist must list `whatsapp`, or
/// `isWhatsAppInstalled` is always false.
@MainActor
public enum WAStickerInteroperability {
    public static let pasteboardExpirationSeconds: TimeInterval = 60
    public static let pasteboardStickerPackDataType = "net.whatsapp.third-party.sticker-pack"
    public static let whatsAppURL = URL(string: "whatsapp://stickerPack")!
    public static let whatsAppSchemeURL = URL(string: "whatsapp://")!

    /// The sample's default bundle id, which WhatsApp refuses.
    static let sampleBundleIdentifier = "WA.WAStickersThirdParty"

    public static var isWhatsAppInstalled: Bool {
        UIApplication.shared.canOpenURL(whatsAppSchemeURL)
    }

    public enum Failure: Error, Equatable, Sendable {
        case sampleBundleIdentifier
        case payloadNotSerializable
        case whatsAppNotInstalled
    }

    /// Places the pack on the pasteboard and opens WhatsApp.
    ///
    /// Returns once WhatsApp has been asked to open. That is a hand-off, not a receipt: whether
    /// the person then adds the pack is decided in WhatsApp, and nothing reports back.
    public static func send(
        _ pack: WAStickerPack,
        iOSAppStoreLink: String?,
        androidPlayStoreLink: String?
    ) throws {
        if Bundle.main.bundleIdentifier?.contains(sampleBundleIdentifier) == true {
            throw Failure.sampleBundleIdentifier
        }
        guard isWhatsAppInstalled else { throw Failure.whatsAppNotInstalled }

        var json = pack.payload()
        json["ios_app_store_link"] = iOSAppStoreLink
        json["android_play_store_link"] = androidPlayStoreLink
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []) else {
            throw Failure.payloadNotSerializable
        }

        UIPasteboard.general.setItems(
            [[pasteboardStickerPackDataType: data]],
            options: [
                .localOnly: true,
                .expirationDate: Date(timeIntervalSinceNow: pasteboardExpirationSeconds),
            ]
        )
        UIApplication.shared.open(whatsAppURL)
    }
}
