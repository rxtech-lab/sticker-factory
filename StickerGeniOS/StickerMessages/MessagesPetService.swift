import Foundation
import os

/// The Pet page's line to the server: the pet, its pose, and the share that sends it.
///
/// The same credential dance as `PetSendReporter` — the shared token broker, then one forced
/// refresh on a 401 that is abandoned if the refresh lands on a different account — but loud where
/// that one is quiet: these calls are things the user is looking at, so their failures surface.
actor MessagesPetService {
    /// What the page needs in one go: the pet, and its pose if it has one to draw.
    struct Loaded: Sendable {
        let pet: MessagesPet
        let pose: Data?
    }

    /// The edge the pose is drawn at. Matches the widget's so the server can reuse its render, and
    /// is comfortably sharp at the size the card and the message bubble show it.
    static let poseSize = 320

    private let logger = Logger(subsystem: "app.rxlab.stickerfactory.message", category: "pet")
    private let broker: SharedTokenBroker
    private let client: StickerLibraryClient

    init() throws {
        broker = SharedTokenBroker(configuration: try SharedAuthConfiguration(bundle: .main))
        client = try StickerLibraryClient(bundle: .main)
    }

    /// `nil` when the account has no pet. The pose is best effort: a pet without a picture still
    /// has a name and stats worth showing, so a failed pose does not fail the load.
    func load() async throws -> Loaded? {
        try await authorized { client, token in
            guard let pet = try await client.fetchPet(accessToken: token) else { return nil }
            let pose = try? await client.fetchPetPose(size: Self.poseSize, accessToken: token)
            return Loaded(pet: pet, pose: pose)
        }
    }

    /// Records the share and returns the pet as it stands after it, with a fresh pose.
    ///
    /// The pose is fetched *after* the share because the share is what may have changed it. If the
    /// server answers with no pet — it was released on another device a moment ago — this throws,
    /// since there is nothing left to send.
    func share() async throws -> (share: MessagesPetShare, pose: Data?) {
        try await authorized { client, token in
            let share = try await client.sharePet(accessToken: token)
            guard share.pet != nil else { throw MessagesPetError.noPet }
            let pose = try? await client.fetchPetPose(size: Self.poseSize, accessToken: token)
            return (share, pose)
        }
    }

    private func authorized<T: Sendable>(
        _ body: @Sendable (StickerLibraryClient, String) async throws -> T
    ) async throws -> T {
        let session = try await broker.authenticatedSession()
        do {
            return try await body(client, session.accessToken)
        } catch StickerLibraryError.unauthorized {
            let refreshed = try await broker.authenticatedSession(forceRefresh: true)
            guard refreshed.subject == session.subject else {
                logger.error("pet request abandoned: account changed during refresh")
                throw StickerLibraryError.unauthorized
            }
            return try await body(client, refreshed.accessToken)
        }
    }
}

enum MessagesPetError: Error, LocalizedError, Sendable {
    case noPet
    case noConversation

    var errorDescription: String? {
        switch self {
        case .noPet:
            String(localized: "You don't have a pet right now. Adopt one in the Winky app.")
        case .noConversation:
            String(localized: "Open a conversation to send your pet.")
        }
    }
}
