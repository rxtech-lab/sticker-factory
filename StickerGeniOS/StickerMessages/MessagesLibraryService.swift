import Foundation

struct MessagesLibrarySnapshot: Sendable {
    let sections: [StickerSection]
    let isOffline: Bool
    var isRefreshing = false

    /// Every sticker across every section, in display order.
    var stickers: [CachedSticker] { sections.flatMap(\.stickers) }

    /// Sections with something in them. A pack whose members all fell back to draft still arrives
    /// as an empty section so the cache can reconcile it; there is just nothing to draw.
    var populatedSections: [StickerSection] { sections.filter { !$0.stickers.isEmpty } }
}

/// Section ids the app last told us the user still has, read from the app group.
///
/// A hint, never a source of truth: absent means "no opinion" and the cache is served whole. Its
/// one job is to stop an offline extension from still offering a pack the user just removed.
enum SharedSectionAllowlist {
    static let defaultsKey = "StickerFactoryVisibleSectionIDs"

    static func current(
        defaults: UserDefaults? = UserDefaults(suiteName: SharedAuthConfiguration.appGroupIdentifier)
    ) -> Set<String>? {
        guard let values = defaults?.stringArray(forKey: defaultsKey), !values.isEmpty else { return nil }
        return Set(values)
    }

    static func filter(_ sections: [StickerSection], allowed: Set<String>?) -> [StickerSection] {
        guard let allowed else { return sections }
        return sections.filter { allowed.contains($0.id) }
    }
}

typealias MessagesLibraryUpdate = @Sendable (MessagesLibrarySnapshot) async -> Void

actor MessagesLibraryService {
    private let tokenBroker: SharedTokenBroker
    private let client: StickerLibraryClient
    private let cache: SharedStickerCache
    private var descriptors: [SystemStickerDescriptor] = []

    init(bundle: Bundle = .main) throws {
        let authConfiguration = try SharedAuthConfiguration(bundle: bundle)
        tokenBroker = SharedTokenBroker(configuration: authConfiguration)
        client = try StickerLibraryClient(bundle: bundle)
        cache = try SharedStickerCache()
    }

    init(tokenBroker: SharedTokenBroker, client: StickerLibraryClient, cache: SharedStickerCache) {
        self.tokenBroker = tokenBroker
        self.client = client
        self.cache = cache
    }

    /// The descriptors behind the last successful refresh.
    ///
    /// A `CachedSticker` describes the file on disk and deliberately says nothing about other
    /// renditions, so the full-size surface reads `previewAsset` from here instead. Empty until a
    /// refresh reaches the server: an offline snapshot is served from cache and has none.
    func lastDescriptors() -> [SystemStickerDescriptor] { descriptors }

    /// Cached sections the user still has, per the app's last published allowlist.
    ///
    /// Used for cached previews and offline paths; the live listing is authoritative.
    private static func allowed(_ sections: [StickerSection]) -> [StickerSection] {
        SharedSectionAllowlist.filter(sections, allowed: SharedSectionAllowlist.current())
    }

    /// Downloads the renditions a refresh still needs, four at a time, publishing rows as they land
    /// so the grid fills in rather than appearing all at once.
    ///
    /// One download per asset however many placements share it, and an asset that fails is skipped
    /// rather than failing the refresh: a library missing one sticker still opens.
    private func downloadPending(
        _ pending: [SystemStickerDescriptor],
        into stored: [CacheKey: CachedSticker],
        subject: String,
        token: String,
        onUpdate: MessagesLibraryUpdate
    ) async throws -> [CacheKey: CachedSticker] {
        var ready = stored
        let placements = Dictionary(grouping: pending, by: \.assetID)
        var seenAssets: Set<String> = []
        var queue = pending.filter { seenAssets.insert($0.assetID).inserted }.makeIterator()
        let client = self.client
        try await withThrowingTaskGroup(of: (String, DownloadedRendition?).self) { group in
            func enqueue(_ descriptor: SystemStickerDescriptor) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return (descriptor.assetID, try await client.download(descriptor, accessToken: token))
                    } catch {
                        try Task.checkCancellation()
                        return (descriptor.assetID, nil)
                    }
                }
            }
            for _ in 0..<4 {
                if let next = queue.next() { enqueue(next) }
            }
            let clock = ContinuousClock()
            var lastUpdate = clock.now
            while let (assetID, rendition) = try await group.next() {
                try Task.checkCancellation()
                if let rendition {
                    for var descriptor in placements[assetID] ?? [] {
                        descriptor.mimeType = rendition.mimeType ?? descriptor.mimeType
                        if let saved = try? await cache.store(rendition.data, descriptor: descriptor, for: subject) {
                            ready[saved.key] = saved
                        }
                    }
                    try Task.checkCancellation()
                    // Fill the first few rows immediately. Later results coalesce to avoid constant relayout.
                    if !ready.isEmpty && (ready.count <= 12 || lastUpdate.duration(to: clock.now) >= .milliseconds(150)) {
                        await onUpdate(MessagesLibrarySnapshot(
                            sections: StickerSection.grouped(Array(ready.values)), isOffline: false, isRefreshing: true
                        ))
                        lastUpdate = clock.now
                    }
                }
                if let next = queue.next() { enqueue(next) }
            }
        }
        return ready
    }

    func refresh(onUpdate: MessagesLibraryUpdate = { _ in }) async throws -> MessagesLibrarySnapshot {
        try Task.checkCancellation()
        descriptors = []
        // A local, account-scoped read comes before token rotation or any network request.
        if let session = try await tokenBroker.cachedSession() {
            let cached = try await cache.cachedSections(for: session.subject, validateFiles: false)
            try Task.checkCancellation()
            await onUpdate(MessagesLibrarySnapshot(
                sections: Self.allowed(cached), isOffline: false, isRefreshing: true
            ))
        }
        try Task.checkCancellation()
        let authenticated: AuthenticatedSession
        do {
            authenticated = try await tokenBroker.authenticatedSession()
        } catch is CancellationError {
            throw CancellationError()
        } catch SharedAuthenticationError.missingCredentials {
            try? await cache.purge()
            throw SharedAuthenticationError.missingCredentials
        } catch SharedAuthenticationError.refreshRejected {
            try? await cache.purge()
            throw SharedAuthenticationError.refreshRejected
        } catch {
            try Task.checkCancellation()
            if let cachedSession = try? await tokenBroker.cachedSession(),
               let sections = try? await cache.cachedSections(for: cachedSession.subject, validateFiles: false),
               !sections.isEmpty {
                return MessagesLibrarySnapshot(sections: Self.allowed(sections), isOffline: true)
            }
            throw error
        }

        try Task.checkCancellation()
        let existing = try await cache.cachedSections(for: authenticated.subject, validateFiles: false)

        let session: AuthenticatedSession
        let descriptors: [SystemStickerDescriptor]
        do {
            let fetched = try await client.fetchSections(accessToken: authenticated.accessToken)
            session = authenticated
            descriptors = fetched
        } catch StickerLibraryError.unauthorized {
            do {
                let refreshed = try await tokenBroker.authenticatedSession(forceRefresh: true)
                try Task.checkCancellation()
                guard refreshed.subject == authenticated.subject else {
                    throw SharedAuthenticationError.missingCredentials
                }
                let fetched = try await client.fetchSections(accessToken: refreshed.accessToken)
                session = refreshed
                descriptors = fetched
            } catch SharedAuthenticationError.missingCredentials {
                try? await cache.purge()
                throw SharedAuthenticationError.missingCredentials
            } catch SharedAuthenticationError.refreshRejected {
                try? await cache.purge()
                throw SharedAuthenticationError.refreshRejected
            } catch let error as StickerLibraryError where error.isUpdateRequired {
                throw error
            } catch {
                try Task.checkCancellation()
                if !existing.isEmpty {
                    return MessagesLibrarySnapshot(sections: Self.allowed(existing), isOffline: true)
                }
                throw error
            }
        } catch let error as StickerLibraryError where error.isUpdateRequired {
            throw error
        } catch {
            try Task.checkCancellation()
            if !existing.isEmpty {
                return MessagesLibrarySnapshot(sections: Self.allowed(existing), isOffline: true)
            }
            throw error
        }

        try Task.checkCancellation()
        self.descriptors = descriptors
        let reconciled = try await cache.reconcile(descriptors, for: session.subject)
        var ready = Dictionary(reconciled.flatMap(\.stickers).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        try Task.checkCancellation()
        await onUpdate(MessagesLibrarySnapshot(sections: reconciled, isOffline: false, isRefreshing: true))

        // Share one download across placements, with a small concurrency limit for the extension.
        // Each completed asset is usable immediately, even when another request stalls.
        let pending = descriptors.filter { ready[$0.key]?.assetID != $0.assetID }
        ready = try await downloadPending(
            pending, into: ready, subject: session.subject, token: session.accessToken, onUpdate: onUpdate
        )
        try Task.checkCancellation()
        return MessagesLibrarySnapshot(
            sections: StickerSection.grouped(Array(ready.values)), isOffline: false
        )
    }
}

private extension StickerLibraryError {
    var isUpdateRequired: Bool {
        if case .updateRequired = self { return true }
        return false
    }
}
