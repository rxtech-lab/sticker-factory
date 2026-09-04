import Foundation

struct MessagesLibrarySnapshot: Sendable {
    let sections: [StickerSection]
    let isOffline: Bool

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

    /// The descriptors behind the last successful refresh.
    ///
    /// A `CachedSticker` describes the file on disk and deliberately says nothing about other
    /// renditions, so the full-size surface reads `previewAsset` from here instead. Empty until a
    /// refresh reaches the server: an offline snapshot is served from cache and has none.
    func lastDescriptors() -> [SystemStickerDescriptor] { descriptors }

    /// Cached sections the user still has, per the app's last published allowlist.
    ///
    /// Only used on the offline paths: a successful refresh is authoritative on its own.
    private static func allowed(_ sections: [StickerSection]) -> [StickerSection] {
        SharedSectionAllowlist.filter(sections, allowed: SharedSectionAllowlist.current())
    }

    func refresh() async throws -> MessagesLibrarySnapshot {
        let authenticated: AuthenticatedSession
        do {
            authenticated = try await tokenBroker.authenticatedSession()
        } catch SharedAuthenticationError.missingCredentials {
            try? await cache.purge()
            throw SharedAuthenticationError.missingCredentials
        } catch SharedAuthenticationError.refreshRejected {
            try? await cache.purge()
            throw SharedAuthenticationError.refreshRejected
        } catch {
            if let cachedSession = try? await tokenBroker.cachedSession(),
               let sections = try? await cache.cachedSections(for: cachedSession.subject),
               !sections.isEmpty {
                return MessagesLibrarySnapshot(sections: Self.allowed(sections), isOffline: true)
            }
            throw error
        }

        try await cache.prepare(for: authenticated.subject)
        let existing = try await cache.cachedSections(for: authenticated.subject)

        let session: AuthenticatedSession
        let descriptors: [SystemStickerDescriptor]
        do {
            let fetched = try await client.fetchSections(accessToken: authenticated.accessToken)
            session = authenticated
            descriptors = fetched
        } catch StickerLibraryError.unauthorized {
            do {
                let refreshed = try await tokenBroker.authenticatedSession(forceRefresh: true)
                let fetched = try await client.fetchSections(accessToken: refreshed.accessToken)
                session = refreshed
                descriptors = fetched
            } catch SharedAuthenticationError.refreshRejected {
                try? await cache.purge()
                throw SharedAuthenticationError.refreshRejected
            } catch let error as StickerLibraryError where error.isUpdateRequired {
                throw error
            } catch {
                if !existing.isEmpty {
                    return MessagesLibrarySnapshot(sections: Self.allowed(existing), isOffline: true)
                }
                throw error
            }
        } catch let error as StickerLibraryError where error.isUpdateRequired {
            throw error
        } catch {
            if !existing.isEmpty {
                return MessagesLibrarySnapshot(sections: Self.allowed(existing), isOffline: true)
            }
            throw error
        }

        // Keyed by (section, sticker): the same sticker can sit in two installed packs, and each
        // placement is its own cache entry even though both resolve to one file on disk.
        let existingByKey = Dictionary(
            uniqueKeysWithValues: existing.flatMap(\.stickers).map { ($0.key, $0) }
        )
        // One asset fetched once, however many sections reference it.
        var downloadedAssetIDs: Set<String> = []
        for descriptor in descriptors {
            if existingByKey[descriptor.key]?.assetID == descriptor.assetID {
                continue
            }
            do {
                let rendition: DownloadedRendition
                if downloadedAssetIDs.contains(descriptor.assetID),
                   let sibling = existingByKey.values.first(where: { $0.assetID == descriptor.assetID }),
                   let bytes = try? Data(contentsOf: sibling.fileURL) {
                    rendition = DownloadedRendition(data: bytes, mimeType: descriptor.mimeType)
                } else {
                    rendition = try await client.download(descriptor, accessToken: session.accessToken)
                    downloadedAssetIDs.insert(descriptor.assetID)
                }
                var verifiedDescriptor = descriptor
                verifiedDescriptor.mimeType = rendition.mimeType ?? descriptor.mimeType
                _ = try await cache.store(rendition.data, descriptor: verifiedDescriptor, for: session.subject)
            } catch StickerLibraryError.unauthorized {
                // Do not expose or retain a rendition that could not be authorized.
                continue
            } catch {
                // Preserve the last verified local rendition when one remote item fails. Other
                // items — and other sections — can still update successfully.
                continue
            }
        }

        try await cache.removeEntries(
            notIn: Set(descriptors.map(\.key)),
            for: session.subject
        )
        self.descriptors = descriptors
        return MessagesLibrarySnapshot(
            sections: try await cache.cachedSections(for: session.subject),
            isOffline: false
        )
    }
}

private extension StickerLibraryError {
    var isUpdateRequired: Bool {
        if case .updateRequired = self { return true }
        return false
    }
}
