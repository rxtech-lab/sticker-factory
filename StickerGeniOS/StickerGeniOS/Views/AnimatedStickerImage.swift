import SwiftUI
import UIKit

/// Plays a decoded sticker animation, scaled to fit whatever it is given.
///
/// SwiftUI's `Image` draws one frame and stops, whatever it is handed — an animated `UIImage` is
/// still a still to it — so playback goes through UIKit. `StickerAnimationPlayerView` owns the
/// clock; this is only the seam that hands it frames and lets SwiftUI lay it out.
struct AnimatedStickerImage: UIViewRepresentable {
    let animation: StickerAnimation

    func makeUIView(context: Context) -> StickerAnimationPlayerView {
        let view = StickerAnimationPlayerView()
        view.animation = animation
        return view
    }

    func updateUIView(_ view: StickerAnimationPlayerView, context: Context) {
        view.animation = animation
    }
}

/// A `UIImageView` driven frame by frame off the display link.
///
/// `UIImageView.animationImages` was the obvious way to do this and cannot: it holds every frame for
/// an equal slice of `animationDuration`, and an export's frames are not equal — the last one is
/// held `loopHoldSeconds` longer so the loop reads as a loop rather than a stutter.
@MainActor
final class StickerAnimationPlayerView: UIView {
    var animation: StickerAnimation? {
        didSet {
            guard animation?.id != oldValue?.id else { return }
            index = 0
            elapsed = 0
            imageView.image = animation?.frames.first
            updateRunState()
        }
    }

    private let imageView = UIImageView()
    private var link: CADisplayLink?
    private var index = 0
    /// Time spent on the current frame, carried across ticks. The display refreshes on its own
    /// cadence and frames are held on theirs, so the two never line up.
    private var elapsed: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // Stickers are transparent and their tiles are sized by the layout, not by the artwork.
        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        // The tile itself is the button in every surface that shows one; the player must not eat
        // the tap.
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Runs only while on screen. A `CADisplayLink` retains its target, so a player left running
    /// after its row scrolled away would keep both itself and its frames alive — and the whole
    /// point of the decode budget is that frames do not accumulate.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRunState()
    }

    private func updateRunState() {
        let shouldRun = window != nil && (animation?.frames.count ?? 0) > 1
        if shouldRun, link == nil {
            let link = CADisplayLink(target: self, selector: #selector(step))
            // `.common`, or every sticker on the screen freezes for the length of a scroll.
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !shouldRun {
            link?.invalidate()
            link = nil
        }
    }

    @objc
    private func step(_ link: CADisplayLink) {
        guard let animation, animation.frames.count > 1 else { return }
        elapsed += link.targetTimestamp - link.timestamp

        // A loop, not an `if`: a frame can be held for less than one refresh, and a link that missed
        // a beat has more than one frame of time to spend. `StickerAnimationDecoder.minimumDelay`
        // keeps every delay positive, so this terminates.
        var advanced = false
        while elapsed >= animation.delays[index] {
            elapsed -= animation.delays[index]
            index = (index + 1) % animation.frames.count
            advanced = true
        }
        if advanced { imageView.image = animation.frames[index] }
    }
}
