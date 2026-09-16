import AnimatedView
import Messages
import SwiftUI

/// The artwork a prepare produced, held until it is sent, re-posed, or the sheet closes.
///
/// The `MSSticker` is built once and kept: the sheet asks for the view on every re-evaluation, and
/// rebuilding it each time would re-read the file and restart the animation under the reader's
/// finger.
nonisolated struct PreparedStickerFile: Sendable {
    var url: URL
    var firstAnimationOnly: Bool
}

struct PreparedSticker {
    let fileURL: URL
    let title: String
    let sticker: MSSticker
    let firstAnimationOnly: Bool

    init(fileURL: URL, title: String, firstAnimationOnly: Bool = false) throws {
        self.firstAnimationOnly = firstAnimationOnly
        self.fileURL = fileURL
        self.title = title
        sticker = try MSSticker(contentsOfFileURL: fileURL, localizedDescription: title)
    }
}

extension PreparedSticker {
    /// The file this pose sends: the cached render when one was already written for exactly these
    /// settings, and otherwise a fresh render stored under that key so the next send is free.
    ///
    /// This is what makes re-posing cheap. Moving a slider away from a prepared pose and back again
    /// asks for a render that is already on disk, so the second prepare costs a file read.
    @MainActor
    static func renderedFile(
        service: MessagesPlaybackService,
        account: String,
        bundle: StickerPlaybackBundle,
        document: AnimatedDocument,
        settings: StickerControlSettings,
        assets: StickerRenderAssets,
        image: Bool
    ) async throws -> PreparedStickerFile {
        // The rung only reaches the sticker path; a full-size image is not sized by Messages and
        // carries the value only so the two kinds cannot collide in the cache.
        let size = SystemStickerSize.stuck
        if let cached = try await service.cachedRender(
            accountID: account, bundle: bundle, settings: settings, image: image, size: size
        ) {
            return cached
        }
        let rendered = try await StickerConfiguredExport.render(
            document: document, settings: settings, assets: assets, image: image, size: size
        )
        defer { try? FileManager.default.removeItem(at: rendered.url) }
        try Task.checkCancellation()
        let url = try await service.storeRender(
            rendered, accountID: account, bundle: bundle, settings: settings, image: image, size: size
        )
        return .init(url: url, firstAnimationOnly: rendered.firstAnimationOnly)
    }
}

/// The prepared sticker, drawn by Messages' own view.
///
/// The point of using `MSStickerView` rather than an `Image` of the same file is the gesture it
/// carries: press and hold, and the sticker peels off the drawer so it can be dropped on a
/// particular bubble. Nothing else in the framework offers that, and a SwiftUI image of the
/// identical artwork looks the same and can only be looked at.
///
/// It needs the transcript on screen to be dropped onto, so the drawer is given back to compact
/// before this is shown — see `MessagesViewController.collapseForPreparedSticker()`.
struct PreparedStickerView: UIViewRepresentable {
    let sticker: MSSticker

    func makeUIView(context: Context) -> MSStickerView {
        let view = MSStickerView(frame: .zero, sticker: sticker)
        view.contentMode = .scaleAspectFit
        // The view derives an intrinsic size from its sticker and would otherwise refuse to take
        // the height SwiftUI proposes for it.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.startAnimating()
        return view
    }

    func updateUIView(_ view: MSStickerView, context: Context) {
        // `startAnimating()` always restarts from the first frame, so re-applying the same sticker
        // on every re-evaluation would visibly re-sync the animation under the reader's finger.
        guard view.sticker?.imageFileURL != sticker.imageFileURL else { return }
        view.stopAnimating()
        view.sticker = sticker
        view.startAnimating()
    }

    static func dismantleUIView(_ view: MSStickerView, coordinator: ()) {
        view.stopAnimating()
    }
}
