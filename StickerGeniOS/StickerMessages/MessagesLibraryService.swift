import Foundation

struct MessagesLibrarySnapshot: Sendable {
    let stickers: [CachedSticker]
    let isOffline: Bool
}

actor MessagesLibraryService {
    private let tokenBroker: SharedTokenBroker
    private let client: StickerLibraryClient
    private let cache: SharedStickerCache

    init(bundle: Bundle = .main) throws {
        let authConfiguration = try SharedAuthConfiguration(bundle: bundle)
        tokenBroker = SharedTokenBroker(configuration: authConfiguration)
        client = try StickerLibraryClient(bundle: bundle)
        cache = try SharedStickerCache()
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
               let stickers = try? await cache.cachedStickers(for: cachedSession.subject),
               !stickers.isEmpty {
                return MessagesLibrarySnapshot(stickers: stickers, isOffline: true)
            }
            throw error
        }

        try await cache.prepare(for: authenticated.subject)
        let existing = try await cache.cachedStickers(for: authenticated.subject)

        let session: AuthenticatedSession
        let descriptors: [SystemStickerDescriptor]
        do {
            let fetched = try await client.fetchLibrary(accessToken: authenticated.accessToken)
            session = authenticated
            descriptors = fetched
        } catch StickerLibraryError.unauthorized {
            do {
                let refreshed = try await tokenBroker.authenticatedSession(forceRefresh: true)
                let fetched = try await client.fetchLibrary(accessToken: refreshed.accessToken)
                session = refreshed
                descriptors = fetched
            } catch SharedAuthenticationError.refreshRejected {
                try? await cache.purge()
                throw SharedAuthenticationError.refreshRejected
            } catch {
                if !existing.isEmpty {
                    return MessagesLibrarySnapshot(stickers: existing, isOffline: true)
                }
                throw error
            }
        } catch {
            if !existing.isEmpty {
                return MessagesLibrarySnapshot(stickers: existing, isOffline: true)
            }
            throw error
        }

        let existingByStickerID = Dictionary(uniqueKeysWithValues: existing.map { ($0.stickerID, $0) })
        for descriptor in descriptors {
            if existingByStickerID[descriptor.stickerID]?.assetID == descriptor.assetID {
                continue
            }
            do {
                let rendition = try await client.download(descriptor, accessToken: session.accessToken)
                let verifiedDescriptor = SystemStickerDescriptor(
                    stickerID: descriptor.stickerID,
                    assetID: descriptor.assetID,
                    title: descriptor.title,
                    mimeType: rendition.mimeType ?? descriptor.mimeType,
                    byteSize: descriptor.byteSize,
                    sha256: descriptor.sha256,
                    updatedAt: descriptor.updatedAt
                )
                _ = try await cache.store(rendition.data, descriptor: verifiedDescriptor, for: session.subject)
            } catch StickerLibraryError.unauthorized {
                // Do not expose or retain a rendition that could not be authorized.
                continue
            } catch {
                // Preserve the last verified local rendition when one remote item
                // fails. Other library items can still update successfully.
                continue
            }
        }

        try await cache.removeEntries(
            notIn: Set(descriptors.map(\.stickerID)),
            for: session.subject
        )
        return MessagesLibrarySnapshot(
            stickers: try await cache.cachedStickers(for: session.subject),
            isOffline: false
        )
    }
}
