import AnimatedView
import Foundation

/// The API-level enums that outlive the document contract.
///
/// The document itself now comes from the `AnimatedView` package as `AnimatedDocument`: the app
/// used to carry a hand-written mirror of the server's zod schema, and keeping two implementations
/// of one contract in step is exactly how the two renderers were drifting. These three types stay
/// because they describe the *API*, not the document — a sticker project has a kind, an export
/// request carries an MP4 background — and they are used in places no document is involved.
nonisolated enum StickerKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case `static`
    case animated
    var id: Self { self }
    var label: String {
        self == .static ? String(localized: "Static") : String(localized: "Animated")
    }
    var symbol: String { self == .static ? "photo" : "sparkles.rectangle.stack" }
    /// The larger poster face of the same idea; `symbol` is now only a semantic lookup key for the
    /// compact cartoon renderer.
    var icon: String { self == .static ? PosterIcon.staticSticker : PosterIcon.animatedSticker }

    /// The document's own spelling of the same distinction.
    var animatedKind: AnimatedKind { self == .static ? .static : .animated }

    init(_ kind: AnimatedKind) { self = kind == .static ? .static : .animated }
}

nonisolated enum StickerLoopBehavior: String, Codable, CaseIterable, Hashable, Sendable {
    case once, loop, pingPong

    var label: String {
        switch self {
        case .once: String(localized: "Once")
        case .loop: String(localized: "Loop")
        case .pingPong: String(localized: "Ping-pong")
        }
    }

    var animatedLoop: AnimatedLoop {
        switch self {
        case .once: .once
        case .loop: .loop
        case .pingPong: .pingPong
        }
    }
}

/// The background an export request asks the server to bake behind an MP4.
///
/// Deliberately still its own type rather than `AnimatedBackground`: the wire shape the server
/// accepts for this field is unchanged — a solid colour or a two-colour linear gradient — and it is
/// a property of the *export*, chosen at publish time, not of the artwork.
