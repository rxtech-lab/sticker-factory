import SwiftUI

extension View {
    /// Keeps `verticalToolbar` in step with whether the toolbar runs down the side of the screen, as
    /// it does on an opened iPhone Duo, and `fullyOpen` with whether its hinge is open all the way.
    /// Built with an SDK older than iOS 27.1, or on a device without a hinge, both stay false.
    @ViewBuilder
    func detectsFoldableLayout(verticalToolbar: Binding<Bool>, fullyOpen: Binding<Bool>) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            modifier(FoldableLayoutReader(isVertical: verticalToolbar))
                .onHingeChange { _, context in
                    let isOpen = context.hinge?.status == .fullyOpen
                    guard isOpen != fullyOpen.wrappedValue else { return }
                    withAnimation(.foldableLayout) { fullyOpen.wrappedValue = isOpen }
                }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct FoldableLayoutReader: ViewModifier {
    @Binding var isVertical: Bool
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    func body(content: Content) -> some View {
        content.onChange(of: toolbarVerticalEdge != nil, initial: true) { _, vertical in
            guard vertical != isVertical else { return }
            withAnimation(.foldableLayout) { isVertical = vertical }
        }
    }
}
#endif

private extension Animation {
    /// How the page rearranges as an iPhone Duo opens or folds: a soft spring, like the hinge.
    static let foldableLayout = Animation.spring(duration: 0.55, bounce: 0.18)
}
