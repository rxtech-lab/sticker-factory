import Foundation
import os

/// Reports each sticker the user sends from the extension, so the server can read it for the pet's mood.
///
/// Best effort by design: a send that fails to report only means the pet misses one mood, so
/// nothing here retries, queues, or tells the user. Peel-and-drag sends never pass through the
/// extension's code and are not reported at all.
actor PetSendReporter {
    private let logger = Logger(subsystem: "app.rxlab.stickerfactory.message", category: "pet")
    private let broker: SharedTokenBroker
    private let client: StickerLibraryClient

    init() throws {
        broker = SharedTokenBroker(configuration: try SharedAuthConfiguration(bundle: .main))
        client = try StickerLibraryClient(bundle: .main)
    }

    /// The context is read at the moment of the send, not when the reporter was built: the app may
    /// have written a fresher snapshot while the drawer stayed open, and the day may have turned.
    func report(stickerID: String) async {
        let context = PetContextSnapshot.current()
        do {
            let session = try await broker.authenticatedSession()
            do {
                try await client.recordPetSend(stickerID: stickerID, context: context, accessToken: session.accessToken)
            } catch StickerLibraryError.unauthorized {
                let refreshed = try await broker.authenticatedSession(forceRefresh: true)
                guard refreshed.subject == session.subject else { return }
                try await client.recordPetSend(stickerID: stickerID, context: context, accessToken: refreshed.accessToken)
            }
        } catch {
            logger.debug("pet send not reported sticker=\(stickerID, privacy: .private) error=\(String(describing: error), privacy: .private)")
        }
    }
}
