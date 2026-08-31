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
    /// - Parameter sharing: the container the animated rendition is shared in, since that is the
    ///   file the person will actually watch land in the share sheet.
    func detail(isAnimated: Bool, sharing: StickerSharingFormat = .default) -> String {
        guard isAnimated else { return String(localized: "A transparent PNG sticker.") }
        return switch self {
        case .sticker: String(localized: "A transparent sticker and \(sharing.label), sized for Messages.")
        case .video: String(localized: "An MP4 with a solid background, for video-only apps.")
        case .both: String(localized: "Sticker, \(sharing.label), and MP4 — everything this sticker can be.")
        }
    }
}

/// Which container an animated sticker is *shared* in.
///
/// A share-sheet choice and nothing more. A publish always uploads the APNG — it is what the
/// library, the Messages extension and the marketplace read, and the server accepts nothing else
/// for a new animated sticker — so this never changes what is stored, only which file is handed to
/// whatever app the person is sending to.
///
/// The option exists because the right answer genuinely differs by destination, and neither choice
/// is strictly better. APNG is several times smaller and keeps 8-bit alpha, so soft edges survive
/// against any background; it animates everywhere Apple renders images. Outside that it thins out
/// fast — WhatsApp, Discord uploads and most web embeds treat one as an ordinary PNG and show a
/// frozen first frame. GIF animates in all of them, and pays with one bit of transparency, so every
/// soft edge hard-cuts against whatever it lands on.
nonisolated enum StickerSharingFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case apng
    case gif

    /// APNG, because the sticker is the point and Messages is where most of them are going. Someone
    /// sending somewhere that cannot play one can say so; someone who never opens the picker gets
    /// the smaller, better-looking file.
    static let `default` = StickerSharingFormat.apng

    var id: Self { self }

    var label: String {
        switch self {
        case .apng: String(localized: "PNG")
        case .gif: String(localized: "GIF")
        }
    }

    var detail: String {
        switch self {
        case .apng: String(localized: "Smaller, with soft transparent edges. Animates in Messages and other Apple apps.")
        case .gif: String(localized: "Larger, with hard-cut edges. Animates anywhere — WhatsApp, Discord, the web.")
        }
    }
}
