import SwiftUI
import UIKit

// ---------------------------------------------------------------------------
// The poster design system: cream paper, ink outlines, hard offset shadows,
// rounded display type, and flat bands of loud colour.
//
// It is a port of the web app's `globals.css`, so the two clients read as one
// product. The rules are few and worth stating once:
//
//   * Depth is a hard shadow — a solid ink copy of the shape, offset a few
//     points. Never a blur, never a gradient, never glass.
//   * Every surface is outlined in ink. That outline is what makes flat colour
//     read as an object rather than as a stain on the page.
//   * Type is rounded. `ContentView` sets `.fontDesign(.rounded)` once at the
//     root so the whole app inherits it; the display helpers below are for
//     places that also want the poster's tight, heavy headline.
//   * Pressing something moves it into its own shadow, the way a printed
//     button would if you could push it.
// ---------------------------------------------------------------------------

nonisolated enum Poster {
    /// Outline weights. `border` for cards and controls, `hairline` for small chrome.
    static let border: CGFloat = 2
    static let hairline: CGFloat = 1.5

    static let cardRadius: CGFloat = 24
    static let tileRadius: CGFloat = 18
    static let chipRadius: CGFloat = 12

    /// Hard-shadow offsets, matching `--shadow-sm/md/lg`.
    static let smallShadow = CGSize(width: 3, height: 3)
    static let mediumShadow = CGSize(width: 5, height: 6)
    static let largeShadow = CGSize(width: 8, height: 9)
    static let noShadow = CGSize.zero
}

// MARK: - Type

extension Font {
    /// Friendly hand-lettered copy for the illustrated welcome and feature cards.
    static var cartoonBody: Font {
        if UIFont(name: "ChalkboardSE-Bold", size: 17) != nil {
            return .custom("ChalkboardSE-Bold", size: 17, relativeTo: .body)
        }
        return .system(.body, design: .rounded, weight: .bold)
    }

    /// The poster headline: rounded, heavy, and tight.
    static func posterDisplay(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// The all-caps monospaced label used for eyebrows, states, and metadata.
    static func posterLabel(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .heavy, design: .monospaced)
    }
}

// MARK: - Shapes

/// The lopsided round shape the web app uses for its brand mark and empty-state icons
/// (`border-radius: 44% 50% 46% 52%`). Four *different* corner radii are what stop it reading as a
/// circle — it looks hand-drawn, which is the whole point, so no two adjacent corners match and
/// none of them is the full half-side that would round the shape out completely.
nonisolated struct BlobShape: InsettableShape {
    /// Corner radii as a fraction of the shorter side, clockwise from the top-left.
    var radii: [CGFloat] = [0.50, 0.33, 0.46, 0.30]
    private var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        guard box.width > 0, box.height > 0 else { return Path() }
        let unit = min(box.width, box.height)
        let corner = radii.map { min($0 * unit, unit / 2) }

        let topLeft = CGPoint(x: box.minX, y: box.minY)
        let topRight = CGPoint(x: box.maxX, y: box.minY)
        let bottomRight = CGPoint(x: box.maxX, y: box.maxY)
        let bottomLeft = CGPoint(x: box.minX, y: box.maxY)

        var path = Path()
        path.move(to: CGPoint(x: box.minX + corner[0], y: box.minY))
        path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: corner[1])
        path.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: corner[2])
        path.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: corner[3])
        path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: corner[0])
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> BlobShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

// MARK: - Surfaces

/// Flat fill, ink outline, and a solid shadow offset behind it. Everything that looks like an
/// object in this app is one of these.
struct PosterSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var fill: Color = AppColors.card
    var stroke: Color = AppColors.ink
    var lineWidth: CGFloat = Poster.border
    var shadow: Color = AppColors.ink
    var offset: CGSize = Poster.mediumShadow

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                if offset != .zero {
                    shape.fill(shadow).offset(x: offset.width, y: offset.height)
                }
                shape.fill(fill)
                shape.strokeBorder(stroke, lineWidth: lineWidth)
            }
        }
    }
}

extension View {
    /// A rounded-rectangle poster surface.
    func posterSurface(
        cornerRadius: CGFloat = Poster.cardRadius,
        fill: Color = AppColors.card,
        stroke: Color = AppColors.ink,
        lineWidth: CGFloat = Poster.border,
        shadow: Color = AppColors.ink,
        offset: CGSize = Poster.mediumShadow
    ) -> some View {
        modifier(
            PosterSurface(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                fill: fill,
                stroke: stroke,
                lineWidth: lineWidth,
                shadow: shadow,
                offset: offset
            )
        )
    }

    /// A capsule poster surface.
    func posterCapsule(
        fill: Color = AppColors.card,
        stroke: Color = AppColors.ink,
        lineWidth: CGFloat = Poster.hairline,
        shadow: Color = AppColors.ink,
        offset: CGSize = Poster.smallShadow
    ) -> some View {
        modifier(
            PosterSurface(
                shape: Capsule(),
                fill: fill,
                stroke: stroke,
                lineWidth: lineWidth,
                shadow: shadow,
                offset: offset
            )
        )
    }

    /// A padded capsule that hugs its content — the app's floating label.
    ///
    /// Bare, with no press affordance: a chip is something to read, not something to tap. The
    /// padding is baked in ahead of the surface on purpose, so any framing belongs *after* this.
    func posterChip(fill: Color = AppColors.card) -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .posterCapsule(fill: fill)
    }

    /// The uppercase monospaced treatment shared by eyebrows, states, and metadata rows.
    func posterLabelStyle(_ size: CGFloat = 11, color: Color = AppColors.ink) -> some View {
        self
            .font(.posterLabel(size))
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

/// The app's card: cream, outlined, sitting a few points above its own shadow.
struct PosterCard<Content: View>: View {
    var padding: CGFloat = 16
    var fill: Color = AppColors.card
    var cornerRadius: CGFloat = Poster.cardRadius
    var shadow: CGSize = Poster.mediumShadow
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .posterSurface(cornerRadius: cornerRadius, fill: fill, offset: shadow)
            // The shadow is drawn outside the content box, so without this the neighbouring card
            // in a grid overlaps it.
            .padding(.trailing, shadow.width)
            .padding(.bottom, shadow.height)
    }
}

// MARK: - Buttons

/// A pill button, pressed into its own shadow.
struct PosterButtonStyle: ButtonStyle {
    var fill: Color = AppColors.ink
    var foreground: Color = AppColors.card
    var shadowColor: Color = AppColors.coral
    var isCompact = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(
            configuration: configuration,
            fill: fill,
            foreground: foreground,
            shadowColor: shadowColor,
            isCompact: isCompact
        )
    }

    /// Not named `Body`: that spelling collides with `ButtonStyle`'s own associated type.
    private struct Pill: View {
        let configuration: Configuration
        let fill: Color
        let foreground: Color
        let shadowColor: Color
        let isCompact: Bool
        @Environment(\.isEnabled) private var isEnabled

        private var pressed: Bool { configuration.isPressed }
        private var restingOffset: CGSize {
            isCompact ? CGSize(width: 3, height: 4) : CGSize(width: 4, height: 5)
        }
        private var shift: CGSize {
            isCompact ? CGSize(width: 2, height: 3) : CGSize(width: 3, height: 4)
        }

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.posterDisplay(isCompact ? 14 : 16, weight: .bold))
                // Disabled is drawn as an empty outline rather than a grey slab: a flat palette
                // has no "dimmer" to reach for, so the button loses its ink and its shadow
                // instead of gaining grey.
                .foregroundStyle(isEnabled ? foreground : AppColors.faint)
                .padding(.horizontal, isCompact ? 14 : 20)
                .frame(minHeight: isCompact ? 34 : 46)
                .posterCapsule(
                    fill: isEnabled ? fill : AppColors.paper,
                    stroke: isEnabled ? AppColors.ink : AppColors.faint,
                    lineWidth: Poster.border,
                    shadow: shadowColor,
                    offset: !isEnabled ? .zero : (pressed ? CGSize(width: 1, height: 1) : restingOffset)
                )
                .offset(x: pressed ? shift.width : 0, y: pressed ? shift.height : 0)
                .animation(.easeOut(duration: 0.12), value: pressed)
                .contentShape(.capsule)
        }
    }
}

extension ButtonStyle where Self == PosterButtonStyle {
    /// The primary call to action: ink, with a coral shadow.
    static var poster: PosterButtonStyle { .init() }
    static var posterCompact: PosterButtonStyle { .init(isCompact: true) }

    /// The cheerful alternative primary — lime on ink.
    static var posterLime: PosterButtonStyle {
        .init(fill: AppColors.lime, foreground: AppColors.ink, shadowColor: AppColors.ink)
    }

    /// A secondary control: cream, outlined, ink shadow.
    static var posterSecondary: PosterButtonStyle {
        .init(fill: AppColors.card, foreground: AppColors.ink, shadowColor: AppColors.ink)
    }

    static var posterSecondaryCompact: PosterButtonStyle {
        .init(fill: AppColors.card, foreground: AppColors.ink, shadowColor: AppColors.ink, isCompact: true)
    }

    /// Destructive, and loud about it.
    static var posterDanger: PosterButtonStyle {
        .init(fill: AppColors.coral, foreground: AppColors.card, shadowColor: AppColors.ink)
    }
}

// MARK: - Backgrounds

struct StickerBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            PosterPaper()
            content
        }
        // Every screen is wrapped in this shell, so setting the behavior here gives the
        // whole app one rule: dragging a vertical scroll view puts the keyboard away.
        // Horizontal strips (attachment chips, thumbnails) opt back out with `.never`.
        .scrollDismissesKeyboard(.immediately)
    }
}

/// Cream paper with two soft colour washes bled into opposite corners — the same treatment the
/// web hero uses. Deliberately the only blurred thing in the app: it is the page, not an object
/// on it, so it has no outline and casts no shadow.
struct PosterPaper: View {
    var body: some View {
        ZStack {
            AppColors.paper
            // Weak, and anchored off the edges: on a phone the washes cover the whole page
            // rather than a corner of a wide hero, so anything stronger stops reading as paper
            // and starts reading as a coloured screen.
            RadialGradient(
                colors: [AppColors.sky.opacity(0.34), AppColors.sky.opacity(0)],
                center: UnitPoint(x: -0.05, y: 0.02),
                startRadius: 0,
                endRadius: 360
            )
            RadialGradient(
                colors: [AppColors.lime.opacity(0.34), AppColors.lime.opacity(0)],
                center: UnitPoint(x: 1.05, y: 0.98),
                startRadius: 0,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Headings

/// A section heading with the poster's marker-pen highlight behind it.
struct PosterSectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var highlight: Color = AppColors.lime
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.posterDisplay(22, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                    .background(alignment: .bottom) {
                        // Sits behind the last third of the line height, the way a marker stroke
                        // under a word does.
                        highlight
                            .frame(height: 9)
                            .offset(y: -1)
                    }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppColors.muted)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension PosterSectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, highlight: Color = AppColors.lime) {
        self.init(title: title, subtitle: subtitle, highlight: highlight) { EmptyView() }
    }
}

/// A `Form` section title in the poster's uppercase label voice. The stock grey caption is the
/// last thing on a settings screen that still reads as somebody else's design system.
struct PosterListHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title).posterLabelStyle(10, color: AppColors.muted)
    }
}

/// The small uppercase tag that opens a section on the web ("● HOW IT WORKS").
struct PosterEyebrow: View {
    let text: String
    var dot: Color = AppColors.coral
    var fill: Color = AppColors.card

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).posterLabelStyle(10)
        }
        .posterChip(fill: fill)
    }
}

// MARK: - States

/// The empty state: a wobbly blob holding a glyph, then the poster's headline and a line of copy.
struct EmptyStateView: View {
    let title: String
    let message: String
    /// Defaults to the brand mark, which is what every empty state on the web shows.
    var icon: String = PosterIcon.mark
    var accent: Color = AppColors.lime

    var body: some View {
        VStack(spacing: 16) {
            StickerBlobIcon(icon: icon, fill: accent)
                .frame(width: 92, height: 92)

            Text(title)
                .font(.posterDisplay(26, weight: .bold))
                .foregroundStyle(AppColors.ink)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(AppColors.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A glyph inside the hand-drawn blob, tilted the way a sticker sits when you slap it on.
///
/// Takes a `PosterIcon` — an emoji or the `✦` mark — rather than an SF Symbol name. A stock
/// symbol inside a cartoon blob was the last thing on these screens still reading as iOS.
struct StickerBlobIcon: View {
    let icon: String
    var fill: Color = AppColors.lime
    var tilt: Double = -6

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Text(icon)
                // Emoji are drawn in their own colours and ignore `foregroundStyle`; `✦` is a
                // text glyph and takes the ink, which is what makes the two mix cleanly.
                .font(.system(size: side * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(AppColors.ink)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .modifier(
                    PosterSurface(
                        shape: BlobShape(),
                        fill: fill,
                        lineWidth: Poster.border,
                        offset: Poster.smallShadow
                    )
                )
        }
        .rotationEffect(.degrees(tilt))
        .accessibilityHidden(true)
    }
}

/// Something that went the way it had to rather than the way that was asked for. Deliberately not
/// an `ErrorBanner`: the work succeeded, and colouring it red would say it did not.
struct NoticeBanner: View {
    let message: String

    var body: some View {
        PosterSymbolLabel(verbatim: message, posterSymbol: "info.circle.fill")
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(AppColors.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .posterSurface(cornerRadius: Poster.tileRadius, fill: AppColors.sky, offset: Poster.smallShadow)
            .padding(.trailing, Poster.smallShadow.width)
            .padding(.bottom, Poster.smallShadow.height)
            .accessibilityIdentifier("notice-banner")
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        PosterSymbolLabel(verbatim: message, posterSymbol: "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(AppColors.card)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .posterSurface(cornerRadius: Poster.tileRadius, fill: AppColors.coral, offset: Poster.smallShadow)
            .padding(.trailing, Poster.smallShadow.width)
            .padding(.bottom, Poster.smallShadow.height)
            .accessibilityIdentifier("error-banner")
    }
}

/// A working indicator that matches the rest of the paper: a spinner and a line of copy on a card.
struct PosterProgress: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(AppColors.coral)
            Text(message)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.ink)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .posterSurface(cornerRadius: Poster.tileRadius, offset: Poster.smallShadow)
    }
}

// MARK: - System chrome

/// Repaints UIKit's bars, which SwiftUI does not reach, so the navigation and tab bars are paper
/// and ink rather than the system's translucent grey.
enum PosterChrome {
    static func apply() {
        let ink = UIColor(AppColors.ink)
        let paper = UIColor(AppColors.paper)

        let title: [NSAttributedString.Key: Any] = [
            .foregroundColor: ink,
            .font: rounded(ofSize: 17, weight: .bold)
        ]
        let largeTitle: [NSAttributedString.Key: Any] = [
            .foregroundColor: ink,
            .font: rounded(ofSize: 34, weight: .heavy)
        ]

        // Transparent in every state — scrolled as well as at rest. The bar has no surface of
        // its own: the page's paper and its colour washes run under it unbroken, and the bar's
        // controls carry their own outlined capsules, so nothing here needs a plate to sit on.
        // An opaque bar instead put a cream band with a hard edge across the top of every screen.
        let navigation = UINavigationBarAppearance()
        navigation.configureWithTransparentBackground()
        navigation.titleTextAttributes = title
        navigation.largeTitleTextAttributes = largeTitle

        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().tintColor = UIColor(AppColors.coral)

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(AppColors.card)
        tab.shadowColor = ink.withAlphaComponent(0.35)
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: rounded(ofSize: 10, weight: .semibold)]
            item.selected.titleTextAttributes = [.font: rounded(ofSize: 10, weight: .bold)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        // The segmented control is the one stock control the app uses in quantity, and its
        // default grey-on-grey is the loudest non-poster surface left on screen.
        let segmented = UISegmentedControl.appearance()
        segmented.backgroundColor = UIColor(AppColors.paper)
        segmented.selectedSegmentTintColor = UIColor(AppColors.lime)
        segmented.setTitleTextAttributes(
            [.foregroundColor: ink, .font: rounded(ofSize: 13, weight: .semibold)],
            for: .normal
        )
        segmented.setTitleTextAttributes(
            [.foregroundColor: ink, .font: rounded(ofSize: 13, weight: .heavy)],
            for: .selected
        )

        // Paging dots default to white, which is invisible on cream.
        UIPageControl.appearance().pageIndicatorTintColor = ink.withAlphaComponent(0.22)
        UIPageControl.appearance().currentPageIndicatorTintColor = ink

        let search = UISearchBar.appearance()
        search.tintColor = UIColor(AppColors.coral)
        search.searchTextField.backgroundColor = UIColor(AppColors.card)
        search.searchTextField.textColor = ink

        UIRefreshControl.appearance().tintColor = UIColor(AppColors.coral)
    }

    /// `Font.system(design: .rounded)` has no UIKit spelling; this is the documented way to get it.
    private static func rounded(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

#Preview("Poster kit") {
    StickerBackground {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PosterEyebrow(text: "Design system")
                PosterSectionHeader(title: "Sticker parts", subtitle: "cream, ink, and one loud accent")

                PosterCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A card").font(.posterDisplay(20))
                        Text("Flat fill, ink outline, hard shadow.")
                            .foregroundStyle(AppColors.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button { } label: { Label("Generate", systemImage: "wand.and.stars") }
                        .buttonStyle(.poster)
                    Button("Cancel") {}
                        .buttonStyle(.posterSecondary)
                }

                NoticeBanner(message: "Saved without motion.")
                ErrorBanner(message: "Could not reach the server.")
                EmptyStateView(
                    title: "No stickers yet",
                    message: "Create a static or animated sticker to get started."
                )
            }
            .padding()
        }
    }
    .fontDesign(.rounded)
}
