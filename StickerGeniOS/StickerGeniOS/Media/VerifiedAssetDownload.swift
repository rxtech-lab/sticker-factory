import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Fetches an asset's bytes to disk and checks them against the digest the server recorded.
///
/// The image cache does this through Kingfisher's processor pipeline; everything that needs the
/// raw file — a published export for the share sheet, a video layer's clip for the decoder — does
/// it here. A file that does not match what the server recorded is not the asset that was
/// published, and it is neither shared nor decoded.
nonisolated enum VerifiedAssetDownload {
    enum Failure: Error, LocalizedError {
        case transport
        case digestMismatch

        var errorDescription: String? {
            switch self {
            case .transport: String(localized: "Couldn't download the asset.")
            case .digestMismatch: String(localized: "The downloaded asset didn't match what was published.")
            }
        }
    }

    struct Result: Sendable {
        var url: URL
        var asset: AssetRecord
        /// Whether the server recorded a digest and the bytes matched it. `false` only for an
        /// asset with no digest at all; a mismatch throws instead.
        var isVerified: Bool
    }

    /// - Parameter directory: where the file lands, named `<assetID>.<ext>`. A file already
    ///   there is reused without a second download — the name carries the asset's id and the id
    ///   never changes its bytes.
    static func fetch(
        assetID: String,
        into directory: URL,
        api: StickerAPIClientProtocol
    ) async throws -> Result {
        let download = try await api.assetDownload(assetID: assetID)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = UTType(mimeType: download.asset.mimeType)?.preferredFilenameExtension ?? "dat"
        let url = directory.appending(path: assetID).appendingPathExtension(fileExtension)
        let expected = download.asset.sha256
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            return Result(url: url, asset: download.asset, isVerified: expected != nil)
        }

        let (data, response) = try await URLSession.shared.data(from: download.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.transport
        }
        if let expected {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else { throw Failure.digestMismatch }
        }
        try data.write(to: url, options: .atomic)
        return Result(url: url, asset: download.asset, isVerified: expected != nil)
    }
}
