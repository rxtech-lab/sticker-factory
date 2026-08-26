import SwiftUI

/// Resolves the external content a document references by id.
///
/// A document is a pure value and never carries pixels, so something has to turn `assetId` into an
/// image. This is that seam: the app backs it with its network cache, previews back it with
/// generated placeholders, and tests back it with nothing at all. Main-actor-isolated because the
/// renderer calls it during `body` evaluation and app implementations are typically `@Observable`
/// stores.
@MainActor
public protocol AnimatedAssetProvider {
    /// The bitmap for an image layer, mask, or image background. `nil` renders a placeholder.
    func image(for assetId: String) -> PlatformImage?
    /// The markup for an `AnimatedSVGSource.asset` layer. `nil` renders nothing for that layer.
    func svgMarkup(for assetId: String) -> String?
}

extension AnimatedAssetProvider {
    public func svgMarkup(for assetId: String) -> String? { nil }
}

/// An empty provider, for documents that reference nothing.
public struct EmptyAnimatedAssets: AnimatedAssetProvider {
    public init() {}
    public func image(for assetId: String) -> PlatformImage? { nil }
    public func svgMarkup(for assetId: String) -> String? { nil }
}

/// An in-memory provider backed by two dictionaries.
///
/// This is what previews, tests, and the exporter use — the exporter in particular already holds
/// every asset it needs before it starts rendering frames, and must not touch the network mid-export.
public struct AnimatedAssetDictionary: AnimatedAssetProvider {
    public var images: [String: PlatformImage]
    public var svgMarkup: [String: String]

    public init(images: [String: PlatformImage] = [:], svgMarkup: [String: String] = [:]) {
        self.images = images
        self.svgMarkup = svgMarkup
    }

    public func image(for assetId: String) -> PlatformImage? { images[assetId] }
    public func svgMarkup(for assetId: String) -> String? { svgMarkup[assetId] }
}

extension AnimatedAssetProvider where Self == EmptyAnimatedAssets {
    public static var empty: EmptyAnimatedAssets { EmptyAnimatedAssets() }
}
