import Foundation
import SwiftUI

/// A message a `MessageList` can render.
///
/// Deliberately does **not** refine `Identifiable`: the pinning controller needs
/// a `Sendable` id, and asking for a separate `messageID` keeps that constraint
/// independent of whatever `id` the model already has.
nonisolated protocol MessageListItem {
    associatedtype MessageID: Hashable & Sendable

    var messageID: MessageID { get }
    var isUserMessage: Bool { get }
    /// Rows that are chrome rather than content — a typing indicator, a spacer.
    ///
    /// Excluded from "is there real content after the pinned user message?", so
    /// a spinner appearing on its own never releases the pin.
    var isMessageListAccessory: Bool { get }
}

nonisolated extension MessageListItem {
    var isMessageListAccessory: Bool { false }
}

/// A chat transcript that pins the latest user message to the top of the
/// viewport and leaves it there while the reply arrives below it.
///
/// **The mechanism.** Sending a message does not `scrollTo(userMessage, .top)`.
/// Instead a tail spacer is sized so that `turnHeight + spacer == viewport`, and
/// a 1pt anchor sits *below* that spacer. Scrolling to the anchor puts the
/// spacer's end at the viewport bottom, which is exactly the position where the
/// user's message rests at the top with reserved space filling the rest. As the
/// reply grows, the spacer shrinks toward zero, absorbing the growth in place.
///
/// **The list never follows the stream.** Once a turn is placed, the transcript
/// stays where the reader put it: no scroll-to-bottom on new content, no
/// re-anchoring while streaming, no throttled catch-up scrolls. A reply that
/// outgrows the viewport simply continues below the fold until the reader
/// scrolls. The only programmatic moves are placing a newly sent turn and, if
/// `placesLatestTurnOnAppear` is set, one initial placement when the transcript
/// first has content.
///
/// **The reservation outlives the session.** It is not a side effect of sending:
/// a transcript that arrives already answered rebuilds it from its newest user
/// message, so reopening a chat looks like the moment its last turn was sent
/// rather than dropping the reader at the raw end of the content.
///
/// The bottom spacing is therefore *computed*, never a fixed padding: it is
/// `viewport - turnHeight`, remeasured whenever the viewport changes (rotation,
/// keyboard, a growing composer) or the turn grows.
struct MessageList<
    Message: MessageListItem,
    RowContent: View,
    LeadingContent: View,
    TrailingContent: View
>: View {
    private let messages: [Message]
    private let isStreaming: Bool
    private let placesLatestTurnOnAppear: Bool
    private let rowContent: (Message) -> RowContent
    private let leadingContent: () -> LeadingContent
    private let trailingContent: () -> TrailingContent

    @State private var pinning = MessageListPinningController<Message.MessageID>()
    @State private var scrollPhase: ScrollPhase = .idle
    /// The height the turn actually gets to occupy — `ScrollGeometry.bounds`, the
    /// visible region *inside* the content insets, and the same region `scrollTo`
    /// aligns into.
    ///
    /// Two nearby values are both wrong here. The scroll view's frame height counts
    /// the strip the floating composer and the navigation bar cover (the transcript
    /// is full-bleed and holds that space with `contentMargins`/safe area), so
    /// reserving against it pushes the turn off the top by the inset total. And
    /// `containerSize` is already inset-adjusted — subtracting the insets from it
    /// double-counts them, which collapses the reservation to nothing.
    @State private var visibleContentHeight: CGFloat = 0
    // Optional on purpose: `nil` is "not measured yet", which is a different thing
    // from a measured 0 (the very top of the content). Collapsing the two lets an
    // unmeasured user message read as sitting at the top, which makes the turn look
    // as tall as the whole transcript and permanently ratchets the spacer to zero.
    @State private var latestUserMinY: CGFloat?
    @State private var tailMarkerMinY: CGFloat?
    @State private var activeTurnMaxMeasuredHeight: CGFloat = 0
    @State private var canReleasePinnedUserMessageByScroll = false
    @State private var hasPlacedInitialContent = false
    @State private var pinTask: Task<Void, Never>?

    init(
        messages: [Message],
        isStreaming: Bool = false,
        placesLatestTurnOnAppear: Bool = true,
        @ViewBuilder rowContent: @escaping (Message) -> RowContent,
        @ViewBuilder leadingContent: @escaping () -> LeadingContent,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent
    ) {
        self.messages = messages
        self.isStreaming = isStreaming
        self.placesLatestTurnOnAppear = placesLatestTurnOnAppear
        self.rowContent = rowContent
        self.leadingContent = leadingContent
        self.trailingContent = trailingContent
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    leadingContent()

                    ForEach(messages, id: \.messageID) { message in
                        let messageID = message.messageID
                        rowContent(message)
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.frame(in: .named(MessageListConstants.coordinateSpaceName)).minY
                            } action: { value in
                                // Keyed off the transcript, NOT the pin. A row reports its
                                // geometry when it lays out, and on a reopened chat that
                                // happens before anything decides to pin — guarding on the
                                // pin would drop the only report we ever get and leave the
                                // turn height unmeasurable for the rest of the session.
                                guard messageID == latestUserMessageID else { return }
                                updateLatestUserMinY(value)
                            }
                            .id(messageID)
                    }

                    trailingContent()

                    tailMarker
                    // The tail spacer is sized so that `turnHeight + spacer == viewport`
                    // (see `pinTailSpacerHeight`). The bottom anchor therefore sits BELOW
                    // the spacer: scrolling to it places the spacer's end at the viewport
                    // bottom, which is exactly the position where the latest user message
                    // rests at the top with the reserved space filling the rest.
                    pinTailSpacer
                    bottomAnchor
                }
                .coordinateSpace(.named(MessageListConstants.coordinateSpaceName))
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.bounds.height
            } action: { _, height in
                updateVisibleContentHeight(height)
            }
            .onScrollGeometryChange(for: MessageListScrollMetrics.self) { geometry in
                MessageListScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    visibleMaxY: geometry.visibleRect.maxY
                )
            } action: { _, _ in
                handleSettledScrollGeometry()
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { oldOffsetY, offsetY in
                guard isDirectUserScroll,
                      pinning.isPinningUserMessage,
                      canReleasePinnedUserMessageByScroll,
                      abs(offsetY - oldOffsetY) > MessageListConstants.userScrollDelta
                else { return }
                releasePinnedUserMessage()
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
            }
            .task {
                guard placesLatestTurnOnAppear, !hasPlacedInitialContent, !messages.isEmpty else { return }
                hasPlacedInitialContent = true
                restoreLatestTurnReservation()
                scrollLatestTurnIntoView(proxy: proxy, animated: false)
            }
            .onChange(of: isStreaming) { oldValue, newValue in
                applyPinningAction(
                    pinning.handleStreamingChange(oldValue: oldValue, newValue: newValue)
                )
            }
            .onChange(of: messageListChangeToken) { oldToken, newToken in
                handleMessageListChange(oldToken: oldToken, newToken: newToken, proxy: proxy)
            }
            .onDisappear {
                pinTask?.cancel()
            }
        }
    }

    // MARK: - Sentinel rows

    private var tailMarker: some View {
        Color.clear
            .frame(height: 1)
            .id(MessageListConstants.tailMarkerID)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .named(MessageListConstants.coordinateSpaceName)).minY
            } action: { value in
                updateTailMarkerMinY(value)
            }
    }

    private var pinTailSpacer: some View {
        Color.clear.frame(height: pinTailSpacerHeight)
    }

    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(MessageListConstants.bottomAnchorID)
    }

    // MARK: - Scroll phase

    private var isUserDrivenScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking, .decelerating: true
        case .idle, .animating: false
        @unknown default: false
        }
    }

    /// Excludes `.decelerating`, which our own animated placement passes through —
    /// treating that as a user scroll would let the app release its own pin the
    /// moment it set it.
    private var isDirectUserScroll: Bool {
        switch scrollPhase {
        case .interacting, .tracking: true
        case .idle, .animating, .decelerating: false
        @unknown default: false
        }
    }

    // MARK: - Geometry

    private var pinTailSpacerHeight: CGFloat {
        // Persistent reservation: as long as there is a latest user message, reserve
        // `viewport - turnHeight` at the bottom so the turn (latest user message →
        // end of content) can rest at the top of the viewport. This is keyed off the
        // tracked user message — NOT the transient `isPinningUserMessage` flag — so the
        // reserved space survives scrolling and the pin "releasing"; it only collapses
        // naturally as the turn grows to fill the viewport, or when the latest user
        // message changes (which resets the measurement to the new turn).
        guard pinning.pinnedUserMessageID != nil, visibleContentHeight > 0 else { return 0 }
        return max(0, visibleContentHeight - activeTurnHeight - MessageListConstants.minimumPinnedTailSpacing)
    }

    /// `nil` until both ends of the turn have reported — never a guess.
    private var rawActiveTurnMeasuredHeight: CGFloat? {
        guard let latestUserMinY, let tailMarkerMinY else { return nil }
        return max(0, tailMarkerMinY - latestUserMinY)
    }

    private var activeTurnHeight: CGFloat {
        // Use only the settled, ratcheted height (committed from the scroll-geometry
        // callback). Mixing in the live `rawActiveTurnMeasuredHeight` here would let a
        // mid-frame desync between the two geometry anchors momentarily shrink the spacer.
        activeTurnMaxMeasuredHeight
    }

    private var pinnedTurnFillsViewport: Bool {
        guard visibleContentHeight > 0 else { return false }
        return activeTurnHeight >= visibleContentHeight - MessageListConstants.minimumPinnedTailSpacing
    }

    // MARK: - Derived transcript state

    private var latestContentItem: Message? {
        messages.last { !$0.isMessageListAccessory }
    }

    private var latestUserMessageID: Message.MessageID? {
        messages.last { $0.isUserMessage }?.messageID
    }

    private var hasContentAfterPinnedUserMessage: Bool {
        guard let pinnedID = pinning.pinnedUserMessageID,
              let pinnedIndex = messages.firstIndex(where: { $0.messageID == pinnedID })
        else { return false }

        let nextIndex = messages.index(after: pinnedIndex)
        guard nextIndex < messages.endIndex else { return false }
        return messages[nextIndex...].contains { !$0.isMessageListAccessory }
    }

    private var shouldReleasePinnedUserMessageForFilledTurn: Bool {
        pinning.isPinningUserMessage
            && hasContentAfterPinnedUserMessage
            && pinnedTurnFillsViewport
    }

    private var messageListChangeToken: MessageListChangeToken<Message.MessageID> {
        MessageListChangeToken(
            ids: messages.map(\.messageID),
            latestContentID: latestContentItem?.messageID,
            latestUserMessageID: latestUserMessageID
        )
    }

    // MARK: - Change handling

    private func handleSettledScrollGeometry() {
        // Commit the active-turn height here rather than from the per-row geometry
        // callbacks. This callback fires once the scroll view's geometry has settled
        // for the frame, so `latestUserMinY` and `tailMarkerMinY` are guaranteed to
        // reflect the same layout pass. Reading them from the individual row
        // callbacks could capture a transient state where one anchor moved (e.g. a
        // lazy row above the turn was just realized while scrolling) but the other
        // had not — which would ratchet a bogus height and permanently collapse the
        // reserved tail spacer.
        updateActiveTurnMaxMeasuredHeight()

        // The turn now fills the viewport on its own; there is nothing left to hold
        // in place. Releasing only stops the re-assert — it never scrolls.
        if shouldReleasePinnedUserMessageForFilledTurn, !isUserDrivenScroll {
            releasePinnedUserMessage()
        }
    }

    private func handleMessageListChange(
        oldToken: MessageListChangeToken<Message.MessageID>,
        newToken: MessageListChangeToken<Message.MessageID>,
        proxy: ScrollViewProxy
    ) {
        // Drop a stale pin if its message is no longer present (e.g. switching
        // stickers or clearing a transcript). The persistent tail spacer is keyed off
        // `pinnedUserMessageID`, so a dangling id would otherwise reserve space for a
        // message that no longer exists.
        if let pinnedID = pinning.pinnedUserMessageID,
           !messages.contains(where: { $0.messageID == pinnedID }) {
            clearPinnedUserMessage()
        }

        // The first transcript to arrive is placed without animation: the reader is
        // arriving too, so there is nothing to preserve.
        let isInitialPlacement = placesLatestTurnOnAppear
            && !hasPlacedInitialContent
            && !messages.isEmpty
        if isInitialPlacement {
            hasPlacedInitialContent = true
        }

        let latestContentItem = latestContentItem
        let action: MessageListPinningAction<Message.MessageID>
        if oldToken.latestUserMessageID != newToken.latestUserMessageID,
           let latestUserMessageID = newToken.latestUserMessageID,
           isStreaming || latestContentItem?.isUserMessage == true {
            action = pinning.handleLastMessageChange(
                id: latestUserMessageID,
                isUserMessage: true,
                isStreaming: isStreaming
            )
        } else if isInitialPlacement, newToken.latestUserMessageID != nil {
            // A transcript that arrives already answered has no send to react to,
            // so the branch above never fires and the reservation would be missing
            // for the rest of the session. Rebuild it from the newest user message,
            // then place it — restoring keeps the measurements it already has, so
            // this deliberately skips the reset the freshly-sent path does below.
            restoreLatestTurnReservation()
            scrollLatestTurnIntoView(proxy: proxy, animated: false)
            return
        } else {
            action = pinning.handleLastMessageChange(
                id: latestContentItem?.messageID,
                isUserMessage: latestContentItem?.isUserMessage == true,
                isStreaming: isStreaming
            )
        }

        if case .pinUserMessageToTop = action {
            resetPinnedTurnMeasurements()
            canReleasePinnedUserMessageByScroll = false
            scrollLatestTurnIntoView(proxy: proxy, animated: !isInitialPlacement)
            return
        }

        applyPinningAction(action)
        if isInitialPlacement {
            scrollLatestTurnIntoView(proxy: proxy, animated: false)
        }
    }

    // MARK: - Placement
    //
    // The one and only scroll in this type. It runs when a turn is newly pinned,
    // and once on first content. Nothing here reacts to content growing.

    /// Positions the latest turn by scrolling to the bottom anchor — NOT by
    /// scrolling the user message to the top. See the type's documentation for why.
    private func scrollLatestTurnIntoView(proxy: ScrollViewProxy, animated: Bool) {
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false

        pinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            if animated {
                withAnimation(.spring(duration: MessageListConstants.pinAnimationSeconds, bounce: 0.05)) {
                    proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
                }
                try? await Task.sleep(for: MessageListConstants.pinAnimationDuration)
            }

            // Re-assert across several frames so the position tracks the tail spacer
            // as it settles to its final size (the turn height is measured a frame or
            // two after the freshly-added content lays out). This is placement
            // settling, not following: it ends after a handful of frames and never
            // restarts on new content.
            for _ in 0..<MessageListConstants.placementSettleFrames {
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }

            // Only arm manual release once settled, or our own animated placement
            // would immediately look like a user scroll and release the pin.
            guard !Task.isCancelled, pinning.isPinningUserMessage else { return }
            canReleasePinnedUserMessageByScroll = true
        }
    }

    /// Rebuilds the tail reservation for a transcript that was already loaded when
    /// the list appeared — the `.task` counterpart to the `handleMessageListChange`
    /// path, for when there is no transcript change to react to at all.
    private func restoreLatestTurnReservation() {
        guard let latestUserMessageID else { return }
        pinning.restoreLatestTurn(id: latestUserMessageID)
        canReleasePinnedUserMessageByScroll = false
        // Adopt whatever the rows have already reported rather than resetting. On a
        // reopened transcript the layout is settled, so a cleared measurement would
        // never be replaced; re-ratcheting from zero picks up the current turn.
        activeTurnMaxMeasuredHeight = 0
        updateActiveTurnMaxMeasuredHeight()
    }

    private func releasePinnedUserMessage() {
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false
        pinning.releasePin()
    }

    private func clearPinnedUserMessage() {
        pinTask?.cancel()
        pinning.clear()
        resetPinnedTurnMeasurements()
        canReleasePinnedUserMessageByScroll = false
    }

    private func applyPinningAction(_ action: MessageListPinningAction<Message.MessageID>) {
        switch action {
        case .none:
            break
        case .clearPin:
            clearPinnedUserMessage()
        case .pinUserMessageToTop:
            // Handled by `handleMessageListChange`, which knows whether this is the
            // first placement and so whether to animate.
            break
        case .repinUserMessageToTop:
            // New content arrived under a held pin. The reserved spacing absorbs it,
            // and the reader keeps the position they had — the list never chases a
            // reply that has outgrown the viewport.
            break
        case .releasePin:
            releasePinnedUserMessage()
        }
    }

    /// Only for a turn that is *about to* lay out — a fresh send. Clearing the
    /// measurements of a turn that is already on screen would strand them: the
    /// geometry callbacks fire on change, and nothing is changing.
    private func resetPinnedTurnMeasurements() {
        latestUserMinY = nil
        tailMarkerMinY = nil
        activeTurnMaxMeasuredHeight = 0
    }

    // MARK: - Measurement
    //
    // Every write below runs in an animation-suppressing transaction:
    // measurement must never animate, or the spacer visibly springs while the
    // turn is still laying out.

    private func updateVisibleContentHeight(_ value: CGFloat) {
        guard abs(value - visibleContentHeight) > 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            visibleContentHeight = value
        }
    }

    private func updateLatestUserMinY(_ value: CGFloat) {
        guard latestUserMinY.map({ abs(value - $0) > 0.5 }) ?? true else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            latestUserMinY = value
        }
    }

    private func updateTailMarkerMinY(_ value: CGFloat) {
        guard tailMarkerMinY.map({ abs(value - $0) > 0.5 }) ?? true else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            tailMarkerMinY = value
        }
    }

    private func updateActiveTurnMaxMeasuredHeight() {
        // Keep measuring the turn height while a latest user message is tracked, even
        // after the pin "releases", so the persistent tail spacer stays correctly sized.
        guard pinning.pinnedUserMessageID != nil, let measured = rawActiveTurnMeasuredHeight else { return }
        // Ratcheted: only ever grows. A transient shrink would grow the spacer
        // and visibly shove the transcript.
        guard measured > activeTurnMaxMeasuredHeight + 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            activeTurnMaxMeasuredHeight = measured
        }
    }
}

extension MessageList where LeadingContent == EmptyView {
    init(
        messages: [Message],
        isStreaming: Bool = false,
        placesLatestTurnOnAppear: Bool = true,
        @ViewBuilder rowContent: @escaping (Message) -> RowContent,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent
    ) {
        self.init(
            messages: messages,
            isStreaming: isStreaming,
            placesLatestTurnOnAppear: placesLatestTurnOnAppear,
            rowContent: rowContent,
            leadingContent: { EmptyView() },
            trailingContent: trailingContent
        )
    }
}

extension MessageList where LeadingContent == EmptyView, TrailingContent == EmptyView {
    init(
        messages: [Message],
        isStreaming: Bool = false,
        placesLatestTurnOnAppear: Bool = true,
        @ViewBuilder rowContent: @escaping (Message) -> RowContent
    ) {
        self.init(
            messages: messages,
            isStreaming: isStreaming,
            placesLatestTurnOnAppear: placesLatestTurnOnAppear,
            rowContent: rowContent,
            leadingContent: { EmptyView() },
            trailingContent: { EmptyView() }
        )
    }
}

nonisolated struct MessageListScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var visibleMaxY: CGFloat
}

/// One `Equatable` value covering structure *and* identity, so a single
/// `onChange` catches insertions, deletions and a new latest turn.
private nonisolated struct MessageListChangeToken<ID: Hashable & Sendable>: Equatable {
    var ids: [ID]
    var latestContentID: ID?
    var latestUserMessageID: ID?
}

private nonisolated enum MessageListConstants {
    static let bottomAnchorID = "message-list-bottom-anchor"
    static let tailMarkerID = "message-list-tail-marker"
    static let coordinateSpaceName = "message-list-content"
    static let minimumPinnedTailSpacing: CGFloat = 16
    static let userScrollDelta: CGFloat = 4
    static let placementSettleFrames = 8
    static let pinAnimationDuration: Duration = .milliseconds(250)
    static let pinAnimationSeconds: Double = 0.25
}
