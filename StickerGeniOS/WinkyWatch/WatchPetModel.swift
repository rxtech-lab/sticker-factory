import Foundation
import Observation
import OSLog
import WatchConnectivity
import WatchKit
import WidgetKit

/// The pet as this watch last heard of it from the phone.
///
/// The watch has no account of its own, so everything here arrives over WatchConnectivity: the
/// phone sends a snapshot and the server's drawing of the pose whenever the pet changes, and this
/// keeps the newest one on disk for the complications. Opening the app asks the phone for the
/// current pet, in case a transfer is still queued behind a sleeping link.
@MainActor
@Observable
final class WatchPetModel: NSObject {
    private(set) var snapshot: PetSnapshot?
    private(set) var pose: Data?
    /// Whether the phone has ever told this watch anything — "no pet" included.
    private(set) var hasHeardFromPhone = false
    /// A refresh the user asked for is waiting on the phone. Drives the overlay.
    private(set) var isRefreshing = false
    /// Set when a refresh the user asked for could not reach the phone. Drives the alert.
    var refreshFailure: String?

    @ObservationIgnored private let store: PetSnapshotStore?
    @ObservationIgnored private var writtenAt: Date?
    @ObservationIgnored private var refreshTimeout: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "app.rxlab.stickerfactory.watchkitapp", category: "pet")

    init(store: PetSnapshotStore? = PetSnapshotStore()) {
        self.store = store
        super.init()
        if let envelope = store?.envelope() {
            hasHeardFromPhone = true
            writtenAt = envelope.writtenAt
            snapshot = envelope.pet
            pose = store?.load()?.pose
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    #if DEBUG
    /// A model frozen in one state, for previews: no disk, no WatchConnectivity.
    init(previewSnapshot snapshot: PetSnapshot?, pose: Data? = nil, hasHeardFromPhone: Bool = true, isRefreshing: Bool = false) {
        store = nil
        self.snapshot = snapshot
        self.pose = pose
        self.hasHeardFromPhone = hasHeardFromPhone
        self.isRefreshing = isRefreshing
        super.init()
    }
    #endif

    /// Asks the phone for the pet. Silent when the app opens; with feedback when the user asked.
    func requestRefresh(userInitiated: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            if userInitiated {
                WKInterfaceDevice.current().play(.failure)
                refreshFailure = String(localized: "Open Winky on your iPhone, then try again.")
            }
            return
        }
        if userInitiated {
            WKInterfaceDevice.current().play(.click)
            isRefreshing = true
            // The answer is a transfer the phone may not send if nothing changed, so the overlay
            // gives up rather than spinning forever.
            refreshTimeout?.cancel()
            refreshTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.isRefreshing = false
            }
        }
        session.sendMessage([PetCompanion.requestKey: true], replyHandler: { _ in }, errorHandler: { [weak self] error in
            Task { @MainActor in
                guard let self, userInitiated else { return }
                self.finishRefresh()
                WKInterfaceDevice.current().play(.failure)
                self.refreshFailure = error.localizedDescription
            }
        })
    }

    /// Keeps `envelope` if it is newer than what the watch has, and redraws the complications.
    private func apply(_ envelope: PetSnapshotEnvelope, pose: Data?) {
        let wasRefreshing = isRefreshing
        finishRefresh()
        if let writtenAt, envelope.writtenAt <= writtenAt {
            if wasRefreshing { WKInterfaceDevice.current().play(.success) }
            return
        }
        do {
            try store?.save(envelope, pose: pose)
        } catch {
            log.error("pet snapshot not saved: \(error.localizedDescription, privacy: .public)")
        }
        writtenAt = envelope.writtenAt
        hasHeardFromPhone = true
        snapshot = envelope.pet
        self.pose = envelope.pet == nil ? nil : (pose ?? self.pose)
        if wasRefreshing { WKInterfaceDevice.current().play(.success) }
        WidgetCenter.shared.reloadTimelines(ofKind: PetCompanion.watchWidgetKind)
    }

    private func finishRefresh() {
        refreshTimeout?.cancel()
        refreshTimeout = nil
        isRefreshing = false
    }
}

extension WatchPetModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        Task { @MainActor in self.requestRefresh(userInitiated: false) }
    }

    /// A new pose. The file is deleted when this returns, so it is read here, before hopping actors.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let data = file.metadata?[PetCompanion.envelopeKey] as? Data,
              let envelope = try? PetSnapshotEnvelope.decode(data),
              let pose = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in self.apply(envelope, pose: pose) }
    }

    /// The pet was released, or the phone signed out.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[PetCompanion.envelopeKey] as? Data,
              let envelope = try? PetSnapshotEnvelope.decode(data) else { return }
        Task { @MainActor in self.apply(envelope, pose: nil) }
    }
}
