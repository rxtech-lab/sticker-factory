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

nonisolated struct CachedStickerImage: Sendable {
    let image: UIImage
    let isVerified: Bool
}

nonisolated enum StickerImageCache {
    private static let cache = ImageCache(name: "sticker-assets-v1")
    private static let manager = KingfisherManager(downloader: .default, cache: cache)

    static func load(
        assetID: String,
        expectedSHA256: String? = nil,
        api: StickerAPIClientProtocol
    ) async throws -> CachedStickerImage {
        let download = try await api.assetDownload(assetID: assetID)
        let expectedSHA256 = expectedSHA256 ?? download.asset.sha256
        let resource = KF.ImageResource(
            downloadURL: download.url,
            cacheKey: "sticker-asset.\(assetID)"
        )
        let result = try await manager.retrieveImage(
            with: resource,
            options: [
                .processor(VerifiedStickerImageProcessor(expectedSHA256: expectedSHA256)),
                .backgroundDecode,
                .waitForCache,
            ]
        )
        return CachedStickerImage(image: result.image, isVerified: expectedSHA256 != nil)
    }
}
