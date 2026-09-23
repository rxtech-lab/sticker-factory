import AnimatedView
import CryptoKit
import Foundation
import ImageIO
import UIKit
import os

actor MessagesPlaybackService {
    private let logger = Logger(subsystem: "app.rxlab.stickerfactory.message", category: "playback")
    /// Failures that mean "the network is not there", as opposed to "the server said no". Only
    /// these fall back to the manifest cached on disk; anything else is a real error to surface.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost
    ]
    private let broker: SharedTokenBroker
    private let client: StickerLibraryClient
    private let root: URL
    init() throws {
        broker = SharedTokenBroker(configuration: try SharedAuthConfiguration(bundle: .main))
        client = try StickerLibraryClient(bundle: .main)
        let identifier = SharedAuthConfiguration.appGroupIdentifier
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw StickerCacheError.appGroupUnavailable
        }
        root = group.appending(path: "StickerFactoryPlayback", directoryHint: .isDirectory)
    }
    func accountID() async throws -> String {
        guard let id = try await broker.cachedSession()?.subject else { throw SharedAuthenticationError.missingCredentials }
        return id
    }
    private func authorized<Value: Sendable>(_ operation: (String) async throws -> Value) async throws -> Value {
        let session = try await broker.authenticatedSession()
        do {
            return try await operation(session.accessToken)
        } catch StickerLibraryError.unauthorized {
            let refreshed = try await broker.authenticatedSession(forceRefresh: true)
            guard refreshed.subject == session.subject else { throw SharedAuthenticationError.missingCredentials }
            return try await operation(refreshed.accessToken)
        }
    }
    private func folder(accountID: String, stickerID: String, revisionID: String) throws -> URL {
        let path = root.appending(path: StickerControlPreferences.digest(accountID), directoryHint: .isDirectory)
            .appending(path: StickerControlPreferences.digest(stickerID), directoryHint: .isDirectory)
            .appending(path: StickerControlPreferences.digest(revisionID), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    func bundle(stickerID: String, revisionID: String) async throws -> (String, StickerPlaybackBundle) {
        let account = try await accountID()
        let path = try folder(accountID: account, stickerID: stickerID, revisionID: revisionID).appending(path: "manifest.json")
        do {
            let bundle = try await authorized { token in
                try await client.fetchPlayback(stickerID: stickerID, revisionID: revisionID, accessToken: token)
            }
            try Task.checkCancellation()
            let accountMatches = account == (try await accountID())
            guard accountMatches, bundle.stickerId == stickerID, bundle.revisionId == revisionID,
                  bundle.version == 1, bundle.document.configuration != nil else {
                logger.error(
                    "playback metadata rejected sticker=\(stickerID, privacy: .private) revision=\(revisionID, privacy: .private) accountMatches=\(accountMatches) stickerMatches=\(bundle.stickerId == stickerID) revisionMatches=\(bundle.revisionId == revisionID) version=\(bundle.version) hasConfiguration=\(bundle.document.configuration != nil)"
                )
                throw StickerLibraryError.invalidResponse
            }
            do {
                _ = try bundle.document.validated()
            } catch {
                logger.error(
                    "playback document rejected sticker=\(stickerID, privacy: .private) revision=\(revisionID, privacy: .private) error=\(String(describing: error), privacy: .private)"
                )
                throw error
            }
            logger.info(
                "playback bundle accepted sticker=\(stickerID, privacy: .private) revision=\(revisionID, privacy: .private) assets=\(bundle.assets.count) layers=\(bundle.document.layers.count)"
            )
            try JSONEncoder().encode(bundle).write(to: path, options: .atomic)
            return (account, bundle)
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            guard account == (try await accountID()), let data = try? Data(contentsOf: path),
                  let bundle = try? JSONDecoder().decode(StickerPlaybackBundle.self, from: data),
                  bundle.revisionId == revisionID, bundle.stickerId == stickerID else { throw error }
            _ = try bundle.document.validated()
            return (account, bundle)
        }
    }
    func loadAssets(bundle: StickerPlaybackBundle, documents: [AnimatedDocument], accountID: String) async throws -> StickerRenderAssets {
        let directory = try folder(accountID: accountID, stickerID: bundle.stickerId, revisionID: bundle.revisionId)
        var required = Set(documents.flatMap(\.layers).filter { !$0.hidden }.flatMap { layer -> [String] in
            if case .sequence(let sequence) = layer { return [sequence.assetId] }
            return layer.referencedImageAssetIDs
        })
        for document in documents {
            if case .image(let id, _) = document.background { required.insert(id) }
        }
        let descriptors = bundle.assets.filter { required.contains($0.id) }
        let sized = descriptors.allSatisfy { $0.width > 0 && $0.height > 0 && $0.width <= 8192 && $0.height <= 8192 }
        let totalBytes = descriptors.reduce(0) { $0 + $1.byteSize }
        guard descriptors.count == required.count, totalBytes <= 128 * 1024 * 1024, sized else {
            logger.error(
                "playback assets rejected sticker=\(bundle.stickerId, privacy: .private) revision=\(bundle.revisionId, privacy: .private) required=\(required.count) described=\(descriptors.count) totalBytes=\(totalBytes) dimensionsValid=\(sized)"
            )
            throw StickerLibraryError.invalidResponse
        }
        let fullCost = descriptors.reduce(0.0) { $0 + Double($1.width) * Double($1.height) * 4 }
        let scale = min(1, sqrt(48 * 1024 * 1024 / max(1, fullCost)))
        var images: [String: UIImage] = [:]
        for asset in descriptors {
            try Task.checkCancellation()
            let path = directory.appending(path: "\(StickerControlPreferences.digest(asset.id)).png")
            let data: Data
            if let cached = try? Data(contentsOf: path), Self.verified(cached, asset: asset) {
                data = cached
            } else {
                let downloaded = try await authorized { token in
                    try await client.download(assetID: asset.id, accessToken: token, maximumByteCount: 25 * 1024 * 1024)
                }
                guard Self.verified(downloaded.data, asset: asset) else { throw StickerCacheError.checksumMismatch }
                data = downloaded.data
                try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(64, Int(Double(max(asset.width, asset.height)) * scale)),
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                logger.error("playback image decode failed asset=\(asset.id, privacy: .private) bytes=\(data.count) width=\(asset.width) height=\(asset.height)")
                throw StickerLibraryError.invalidResponse
            }
            images[asset.id] = UIImage(cgImage: image)
        }
        guard accountID == (try await self.accountID()) else { throw SharedAuthenticationError.missingCredentials }
        let keep = Set(required.map { directory.appending(path: "\(StickerControlPreferences.digest($0)).png") })
        trimDisk(keeping: keep.union([directory.appending(path: "manifest.json")]))
        return .init(images: images)
    }
    private static func verified(_ data: Data, asset: StickerPlaybackBundle.Asset) -> Bool {
        data.count == asset.byteSize && data.count < 25 * 1024 * 1024 && asset.mimeType == "image/png"
            && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == asset.sha256.lowercased()
    }
    func cachedRender(accountID: String, bundle: StickerPlaybackBundle, settings: StickerControlSettings, image: Bool,
                      size: SystemStickerSize = .default) throws -> PreparedStickerFile? {
        let url = try renderURL(accountID: accountID, bundle: bundle, settings: settings, image: image, size: size)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url.appendingPathExtension("json")),
              let firstOnly = try? JSONDecoder().decode(Bool.self, from: data) else { return nil }
        return .init(url: url, firstAnimationOnly: firstOnly)
    }
    func storeRender(_ export: RenderedStickerExport, accountID: String, bundle: StickerPlaybackBundle,
                     settings: StickerControlSettings, image: Bool, size: SystemStickerSize = .default) throws -> URL {
        let url = try renderURL(accountID: accountID, bundle: bundle, settings: settings, image: image, size: size)
        try Data(contentsOf: export.url).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let metadata = url.appendingPathExtension("json")
        try JSONEncoder().encode(export.firstAnimationOnly).write(to: metadata, options: .atomic)
        trimRenders(in: url.deletingLastPathComponent())
        trimDisk(keeping: [url, metadata, url.deletingLastPathComponent().appending(path: "manifest.json")])
        return url
    }
    /// Assets are compressed on disk; decoded images have a separate 48 MiB selection budget.
    private func trimDisk(keeping: Set<URL>) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int, Date)] = []
        for case let url as URL in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.1 }
        for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) where total > 128 * 1024 * 1024 && !keeping.contains(url) {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
    private func renderURL(accountID: String, bundle: StickerPlaybackBundle, settings: StickerControlSettings, image: Bool,
                           size: SystemStickerSize) throws -> URL {
        let key = try StickerControlPreferences.renderKey(
            accountID: accountID, stickerID: bundle.stickerId, revisionID: bundle.revisionId,
            settings: settings, image: image, size: size
        )
        let directory = try folder(accountID: accountID, stickerID: bundle.stickerId, revisionID: bundle.revisionId)
        return directory.appending(path: "render-\(key).png")
    }
    private func trimRenders(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let renders = files.filter { $0.lastPathComponent.hasPrefix("render-") && $0.pathExtension == "png" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
              > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for url in renders.dropFirst(8) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("json"))
        }
    }
    func reconcile(_ sections: [StickerSection]) async {
        guard let account = try? await accountID() else { return }
        let accountKey = StickerControlPreferences.digest(account)
        let accounts = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for directory in accounts where directory.lastPathComponent != accountKey { try? FileManager.default.removeItem(at: directory) }
        let directory = root.appending(path: accountKey)
        let keep = Dictionary(sections.flatMap(\.stickers).compactMap { sticker -> (String, String)? in
            guard let revision = sticker.playbackRevisionID else { return nil }
            return (StickerControlPreferences.digest(sticker.stickerID), StickerControlPreferences.digest(revision))
        }, uniquingKeysWith: { _, newer in newer })
        for sticker in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard let revision = keep[sticker.lastPathComponent] else { try? FileManager.default.removeItem(at: sticker); continue }
            let revisions = (try? FileManager.default.contentsOfDirectory(at: sticker, includingPropertiesForKeys: nil)) ?? []
            for old in revisions where old.lastPathComponent != revision {
                try? FileManager.default.removeItem(at: old)
            }
        }
    }
}
