import Foundation
import os

enum FullSizeStickerLibraryError: Error, LocalizedError, Sendable {
    case unknownSticker
    case offline

    var errorDescription: String? {
        switch self {
        case .unknownSticker:
            String(localized: "That sticker is no longer in your library.")
        case .offline:
            String(localized: "Full-size images need a connection.")
        }
    }
}

/// What to attach for one sticker in `.image` mode, and where it came from.
///
/// `isFullSize == false` is a legitimate send, not a degraded one: for that sticker the ≤500 KB
/// file genuinely is the largest rendition that exists, so it is what an image send attaches.
struct ResolvedAttachment: Sendable {
    let fileURL: URL
    let title: String
    let isFullSize: Bool
}

/// The full-size surface's library.
///
/// Deliberately two caches. `MessagesLibraryService` keeps doing exactly what it does for the
/// sticker surface — fetch the listing, download every ≤500 KB rendition, reconcile — and that
/// cache backs the grid's thumbnails here. The full-size files are much larger and most of them are
/// never sent, so they are fetched one at a time on tap into a second, LRU-bounded cache.
///
/// Both surfaces now live in one extension, chosen per presentation context, so this is
/// constructed only when the extension comes up inside Messages. The system Stickers drawer never
/// pays for the second cache.
actor FullSizeStickerLibraryService {
    private let inner: MessagesLibraryService
    private let tokenBroker: SharedTokenBroker
    private let client: StickerLibraryClient
    private let fullCache: SharedStickerCache

    /// The last refresh's descriptors, which is where `previewAsset` lives. A tap resolves
    /// through this rather than re-fetching the listing.
    private var descriptorsByKey: [CacheKey: SystemStickerDescriptor] = [:]
    /// The system-cache file for each sticker, so a fallback send needs no network at all.
    private var systemFileURLsByKey: [CacheKey: URL] = [:]
    private var subject: String?

    private let logger = Logger(
        subsystem: "app.rxlab.stickerfactory.message",
        category: "renditions"
    )

    init(bundle: Bundle = .main) throws {
        let authConfiguration = try SharedAuthConfiguration(bundle: bundle)
        inner = try MessagesLibraryService(bundle: bundle)
        tokenBroker = SharedTokenBroker(configuration: authConfiguration)
        client = try StickerLibraryClient(bundle: bundle)
        fullCache = try SharedStickerCache(policy: .fullSize)
    }

    func refresh() async throws -> MessagesLibrarySnapshot {
        let snapshot = try await inner.refresh()
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: a duplicate key would be a cache
        // bug, and trapping the extension over one is a far worse outcome than showing it twice.
        descriptorsByKey = Dictionary(
            await inner.lastDescriptors().map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        systemFileURLsByKey = Dictionary(
            snapshot.stickers.map { ($0.key, $0.fileURL) },
            uniquingKeysWith: { first, _ in first }
        )

        // The full-size cache follows the same key set as the system one: a sticker that left the
        // library must not keep its file on disk. Only stickers actually sent as images are in the
        // index, so this is a no-op for everything never tapped — and an entry written under an
        // older variant scheme matches no key here and is swept for it.
        if let session = try? await tokenBroker.cachedSession() {
            subject = session.subject
            let live = Set(descriptorsByKey.keys.map { key in
                CacheKey(
                    sectionID: key.sectionID,
                    stickerID: key.stickerID,
                    variant: SystemStickerDescriptor.fullSizeVariant
                )
            })
            try? await fullCache.removeEntries(notIn: live, for: session.subject)
        }
        return snapshot
    }

    /// The file to attach for one sticker in `.image` mode, fetched once if it is not already
    /// cached.
    ///
    /// Falls back to the cached ≤500 KB Messages file when the server offered nothing bigger. That
    /// is a legitimate send rather than a degraded one — for that sticker, it is the only rendition
    /// there is — and it needs no network at all.
    func attachment(for key: CacheKey) async throws -> ResolvedAttachment {
        guard let descriptor = descriptorsByKey[key] else {
            throw FullSizeStickerLibraryError.unknownSticker
        }

        if let sized = descriptor.fullSizeDescriptor() {
            let session = try await resolvedSubject()
            if let cached = try await fullCache.cachedSticker(for: sized.key, subject: session) {
                try? await fullCache.markUsed(sized.key)
                return ResolvedAttachment(
                    fileURL: cached.fileURL, title: cached.title, isFullSize: true
                )
            }
            let stored = try await download(sized, subject: session)
            return ResolvedAttachment(
                fileURL: stored.fileURL, title: stored.title, isFullSize: true
            )
        }

        guard let fileURL = systemFileURLsByKey[key] else {
            throw FullSizeStickerLibraryError.unknownSticker
        }
        return ResolvedAttachment(fileURL: fileURL, title: descriptor.title, isFullSize: false)
    }

    /// True when a tap would need the network, so the caller can say so before spinning.
    func requiresDownload(_ key: CacheKey) async -> Bool {
        guard let descriptor = descriptorsByKey[key],
              let sized = descriptor.fullSizeDescriptor()
        else { return false }
        guard let subject = try? await resolvedSubject(),
              let cached = try? await fullCache.cachedSticker(for: sized.key, subject: subject) else {
            return true
        }
        return cached == nil
    }

    private func download(
        _ descriptor: SystemStickerDescriptor,
        subject: String
    ) async throws -> CachedSticker {
        let budget = StickerCachePolicy.fullSize.maximumByteCount
        func fetch(forceRefresh: Bool) async throws -> (AuthenticatedSession, DownloadedRendition) {
            let session = try await tokenBroker.authenticatedSession(forceRefresh: forceRefresh)
            return (session, try await client.download(
                assetID: descriptor.assetID,
                accessToken: session.accessToken,
                maximumByteCount: budget
            ))
        }

        let session: AuthenticatedSession
        let rendition: DownloadedRendition
        do {
            (session, rendition) = try await fetch(forceRefresh: false)
        } catch StickerLibraryError.unauthorized {
            // Mirrors MessagesLibraryService: one forced rotation, then give up.
            (session, rendition) = try await fetch(forceRefresh: true)
        }

        var verified = descriptor
        verified.mimeType = rendition.mimeType ?? descriptor.mimeType
        let stored = try await fullCache.store(rendition.data, descriptor: verified, for: session.subject)
        // Only after a successful store, so a trim can never evict the file just written.
        try? await fullCache.trim()
        return stored
    }

    private func resolvedSubject() async throws -> String {
        if let subject { return subject }
        guard let session = try await tokenBroker.cachedSession() else {
            throw SharedAuthenticationError.missingCredentials
        }
        subject = session.subject
        return session.subject
    }
}
