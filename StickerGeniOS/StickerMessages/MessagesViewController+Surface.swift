import Messages

/// The two shapes the controller can take, kept beside it rather than inside it: which surface the
/// host asked for, and the listing service that surface refreshes from. Both are nested on
/// `MessagesViewController` because neither means anything away from it.
extension MessagesViewController {
    /// Which of the two behaviours the host asked for.
    enum Surface {
        case sticker
        case fullSize

        init(_ context: MSMessagesAppPresentationContext) {
            self = context == .media ? .sticker : .fullSize
        }

        /// The recovery advice differs per surface, and wrongly telling someone in the full-size
        /// surface to peel and drag would send the small file they came here to avoid.
        var insertSurface: StickerInsertPolicy.StickerInsertSurface {
            switch self {
            case .sticker: .sticker
            case .fullSize: .fullSize
            }
        }
    }

    /// Both surfaces refresh the same listing; only the full-size one also resolves attachments,
    /// so the second (much larger) cache is never constructed for the Stickers drawer.
    enum Library: Sendable {
        case sticker(MessagesLibraryService)
        case fullSize(FullSizeStickerLibraryService)

        func refresh(onUpdate: MessagesLibraryUpdate) async throws -> MessagesLibrarySnapshot {
            switch self {
            case .sticker(let service): try await service.refresh(onUpdate: onUpdate)
            case .fullSize(let service): try await service.refresh(onUpdate: onUpdate)
            }
        }

        var fullSize: FullSizeStickerLibraryService? {
            guard case .fullSize(let service) = self else { return nil }
            return service
        }
    }
}
