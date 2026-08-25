import SwiftUI
import UIKit

/// A document presented full screen. `StickerDocumentV1` is a value type with no identity of its
/// own, so this wrapper gives `.fullScreenCover(item:)` something to key on.
nonisolated struct PresentedStickerDocument: Identifiable, Sendable {
    let id = UUID()
    let document: StickerDocumentV1
}

struct FullScreenStickerPlayer: View {
    let document: StickerDocumentV1
    let assets: [String: UIImage]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            StickerPlayer(document: document, assets: assets, repeats: true)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("full-screen-sticker-player")

            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
                .padding()
                .accessibilityIdentifier("dismiss-full-screen-player")
        }
    }
}
