import AnimatedView
import os
import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Everything the chat screen *does*: media loading, composer drafts, turn lifecycle and the
/// candidate/plan decisions. The view layout lives in `StickerChatView.swift`.
extension StickerChatView {
    /// A device edit is authored as `role: .user` so the agent reads it as the user's doing, but it
    /// still owns the revision it saved — so it gets the same attachment an assistant turn would.
    func revisionDocument(for message: ChatMessage) -> AnimatedDocument? {
        guard message.role == .assistant || message.kind == .deviceEdit else { return nil }
        guard let revisionID = message.revisionId else { return nil }
        return detail?.revisions.first(where: { $0.id == revisionID })?.document
    }

    func preloadMessageMedia() async {
        for message in messages {
            if let plan = message.plan, plan.plan.kind == .animated, plan.actionable {
                // A plan card's confirm button waits on this image, so a card that never becomes
                // tappable is either a plan with no concept to load — capture-led plans have none —
                // or an asset fetch that failed, and the two look identical on screen.
                StickerAssetStore.log.debug(
                    """
                    plan-reference: plan=\(plan.id, privacy: .public) \
                    concept=\(plan.conceptAssetId ?? "none", privacy: .public) \
                    generated=\(plan.generationCount) \
                    loaded=\(plan.conceptAssetId.map { assetStore.images[$0] != nil } ?? false)
                    """
                )
            }
            if let referenceID = message.plan?.conceptAssetId {
                await assetStore.load(assetID: referenceID, api: store.api)
            }
            for attachment in message.attachments {
                await assetStore.load(assetID: attachment.assetId, api: store.api)
            }
            if let document = revisionDocument(for: message) {
                await assetStore.preload(document: document, api: store.api)
            }
        }
    }

    /// Picking a photo attaches it, exactly as in `CreateStickerView.loadReferences`.
    ///
    /// Kept as two small copies rather than one shared helper because the two composers hold their
    /// drafts differently, and the only part genuinely worth sharing — the pipeline — already is.
    func loadReferences(_ items: [PhotosPickerItem]) async {
        // Emptied immediately, and never read as the source of truth again. A picker's `selection`
        // binding remembers everything ever chosen, so leaving items in it means a photo the user
        // later removed is still "selected" — and the next pick re-delivers it and it reappears,
        // which is exactly what made deletions look like they had not taken. Clearing it re-enters
        // this method with an empty array, which the guard drops.
        guard !items.isEmpty else { return }
        referenceItems = []

        var loaded: [PendingMediaAttachment] = []
        for (index, item) in items.prefix(max(0, 8 - references.count)).enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                var attachment = try MediaNormalizer.reference(
                    data: data,
                    basename: "chat-reference-\(references.count + index)"
                )
                attachment.source = item
                loaded.append(attachment)
            } catch {
                localError = error.localizedDescription
            }
        }
        references.append(contentsOf: loaded)
        if !loaded.isEmpty { Haptics.selection() }
    }

    /// Publishes a plan's visual into the sticker pack, so it can be sent from Messages.
    ///
    /// This is the whole point of the action and not a shortcut to it: Messages reads the published
    /// library, so the image becomes its own static sticker project and is exported the same way any
    /// finished sticker is. Nothing is generated, so it costs the user no model time — but it does
    /// cost a render and two uploads, which is why the menu item reports that it is working rather
    /// than looking like it did nothing.
    func addPlanImageToStickerPack(_ image: UIImage) async {
        guard !isAddingToStickerPack else { return }
        localError = nil
        packNotice = .init(message: String(localized: "Adding to your stickers…"), isWorking: true)
        do {
            try await store.addImageToStickerPack(image, title: stickerTitle)
            packNotice = .init(
                message: String(localized: "Added to your stickers. It's ready in Messages."),
                isWorking: false
            )
            Haptics.success()
        } catch {
            // The pill only ever says the work is going or went well; a failure belongs in the error
            // line, which is where every other thing that can go wrong on this screen reports.
            packNotice = nil
            guard !StickerStore.isCancellation(error) else { return }
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    /// Saves only the image the user long-pressed. Add-only authorization avoids asking to browse
    /// the rest of the library for an operation that never reads it.
    func savePlanImageToPhotoLibrary(_ image: UIImage) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            localError = String(localized: "Allow photo-library access in Settings to save this image.")
            Haptics.failure()
            return
        }
        do {
            try await Self.addToPhotoLibrary(image)
            localError = nil
            Haptics.success()
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    /// Photos runs the change block on a thread of its own choosing. This file is main-actor by
    /// default, so a block written inline above would be inferred `@MainActor` and trap the moment
    /// Photos called it off the main thread; `nonisolated` leaves it with no actor to check.
    nonisolated static func addToPhotoLibrary(_ image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// One line about the sticker-pack publish, and whether it is still going.
    ///
    /// `isWorking` is carried rather than inferred from the wording: it decides the spinner, whether
    /// the notice dismisses itself, and whether the menu item is still disabled — three things that
    /// must not be re-derived from a localized string.
    struct StickerPackNotice: Equatable {
        var message: String
        var isWorking: Bool
    }

    /// What the composer held, taken out of it.
    ///
    /// Sending empties the composer before it has anywhere to put what it took, so the draft travels
    /// with the request that is trying to deliver it — and comes back if that request is refused.
    struct ComposerDraft {
        var text: String
        var referenceItems: [PhotosPickerItem]
        var references: [PendingMediaAttachment]
    }

    func takeComposerDraft() -> ComposerDraft {
        let draft = ComposerDraft(text: text, referenceItems: referenceItems, references: references)
        text = ""
        referenceItems = []
        references = []
        rebuildComposerField()
        return draft
    }

    /// Replaces the text field with a fresh one carrying the current `text`.
    ///
    /// A `.vertical` axis text field keeps drawing what the user typed when its binding is written
    /// from code while it holds the keyboard — the field owns the editing session, and it does not
    /// re-read the binding on the way through. So emptying `text` is not enough to empty the
    /// composer: the field it is showing has to be a new one. Focus is handed back afterwards,
    /// because the field taking the keyboard with it is the whole reason this is not free.
    func rebuildComposerField() {
        guard composerFocused else {
            composerFieldGeneration &+= 1
            return
        }
        composerFieldGeneration &+= 1
        // The replacement does not exist until this update has been applied, so it can only be
        // focused on the next one — soon enough that the keyboard never leaves.
        Task { @MainActor in composerFocused = true }
    }

    func send(_ draft: ComposerDraft) async {
        let submittedText = draft.text
        let submittedReferenceItems = draft.referenceItems
        let submittedReferences = draft.references
        let value = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = value.isEmpty ? String(localized: "Use these reference images for the sticker.") : value
        let baseRevisionID = detail?.revisions.first(where: { $0.state == .candidate })?.id ?? detail?.activeRevisionId

        localError = nil
        // A settled pack notice is older news than the turn about to start; one still working keeps
        // its pill, because the work is still going whatever this screen does next.
        if packNotice?.isWorking == false { packNotice = nil }

        do {
            try await store.sendMessage(
                stickerID: stickerID,
                content: content,
                references: submittedReferences,
                mask: nil,
                targetLayerID: nil,
                intent: .chat,
                imagePlacement: .replace,
                baseRevisionID: baseRevisionID
            )
            localError = nil
        } catch {
            // Giving the text back is only correct when the send certainly never became a turn. If
            // it may have landed, the turn is already running: restoring the composer would show the
            // user their message twice and invite them to send a duplicate. Refetch instead, so the
            // real message and its job appear without waiting for the reconciliation poller.
            if (error as? SendMessageFailure)?.mayHaveBeenDelivered == true {
                await store.loadMessages(stickerID: stickerID)
                await store.loadDetail(stickerID: stickerID)
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Only into a composer still empty from the send. Once the user has started typing
                // again, the refused message must not shove itself in front of what they are writing
                // now — losing a rejected draft beats mangling a live one.
                text = submittedText
                referenceItems = Array((submittedReferenceItems + referenceItems).prefix(8))
                references = Array((submittedReferences + references).prefix(8))
                // Same reason as the send: a field holding the keyboard shows what it was given
                // last, not what the binding says, so putting the draft back needs a new field.
                rebuildComposerField()
            }
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    /// The single beat that says the turn is over. A candidate announces itself through
    /// `candidate`'s own handler, so this stays quiet whenever one arrived with the turn.
    func turnEnded() {
        if stoppedByUser {
            stoppedByUser = false
        } else if store.jobs[stickerID]?.isFailed == true {
            Haptics.failure()
        } else if candidate == nil {
            Haptics.tap(.soft)
        }
    }

    /// Returns whether the decision landed, so the sheet knows whether to keep its spinner up or
    /// step aside for the error alert.
    @discardableResult
    func acceptCandidate(_ revision: StickerRevision) async -> Bool {
        Haptics.tap(.light)
        isDeciding = true
        defer { isDeciding = false }
        do {
            try await store.transition(stickerID: stickerID, revisionID: revision.id, action: .accept)
            StickerOnboardingTips.acceptedRevisionBecameAvailable()
            exportModel.invalidateExports()
            Haptics.success()
            localError = nil
            return true
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
            return false
        }
    }

    @discardableResult
    func rejectCandidate(_ revision: StickerRevision) async -> Bool {
        Haptics.tap(.light)
        isDeciding = true
        defer { isDeciding = false }
        do {
            try await store.transition(stickerID: stickerID, revisionID: revision.id, action: .reject)
            // The banner and the sheet only leave once the decision has landed; until then the
            // spinner on the tapped button is what says the tap registered. Hidden from here
            // rather than a reload later, when the refreshed detail happens to drop the candidate.
            rejectedRevisionIDs.insert(revision.id)
            showingCandidate = false
            // Deliberately not a `success`: the decision went through, but throwing work away is
            // not the note to end on.
            Haptics.tap(.medium)
            localError = nil
            return true
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
            return false
        }
    }

    func confirmPlan(_ record: PlanRecord) async {
        isConfirmingPlan = true
        defer { isConfirmingPlan = false }
        do {
            try await store.confirmPlan(stickerID: stickerID, planID: record.id)
            localError = nil
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    func rejectPlan(_ record: PlanRecord, reason: String?) async {
        do {
            try await store.cancelPlan(stickerID: stickerID, planID: record.id, reason: reason)
            localError = nil
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    func retryFailedTurn() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        do {
            try await store.retryFailedMessage(stickerID: stickerID)
            localError = nil
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    func stop() async {
        do {
            try await store.stopGeneration(stickerID: stickerID)
            localError = nil
        } catch {
            // The turn is still running, so the beat that ends it is still worth feeling.
            stoppedByUser = false
            localError = error.localizedDescription
            Haptics.failure()
        }
    }
}
