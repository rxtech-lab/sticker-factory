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
/// scrolls. The only programmatic moves are placing a newly sent turn, keeping a
/// held pin where placement left it when the geometry under it shifts, holding
/// the reader's place when an older page is prepended, and — if
/// `placesLatestTurnOnAppear` is set — one initial placement when the transcript
/// first has content.
///
/// **The reservation belongs to the live turn.** It starts when the user sends a
/// message and comes back with the reader if they leave and return while the
/// reply is still arriving. Reopening an already-answered chat scrolls to its
/// real end without rebuilding the reservation, so loaded history does not gain
/// an empty tail.
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
    /// The viewport reported by the live scroll view tracks keyboard and content margins.
    /// Subtracting its content insets again can collapse this to zero with the keyboard open.
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
    @State private var activeTurnMeasurement: MessageListTurnMeasurement<Message.MessageID>?
    private var activeTurnHeight: CGFloat {
        guard activeTurnMeasurement?.messageID == pinning.pinnedUserMessageID else { return 0 }
        return activeTurnMeasurement?.height ?? 0
    }
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
                placeInitialContent(proxy: proxy)
            }
            .onChange(of: pinTailSpacerHeight) { _, _ in
                // The room under the turn was just re-measured — the keyboard came or went, the
                // composer grew a banner, the turn itself changed size. Any of those can leave
                // the scroll offset clamped somewhere other than where the pin put it.
                holdPinnedUserMessage(proxy: proxy)
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
        .onGeometryChange(for: MessageListTurnMeasurement<Message.MessageID>.self) { geometry in
            MessageListTurnMeasurement(messageID: pinning.pinnedUserMessageID, height: geometry.size.height)
        } action: { measurement in
            updateActiveTurnMeasurement(measurement)
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
        if canReleasePinnedUserMessageByScroll,
           shouldReleasePinnedUserMessageForFilledTurn, !isUserDrivenScroll {
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
        if placesLatestTurnOnAppear, !hasPlacedInitialContent, !messages.isEmpty {
            hasPlacedInitialContent = true
            placeInitialContent(proxy: proxy)
            return
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
        } else {
            action = pinning.handleLastMessageChange(
                id: latestContentItem?.messageID,
                isUserMessage: latestContentItem?.isUserMessage == true,
                isStreaming: isStreaming
            )
        }

        if case .pinUserMessageToTop(let pinnedID) = action {
            canReleasePinnedUserMessageByScroll = false
            scroll(to: .messageTop(pinnedID), proxy: proxy, animated: true)
            return
        }

        applyPinningAction(action, proxy: proxy)
    }

    /// Where the reader lands when the transcript is first on screen.
    ///
    /// Two cases, and they land differently. A turn still being answered gets its
    /// reservation back: the message being waited on goes to the top with the room
    /// its reply is filling under it, exactly as it was when the reader left — the
    /// spacer is keyed off the pin, so without this the transcript comes back
    /// scrolled to its end with no room under the turn at all. An answered chat
    /// lands at its real end; rebuilding a finished turn's reservation would only
    /// add a viewport-sized empty tail to loaded history.
    ///
    /// Runs from both places a first transcript can come from — already in memory
    /// when the view appears, or arriving after it — so the two agree.
    private func placeInitialContent(proxy: ScrollViewProxy) {
        if isStreaming, let latestUserMessageID {
            let action = pinning.handleLastMessageChange(
                id: latestUserMessageID,
                isUserMessage: true,
                isStreaming: true
            )
            if case .pinUserMessageToTop(let pinnedID) = action {
                canReleasePinnedUserMessageByScroll = false
                scroll(to: .messageTop(pinnedID), proxy: proxy, animated: false)
                return
            }
        }
        scroll(to: .transcriptEnd, proxy: proxy, animated: false)
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

    /// Puts a held pin back where placement left it, without animation.
    ///
    /// Placement settles over a few frames and then stops; this is what keeps it
    /// true afterwards. Anything that changes the geometry under the turn — the
    /// keyboard, a banner joining the composer, content arriving or being replaced
    /// above or below — can leave the scroll offset clamped a little way from
    /// where the pin put it, and a message that is meant to be held at the top
    /// drifts up under the navigation bar or down into the middle of the screen.
    /// Re-asserting the message's own top is a no-op when nothing moved, so it
    /// never reads as the list following the reply.
    ///
    /// Only while the pin is held and settled: never during placement (which is
    /// re-asserting on its own), never once the pin is released, and never under
    /// the reader's finger — a user scroll is what releases the pin, and it must
    /// not have to fight for it.
    private func holdPinnedUserMessage(proxy: ScrollViewProxy) {
        guard pinning.isPinningUserMessage,
              canReleasePinnedUserMessageByScroll,
              !isUserDrivenScroll,
              let pinnedID = pinning.pinnedUserMessageID
        else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            apply(.messageTop(pinnedID), proxy: proxy)
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

    private func applyPinningAction(
        _ action: MessageListPinningAction<Message.MessageID>,
        proxy: ScrollViewProxy? = nil
    ) {
        switch action {
        case .none:
            break
        case .clearPin:
            clearPinnedUserMessage()
        case .pinUserMessageToTop:
            // Handled by `handleMessageListChange` and `placeInitialContent`, which
            // know whether this is the first placement and so whether to animate.
            break
        case .repinUserMessageToTop:
            // New content arrived under a held pin. The reserved spacing absorbs it,
            // so the message's own position is unchanged and holding it is a no-op —
            // the list never chases a reply that has outgrown the viewport. What it
            // does correct is a transcript replaced wholesale (a reload after the
            // server accepted the turn), where rows above the pin can change height.
            if let proxy { holdPinnedUserMessage(proxy: proxy) }
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

    private func updateActiveTurnMeasurement(_ value: MessageListTurnMeasurement<Message.MessageID>) {
        // A queued callback from the previous turn must never size or release the new pin.
        guard value.messageID == pinning.pinnedUserMessageID else { return }
        guard activeTurnMeasurement?.messageID != value.messageID
            || abs(value.height - (activeTurnMeasurement?.height ?? 0)) > 0.5 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            activeTurnMeasurement = value
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

private nonisolated struct MessageListTurnMeasurement<ID: Hashable & Sendable>: Equatable {
    var messageID: ID?
    var height: CGFloat
}
