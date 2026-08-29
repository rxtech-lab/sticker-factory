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
/// **The mechanism.** A tail spacer is sized so that `turnHeight + spacer ==
/// viewport`, which is exactly the room the turn needs to be able to rest at the
/// top with the reserved space filling the rest. Placement then scrolls the user
/// message itself to the top of the viewport. As the reply grows, the spacer
/// shrinks toward zero, absorbing the growth in place.
///
/// Anchoring the *message* rather than the end of the reserved space is what
/// makes the placement self-correcting: a spacer that is momentarily too tall
/// leaves harmless empty room below, where anchoring the tail would push the
/// message up off the top of the screen and under the navigation bar by however
/// much the reservation was over.
///
/// **The list never follows the stream.** Once a turn is placed, the transcript
/// stays where the reader put it: no scroll-to-bottom on new content, no
/// re-anchoring while streaming, no throttled catch-up scrolls. A reply that
/// outgrows the viewport simply continues below the fold until the reader
/// scrolls. The only programmatic moves are placing a newly sent turn, holding
/// the reader's place when an older page is prepended, and — if
/// `placesLatestTurnOnAppear` is set — one initial placement when the transcript
/// first has content.
///
/// **The reservation belongs to the live session.** It starts when the user sends
/// a message. Reopening an already-answered chat scrolls to its real end without
/// rebuilding the reservation, so loaded history does not gain an empty tail.
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
    /// The active turn — the pinned user message and everything under it — measured
    /// as ONE view.
    ///
    /// It used to be the distance between two separately reported anchors, a user
    /// row's `minY` and a tail marker's. That subtraction is only correct while both
    /// anchors describe the same layout pass, and every relayout *above* the turn
    /// moves both: prepending a page of older messages, an image in old history
    /// finishing its load. Whichever anchor reports first leaves the pair describing
    /// two different layouts, and the difference between them is then off by the
    /// whole inserted height — which, ratcheted, collapsed the reservation for good.
    ///
    /// One view's own height cannot disagree with itself, so none of that arises:
    /// content above may move the turn, but never changes how tall it is.
    @State private var activeTurnHeight: CGFloat = 0
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

                    ForEach(historyMessages, id: \.messageID) { message in
                        rowContent(message)
                            .id(message.messageID)
                    }

                    activeTurn

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
                scroll(to: .transcriptEnd, proxy: proxy, animated: false)
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

    // MARK: - Content

    /// The pinned user message and everything under it, in one measured container.
    ///
    /// Not lazy, unlike the history above it: this is the turn the reader is looking
    /// at, so its rows are on screen anyway, and a container only reports a height
    /// once every row inside it has one.
    private var activeTurn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(activeTurnMessages, id: \.messageID) { message in
                rowContent(message)
                    .id(message.messageID)
            }

            trailingContent()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            updateActiveTurnHeight(height)
        }
    }

    // MARK: - Sentinel rows

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

    private var pinnedTurnFillsViewport: Bool {
        guard visibleContentHeight > 0 else { return false }
        return activeTurnHeight >= visibleContentHeight - MessageListConstants.minimumPinnedTailSpacing
    }

    // MARK: - Derived transcript state

    /// Where the active turn starts. `nil` means there is no reservation to make, and
    /// the whole transcript is history.
    private var activeTurnStartIndex: Int? {
        guard let pinnedID = pinning.pinnedUserMessageID else { return nil }
        return messages.firstIndex { $0.messageID == pinnedID }
    }

    private var historyMessages: ArraySlice<Message> {
        activeTurnStartIndex.map { messages[..<$0] } ?? messages[...]
    }

    private var activeTurnMessages: ArraySlice<Message> {
        activeTurnStartIndex.map { messages[$0...] } ?? messages[messages.endIndex...]
    }

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

        // A page of older messages arrived above everything the reader is looking at.
        // The scroll view keeps its offset through an insertion, so without this the
        // transcript silently jumps by the height of the whole inserted page — the
        // reader is dumped in the middle of history, and the reserved tail ends up an
        // unreachable screenful below.
        if let previousFirstID = oldToken.ids.first,
           previousFirstID != newToken.ids.first,
           newToken.ids.count > oldToken.ids.count,
           Array(newToken.ids.suffix(oldToken.ids.count)) == oldToken.ids {
            // Held to whichever row the reader was reading from: the pinned turn if a
            // turn is being held at the top, and otherwise the row that was first
            // before the page arrived — the one the "load earlier" control sat above.
            let anchorID = pinning.isPinningUserMessage
                ? (pinning.pinnedUserMessageID ?? previousFirstID)
                : previousFirstID
            scroll(to: .messageTop(anchorID), proxy: proxy, animated: false)
            return
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
        } else if isInitialPlacement {
            // Loaded history should land at its real end. Rebuilding the newest
            // turn's reservation here would add a viewport-sized empty tail.
            scroll(to: .transcriptEnd, proxy: proxy, animated: false)
            return
        } else {
            action = pinning.handleLastMessageChange(
                id: latestContentItem?.messageID,
                isUserMessage: latestContentItem?.isUserMessage == true,
                isStreaming: isStreaming
            )
        }

        if case .pinUserMessageToTop(let pinnedID) = action {
            canReleasePinnedUserMessageByScroll = false
            scroll(to: .messageTop(pinnedID), proxy: proxy, animated: !isInitialPlacement)
            return
        }

        applyPinningAction(action)
        if isInitialPlacement {
            scroll(to: .transcriptEnd, proxy: proxy, animated: false)
        }
    }

    // MARK: - Placement
    //
    // The only scrolls in this type. They run when a turn is newly pinned, when an
    // older page shifts the content out from under the reader, and once on first
    // content. Nothing here reacts to content growing.

    private enum PlacementTarget {
        /// Rest this message against the top of the viewport.
        case messageTop(Message.MessageID)
        /// The real end of the transcript.
        case transcriptEnd
    }

    private func scroll(to target: PlacementTarget, proxy: ScrollViewProxy, animated: Bool) {
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false

        pinTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            if animated {
                withAnimation(.spring(duration: MessageListConstants.pinAnimationSeconds, bounce: 0.05)) {
                    apply(target, proxy: proxy)
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
                    apply(target, proxy: proxy)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }

            // Only arm manual release once settled, or our own animated placement
            // would immediately look like a user scroll and release the pin.
            guard !Task.isCancelled, pinning.isPinningUserMessage else { return }
            canReleasePinnedUserMessageByScroll = true
        }
    }

    private func apply(_ target: PlacementTarget, proxy: ScrollViewProxy) {
        switch target {
        case .messageTop(let id):
            proxy.scrollTo(id, anchor: .top)
        case .transcriptEnd:
            proxy.scrollTo(MessageListConstants.bottomAnchorID, anchor: .bottom)
        }
    }

    private func releasePinnedUserMessage() {
        pinTask?.cancel()
        canReleasePinnedUserMessageByScroll = false
        pinning.releasePin()
    }

    private func clearPinnedUserMessage() {
        pinTask?.cancel()
        pinning.clear()
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

    private func updateActiveTurnHeight(_ value: CGFloat) {
        guard abs(value - activeTurnHeight) > 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            activeTurnHeight = value
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
    static let coordinateSpaceName = "message-list-content"
    static let minimumPinnedTailSpacing: CGFloat = 16
    static let userScrollDelta: CGFloat = 4
    static let placementSettleFrames = 8
    static let pinAnimationDuration: Duration = .milliseconds(250)
    static let pinAnimationSeconds: Double = 0.25
}
