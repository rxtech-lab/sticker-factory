import Foundation
import Observation
import OSLog
import TelegramStickersImport
import UIKit
import WASticker

/// What can go wrong fetching a prepared rendition.
nonisolated enum MessengerExportError: Error, LocalizedError, Equatable {
    /// The sticker has no rendition for this messenger — it was added to the pack before the app
    /// started preparing them, or its artwork would not fit the messenger's ceiling.
    case notPrepared(MessengerDestination)
    /// The server offered a container this app does not know how to hand over.
    case unexpectedFormat(String)

    var errorDescription: String? {
        switch self {
        case .notPrepared(let destination):
            String(localized: "This sticker isn't prepared for \(destination.label) yet.")
        case .unexpectedFormat:
            String(localized: "This sticker's prepared file could not be read.")
        }
    }
}

/// Progress through one export: which sticker is being fetched.
nonisolated struct MessengerExportProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
    var stickerTitle: String
    var detail: String?

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

/// Everything one messenger export screen holds: the parts the pack splits into, the files fetched
/// for them, and which parts have already been handed over.
///
/// This screen no longer encodes anything. The 512 px WebP, PNG and WebM copies were made once, on
/// the phone that added each sticker to the pack, and uploaded — so opening this sheet is a
/// download and nothing more, it works the same on the tenth open as the first, and a pack
/// installed from someone else costs its reader no encoding at all. A member without a rendition
/// cannot be sent and is shown grayed rather than quietly re-made.
@MainActor
@Observable
final class MessengerPackExportModel {
    enum Phase: Equatable {
        case idle
        case preparing
        case ready
        case cancelled
        case failed(String)
    }

    let destination: MessengerDestination
    let pack: StickerPackDetail
    let api: StickerAPIClientProtocol
    private let emojiStore: MessengerEmojiStore

    private(set) var phase: Phase = .idle
    private(set) var progress: MessengerExportProgress?
    private(set) var rendered: [String: MessengerPreparedSticker] = [:]
    /// Why a sticker could not be fetched, by id, in words the screen shows next to it.
    private(set) var failures: [String: String] = [:]
    /// Stickers the person chose to leave out — usually because they would not fit.
    private(set) var excluded: Set<String> = []
    /// Parts that have been placed on the pasteboard and opened in the messenger. A hand-off, not
    /// a receipt: nothing reports whether the messenger finished adding them.
    private(set) var handedOff: Set<String> = []
    /// The WhatsApp pack names, editable per part. Telegram names its packs in its own flow.
    var partTitles: [String: String] = [:]
    /// WhatsApp's 96 px tray image, built once the renditions are in hand.
    ///
    /// Computed during `prepare` rather than at Send, because building it can need a download: a
    /// tray image is not optional to WhatsApp — without one the whole pack is refused, not one
    /// sticker — so if the rendition will not decode, the sticker's published artwork is fetched
    /// instead, and neither is something a button press can wait on.
    private(set) var trayIcon: Data?
    /// The emoji per sticker, seeded from the device-local store and written back as it changes.
    var emojis: [String: String] = [:] {
        didSet {
            for (stickerID, emoji) in emojis where oldValue[stickerID] != emoji {
                emojiStore.setEmoji(emoji, for: stickerID)
            }
        }
    }
    var errorMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "messenger-export")

    init(
        destination: MessengerDestination,
        pack: StickerPackDetail,
        api: StickerAPIClientProtocol,
        emojiStore: MessengerEmojiStore = MessengerEmojiStore()
    ) {
        self.destination = destination
        self.pack = pack
        self.api = api
        self.emojiStore = emojiStore
        for sticker in pack.stickers {
            // The creator's choice, unless this reader has made one of their own.
            emojis[sticker.id] = emojiStore.emoji(for: sticker)
        }
        for part in outcome.parts {
            partTitles[part.id] = part.title
        }
    }

    // MARK: - Parts

    /// How the pack cuts up for this messenger, given everything excluded so far.
    var outcome: MessengerSplitOutcome {
        MessengerPackSplitter.split(
            packID: pack.id,
            packTitle: pack.title,
            stickers: pack.stickers,
            destination: destination,
            excluding: excluded
        )
    }

    /// Every pack member, in order, whether or not it can be sent.
    ///
    /// The sheet lists all of them and grays the ones without a rendition, rather than dropping
    /// them out of sight — a member missing from a list it was expected in reads as a bug, where a
    /// grayed row with a reason beside it reads as an explanation.
    var allMembers: [Sticker] { pack.stickers }

    /// The stickers that will actually be fetched: every part's members, each once.
    var stickersToRender: [Sticker] {
        var seen = Set<String>()
        return outcome.parts.flatMap(\.stickers).filter { seen.insert($0.id).inserted }
    }

    func title(for part: MessengerPackPart) -> String {
        let custom = partTitles[part.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? part.title : custom
    }

    /// Whether every sticker in the part has been rendered, so the part can be sent.
    func isReady(_ part: MessengerPackPart) -> Bool {
        phase == .ready && part.stickers.allSatisfy { rendered[$0.id] != nil }
    }

    /// The members that failed to download, which is what stands between the part and Send.
    func blockers(for part: MessengerPackPart) -> [Sticker] {
        part.stickers.filter { failures[$0.id] != nil }
    }

    func exclude(_ stickerID: String) {
        excluded.insert(stickerID)
        failures[stickerID] = nil
        for part in outcome.parts where partTitles[part.id] == nil {
            partTitles[part.id] = part.title
        }
    }

    func include(_ stickerID: String) {
        excluded.remove(stickerID)
        // Back in the pack means back in the queue: it has no render yet, and a part that lists
        // it cannot be sent until it does.
        if phase == .ready, rendered[stickerID] == nil { prepare() }
    }

    // MARK: - Fetching

    /// Downloads the prepared rendition for every sticker the parts need.
    ///
    /// Concurrent, unlike the encode this replaced: these are network reads of a few hundred
    /// kilobytes each, and the reason the old loop ran one at a time — two 512² encoders would
    /// double peak memory for no gain — simply does not apply to them. Bounded all the same, so a
    /// hundred-sticker pack does not open a hundred sockets at once.
    ///
    /// `StickerAssetData.load` caches to disk and verifies the digest, so a second export of the
    /// same pack does no network work at all and an offline one still succeeds.
    func prepare() {
        task?.cancel()
        phase = .preparing
        errorMessage = nil
        let pending = stickersToRender.filter { rendered[$0.id] == nil }
        let total = pending.count
        progress = .init(completed: 0, total: total, stickerTitle: pending.first?.title ?? "", detail: String(localized: "Downloading"))
        let destination = destination
        let api = api
        task = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            await withTaskGroup(of: (String, Result<MessengerPreparedSticker, Error>)?.self) { group in
                var next = 0
                let inFlight = min(Self.concurrentDownloads, pending.count)
                func submit() {
                    guard next < pending.count else { return }
                    let sticker = pending[next]
                    next += 1
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        do {
                            return (sticker.id, .success(try await Self.fetch(sticker: sticker, destination: destination, api: api)))
                        } catch {
                            return (sticker.id, .failure(error))
                        }
                    }
                }
                for _ in 0..<inFlight { submit() }
                while let finished = await group.next() {
                    guard !Task.isCancelled else { break }
                    if let (stickerID, result) = finished {
                        switch result {
                        case .success(let prepared):
                            rendered[stickerID] = prepared
                            failures[stickerID] = nil
                        case .failure(let error) where error is CancellationError:
                            break
                        case .failure(let error):
                            Self.log.error("""
                                fetch failed sticker=\(stickerID, privacy: .public) \
                                error=\(error.localizedDescription, privacy: .public)
                                """)
                            failures[stickerID] = error.localizedDescription
                        }
                        completed += 1
                        progress = .init(
                            completed: completed,
                            total: total,
                            stickerTitle: pending.first { $0.id == stickerID }?.title ?? "",
                            detail: String(localized: "Downloading")
                        )
                    }
                    submit()
                }
                if Task.isCancelled { group.cancelAll() }
            }
            if !Task.isCancelled, destination == .whatsapp, trayIcon == nil {
                trayIcon = await buildTrayIcon()
            }
            progress = nil
            phase = Task.isCancelled ? .cancelled : .ready
            task = nil
        }
    }

    /// WhatsApp's tray image, from the first rendition that will decode.
    ///
    /// Falls back to the sticker's published artwork, which is a PNG every surface in this app can
    /// already read — worth one extra download, because the alternative is WhatsApp refusing the
    /// entire pack over a 96 px thumbnail.
    private func buildTrayIcon() async -> Data? {
        for sticker in stickersToRender {
            if let data = rendered[sticker.id]?.data,
               let tray = try? MessengerStickerRenderer.trayIconPNG(fromEncoded: data) {
                return tray
            }
        }
        Self.log.error("tray icon from renditions failed pack=\(self.pack.id, privacy: .public)")
        for sticker in stickersToRender {
            guard let asset = MessengerFrameSource.asset(for: sticker),
                  let artwork = try? await StickerAssetData.load(assetID: asset.id, expectedSHA256: asset.sha256, api: api),
                  let tray = try? MessengerStickerRenderer.trayIconPNG(fromEncoded: artwork)
            else { continue }
            return tray
        }
        return nil
    }

    /// How many renditions are fetched at once. Enough to keep a pack opening quickly, few enough
    /// that a large one does not saturate a phone's connection.
    static let concurrentDownloads = 4

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
        if phase == .preparing { phase = .cancelled }
    }

    /// The prepared rendition for one sticker, off the server.
    private static func fetch(
        sticker: Sticker,
        destination: MessengerDestination,
        api: StickerAPIClientProtocol
    ) async throws -> MessengerPreparedSticker {
        guard let asset = sticker.messengerAsset(for: destination) else { throw MessengerExportError.notPrepared(destination) }
        let data = try await StickerAssetData.load(assetID: asset.id, expectedSHA256: asset.sha256, api: api)
        try Task.checkCancellation()
        guard let prepared = MessengerPreparedSticker(stickerID: sticker.id, kind: sticker.kind, asset: asset, data: data) else {
            throw MessengerExportError.unexpectedFormat(asset.mimeType)
        }
        return prepared
    }

    // MARK: - Hand-off

    /// Puts one part on the pasteboard and opens the messenger.
    ///
    /// Returns once the messenger has been asked to open. The person finishes the import there and
    /// comes back for the next part; nothing here can know whether they did, which is why the
    /// screen calls this a hand-off rather than an install.
    func send(_ part: MessengerPackPart) {
        errorMessage = nil
        guard destination.isInstalled else {
            errorMessage = String(localized: "\(destination.label) is not installed on this iPhone.")
            return
        }
        let stickers = part.stickers.compactMap { rendered[$0.id] }
        guard stickers.count == part.stickers.count else {
            errorMessage = String(localized: "Some stickers in this pack are not ready yet.")
            return
        }
        do {
            switch destination {
            case .whatsapp: try sendToWhatsApp(part, stickers: stickers)
            case .telegram: try sendToTelegram(part, stickers: stickers)
            }
            AppTelemetry.event(
                "share",
                parameters: ["method": destination.rawValue, "content_type": "sticker_pack", "item_count": stickers.count]
            )
            handedOff.insert(part.id)
            Haptics.success()
        } catch {
            AppTelemetry.failure(error, operation: "share_pack")
            Self.log.error("hand-off failed part=\(part.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
            errorMessage = Self.describe(error)
            Haptics.failure()
        }
    }

    private func sendToWhatsApp(_ part: MessengerPackPart, stickers: [MessengerPreparedSticker]) throws {
        guard let first = stickers.first else { return }
        // Drawn from the pack's own first rendition, which is a WebP this app can read even though
        // it cannot write one. A tray image is not optional to WhatsApp — without it the whole pack
        // is refused, not one sticker — so a decode failure falls back to the sticker's published
        // artwork rather than taking the hand-off down with it.
        guard let trayData = trayIcon ?? (try? MessengerStickerRenderer.trayIconPNG(fromEncoded: first.data)) else {
            throw MessengerRenderError.renderFailed
        }
        let tray = try WAStickerImage(data: trayData, format: .png)
        var pack = try WAStickerPack(
            identifier: String(part.id.prefix(WAStickerLimits.maxCharLimit128)),
            name: String(title(for: part).prefix(WAStickerLimits.maxCharLimit128)),
            publisher: String(self.pack.creator.displayName.prefix(WAStickerLimits.maxCharLimit128)),
            trayImage: tray,
            isAnimated: part.kind == .animated,
            publisherWebsite: StickerShareRoute.homeURL.absoluteString
        )
        for sticker in stickers {
            let image = try WAStickerImage(data: sticker.data, format: .webp)
            try pack.add(try WASticker(image: image, emojis: [emojis[sticker.stickerID] ?? MessengerEmojiStore.defaultEmoji]))
        }
        try WAStickerInteroperability.send(
            pack,
            iOSAppStoreLink: StickerShareRoute.appStoreURL.absoluteString,
            androidPlayStoreLink: nil
        )
    }

    private func sendToTelegram(_ part: MessengerPackPart, stickers: [MessengerPreparedSticker]) throws {
        let set = StickerSet(software: AppConfiguration.defaultAppName, type: part.kind == .animated ? .video : .image)
        for sticker in stickers {
            let data: TelegramStickersImport.Sticker.StickerData = sticker.format == .webm ? .video(sticker.data) : .image(sticker.data)
            try set.addSticker(data: data, emojis: [emojis[sticker.stickerID] ?? MessengerEmojiStore.defaultEmoji])
        }
        try set.import()
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? WAStickerInteroperability.Failure {
            switch failure {
            case .whatsAppNotInstalled: return String(localized: "WhatsApp is not installed on this iPhone.")
            case .payloadNotSerializable, .sampleBundleIdentifier: return String(localized: "The pack could not be handed to WhatsApp.")
            }
        }
        if let failure = error as? StickersError {
            switch failure {
            case .telegramNotInstalled: return String(localized: "Telegram is not installed on this iPhone.")
            case .fileTooBig: return String(localized: "A sticker is over Telegram's size limit.")
            case .invalidDimensions: return String(localized: "A sticker is not the size Telegram expects.")
            case .countLimitExceeded: return String(localized: "Too many stickers for one Telegram set.")
            case .dataTypeMismatch: return String(localized: "The set mixes still and video stickers.")
            case .setIsEmpty: return String(localized: "There is nothing to send.")
            case .emojiIsEmpty: return String(localized: "Every sticker needs an emoji.")
            case .fileIsEmpty: return String(localized: "A sticker file is empty.")
            }
        }
        if let failure = error as? WAStickerPackError {
            return String(localized: "WhatsApp refused the pack: \(String(describing: failure)).")
        }
        return error.localizedDescription
    }
}
