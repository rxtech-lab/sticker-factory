import CryptoKit
import Foundation
import Observation
import OSLog

/// How far a preparation run has got, for the conversion screen.
nonisolated struct MessengerPreparationProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
    var stickerID: String
    var stickerTitle: String
    /// The messenger currently being encoded, when one is.
    var destination: MessengerDestination?
    /// How far through the current sticker the run is, 0–1: its download and each of its encodes
    /// are steps. An animation is a minute of work for one messenger, and a bar that moved only
    /// when a whole sticker finished sat still for all of it.
    var stepFraction: Double = 0
    /// What the encoder is doing right now — "Encoding frame 12 of 48" — when it says.
    var detail: String?

    var fraction: Double { total == 0 ? 0 : (Double(completed) + min(max(stepFraction, 0), 1)) / Double(total) }
}

/// What became of one sticker's two encodes.
nonisolated struct MessengerPreparationOutcome: Equatable, Sendable {
    /// The messengers this sticker can now be sent to.
    var prepared: Set<MessengerDestination> = []
    /// Why a messenger was not reached, in words the pack screen can show.
    var failures: [MessengerDestination: String] = [:]

    var isComplete: Bool { failures.isEmpty }
}

/// Encodes and uploads the WhatsApp and Telegram copies of the stickers just added to a pack.
///
/// This is where the messenger work moved to. It used to happen in the export sheet, once per
/// messenger, every single time anyone opened it — so a pack of thirty animations was thirty full
/// decode-and-encode passes before the first Send button lit up, and thirty more for the other
/// messenger. Doing it here instead means it happens once ever, on the phone of the person who
/// assembled the pack, and everyone who installs that pack afterwards just downloads the result.
///
/// Driven by `MessengerPreparationView`, which the composer and the editor push the moment a pack
/// is saved with a member that is missing a rendition. That screen is the only place the run is
/// visible, and it can only be left by cancelling or by waiting for the run to finish — so the
/// preparer is never encoding behind a screen that has forgotten about it.
///
/// Owned by `MarketplaceStore` rather than by the view all the same: the store is where the bound
/// stickers have to land, so that a pack screen already on the stack shows the new renditions
/// without another round trip.
@MainActor
@Observable
final class MessengerRenditionPreparer {
    private let api: StickerAPIClientProtocol
    private let emojiStore: MessengerEmojiStore

    private(set) var progress: MessengerPreparationProgress?
    private(set) var outcomes: [String: MessengerPreparationOutcome] = [:]
    /// True from the moment a run starts until it finishes or is cancelled.
    var isPreparing: Bool { progress != nil }
    /// Called with the sticker as the server now describes it, each time a bind lands. The store
    /// uses it to refresh every pack that holds the sticker.
    @ObservationIgnored var onStickerPrepared: ((Sticker) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?

    static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "messenger-renditions")

    init(api: StickerAPIClientProtocol, emojiStore: MessengerEmojiStore = MessengerEmojiStore()) {
        self.api = api
        self.emojiStore = emojiStore
    }

    /// Prepares every sticker that is still missing a rendition, and returns the ones it changed.
    ///
    /// Stickers already carrying both are skipped without so much as a download, which is what
    /// makes putting a sticker into a second pack free — and what makes an interrupted run
    /// resumable: whatever landed the first time is simply not attempted again.
    @discardableResult
    func prepare(_ stickers: [Sticker]) -> Task<Void, Never> {
        let pending = Self.pending(in: stickers)
        guard !pending.isEmpty else {
            progress = nil
            return Task {}
        }

        task?.cancel()
        // A run starts from a clean slate for the stickers it is about to touch: an outcome left
        // over from an earlier attempt would otherwise show as this run's result before this run
        // had reached the sticker.
        for sticker in pending { outcomes[sticker.id] = nil }
        progress = .init(completed: 0, total: pending.count, stickerID: pending[0].id, stickerTitle: pending[0].title, destination: nil)
        let task = Task { [weak self] in
            guard let self else { return }
            for (index, sticker) in pending.enumerated() {
                guard !Task.isCancelled else { break }
                progress = .init(
                    completed: index,
                    total: pending.count,
                    stickerID: sticker.id,
                    stickerTitle: sticker.title,
                    destination: nil
                )
                await prepareOne(sticker, index: index, total: pending.count)
            }
            progress = nil
            self.task = nil
        }
        self.task = task
        return task
    }

    /// Whether this sticker still needs a run: published, and short of at least one rendition.
    ///
    /// A draft is left alone — it has no artwork to encode from — and a member carrying both files
    /// has nothing to do, which is what makes saving a pack a second time free.
    nonisolated static func needsPreparation(_ sticker: Sticker) -> Bool {
        sticker.status == .published && !sticker.missingMessengerDestinations.isEmpty
    }

    /// The members a run would touch, in the order it would touch them.
    ///
    /// Static stickers go first. They encode in a fraction of the time an animation does, so
    /// leading with them means a mixed pack becomes partly sendable in seconds rather than after
    /// the whole queue has drained.
    nonisolated static func pending(in stickers: [Sticker]) -> [Sticker] {
        var seen = Set<String>()
        return stickers
            .filter { needsPreparation($0) && seen.insert($0.id).inserted }
            .sorted { left, right in
                left.kind == right.kind ? left.title < right.title : left.kind == .static
            }
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    /// One sticker: one artwork download, then one encode and upload per missing messenger.
    private func prepareOne(_ sticker: Sticker, index: Int, total: Int) async {
        var outcome = outcomes[sticker.id] ?? .init()
        guard let source = MessengerFrameSource.asset(for: sticker) else {
            for destination in sticker.missingMessengerDestinations {
                outcome.failures[destination] = MessengerRenderError.noArtwork.localizedDescription
            }
            outcomes[sticker.id] = outcome
            return
        }

        // The download is one step and each encode another, so the bar has something to show
        // between whole stickers.
        let missing = sticker.missingMessengerDestinations
        let steps = Double(1 + missing.count)
        progress = .init(
            completed: index,
            total: total,
            stickerID: sticker.id,
            stickerTitle: sticker.title,
            destination: nil,
            stepFraction: 0,
            detail: String(localized: "Downloading artwork…")
        )

        let artwork: Data
        do {
            artwork = try await StickerAssetData.load(assetID: source.id, expectedSHA256: source.sha256, api: api)
        } catch {
            guard !Task.isCancelled else { return }
            Self.log.error("""
                artwork download failed sticker=\(sticker.id, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """)
            for destination in sticker.missingMessengerDestinations {
                outcome.failures[destination] = error.localizedDescription
            }
            outcomes[sticker.id] = outcome
            return
        }

        // The artwork is decoded once and encoded twice. `MessengerFrameSource` reads frames from
        // the `Data` on demand, so handing the same bytes to both destinations costs one download
        // and no extra memory — the export sheet used to pay for both separately, per messenger.
        var whatsappAssetID: String?
        var telegramAssetID: String?
        for (step, destination) in missing.enumerated() {
            guard !Task.isCancelled else { return }
            progress = .init(
                completed: index,
                total: total,
                stickerID: sticker.id,
                stickerTitle: sticker.title,
                destination: destination,
                stepFraction: Double(step + 1) / steps,
                detail: nil
            )
            do {
                let assetID = try await encodeAndUpload(sticker: sticker, artwork: artwork, destination: destination)
                switch destination {
                case .whatsapp: whatsappAssetID = assetID
                case .telegram: telegramAssetID = assetID
                }
                outcome.prepared.insert(destination)
                outcome.failures[destination] = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Deliberately not fatal to the sticker. WhatsApp gives an animation 500 KB and
                // Telegram 256 KB, so artwork that comfortably clears one routinely misses the
                // other — and a pack that can go to one messenger is not a failed pack.
                Self.log.error("""
                    encode failed sticker=\(sticker.id, privacy: .public) \
                    destination=\(destination.rawValue, privacy: .public) \
                    error=\(error.localizedDescription, privacy: .public)
                    """)
                outcome.failures[destination] = error.localizedDescription
            }
        }

        guard whatsappAssetID != nil || telegramAssetID != nil else {
            outcomes[sticker.id] = outcome
            return
        }
        guard let revisionID = sticker.activeRevisionId else {
            outcomes[sticker.id] = outcome
            return
        }
        do {
            // One bind per sticker, carrying whichever encodes landed. The emoji rides along so a
            // pack installed by someone else arrives labelled the way its creator labelled it.
            let bound = try await api.bindMessengerRenditions(
                stickerID: sticker.id,
                request: .init(
                    revisionId: revisionID,
                    whatsappAssetId: whatsappAssetID,
                    telegramAssetId: telegramAssetID,
                    emoji: emojiStore.emoji(for: sticker)
                ),
                idempotencyKey: "messenger-bind-\(revisionID)"
            )
            onStickerPrepared?(bound)
        } catch {
            Self.log.error("bind failed sticker=\(sticker.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            for destination in outcome.prepared {
                outcome.failures[destination] = error.localizedDescription
            }
            outcome.prepared.removeAll()
        }
        outcomes[sticker.id] = outcome
    }

    private func encodeAndUpload(
        sticker: Sticker,
        artwork: Data,
        destination: MessengerDestination
    ) async throws -> String {
        let rendered = try await Self.renderOffMain(sticker: sticker, artwork: artwork, destination: destination) { [weak self] detail in
            Task { @MainActor [weak self] in self?.setDetail(detail, for: sticker.id, destination: destination) }
        }
        try Task.checkCancellation()
        progress?.detail = String(localized: "Uploading…")
        // The digest is in the key on purpose. `executeIdempotent` hashes the request body against
        // it, and VP9 rate control is not guaranteed to produce identical bytes twice — so a key
        // fixed to the sticker alone would turn an honest retry into a 409.
        let digest = SHA256.hash(data: rendered.data).map { String(format: "%02x", $0) }.joined()
        return try await api.upload(
            data: rendered.data,
            stickerID: sticker.id,
            kind: destination.assetKind,
            filename: "\(sticker.id)-\(destination.rawValue).\(rendered.format.rawValue)",
            mimeType: rendered.format.mimeType,
            sequence: nil,
            idempotencyKey: "messenger-\(destination.rawValue)-\(sticker.id)-\(digest.prefix(16))"
        )
    }

    /// The encode, off the main actor.
    ///
    /// `@concurrent` rather than a detached task, for the reason the export sheet's own renderer
    /// gave: a detached task would not inherit cancellation, and Cancel would have to wait out the
    /// whole frame loop instead of stopping it.
    @concurrent
    private static func renderOffMain(
        sticker: Sticker,
        artwork: Data,
        destination: MessengerDestination,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> MessengerRenderedSticker {
        try MessengerStickerRenderer.render(sticker: sticker, artwork: artwork, destination: destination, progress: progress)
    }

    /// The encoder's own word on what it is doing, dropped if the run has moved on since it spoke.
    private func setDetail(_ detail: String, for stickerID: String, destination: MessengerDestination) {
        guard progress?.stickerID == stickerID, progress?.destination == destination else { return }
        progress?.detail = detail
    }
}

nonisolated extension MessengerDestination {
    /// The asset kind this messenger's rendition is uploaded under.
    var assetKind: AssetKind {
        switch self {
        case .whatsapp: .messengerWhatsApp
        case .telegram: .messengerTelegram
        }
    }
}
