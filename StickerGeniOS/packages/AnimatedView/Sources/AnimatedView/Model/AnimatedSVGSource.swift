import Foundation

/// Where an SVG layer's markup comes from.
///
/// Inline markup keeps a document self-contained, which is what makes an SVG layer free — unlike
/// an image layer it needs no asset round-trip and no generation. `asset` exists for artwork too
/// large to embed in a document that has to fit in a model's context window.
public enum AnimatedSVGSource: Codable, Hashable, Sendable {
    case inline(markup: String)
    case asset(assetId: String)

    private enum CodingKeys: String, CodingKey { case kind, markup, assetId }
    private enum Kind: String, Codable { case inline, asset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .inline: self = .inline(markup: try container.decode(String.self, forKey: .markup))
        case .asset: self = .asset(assetId: try container.decode(String.self, forKey: .assetId))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inline(let markup):
            try container.encode(Kind.inline, forKey: .kind)
            try container.encode(markup, forKey: .markup)
        case .asset(let assetId):
            try container.encode(Kind.asset, forKey: .kind)
            try container.encode(assetId, forKey: .assetId)
        }
    }

    /// Markup limits and the hostile-content check.
    ///
    /// Rejected constructs are the ones that would turn a document into a fetch or an execution:
    /// SVGView ignores `<script>` today, but a document is stored, replayed, and re-rendered by the
    /// web preview too, and that one runs in a browser where the same markup is live.
    public var isValid: Bool {
        switch self {
        case .asset(let assetId):
            return assetId.isAnimatedUUID
        case .inline(let markup):
            guard !markup.isEmpty, markup.utf8.count <= 200_000 else { return false }
            let lowered = markup.lowercased()
            let banned = ["<script", "<foreignobject", "<iframe", "javascript:"]
            guard !banned.contains(where: lowered.contains) else { return false }
            // Remote references make a render depend on the network and leak a fetch to whoever
            // authored the markup. Only *referencing* attributes are inspected — `xmlns` and
            // `xmlns:xlink` are `http://www.w3.org/…` in essentially every real SVG, and they are
            // namespace identifiers that are never fetched. Data URIs stay allowed: self-contained.
            for attribute in ["href", "src", "url("] where Self.referencesRemoteURL(attribute, in: lowered) {
                return false
            }
            return true
        }
    }

    /// True if any occurrence of `attribute` is followed by a value that would be fetched.
    ///
    /// The value is read directly rather than scanning the surrounding window for `//`, because a
    /// base64 data URI legitimately contains `/` characters and would trip a windowed check.
    private static func referencesRemoteURL(_ attribute: String, in lowered: String) -> Bool {
        var search = lowered[...]
        while let hit = search.range(of: attribute) {
            var cursor = hit.upperBound
            // Skip the delimiter between the attribute name and its value: `="`, `='`, or `(`.
            while cursor < lowered.endIndex, "=\"' \t\n".contains(lowered[cursor]) {
                cursor = lowered.index(after: cursor)
            }
            let value = lowered[cursor...].prefix(8)
            if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("//") {
                return true
            }
            search = lowered[hit.upperBound...]
        }
        return false
    }
}

/// How an SVG layer reaches the screen.
public enum AnimatedSVGRenderMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Rendered by SVGView directly. Highest fidelity — text, embedded rasters, and everything
    /// else SVGView draws — but the document is opaque, so trim and per-subpath tint do not apply.
    case native
    /// Flattened to `SVGDrawing` value types first. This is what enables draw-on animation,
    /// per-subpath tinting, and stroke overrides. Text and embedded raster nodes cannot be
    /// flattened to a path; they are drawn in place and simply ignore trim.
    case vector
}
