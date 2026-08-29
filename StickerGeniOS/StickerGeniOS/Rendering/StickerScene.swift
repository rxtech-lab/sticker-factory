import AnimatedView
import os
import SwiftUI
import UIKit

/// Plays a sticker document.
///
/// A thin wrapper over `AnimatedIconView` from the `AnimatedView` package. The app used to carry
/// its own renderer here — a second implementation of the same contract, complete with its own
/// interpolator and shape library — and the two had already begun to drift. One engine draws every
/// sticker now: the chat bubble, the full-screen player, the editor, and every exported frame.
///
/// The wrapper survives only because a dozen call sites pass `[String: UIImage]` and expect a
/// `repeats` flag, and because that dictionary is what `StickerAssetStore` already holds.
struct StickerPlayer: View {
    let document: AnimatedDocument
    var assets: [String: UIImage] = [:]
    var repeats = false

    var body: some View {
        AnimatedIconView(
            document: document,
            assets: AnimatedAssetDictionary(images: assets),
            repeats: repeats
        )
    }
}

/// Loads and caches the bitmaps a document's layers reference.
///
/// Conforms to `AnimatedAssetProvider`, which is the seam the renderer uses to turn an `assetId`
/// into pixels — so the store can be handed straight to `AnimatedIconView`, the editor, or the
/// exporter without anyone copying its dictionary first.
@MainActor
@Observable
final class StickerAssetStore: AnimatedAssetProvider {
    /// Why a bitmap never arrived. Loading degrades to a placeholder by design, which is right for
    /// the renderer and leaves anyone debugging a permanently-empty slot with nothing to read.
    ///
    /// `xcrun simctl spawn booted log stream --predicate 'category == "assets"'`
    nonisolated static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "assets")

    private(set) var images: [String: UIImage] = [:]
    private(set) var verifiedAssetIDs: Set<String> = []
    private var loading: Set<String> = []

    // MARK: - AnimatedAssetProvider

    func image(for assetId: String) -> PlatformImage? { images[assetId] }

    /// SVG layers currently only ever carry inline markup, which needs no resolution. This exists
    /// so a document that later references uploaded artwork degrades to drawing nothing rather than
    /// failing to compile.
    func svgMarkup(for assetId: String) -> String? { nil }

    // MARK: - Loading

    /// Fetches every bitmap a document needs, including image-layer masks, capture atlases, and an
    /// image background.
    func preload(document: AnimatedDocument, api: StickerAPIClientProtocol) async {
        var ids = Set(document.layers.flatMap(\.referencedImageAssetIDs))
        if case .image(let assetId, _) = document.background { ids.insert(assetId) }
        for id in ids { await load(assetID: id, api: api) }
    }

    func load(assetID: String, api: StickerAPIClientProtocol) async {
        guard images[assetID] == nil, !loading.contains(assetID) else { return }
        loading.insert(assetID)
        defer { loading.remove(assetID) }
        do {
            let result = try await StickerImageCache.load(assetID: assetID, api: api)
            if result.isVerified { verifiedAssetIDs.insert(assetID) }
            images[assetID] = result.image
        } catch {
            // The renderer keeps its deterministic placeholder and can retry when the layer becomes
            // visible again or connectivity returns.
            Self.log.error("asset: load failed id=\(assetID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
