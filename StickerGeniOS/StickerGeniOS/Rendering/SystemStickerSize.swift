import Foundation

/// How big the sticker arrives in someone else's conversation.
///
/// Messages draws a sticker in the transcript at its own pixel size over three, so the exported
/// rendition's pixel dimension is the only thing that changes how large it lands — nothing about the
/// document does. `AnimatedCanvas` in particular cannot: positions there are normalized, so a canvas
/// resize that keeps the aspect ratio moves no pixel, and every exporter renders a square frame
/// regardless of what the canvas says.
///
/// This is a *starting rung*, not a guarantee. `StickerExporter` still has to land under Apple's
/// 500 KB ceiling, and dense artwork can force it down the ladder; asking for Large and receiving
/// Small is a legitimate outcome for a detailed animation.
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
        case .large: "Large"
        case .medium: "Medium"
        case .small: "Small"
        }
    }

    /// The transcript size Messages derives from `dimension`.
    var approximatePoints: Int { dimension / 3 }

    var detail: String { "\(dimension) px · arrives about \(approximatePoints) pt wide" }
}
