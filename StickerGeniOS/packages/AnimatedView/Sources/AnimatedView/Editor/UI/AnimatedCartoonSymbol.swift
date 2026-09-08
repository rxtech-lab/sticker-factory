import SwiftUI

/// Compact illustrated marks for editor chrome. The editor is a package, so it owns a small copy
/// of the app's cartoon vocabulary instead of reaching back into the host target's design system.
struct AnimatedCartoonSymbol: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Text(Self.art(for: name))
            .fontDesign(.rounded)
            .accessibilityHidden(true)
    }

    /// SF Symbol name → the cartoon glyph drawn in its place.
    private nonisolated static let glyphs: [String: String] = [
        "plus": "+",
        "plus.circle": "+",
        "plus.circle.fill": "+",
        "minus": "−",
        "minus.circle": "−",
        "checkmark": "✓",
        "diamond": "◆",
        "diamond.fill": "◆",
        "trash": "🗑️",
        "eye": "👁️",
        "eye.slash": "🙈",
        "photo": "🖼️",
        "camera.filters": "🖼️",
        "video": "🎞️",
        "livephoto": "🎞️",
        "textformat": "✍️",
        "scribble.variable": "✍️",
        "circle": "●",
        "ellipse": "●",
        "rectangle": "▰",
        "rectangle.lefthalf.filled": "▰",
        "capsule": "▬",
        "star": "★",
        "heart": "♥",
        "theatermasks": "🎭",
        "circle.lefthalf.filled": "🎭",
        "wand.and.stars": "🪄",
        "plus.square.on.square": "🗂️",
        "doc.on.clipboard": "📋",
        "shuffle": "🔀",
        "play.fill": "▶",
        "pause.fill": "Ⅱ",
        "arrow.uturn.backward": "↶",
        "arrow.uturn.forward": "↷",
        "rotate.right": "↻",
        "arrow.up.and.down.and.arrow.left.and.right": "✥",
        "arrow.up.left.and.arrow.down.right": "⤢",
        "slider.horizontal.3": "🎛️",
        "square.grid.2x2": "▦",
        "sun.max": "☀",
        "moon": "☾",
        "square.dashed": "?",
        "questionmark.square.dashed": "?",
        "exclamationmark.circle": "!",
        "exclamationmark.triangle.fill": "!",
        "info.circle": "i"
    ]

    private nonisolated static func art(for name: String) -> String {
        glyphs[name] ?? "✦"
    }
}

struct AnimatedCartoonLabel: View {
    let title: Text
    let icon: String

    init(_ title: LocalizedStringKey, icon: String) {
        self.title = Text(title)
        self.icon = icon
    }

    init(verbatim title: String, icon: String) {
        self.title = Text(title)
        self.icon = icon
    }

    var body: some View {
        Label {
            title
        } icon: {
            AnimatedCartoonSymbol(icon)
        }
    }
}
