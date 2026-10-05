import SwiftUI
import UIKit
import WidgetKit

/// The pet's drawn pose, or a paw where the picture would be.
///
/// Shared by the phone's widget, the watch app, and the watch's complications, so every surface
/// draws the pet the same way and falls back the same way.
struct PetPoseImage: View {
    let data: Data?

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                // Keeps the pet in full colour on a tinted Home Screen or watch face, instead of a
                // flat silhouette of itself.
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFit()
        } else {
            Image(systemName: "pawprint.fill")
                .resizable()
                .scaledToFit()
                .padding(8)
                .foregroundStyle(.secondary)
        }
    }
}
