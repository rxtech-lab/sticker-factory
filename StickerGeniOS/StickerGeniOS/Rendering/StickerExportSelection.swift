import Foundation

/// Which files an export hands back.
///
/// A sticker and a video are two different things to want. The sticker rendition is what Messages
/// carries — transparent, under Apple's 500 KB ceiling, and small enough to be a sticker; the MP4 is
/// a full-size opaque video for anywhere that plays video and nothing that peels. Someone posting to
/// a feed wants the second and nothing else; someone building a sticker pack wants the first.
///
/// This only decides what is *shared*. An animated sticker that gets published still renders and
/// uploads its whole rendition set, because the library and the Messages extension are entitled to
/// every format regardless of which one the person in front of the share sheet asked for.
nonisolated enum StickerExportSelection: String, CaseIterable, Identifiable, Codable, Sendable {
    case sticker
    case video
    case both

    static let `default` = StickerExportSelection.both

    var id: Self { self }

    var label: String {
        switch self {
        case .sticker: "Sticker"
        case .video: "Video"
        case .both: "Both"
        }
    }

    var includesSticker: Bool { self != .video }
    var includesVideo: Bool { self != .sticker }

    /// - Parameter isAnimated: a static sticker has no video to offer, so the picker is hidden and
    ///   this description never names one.
    func detail(isAnimated: Bool) -> String {
        guard isAnimated else { return "A transparent PNG sticker." }
        return switch self {
        case .sticker: "A transparent sticker and GIF, sized for Messages."
        case .video: "An MP4 with a solid background, for video-only apps."
        case .both: "Sticker, GIF, and MP4 — everything this sticker can be."
        }
    }
}
