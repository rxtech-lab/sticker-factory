import SwiftUI
import UIKit

// The poster icon vocabulary — emoji and drawn glyphs standing in for SF Symbols — split
// out of `DesignSystem.swift`, which holds the palette, type and surfaces they sit on.

/// The app's illustrative icon vocabulary, in the same voice the web uses: emoji for anything
/// that stands for a *thing* (a sticker, a pack, a step of the workflow), and `✦` for the brand
/// and every empty state — exactly the marks `server/app/page.tsx` draws.
///
/// Icon-only mechanisms use the hand-inked `PosterToolbarIcon` or chunky marks from
/// `PosterSymbol`; subjects use emoji-style artwork. Tabs, menus, and controls that pair an icon
/// with text deliberately keep SF Symbols for predictable sizing and native interaction behavior.
nonisolated enum PosterIcon {
    /// The brand and empty-state mark. Not an emoji — a glyph, so it takes the ink colour.
    static let mark = "✦"

    static let staticSticker = "🖼️"
    static let animatedSticker = "🎞️"

    static let welcome = "👋"
    static let write = "✍️"
    static let review = "👀"
    static let versions = "🗂️"
    static let publish = "📦"
    static let chat = "💬"

    static let share = "📤"
    static let save = "📥"
    static let sparkle = "✨"
    static let history = "🕰️"
    static let mail = "✉️"
    static let credits = "⚡"
    /// A screen that could not reach the server at all.
    static let offline = "📡"
}

/// Small, hand-inked glyphs for the navigation bar.
///
/// These actions used to use SF Symbols. Their strokes are intentionally a little uneven and
/// carry the poster palette's ink edge, so they read as tiny pieces of sticker art even when the
/// system gives the surrounding toolbar button its own material.
nonisolated enum PosterToolbarGlyph: CaseIterable {
    case credits
    case create
    case filter
    case sort
    case add
    case signOut

    var tilt: Double {
        switch self {
        case .credits: -5
        case .create: 3
        case .filter: -2
        case .sort: -1
        case .add: 2
        case .signOut: -3
        }
    }
}

struct PosterToolbarIcon: View {
    let glyph: PosterToolbarGlyph
    var size: CGFloat = 24

    var body: some View {
        let ink = AppColors.ink
        let coral = AppColors.coral
        let lime = AppColors.lime
        let sky = AppColors.sky

        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24
            let insetX = (canvasSize.width - 24 * scale) / 2
            let insetY = (canvasSize.height - 24 * scale) / 2
            let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
                CGPoint(x: insetX + x * scale, y: insetY + y * scale)
            }
            let outerStroke = StrokeStyle(
                lineWidth: 5 * scale,
                lineCap: .round,
                lineJoin: .round
            )
            let innerStroke = StrokeStyle(
                lineWidth: 2.6 * scale,
                lineCap: .round,
                lineJoin: .round
            )

            func drawInkedStroke(_ path: Path) {
                context.stroke(path, with: .color(ink), style: outerStroke)
                context.stroke(path, with: .color(coral), style: innerStroke)
            }

            func drawStickerFill(_ path: Path, color: Color) {
                let shadow = path.applying(
                    CGAffineTransform(translationX: 1.1 * scale, y: 1.2 * scale)
                )
                context.fill(shadow, with: .color(ink))
                context.fill(path, with: .color(color))
                context.stroke(
                    path,
                    with: .color(ink),
                    style: StrokeStyle(
                        lineWidth: 1.4 * scale,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }

            func sparkle(centerX: CGFloat, centerY: CGFloat, radius: CGFloat) -> Path {
                var path = Path()
                path.move(to: point(centerX, centerY - radius))
                path.addLine(to: point(centerX + radius * 0.24, centerY - radius * 0.24))
                path.addLine(to: point(centerX + radius, centerY))
                path.addLine(to: point(centerX + radius * 0.24, centerY + radius * 0.24))
                path.addLine(to: point(centerX, centerY + radius))
                path.addLine(to: point(centerX - radius * 0.24, centerY + radius * 0.24))
                path.addLine(to: point(centerX - radius, centerY))
                path.addLine(to: point(centerX - radius * 0.24, centerY - radius * 0.24))
                path.closeSubpath()
                return path
            }

            switch glyph {
            case .credits:
                var bolt = Path()
                bolt.move(to: point(13.5, 1.5))
                bolt.addLine(to: point(4.8, 13.1))
                bolt.addLine(to: point(10.8, 12.8))
                bolt.addLine(to: point(8.8, 22.3))
                bolt.addLine(to: point(19.3, 9.4))
                bolt.addLine(to: point(13.1, 9.7))
                bolt.addLine(to: point(15.5, 1.9))
                bolt.closeSubpath()
                drawStickerFill(bolt, color: coral)

            case .create:
                var wand = Path()
                wand.move(to: point(6.2, 19.3))
                wand.addLine(to: point(17.8, 7.1))
                drawInkedStroke(wand)
                drawStickerFill(sparkle(centerX: 18.6, centerY: 5.2, radius: 3.2), color: lime)
                drawStickerFill(sparkle(centerX: 5.2, centerY: 6.2, radius: 2.2), color: coral)
                drawStickerFill(sparkle(centerX: 18.6, centerY: 17.5, radius: 1.7), color: sky)

            case .filter:
                var funnel = Path()
                funnel.move(to: point(2.5, 4.1))
                funnel.addCurve(
                    to: point(11, 13),
                    control1: point(5.8, 7.2),
                    control2: point(8.5, 10.4)
                )
                funnel.addLine(to: point(11.1, 20.8))
                funnel.addLine(to: point(15.1, 18.3))
                funnel.addLine(to: point(14.9, 12.5))
                funnel.addCurve(
                    to: point(21.5, 3.6),
                    control1: point(17.4, 9.4),
                    control2: point(19.8, 6.6)
                )
                funnel.closeSubpath()
                drawStickerFill(funnel, color: sky)

            case .sort:
                var arrows = Path()
                arrows.move(to: point(7.3, 20.5))
                arrows.addLine(to: point(7.7, 3.5))
                arrows.move(to: point(2.8, 8.3))
                arrows.addLine(to: point(7.7, 3.5))
                arrows.addLine(to: point(12, 8.2))
                arrows.move(to: point(16.6, 3.5))
                arrows.addLine(to: point(16.3, 20.6))
                arrows.move(to: point(11.8, 15.9))
                arrows.addLine(to: point(16.3, 20.6))
                arrows.addLine(to: point(21.2, 15.7))
                drawInkedStroke(arrows)

            case .signOut:
                var door = Path()
                door.move(to: point(3, 3))
                door.addLine(to: point(13, 2))
                door.addLine(to: point(13, 21))
                door.addLine(to: point(3.5, 20))
                door.closeSubpath()
                drawStickerFill(door, color: sky)

                var arrow = Path()
                arrow.move(to: point(9, 10))
                arrow.addLine(to: point(16, 10))
                arrow.addLine(to: point(16, 6.5))
                arrow.addLine(to: point(22, 12))
                arrow.addLine(to: point(16, 17.5))
                arrow.addLine(to: point(16, 14))
                arrow.addLine(to: point(9, 14))
                arrow.closeSubpath()
                drawStickerFill(arrow, color: coral)

            case .add:
                var plus = Path()
                plus.move(to: point(12.1, 2.8))
                plus.addCurve(
                    to: point(11.8, 21.3),
                    control1: point(12.6, 8.7),
                    control2: point(11.4, 15.2)
                )
                plus.move(to: point(2.8, 12.2))
                plus.addCurve(
                    to: point(21.1, 11.8),
                    control1: point(8.4, 11.6),
                    control2: point(15.4, 12.4)
                )
                drawInkedStroke(plus)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(glyph.tilt))
        .accessibilityHidden(true)
    }
}

/// The rest of the app's compact icon vocabulary.
///
/// Names stay compatible with the semantic names the existing models expose, but no SF Symbol is
/// drawn. Mechanisms become chunky text marks, while objects become the same emoji-style artwork
/// already used throughout the poster design system.
struct PosterSymbol: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Text(Self.art(for: name))
            .fontDesign(.rounded)
            .accessibilityHidden(true)
    }

    /// SF Symbol name → the poster glyph drawn in its place.
    private nonisolated static let glyphs: [String: String] = [
        "plus": "+",
        "plus.circle": "+",
        "plus.circle.fill": "+",
        "minus": "−",
        "minus.circle": "−",
        "minus.circle.fill": "−",
        "xmark": "×",
        "xmark.circle": "×",
        "xmark.circle.fill": "×",
        "checkmark": "✓",
        "checkmark.circle": "✓",
        "checkmark.circle.fill": "✓",
        "checkmark.seal": "✓",
        "circle": "○",
        "square": "□",
        "checkmark.square.fill": "☑",
        "arrow.up": "↑",
        "arrow.clockwise": "↻",
        "clock.arrow.circlepath": "↻",
        "arrow.up.arrow.down": "↕",
        "chevron.up.chevron.down": "↕",
        "arrow.up.left.and.arrow.down.right": "⤢",
        "chevron.left": "‹",
        "chevron.right": "›",
        "ellipsis.circle": "•••",
        "stop.fill": "■",
        "play.fill": "▶",
        "pause.fill": "Ⅱ",
        "exclamationmark": "!",
        "exclamationmark.circle": "!",
        "exclamationmark.triangle.fill": "!",
        "info.circle": "i",
        "info.circle.fill": "i",
        "diamond": "◆",
        "diamond.fill": "◆",
        "square.dashed": "?",
        "questionmark.square.dashed": "?",
        "pencil": "✏️",
        "pencil.and.outline": "✏️",
        "trash": "🗑️",
        "photo": PosterIcon.staticSticker,
        "photo.on.rectangle": PosterIcon.staticSticker,
        "photo.stack": "🗂️",
        "photo.stack.fill": "🗂️",
        "rectangle.on.rectangle": "🗂️",
        "plus.square.on.square": "🗂️",
        "livephoto": PosterIcon.animatedSticker,
        "video": PosterIcon.animatedSticker,
        "waveform.path": PosterIcon.animatedSticker,
        "sparkles.rectangle.stack": PosterIcon.animatedSticker,
        "shippingbox": PosterIcon.publish,
        "shippingbox.fill": PosterIcon.publish,
        "square.and.arrow.down": PosterIcon.save,
        "square.and.arrow.down.fill": PosterIcon.save,
        "icloud.and.arrow.up": PosterIcon.share,
        "paperplane.fill": PosterIcon.share,
        "message.fill": PosterIcon.chat,
        "person.crop.circle": "🙂",
        "person.and.background.dotted": "🧍",
        "hand.raised.fill": "✋",
        "hand.tap": "👆",
        "eye": "👁️",
        "eye.slash": "🙈",
        "circle.lefthalf.filled": "🎭",
        "theatermasks": "🎭",
        "bag": "🛍️",
        "creditcard": "🛍️",
        "square.grid.2x2": "🖼️",
        "square.stack.3d.up": "🖼️",
        "wand.and.stars": "🪄",
        "sparkles": "🪄",
        "list.number": "🔢",
        "wifi.exclamationmark": "📡",
        "antenna.radiowaves.left.and.right.slash": "📡",
        "hourglass": "⌛",
        "doc.text.fill": "📄",
        "doc.on.clipboard": "📄",
        "slider.horizontal.3": "🎛️",
        "arrow.uturn.backward": "↶",
        "arrow.uturn.forward": "↷",
        "arrow.triangle.2.circlepath": "🔀",
        "shuffle": "🔀"
    ]

    private nonisolated static func art(for name: String) -> String {
        glyphs[name] ?? PosterIcon.mark
    }
}

struct PosterSymbolLabel: View {
    let title: Text
    let symbol: String

    init(_ title: LocalizedStringKey, posterSymbol: String) {
        self.title = Text(title)
        self.symbol = posterSymbol
    }

    init(verbatim title: String, posterSymbol: String) {
        self.title = Text(title)
        self.symbol = posterSymbol
    }

    var body: some View {
        Label {
            title
        } icon: {
            PosterSymbol(symbol)
        }
    }
}

/// Menus deliberately use SF Symbols. SwiftUI bridges these labels to native `UIMenu` rows, where
/// system images have the right optical size, destructive tint, and accessibility behavior.
struct PosterMenuLabel: View {
    let title: Text
    let icon: PosterMenuIcon

    init(_ title: LocalizedStringKey, icon: PosterMenuIcon) {
        self.title = Text(title)
        self.icon = icon
    }

    init(verbatim title: String, icon: PosterMenuIcon) {
        self.title = Text(title)
        self.icon = icon
    }

    var body: some View {
        Label {
            title
        } icon: {
            Image(systemName: icon.systemName)
        }
    }
}

nonisolated enum PosterMenuIcon {
    case accept
    case add
    case compare
    case delete
    case export
    case history
    case photo
    case reject
    case rename
    case save

    var systemName: String {
        switch self {
        case .accept: "checkmark.circle"
        case .add: "plus"
        case .compare: "rectangle.on.rectangle"
        case .delete: "trash"
        case .export: "shippingbox"
        case .history: "clock.arrow.circlepath"
        case .photo: "photo.on.rectangle"
        case .reject: "xmark"
        case .rename: "pencil"
        case .save: "square.and.arrow.down"
        }
    }
}

/// A title with one of the poster's emoji in front of it.
///
/// A `Label` rather than an interpolated string so `PosterButtonStyle`'s `.titleAndIcon` label
/// style keeps its spacing, and so VoiceOver reads the title without spelling out the emoji.
struct PosterLabel: View {
    let title: String
    let icon: String

    init(_ title: String, _ icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Text(icon).accessibilityHidden(true)
        }
    }
}
