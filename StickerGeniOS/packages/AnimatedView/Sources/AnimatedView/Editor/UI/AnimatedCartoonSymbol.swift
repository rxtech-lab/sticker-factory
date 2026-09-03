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

    private nonisolated static func art(for name: String) -> String {
        switch name {
        case "plus", "plus.circle", "plus.circle.fill": "+"
        case "minus", "minus.circle": "−"
        case "checkmark": "✓"
        case "diamond", "diamond.fill": "◆"
        case "trash": "🗑️"
        case "eye": "👁️"
        case "eye.slash": "🙈"
        case "photo", "camera.filters": "🖼️"
        case "video", "livephoto": "🎞️"
        case "textformat", "scribble.variable": "✍️"
        case "circle", "ellipse": "●"
        case "rectangle", "rectangle.lefthalf.filled": "▰"
        case "capsule": "▬"
        case "star": "★"
        case "heart": "♥"
        case "theatermasks", "circle.lefthalf.filled": "🎭"
        case "wand.and.stars": "🪄"
        case "plus.square.on.square": "🗂️"
        case "doc.on.clipboard": "📋"
        case "shuffle": "🔀"
        case "play.fill": "▶"
        case "pause.fill": "Ⅱ"
        case "arrow.uturn.backward": "↶"
        case "arrow.uturn.forward": "↷"
        case "rotate.right": "↻"
        case "arrow.up.and.down.and.arrow.left.and.right": "✥"
        case "arrow.up.left.and.arrow.down.right": "⤢"
        case "slider.horizontal.3": "🎛️"
        case "square.grid.2x2": "▦"
        case "sun.max": "☀"
        case "moon": "☾"
        case "square.dashed", "questionmark.square.dashed": "?"
        case "exclamationmark.circle", "exclamationmark.triangle.fill": "!"
        case "info.circle": "i"
        default: "✦"
        }
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
