import CryptoKit
import Foundation
import Kingfisher
import UIKit

nonisolated struct VerifiedStickerImageProcessor: ImageProcessor {
    let expectedSHA256: String?

    var identifier: String {
        "com.rxlab.sticker-asset.sha256.\(expectedSHA256?.lowercased() ?? "unverified")"
    }

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> UIImage? {
        if case .data(let data) = item, !accepts(data) { return nil }
        return DefaultImageProcessor.default.process(item: item, options: options)
    }

    func accepts(_ data: Data) -> Bool {
        guard let expectedSHA256 else { return true }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }
}

/// Verification plus `StickerPosterFrame`, for the surfaces that show one still frame.
///
/// Kingfisher hands a still `UIImage` to SwiftUI's `Image(uiImage:)`, and for GIF or APNG data that
/// image is frame zero — blank for any sticker that fades or slides in.
nonisolated struct PosterFrameStickerImageProcessor: ImageProcessor {
    let verification: VerifiedStickerImageProcessor

    var identifier: String { "\(verification.identifier).poster" }

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> UIImage? {
        guard case .data(let data) = item else {
            return verification.process(item: item, options: options)
        }
        guard verification.accepts(data) else { return nil }
        return StickerPosterFrame.image(from: data)
            ?? DefaultImageProcessor.default.process(item: item, options: options)
    }
}

nonisolated struct CachedStickerImage: Sendable {
    let image: UIImage
    let isVerified: Bool
}

nonisolated enum StickerImageCache {
    private static let cache = ImageCache(name: "sticker-assets-v1")
    private static let manager = KingfisherManager(downloader: .default, cache: cache)

    static var diskDirectory: URL { cache.diskStorage.directoryURL }

    static func clear() async {
        await cache.clearCache()
    }

    /// - Parameter posterFrame: for callers that render one still frame. See
    ///   `PosterFrameStickerImageProcessor`. The processor's identifier keys the cache, so a poster
    ///   and a plain decode of the same asset never overwrite each other.
    static func load(
        assetID: String,
        expectedSHA256: String? = nil,
        posterFrame: Bool = false,
        api: StickerAPIClientProtocol
    ) async throws -> CachedStickerImage {
        let download = try await api.assetDownload(assetID: assetID)
        let expectedSHA256 = expectedSHA256 ?? download.asset.sha256
        let resource = KF.ImageResource(
            downloadURL: download.url,
            cacheKey: "sticker-asset.\(assetID)"
        )
        let verification = VerifiedStickerImageProcessor(expectedSHA256: expectedSHA256)
        let processor: any ImageProcessor = posterFrame
            ? PosterFrameStickerImageProcessor(verification: verification)
            : verification
        let result = try await manager.retrieveImage(
            with: resource,
            options: [
                .processor(processor),
                .backgroundDecode,
                .waitForCache
            ]
        )
        return CachedStickerImage(image: result.image, isVerified: expectedSHA256 != nil)
    }
}
