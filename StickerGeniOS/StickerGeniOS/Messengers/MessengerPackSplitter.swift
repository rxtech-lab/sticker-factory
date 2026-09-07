import Foundation

/// One pack the messenger will receive: a run of stickers of a single kind, small enough to fit.
nonisolated struct MessengerPackPart: Identifiable, Equatable, Sendable {
    var id: String
    /// The name the part is offered under. WhatsApp takes it as the pack name; Telegram asks for
    /// its own in the import flow.
    var title: String
    var kind: StickerKind
    var stickers: [Sticker]
    /// This part's position among the parts of the same kind, 1-based, and how many there are.
    var index: Int
    var count: Int
}

nonisolated enum MessengerSkipReason: Equatable, Sendable {
    /// The sticker has no published artwork to export from.
    case notPublished
    /// Published, but with no rendition for this messenger.
    ///
    /// Either it was added to the pack before this app prepared renditions, or its artwork could
    /// not be squeezed under the messenger's ceiling. Preparing happens when the pack is saved by
    /// its creator, so the way to a rendition is through Edit pack, not through this screen.
    case notPrepared
    /// Too few of this kind for the messenger's minimum; carries the count and the minimum.
    case belowMinimum(kind: StickerKind, count: Int, minimum: Int)

    func message(for destination: MessengerDestination) -> String {
        switch self {
        case .notPublished:
            return String(localized: "Not published yet, so there is no artwork to send.")
        case .notPrepared:
            return String(localized: "Not prepared for \(destination.label) yet. Its creator can prepare it from Edit pack.")
        case .belowMinimum(let kind, let count, let minimum):
            let kindLabel = kind == .static
                ? String(localized: "static stickers")
                : String(localized: "animated stickers")
            return String(localized: "\(destination.label) packs need at least \(minimum) \(kindLabel); this pack has \(count).")
        }
    }
}

nonisolated struct MessengerSkippedSticker: Identifiable, Equatable, Sendable {
    var sticker: Sticker
    var reason: MessengerSkipReason
    var id: String { sticker.id }
}

nonisolated struct MessengerSplitOutcome: Equatable, Sendable {
    var parts: [MessengerPackPart]
    var skipped: [MessengerSkippedSticker]
}

/// Turns one of this app's packs into as many messenger packs as the messenger's rules require.
///
/// Both messengers refuse a pack that mixes still and animated stickers, and both cap how many a
/// pack holds — so a pack here becomes one part per kind, each cut into balanced runs no longer
/// than the cap. Balanced rather than greedy: 31 stickers become 16 + 15, not 30 + 1, so no
/// part is left below WhatsApp's minimum by the accident of the count.
nonisolated enum MessengerPackSplitter {
    static func split(
        packID: String,
        packTitle: String,
        stickers: [Sticker],
        destination: MessengerDestination,
        excluding excluded: Set<String> = []
    ) -> MessengerSplitOutcome {
        let limits = destination.limits
        var skipped: [MessengerSkippedSticker] = []
        var eligible: [Sticker] = []
        for sticker in stickers where !excluded.contains(sticker.id) {
            if isExportable(sticker, for: destination) {
                eligible.append(sticker)
            } else if sticker.status != .published {
                skipped.append(.init(sticker: sticker, reason: .notPublished))
            } else {
                skipped.append(.init(sticker: sticker, reason: .notPrepared))
            }
        }

        var parts: [MessengerPackPart] = []
        let kinds: [StickerKind] = [.static, .animated]
        let presentKinds = kinds.filter { kind in eligible.contains { $0.kind == kind } }
        for kind in presentKinds {
            let members = eligible.filter { $0.kind == kind }
            guard members.count >= limits.minimumStickers else {
                skipped.append(contentsOf: members.map {
                    .init(sticker: $0, reason: .belowMinimum(kind: kind, count: members.count, minimum: limits.minimumStickers))
                })
                continue
            }
            let runs = balancedRuns(members, maximum: limits.maximumStickers)
            for (offset, run) in runs.enumerated() {
                parts.append(.init(
                    id: "\(packID)-\(kind.rawValue)-\(offset + 1)",
                    title: title(
                        packTitle: packTitle,
                        kind: kind,
                        includesKind: presentKinds.count > 1,
                        index: offset + 1,
                        count: runs.count
                    ),
                    kind: kind,
                    stickers: run,
                    index: offset + 1,
                    count: runs.count
                ))
            }
        }
        return .init(parts: parts, skipped: skipped)
    }

    /// Whether this member can be handed to this messenger.
    ///
    /// It used to be enough to have *any* published artwork, because the export drew from it and
    /// encoded on the spot. It no longer does: what gets handed over is the file prepared when the
    /// sticker was added to the pack, so having artwork says nothing about being sendable, and the
    /// question is now per-messenger — Telegram's animated budget is half of WhatsApp's, and
    /// clearing one ceiling is no promise about the other.
    static func isExportable(_ sticker: Sticker, for destination: MessengerDestination) -> Bool {
        sticker.supports(destination)
    }

    /// Cuts a list into the fewest runs of at most `maximum`, as evenly as the count allows.
    static func balancedRuns<T>(_ items: [T], maximum: Int) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let runCount = (items.count + maximum - 1) / maximum
        let base = items.count / runCount
        let extra = items.count % runCount
        var runs: [[T]] = []
        var start = 0
        for index in 0..<runCount {
            let size = base + (index < extra ? 1 : 0)
            runs.append(Array(items[start..<(start + size)]))
            start += size
        }
        return runs
    }

    /// "Cozy Cats", then "Cozy Cats · Animated" once both kinds are present, then
    /// "Cozy Cats · Animated (2/3)" once a kind needs several parts.
    static func title(packTitle: String, kind: StickerKind, includesKind: Bool, index: Int, count: Int) -> String {
        var title = packTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = String(localized: "Stickers") }
        if includesKind { title += " · " + kind.label }
        if count > 1 { title += " (\(index)/\(count))" }
        return title
    }
}
