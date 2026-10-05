import SwiftUI
import UIKit

/// The room the pet lives in, filling the tab behind it, or the plain page when it has none. A new
/// room fades in over the old one. A room whose window glass the server cut out looks onto the
/// owner's weather, drawn live behind it.
struct PetRoomBackdrop: View {
    let image: UIImage?
    let weather: PetWeather?

    var body: some View {
        ZStack {
            PosterPaper()
            if let image {
                if image.hasWindows {
                    PetWindowSky(weather: weather)
                        .transition(.opacity)
                        .accessibilityIdentifier("pet-room-window-sky")
                }
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    // A soft wash at the top keeps the toolbar and weather readable over any room.
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [AppColors.paper.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
                    }
                    .id(image)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: image)
        .accessibilityIdentifier(image == nil ? "pet-room-backdrop-plain" : "pet-room-backdrop")
    }
}

private extension UIImage {
    /// Whether this room drawing has see-through windows. Rooms drawn before windows were cut out,
    /// and rooms whose cut failed, are stored without an alpha channel at all.
    var hasWindows: Bool {
        switch cgImage?.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        default: false
        }
    }
}
