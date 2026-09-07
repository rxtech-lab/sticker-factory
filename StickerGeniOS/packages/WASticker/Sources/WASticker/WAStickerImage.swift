//
// Copyright (c) Meta Platforms, Inc. and affiliates.
// All rights reserved.
//
// This source code is licensed under the BSD-style license found in the
// LICENSE file in the root directory of this source tree.
//
// Adapted from WAStickersThirdParty/ImageData.swift. The sample decoded WebP through a bundled
// copy of YYImage; this reads the same facts through ImageIO, which has decoded WebP since iOS 14.

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sticker bytes plus what WhatsApp checks about them.
public struct WAStickerImage: Sendable, Equatable {
    public enum Format: String, Sendable {
        case png
        case webp
    }

    public let data: Data
    public let format: Format
    public let width: Int
    public let height: Int
    public let frameCount: Int
    /// Every frame's delay in milliseconds. Empty for a still.
    public let frameDurationsMilliseconds: [Int]

    public var isAnimated: Bool { frameCount > 1 }
    public var totalDurationMilliseconds: Int { frameDurationsMilliseconds.reduce(0, +) }
    public var minimumFrameDurationMilliseconds: Int { frameDurationsMilliseconds.min() ?? 0 }

    /// Reads the facts out of the container. Throws when ImageIO cannot decode it at all.
    public init(data: Data, format: Format) throws {
        guard !data.isEmpty else { throw WAStickerPackError.invalidImage }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw WAStickerPackError.invalidImage }
        let count = CGImageSourceGetCount(source)
        var durations: [Int] = []
        if count > 1 {
            for index in 0..<count {
                let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let webp = frame?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
                let png = frame?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                let seconds = (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                    ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double)
                    ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                    ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double)
                    ?? 0
                durations.append(Int((seconds * 1_000).rounded()))
            }
        }
        self.data = data
        self.format = format
        self.width = width
        self.height = height
        self.frameCount = count
        self.frameDurationsMilliseconds = durations
    }

    /// The checks `ImageData.imageDataIfCompliant` made in the sample, for a sticker or a tray icon.
    public func validate(asTray isTray: Bool) throws {
        if isTray {
            guard !isAnimated else { throw WAStickerPackError.animatedImagesNotSupported }
            guard data.count <= WAStickerLimits.maxTrayImageFileSize else {
                throw WAStickerPackError.imageTooBig(data.count, animated: false)
            }
            guard width == WAStickerLimits.trayImageSide, height == WAStickerLimits.trayImageSide else {
                throw WAStickerPackError.incorrectImageSize(width: width, height: height)
            }
        } else {
            let limit = isAnimated ? WAStickerLimits.maxAnimatedStickerFileSize : WAStickerLimits.maxStaticStickerFileSize
            guard data.count <= limit else { throw WAStickerPackError.imageTooBig(data.count, animated: isAnimated) }
            guard width == WAStickerLimits.imageSide, height == WAStickerLimits.imageSide else {
                throw WAStickerPackError.incorrectImageSize(width: width, height: height)
            }
            if isAnimated {
                guard minimumFrameDurationMilliseconds >= WAStickerLimits.minAnimatedStickerFrameDurationMilliseconds else {
                    throw WAStickerPackError.minFrameDurationTooShort(minimumFrameDurationMilliseconds)
                }
                guard totalDurationMilliseconds <= WAStickerLimits.maxAnimatedStickerTotalDurationMilliseconds else {
                    throw WAStickerPackError.totalAnimationDurationTooLong(totalDurationMilliseconds)
                }
            }
        }
    }
}
