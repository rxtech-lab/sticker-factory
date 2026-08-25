import Foundation
import SwiftUI

/// Parse-once storage for SVG documents.
///
/// `AnimatedIconView` re-evaluates its body on every frame under `TimelineView`. Re-parsing an SVG
/// each time would dominate the frame budget for any real icon, so parsing happens once per
/// distinct source and the resulting values are reused. Main-actor-isolated because it hands back
/// `SVGParsedDocument`, which holds SVGView's non-`Sendable` nodes.
@MainActor
public final class SVGCache {
    public static let shared = SVGCache()

    /// Enough for a document's worth of layers plus whatever a gallery is scrolling past. Parsed
    /// documents are small; the point of the bound is to stop an app that renders hundreds of
    /// distinct icons from growing without limit.
    private let capacity: Int
    private var storage: [Key: SVGParsedDocument] = [:]
    private var order: [Key] = []

    public init(capacity: Int = 64) {
        self.capacity = capacity
    }

    private enum Key: Hashable {
        case markup(String)
        case asset(String)
    }

    private var paths: [String: Path] = [:]

    /// The geometry for an `AnimatedShapeKind.path`, parsed once per distinct `d` string.
    public func path(forPathData data: String) -> Path? {
        if let cached = paths[data] { return cached }
        guard let parsed = SVGFlattener.path(fromPathData: data) else { return nil }
        if paths.count >= capacity { paths.removeAll() }
        paths[data] = parsed
        return parsed
    }

    /// The parsed document for a layer's source, or `nil` if the markup is unavailable or invalid.
    public func document(for source: AnimatedSVGSource, assets: AnimatedAssetProvider) -> SVGParsedDocument? {
        switch source {
        case .inline(let markup):
            return document(key: .markup(markup)) { SVGFlattener.parse(markup: markup) }
        case .asset(let assetId):
            return document(key: .asset(assetId)) {
                guard let markup = assets.svgMarkup(for: assetId) else { return nil }
                return SVGFlattener.parse(markup: markup)
            }
        }
    }

    public func drawing(for source: AnimatedSVGSource, assets: AnimatedAssetProvider) -> SVGDrawing? {
        document(for: source, assets: assets)?.drawing
    }

    private func document(key: Key, build: () -> SVGParsedDocument?) -> SVGParsedDocument? {
        if let cached = storage[key] {
            touch(key)
            return cached
        }
        guard let parsed = build() else { return nil }
        storage[key] = parsed
        order.append(key)
        evictIfNeeded()
        return parsed
    }

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage[oldest] = nil
        }
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
    }
}
