#if os(iOS)
import SwiftUI

/// Previews for the editor, over the same fixtures the renderer's own previews use.
///
/// Each one targets a specific thing that is hard to reason about statically — letterboxing on a
/// non-square canvas, uniform text scaling, taps falling through a full-bleed particle layer — so
/// the canvas is a real check rather than a screenshot.
private struct EditorPreviewHost: View {
    @State var document: AnimatedDocument
    var assets: any AnimatedAssetProvider = EmptyAnimatedAssets()
    var configuration: AnimatedEditorConfiguration = .init()
    var picksImages = false

    var body: some View {
        NavigationStack {
            AnimatedIconEditor(
                document: $document,
                assets: assets,
                configuration: configuration,
                onPickImageAsset: picksImages
                    ? { AnimatedPreviewDocuments.imageAssetID }
                    : nil
            )
            .navigationTitle("Edit Sticker")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The general case: several layer kinds, real motion, everything reachable.
#Preview("Composite") {
    EditorPreviewHost(document: AnimatedPreviewDocuments.composite)
}

/// Letterboxing. Drag a layer to a visual corner and the inspector should read roughly (0, 0) —
/// if the stage and the artwork disagreed about the content rect, it would not.
#Preview("Wide canvas") {
    EditorPreviewHost(document: AnimatedPreviewDocuments.wideCanvas)
}

/// Preset motion: the timeline is dimmed and offers "Edit Keyframes" rather than letting the
/// tracks be dragged, and the Motion section lists the specs that are generating them.
#Preview("Preset motion") {
    EditorPreviewHost(document: AnimatedPreviewDocuments.svgDrawOn)
}

/// Text scales uniformly, so the inspector must show one Size slider rather than two.
#Preview("Text") {
    EditorPreviewHost(document: AnimatedPreviewDocuments.text)
}

/// A particle layer covers the whole canvas, so taps have to fall through it to the shapes above.
#Preview("Particles") {
    EditorPreviewHost(document: AnimatedPreviewDocuments.particles)
}

/// The image path, with a stub picker and an asset dictionary standing in for the app's cache.
#Preview("Image") {
    EditorPreviewHost(
        document: AnimatedPreviewDocuments.image,
        assets: EmptyAnimatedAssets(),
        picksImages: true
    )
}

/// A still document: no timeline, no transport scrubber, and the Motion pane stays empty.
#Preview("Static") {
    EditorPreviewHost(document: AnimatedPreviewDocuments.staticDocument)
}

/// A host bound to the v1 server contract, which pins the canvas and knows nothing about SVG
/// layers. This is what `AnimatedEditorConfiguration` is for.
#Preview("Restricted host") {
    EditorPreviewHost(
        document: AnimatedPreviewDocuments.shapes,
        configuration: .init(
            allowsCanvasResize: false,
            allowsKindChange: false,
            allowedLayerTypes: [.image, .text, .shape, .particle]
        )
    )
}
#endif
