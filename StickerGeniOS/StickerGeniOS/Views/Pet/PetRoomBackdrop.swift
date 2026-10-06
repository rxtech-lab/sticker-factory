import SwiftUI
import UIKit

/// The room the pet lives in, filling the tab behind it, or the plain page when it has none. A new
/// room fades in over the old one. A room whose window glass the server cut out looks onto the
/// owner's weather, drawn live behind it, and a room or place with a clock face, weather board and
/// status board drawn in has the time, the weather and the pet's stats written on them.
struct PetRoomBackdrop: View {
    let image: UIImage?
    let weather: PetWeather?
    /// The places in `image` to write the time, weather and stats; nil when it has none, or is not loaded yet.
    var fixtures: PetRoomFixtures?
    /// What the status board shows.
    var stats: PetRoomStats?
    /// That weather drawn in the pet's style, to look out on instead of the painted sky once it lands.
    var sky: PetWindowSprites?
    /// The weather drawn in the pet's style, for a room's weather board.
    var weatherArt: UIImage?
    /// Told which of `fixtures` show on screen once the room is cropped to the tab.
    var onVisibleFixturesChange: (PetRoomFixtures?) -> Void = { _ in }
    /// Told where the status board shows on screen, in global points, so the tab can keep the pet
    /// clear of it; nil when it does not show.
    var onStatusFrameChange: (CGRect?) -> Void = { _ in }
    /// The window and visible writing surfaces to keep clear of the pet's dialogue.
    var onDialogueObstaclesChange: ([CGRect]) -> Void = { _ in }
    @State private var windowLayout: PetWindowOpeningLayout?

    var body: some View {
        // Held to the space it is given: left to itself the stack grows to the room's full fill
        // width, off-centre and wider than the screen, and the clock could not tell it was cut off.
        GeometryReader { proxy in
            room(bounds: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .onChange(of: windowLayoutKey(in: proxy.size), initial: true) { _, key in
                    windowLayout = key.map { PetWindowOpeningLayout(image: $0.image, drawn: $0.drawn, bounds: $0.bounds) }
                }
                .onChange(of: statusFrame(in: proxy), initial: true) { _, frame in onStatusFrameChange(frame) }
                .onChange(of: dialogueObstacles(in: proxy), initial: true) { _, frames in onDialogueObstaclesChange(frames) }
                // Reported here rather than from the fixtures over the drawing: a room fading out
                // as the pet goes somewhere would otherwise clear them after the new place's land.
                .onChange(of: visibleFixtures(in: proxy.size), initial: true) { _, shown in onVisibleFixturesChange(shown) }
        }
        .onDisappear {
            onStatusFrameChange(nil)
            onVisibleFixturesChange(nil)
            onDialogueObstaclesChange([])
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: image)
        // A container, so the clock and board inside keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(image == nil ? "pet-room-backdrop-plain" : "pet-room-backdrop")
    }

    private func room(bounds: CGSize) -> some View {
        ZStack {
            PosterPaper()
            if let image {
                if image.hasWindows {
                    PetWindowSky(weather: weather, sprites: sky, openings: windowLayout)
                        .transition(.opacity)
                        .accessibilityIdentifier("pet-room-window-sky")
                }
                // Filling the tab, and slid sideways within what the fill crops off when that
                // brings the room's clock and weather board further into view.
                let (drawn, shift) = placement(of: image, in: bounds)
                let size = drawn.size
                Image(uiImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .accessibilityHidden(true)
                    // Laid over the drawing at the size it is drawn, before it is cropped to the
                    // tab, so each lands on its own surface in the room.
                    .overlay {
                        if let fixtures {
                            PetRoomFixturesLayer(fixtures: fixtures, weather: weather, stats: stats, weatherArt: weatherArt,
                                                 drawn: drawn, bounds: bounds)
                        }
                    }
                    .offset(x: shift)
                    .frame(width: bounds.width, height: bounds.height)
                    .clipped()
                    // A soft wash at the top keeps the toolbar and weather readable over any room.
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [AppColors.paper.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
                    }
                    .id(image)
                    .transition(.opacity)
            }
        }
    }
}

private extension PetRoomBackdrop {
    struct WindowLayoutKey: Equatable {
        let image: UIImage
        let drawn: CGRect
        let bounds: CGSize
    }

    func windowLayoutKey(in bounds: CGSize) -> WindowLayoutKey? {
        guard let image, image.hasWindows else { return nil }
        return WindowLayoutKey(image: image, drawn: placement(of: image, in: bounds).drawn, bounds: bounds)
    }

    /// Where `image` is drawn filling `bounds`: slid sideways within what the fill crops off when
    /// that brings the room's fixtures further into view.
    func placement(of image: UIImage, in bounds: CGSize) -> (drawn: CGRect, shift: CGFloat) {
        let size = image.size.filling(bounds)
        let shift = fixtures?.bestShift(drawn: size, bounds: bounds) ?? 0
        let drawn = CGRect(x: (bounds.width - size.width) / 2 + shift, y: (bounds.height - size.height) / 2,
                           width: size.width, height: size.height)
        return (drawn, shift)
    }

    /// Which of `fixtures` show once the room is cropped to `bounds`; nil with no room or none in view.
    func visibleFixtures(in bounds: CGSize) -> PetRoomFixtures? {
        guard let image else { return nil }
        return fixtures?.visible(drawnIn: placement(of: image, in: bounds).drawn, bounds: bounds)
    }

    /// Global frames after the backdrop is shifted and cropped, including its actual window opening.
    func dialogueObstacles(in proxy: GeometryProxy) -> [CGRect] {
        guard let image else { return [] }
        let drawn = placement(of: image, in: proxy.size).drawn
        let origin = proxy.frame(in: .global).origin
        let visible = visibleFixtures(in: proxy.size)
        var frames = [visible?.clock, visible?.weather, stats == nil ? nil : visible?.status].compactMap { fixture -> CGRect? in
            guard let fixture, let shown = fixture.onScreen(drawnIn: drawn, bounds: proxy.size) else { return nil }
            return shown.offsetBy(dx: origin.x + drawn.minX + fixture.x * drawn.width,
                                  dy: origin.y + drawn.minY + fixture.y * drawn.height)
        }
        if let window = windowLayout?.bounds, !window.isEmpty {
            frames.append(window.offsetBy(dx: origin.x, dy: origin.y))
        }
        return frames
    }

    /// The part of the status board on screen, in global points; nil when it does not show.
    func statusFrame(in proxy: GeometryProxy) -> CGRect? {
        guard let image, stats != nil else { return nil }
        let bounds = proxy.size
        let drawn = placement(of: image, in: bounds).drawn
        guard let board = fixtures?.visible(drawnIn: drawn, bounds: bounds)?.status,
              let shown = board.onScreen(drawnIn: drawn, bounds: bounds) else { return nil }
        let origin = proxy.frame(in: .global).origin
        return shown.offsetBy(dx: origin.x + drawn.minX + board.x * drawn.width,
                              dy: origin.y + drawn.minY + board.y * drawn.height)
    }
}

private extension CGSize {
    /// This size scaled to fill `bounds`, as `scaledToFill` draws it.
    func filling(_ bounds: CGSize) -> CGSize {
        guard width > 0, height > 0 else { return bounds }
        let scale = Swift.max(bounds.width / width, bounds.height / height)
        return CGSize(width: width * scale, height: height * scale)
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
