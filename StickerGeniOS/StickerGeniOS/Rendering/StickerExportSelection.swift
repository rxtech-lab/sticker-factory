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
/// A share-sheet choice and nothing more. What a publish stores does not depend on it: the APNG is
/// always uploaded — it is what the library, the marketplace and every non-Messages surface read,
/// and the server accepts nothing else as an animated sticker's sharing rendition — and the WebP is
/// always attempted beside it. This picks which of the three is handed to whatever app the person
/// is sending to.
///
/// The option exists because the right answer genuinely differs by destination, and none of the
/// three is strictly better. APNG keeps 8-bit alpha, so soft edges survive against any background,
/// and it animates everywhere Apple renders images — but outside that it thins out fast: WhatsApp,
/// Discord uploads and most web embeds treat one as an ordinary PNG and show a frozen first frame.
/// GIF animates in all of them and pays with one bit of transparency, so every soft edge hard-cuts
/// against whatever it lands on. WebP is the smallest by a wide margin and gives up neither — soft
/// alpha and animation, in Apple's apps and in those same third-party ones — and pays instead at
/// the far end of the age range, where something predating iOS 14 shows nothing at all rather than
/// a still.
nonisolated enum StickerSharingFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case apng
    case gif
    /// Smallest of the three, and the newest thing that reads one.
    ///
    /// Every Apple platform since iOS 14 decodes WebP through ImageIO, so it animates in Messages
    /// and Photos exactly as the APNG does — while WhatsApp, Discord and every modern browser read
    /// it too, which is the reach GIF was chosen for. What it is not is universal: something old
    /// enough to predate the format shows nothing at all rather than a frozen first frame, which is
    /// why it is offered rather than made the default.
    case webp

    /// APNG, because the sticker is the point and Messages is where most of them are going. Someone
    /// sending somewhere that cannot play one can say so; someone who never opens the picker gets
    /// the smaller, better-looking file.
    static let `default` = StickerSharingFormat.apng

    var id: Self { self }

    var label: String {
        switch self {
        case .apng: String(localized: "PNG")
        case .gif: String(localized: "GIF")
        case .webp: String(localized: "WebP")
        }
    }

    var detail: String {
        switch self {
        case .apng: String(localized: "Smaller, with soft transparent edges. Animates in Messages and other Apple apps.")
        case .gif: String(localized: "Larger, with hard-cut edges. Animates anywhere — WhatsApp, Discord, the web.")
        case .webp: String(localized: "Smallest, with soft transparent edges. Animates in Messages, WhatsApp, and modern browsers.")
        }
    }
}
