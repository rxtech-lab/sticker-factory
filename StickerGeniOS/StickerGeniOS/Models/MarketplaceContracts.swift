import Foundation

/// The marketplace half of the v1 contract.
///
/// Kept out of `APIContracts.swift`, which is already long, but decoded by the same
/// `JSONDecoder.api`. Pack members are plain `Sticker` values — the server reuses
/// `StickerSummaryV1` verbatim for them, so nothing here needs a second sticker model.

nonisolated enum PackState: String, Codable, Hashable, Sendable {
    case draft, published, unlisted, removed
    case unknown

    /// A newer server adding a state must not poison a whole page of packs, so an unrecognized
    /// value degrades to `.unknown` rather than throwing. Mirrors `GenerationEventType`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PackState(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .draft: "Draft"
        case .published: "Published"
        case .unlisted: "Unlisted"
        case .removed: "Removed"
        case .unknown: "Unknown"
        }
    }
}

nonisolated struct PackCreator: Codable, Hashable, Sendable {
    var handle: String
    /// Never blank: the server falls back through the profile name, the account name, then `@handle`.
    var displayName: String
    var bio: String?
    var packCount: Int
    var isSelf: Bool

    var byline: String { isSelf ? "you" : displayName }
}

/// Placeholder only — every pack is free and nothing charges today.
nonisolated struct PackMonetization: Codable, Hashable, Sendable {
    var kind: String
    var priceCents: Int
    var currency: String
}

nonisolated struct StickerPack: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var slug: String
    var title: String
    var summary: String?
    var state: PackState
    var creator: PackCreator
    var itemCount: Int
    var installCount: Int
    var installed: Bool
    var isMine: Bool
    var coverStickers: [Sticker]
    var monetization: PackMonetization
    var publishedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var installCountLabel: String { PackInstallCount.label(installCount) }
}

/// How many people added a pack, phrased for display. Shared so the browse card and the detail
/// header can never drift apart.
nonisolated enum PackInstallCount {
    static func label(_ count: Int) -> String {
        switch count {
        case 0: "No installs yet"
        case 1: "1 install"
        default: "\(count.formatted(.number)) installs"
        }
    }
}

nonisolated struct StickerPackDetail: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var slug: String
    var title: String
    var summary: String?
    var state: PackState
    var creator: PackCreator
    var itemCount: Int
    var installCount: Int
    var installed: Bool
    var isMine: Bool
    var coverStickers: [Sticker]
    var monetization: PackMonetization
    var publishedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var stickers: [Sticker]

    var installCountLabel: String { PackInstallCount.label(installCount) }

    /// The summary view of this pack, so a detail fetch can refresh a browse list in place.
    var pack: StickerPack {
        StickerPack(
            id: id,
            slug: slug,
            title: title,
            summary: summary,
            state: state,
            creator: creator,
            itemCount: itemCount,
            installCount: installCount,
            installed: installed,
            isMine: isMine,
            coverStickers: coverStickers,
            monetization: monetization,
            publishedAt: publishedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

nonisolated enum LibrarySectionKind: String, Codable, Hashable, Sendable {
    case mine, pack

    /// An unrecognized kind is treated as a pack section: it renders under a header, which is the
    /// safe reading — mistaking a pack for "My Stickers" would imply the user can edit it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LibrarySectionKind(rawValue: raw) ?? .pack
    }
}

/// One group in the sectioned library: the user's own stickers, or an installed pack.
nonisolated struct LibrarySection: Codable, Identifiable, Hashable, Sendable {
    /// `"mine"`, or `"pack:<uuid>"`.
    var id: String
    var kind: LibrarySectionKind
    var title: String
    var packId: String?
    var packSlug: String?
    var creator: PackCreator?
    var installedAt: Date?
    var updatedAt: Date
    var stickers: [Sticker]
}

nonisolated struct LibrarySectionsResponse: Codable, Sendable {
    var sections: [LibrarySection]
    var generatedAt: Date

    var packSections: [LibrarySection] { sections.filter { $0.kind == .pack } }
}

nonisolated struct CreatorPacksResponse: Codable, Sendable {
    var creator: PackCreator
    var data: [StickerPack]
    var nextCursor: String?

    var items: [StickerPack] { data }
}

nonisolated struct CreatePackRequest: Codable, Sendable {
    var title: String
    var summary: String?
    var stickerIds: [String]
    var state: String

    init(title: String, summary: String? = nil, stickerIds: [String], publish: Bool = false) {
        self.title = title
        self.summary = summary
        self.stickerIds = stickerIds
        state = publish ? "published" : "draft"
    }
}

nonisolated struct UpdatePackRequest: Codable, Sendable {
    var title: String?
    var summary: String?
}

nonisolated struct ReorderPackItemsRequest: Codable, Sendable {
    var stickerIds: [String]
}

nonisolated struct UnpublishPackRequest: Codable, Sendable {
    var state: String
}

nonisolated struct InstallPackResponse: Codable, Sendable {
    var packId: String
    /// Deliberately no install count: install responses are replayed from the idempotency store
    /// for 24 hours, so an embedded count would be stale. Refetch the detail instead.
    var installed: Bool
}

nonisolated struct DeletePackResponse: Codable, Sendable {
    var packId: String
}
