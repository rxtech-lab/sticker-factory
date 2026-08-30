import Foundation

/// Which files an export hands back.
///
/// A sticker and a video are two different things to want. The sticker rendition is what Messages
/// carries — transparent, under Apple's 500 KB ceiling, and small enough to be a sticker; the MP4 is
/// a full-size opaque video for anywhere that plays video and nothing that peels. Someone posting to
/// a feed wants the second and nothing else; someone building a sticker pack wants the first.
///
/// The sticker set is rendered and uploaded either way — the library and the Messages extension are
/// entitled to it regardless of what the person in front of the share sheet asked for. The video is
/// the exception: it is the slowest thing an export does and nothing on the platform reads it, so
/// choosing Sticker skips the encode outright. Wanting it later costs that encode then, not a
/// re-publish; see `StickerPublisher.publishedExports`.
nonisolated enum StickerExportSelection: String, CaseIterable, Identifiable, Codable, Sendable {
    case sticker
    case video
    case both

    static let `default` = StickerExportSelection.both

    var id: Self { self }

    var label: String {
        switch self {
        case .sticker: String(localized: "Sticker")
        case .video: String(localized: "Video")
        case .both: String(localized: "Both")
        }
    }

    var includesSticker: Bool { self != .video }
    var includesVideo: Bool { self != .sticker }

    /// - Parameter isAnimated: a static sticker has no video to offer, so the picker is hidden and
    ///   this description never names one.
    func detail(isAnimated: Bool) -> String {
        guard isAnimated else { return String(localized: "A transparent PNG sticker.") }
        return switch self {
        case .sticker: String(localized: "A transparent sticker and GIF, sized for Messages.")
        case .video: String(localized: "An MP4 with a solid background, for video-only apps.")
        case .both: String(localized: "Sticker, GIF, and MP4 — everything this sticker can be.")
        }
    }
}
