//
// Copyright (c) Meta Platforms, Inc. and affiliates.
// All rights reserved.
//
// This source code is licensed under the BSD-style license found in the
// LICENSE file in the root directory of this source tree.
//
// Adapted from WAStickersThirdParty/Limits.swift.

import Foundation

/// What WhatsApp enforces on a third-party pack. Source of truth:
/// https://github.com/WhatsApp/stickers/blob/main/iOS/README.md
public enum WAStickerLimits {
    public static let maxStaticStickerFileSize = 100 * 1024
    public static let maxAnimatedStickerFileSize = 500 * 1024
    public static let maxTrayImageFileSize = 50 * 1024

    public static let minAnimatedStickerFrameDurationMilliseconds = 8
    public static let maxAnimatedStickerTotalDurationMilliseconds = 10_000

    public static let trayImageSide = 96
    public static let imageSide = 512

    public static let minStickersPerPack = 3
    public static let maxStickersPerPack = 30

    public static let maxCharLimit128 = 128
    public static let maxEmojisCount = 3

    public static let maxStaticStickerAccessibilityTextLength = 125
    public static let maxAnimatedStickerAccessibilityTextLength = 255
}
