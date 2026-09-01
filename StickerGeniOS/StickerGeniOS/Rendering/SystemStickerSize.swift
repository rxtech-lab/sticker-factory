import Foundation

/// Where the Messages sticker ladder starts.
///
/// No longer a user-facing choice. It used to be one — a picker in the export sheet that baked a
/// dimension into the published `system` rendition — and that was the wrong moment to ask, because
/// how big a sticker should arrive depends on the conversation it is going into. A publish now
/// renders every size the sticker can be sent at and WinkySticker picks between them at send time;
/// see `StickerExportMetadataPolicy.attachmentDimensions`.
///
/// What remains is the ladder's own vocabulary. `exportSystemSticker` starts at `.large`, which is
/// what the ≤500 KB rendition Messages carries has always begun at, and the smaller cases still name
/// the rungs below it for the tests that watch it walk.
///
/// A *starting rung*, not a guarantee: `StickerExporter` still has to land under Apple's 500 KB
/// ceiling, and dense artwork can force it down. Only this rendition is bounded that way — the three
/// attachment renditions are not, which is why none of them gives up frame rate.
nonisolated enum SystemStickerSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case large
    case medium
    case small

    static let `default` = SystemStickerSize.large

    var id: Self { self }

    var dimension: Int {
        switch self {
        case .large: 618
        case .medium: 408
        case .small: 300
        }
    }

    var label: String {
        switch self {
        case .large: String(localized: "Large")
        case .medium: String(localized: "Medium")
        case .small: String(localized: "Small")
        }
    }

    /// The transcript size Messages derives from `dimension`.
    var approximatePoints: Int { dimension / 3 }

    var detail: String {
        String(localized: "\(dimension) px · arrives about \(approximatePoints) pt wide")
    }
}
