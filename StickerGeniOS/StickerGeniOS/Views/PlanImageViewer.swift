import SwiftUI
import UIKit

/// Shared by plan artwork and uploaded images. Each presentation starts fitted to the screen.
struct PlanImageViewer: View {
    let image: UIImage
    var title = String(localized: "Plan image")
    var accessibilityPrefix = "plan-image"
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    private var zoomLabel: String { Double(zoom).formatted(.percent.precision(.fractionLength(0))) }

    var body: some View {
        NavigationStack {
            ZoomablePlanImage(image: image, zoom: $zoom, accessibilityLabel: title)
                .background(Color.black)
                .accessibilityIdentifier("\(accessibilityPrefix)-zoom-surface")
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 28) {
                        Button { zoom = max(1, zoom / 1.5) } label: {
                            Label("Zoom out", systemImage: "minus.magnifyingglass")
                                .frame(width: 44, height: 44)
                        }
                        .disabled(zoom <= 1.01)
                        .accessibilityIdentifier("\(accessibilityPrefix)-zoom-out")
                        Button { zoom = 1 } label: {
                            Text(zoomLabel)
                                .monospacedDigit()
                                .frame(minWidth: 64, minHeight: 44)
                        }
                        .accessibilityLabel("Reset zoom")
                        .accessibilityValue(zoomLabel)
                        .accessibilityIdentifier("\(accessibilityPrefix)-reset-zoom")
                        Button { zoom = min(6, zoom * 1.5) } label: {
                            Label("Zoom in", systemImage: "plus.magnifyingglass")
                                .frame(width: 44, height: 44)
                        }
                        .disabled(zoom >= 5.99)
                        .accessibilityIdentifier("\(accessibilityPrefix)-zoom-in")
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("\(accessibilityPrefix)-close")
                    }
                }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("\(accessibilityPrefix)-viewer")
    }
}

private struct ZoomablePlanImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoom: CGFloat
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(zoom: $zoom) }

    func makeUIView(context: Context) -> PlanImageScrollView {
        let view = PlanImageScrollView()
        view.imageView.image = image
        view.imageView.accessibilityLabel = accessibilityLabel
        view.delegate = context.coordinator
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ view: PlanImageScrollView, context: Context) {
        context.coordinator.zoom = $zoom
        if view.imageView.image !== image { view.imageView.image = image }
        view.imageView.accessibilityLabel = accessibilityLabel
        if abs(view.zoomScale - zoom) > 0.01 {
            context.coordinator.isUpdating = true
            view.setZoomScale(zoom, animated: false)
            context.coordinator.isUpdating = false
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var zoom: Binding<CGFloat>
        var isUpdating = false
        init(zoom: Binding<CGFloat>) { self.zoom = zoom }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? PlanImageScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !isUpdating else { return }
            // Rotation can reset the fit during UIKit layout, outside a SwiftUI update.
            let scale = scrollView.zoomScale
            DispatchQueue.main.async { [weak self] in self?.zoom.wrappedValue = scale }
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PlanImageScrollView else { return }
            if view.zoomScale > 1.01 {
                view.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: view.imageView)
                let size = CGSize(width: view.bounds.width / 3, height: view.bounds.height / 3)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: true)
            }
        }
    }
}

private final class PlanImageScrollView: UIScrollView {
    let imageView = UIImageView()
    private var fittedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityHint = String(localized: "Pinch to zoom. Drag to move around. Double tap to zoom or reset.")
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != fittedSize, bounds.width > 0, bounds.height > 0 else { return }
        fittedSize = bounds.size
        setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
    }
}
