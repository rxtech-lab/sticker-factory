import Foundation

/// The layers the "add layer" menu creates.
///
/// Each starter is chosen to be immediately visible and already `isValid` — a new layer that draws
/// nothing, or that puts the document into a state `validated()` rejects, reads as a broken button
/// rather than as an invitation to edit.
public enum AnimatedEditorDefaults {
    /// A simple closed path that parses, draws, and can be trimmed.
    ///
    /// Inline rather than an asset so a new SVG layer needs no upload round-trip, and deliberately
    /// plain so it is obviously a placeholder to replace. Passes `AnimatedSVGSource.isValid`: no
    /// script, no remote reference, well under the size cap.
    public static let starterSVGMarkup = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">\
        <path d="M50 8 L92 50 L50 92 L8 50 Z" fill="#7C5CFF"/>\
        </svg>
        """

    /// A starter layer of the given type, or `nil` when one cannot be made.
    ///
    /// Only `.image` returns `nil`, and only when `assetID` is missing or malformed: a document
    /// carries no pixels, so an image layer is meaningless without an asset the host has already
    /// resolved. That is why the add menu hides image layers unless the host supplied a picker.
    public static func layer(
        _ type: AnimatedLayerType,
        id: String,
        name: String? = nil,
        assetID: String? = nil
    ) -> AnimatedLayer? {
        let base = AnimatedLayerBase(id: id, name: name ?? defaultName(for: type))
        switch type {
        case .image:
            guard let assetID, assetID.isAnimatedUUID else { return nil }
            return .image(.init(base: base, assetId: assetID))
        case .text:
            // Non-empty because `AnimatedTextLayer.isValid` requires it, and because an empty text
            // layer is invisible — the user would have added a layer and seen nothing happen.
            return .text(.init(base: base, text: "Text"))
        case .shape:
            // A fill is mandatory: `AnimatedShapeLayer.isValid` rejects a shape with neither fill
            // nor stroke, since it would draw nothing.
            return .shape(.init(base: base, shape: .circle, fill: .solid("#7C5CFF")))
        case .svg:
            return .svg(.init(base: base, source: .inline(markup: starterSVGMarkup)))
        case .particle:
            return .particle(.init(base: base, preset: .sparkles))
        }
    }

    public static func defaultName(for type: AnimatedLayerType) -> String {
        switch type {
        case .image: "Image"
        case .text: "Text"
        case .shape: "Shape"
        case .svg: "Artwork"
        case .particle: "Sparkles"
        }
    }

    public static func symbolName(for type: AnimatedLayerType) -> String {
        switch type {
        case .image: "photo"
        case .text: "textformat"
        case .shape: "circle"
        case .svg: "scribble.variable"
        case .particle: "sparkles"
        }
    }
}

/// Translation between the layer array and the way a layer list displays it.
///
/// `AnimatedIconFrame` draws `ForEach(document.layers)` in array order, so index 0 is the
/// **bottom-most** layer. Every layers panel a user has seen puts the top-most first, so the list
/// shows the array reversed — and every index crossing that boundary has to be converted.
///
/// This lives here, in the cross-platform layer, rather than inline in the SwiftUI view, for one
/// reason: `.onMove`'s destination semantics under a reversed array are genuinely easy to get
/// wrong, and a view cannot be unit-tested on macOS.
public enum AnimatedLayerListOrder {
    /// The array index of the layer shown at `displayIndex`.
    public static func modelIndex(displayIndex: Int, count: Int) -> Int {
        count - 1 - displayIndex
    }

    /// Where a moved layer must land in the array, given SwiftUI's display-space destination.
    ///
    /// `destination` follows `.onMove`'s convention: an insertion point in the *pre-removal* array,
    /// so it ranges over `0...count` and means "before this row". Subtracting one when moving down
    /// accounts for the row's own removal shifting everything after it.
    public static func modelDestination(displayDestination: Int, movingFrom displayIndex: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let adjusted = displayDestination > displayIndex ? displayDestination - 1 : displayDestination
        return min(max((count - 1) - adjusted, 0), count - 1)
    }
}

extension AnimatedDocument {
    /// Adds a starter layer of `type` on top of the stack.
    ///
    /// Returns the new document and the id it assigned, so the caller can select what it just made
    /// without having to diff the layer arrays.
    public func addingStarterLayer(
        _ type: AnimatedLayerType,
        assetID: String? = nil
    ) throws -> (document: Self, layerID: String) {
        guard layers.count < Self.maximumLayerCount else { throw AnimatedEditorError.layerLimitReached }
        let id = uniqueLayerID(preferring: AnimatedEditorDefaults.defaultName(for: type).lowercased())
        guard let layer = AnimatedEditorDefaults.layer(type, id: id, assetID: assetID) else {
            throw AnimatedEditorError.invalidAssetID(assetID ?? "")
        }
        return (try addingLayer(layer), id)
    }
}
