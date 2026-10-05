import Foundation
import OSLog
import WatchConnectivity

/// The phone's end of the pet's channel to the watch.
///
/// The pose travels as a file transfer with the snapshot as its metadata: queued by the system,
/// delivered even when the watch app is not running, and small enough at `PetCompanion.poseSize` to
/// arrive quickly. "No pet" has no picture, so it travels as user info instead. The watch keeps
/// whichever it has heard of with the newest `writtenAt`, so the two queues may arrive in any order.
@MainActor
final class PetWatchBridge: NSObject {
    private static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "pet-watch")

    private var onRequest: (@MainActor () async -> Void)?
    private var onReachable: (@MainActor (_ force: Bool) -> Void)?
    /// The `writtenAt` of the last snapshot handed to WatchConnectivity, so reconnecting on every
    /// launch does not re-send a picture the watch already has.
    private let defaults: UserDefaults
    private static let lastSentKey = "PetWatchBridge.lastSentWrittenAt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate(onRequest: @escaping @MainActor () async -> Void, onReachable: @escaping @MainActor (_ force: Bool) -> Void) {
        self.onRequest = onRequest
        self.onReachable = onReachable
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    /// Sends `envelope`, unless `onlyIfNew` and the watch was already sent this exact one.
    func send(_ envelope: PetSnapshotEnvelope, poseURL: URL?, onlyIfNew: Bool = false) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let stamp = envelope.writtenAt.timeIntervalSince1970
        if onlyIfNew, defaults.object(forKey: Self.lastSentKey) as? Double == stamp { return }
        let data: Data
        do {
            data = try envelope.encoded()
        } catch {
            Self.log.error("pet envelope did not encode: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Only the newest pose is worth the trip; one still queued behind a slow link is stale.
        for transfer in session.outstandingFileTransfers where transfer.file.metadata?[PetCompanion.envelopeKey] != nil {
            transfer.cancel()
        }
        defaults.set(stamp, forKey: Self.lastSentKey)
        guard let poseURL else {
            session.transferUserInfo([PetCompanion.envelopeKey: data])
            return
        }
        // A copy, because the transfer reads the file later and the next publish replaces the original.
        let copy = FileManager.default.temporaryDirectory.appending(path: "pet-pose-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: poseURL, to: copy)
            session.transferFile(copy, metadata: [PetCompanion.envelopeKey: data])
        } catch {
            Self.log.error("pet pose not sent to watch: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension PetWatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        Task { @MainActor in self.onReachable?(false) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to another watch; talk to that one instead.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Installing the watch app after the pet was chosen should not mean waiting for its next mood.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        guard session.isWatchAppInstalled else { return }
        Task { @MainActor in self.onReachable?(true) }
    }

    /// The watch opening its app and asking for the pet. The answer travels as a transfer, so the
    /// reply only acknowledges — WatchConnectivity times out a reply that waits on the network.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let isRequest = message[PetCompanion.requestKey] != nil
        replyHandler([:])
        guard isRequest else { return }
        Task { @MainActor in await self.onRequest?() }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
