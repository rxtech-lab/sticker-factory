import SwiftUI
import RxAuthSwiftUI

@main
struct StickerAppClipApp: App {
    @State private var route: StickerShareRoute = .quick
    @State private var authentication = ClipAuthentication()

    init() {
        PosterChrome.apply()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--clip-library-fixtures") {
            UserDefaults.standard.removeObject(forKey: "clip-library-fixture-created")
            let fixture = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320)).pngData { _ in
                ("🐱" as NSString).draw(at: CGPoint(x: 22, y: 10), withAttributes: [.font: UIFont.systemFont(ofSize: 250)])
            }
            try? fixture.write(to: FileManager.default.temporaryDirectory.appending(path: "clip-library-fixture.png"))
            URLProtocol.registerClass(ClipLibraryFixtureProtocol.self)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                switch route {
                case .pack(let slug): ClipPackView(slug: slug)
                case .quick: ClipQuickEntry(authentication: authentication)
                }
            }
            .tint(AppColors.accent)
            .foregroundStyle(AppColors.ink)
            .preferredColorScheme(.light)
            .fontDesign(.rounded)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL, let destination = StickerShareRoute(url: url) { route = destination }
            }
            .onOpenURL { url in if let destination = StickerShareRoute(url: url) { route = destination } }
        }
    }
}

private struct ClipQuickEntry: View {
    @Bindable var authentication: ClipAuthentication
    @State private var showingSignIn = false
    var body: some View {
        Group {
            if authentication.signedIn, let baseURL = try? MessagesAPIConfiguration.baseURL() {
                ClipLibraryView(
                    generation: QuickModeModel(baseURL: baseURL, appClip: true) { force in
                        try await authentication.token(forceRefresh: force)
                    },
                    makeModel: {
                        QuickModeModel(baseURL: baseURL, appClip: true) { force in
                            try await authentication.token(forceRefresh: force)
                        }
                    }
                )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .destructive) { authentication.signOut() } label: {
                                PosterToolbarIcon(glyph: .signOut)
                            }
                            .accessibilityLabel("Sign Out")
                            .accessibilityIdentifier("clip-sign-out")
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if let error = authentication.error { ErrorBanner(message: error).padding() }
                    }
            } else {
                welcome
            }
        }
        .onChange(of: authentication.signedIn) { _, signedIn in
            if signedIn { showingSignIn = false }
        }
        .sheet(isPresented: $showingSignIn, onDismiss: { authentication.endSignIn() }, content: {
            NavigationStack {
                if let manager = authentication.signInManager {
                    RxSignInView(
                        manager: manager,
                        appearance: .init(
                            icon: .systemImage("person.crop.circle"),
                            title: "Sticker Factory",
                            subtitle: "Make expressive stickers from words and photos.",
                            signInButtonTitle: "Sign in with RxLab",
                            accentColor: AppColors.accent,
                            secondaryColor: AppColors.secondaryAccent,
                            showsAnimatedBackground: true
                        ),
                        style: .native,
                        onAuthSuccess: { authentication.completeNativeSignIn() }
                    )
                    .accessibilityIdentifier("clip-native-sign-in")
                    .safeAreaInset(edge: .bottom) {
                        if let error = authentication.error { ErrorBanner(message: error).padding() }
                    }
                    .navigationTitle("Sign in")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingSignIn = false }
                                .accessibilityIdentifier("clip-sign-in-close")
                                .disabled(manager.isAuthenticating)
                        }
                    }
                }
            }
            .interactiveDismissDisabled()
            .presentationDragIndicator(.hidden)
        })
    }

    private var welcome: some View {
        StickerBackground {
            ScrollView {
                VStack(spacing: 24) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            brand
                            Spacer(minLength: 12)
                            clipBadge
                        }
                        VStack(spacing: 12) { brand; clipBadge }
                    }

                    ZStack {
                        StickerBlobIcon(icon: "👋", fill: AppColors.sky, tilt: -12)
                            .frame(width: 100, height: 104)
                            .offset(x: -94, y: 12)
                        StickerBlobIcon(icon: "💬", fill: AppColors.peach, tilt: 12)
                            .frame(width: 94, height: 100)
                            .offset(x: 98, y: -8)
                        StickerBlobIcon(icon: PosterIcon.mark, fill: AppColors.lime, tilt: -5)
                            .frame(width: 132, height: 136)
                            .offset(y: -8)
                    }
                    .frame(height: 164)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)

                    VStack(spacing: 12) {
                        Text("Make a sticker")
                            .font(.posterDisplay(36, weight: .heavy))
                            .tracking(-1.2)
                            .accessibilityAddTraits(.isHeader)
                        Text("A little idea. A lot of personality.")
                            .font(.title3.weight(.semibold))
                        Text("Turn words or a favorite photo into a sticker worth sending.")
                            .font(.body)
                            .foregroundStyle(AppColors.muted)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    PosterCard(fill: AppColors.lime) {
                        HStack(spacing: 14) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 36, weight: .heavy))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Free quick generations")
                                    .font(.headline)
                                Text("Sign in to see your allowance.")
                                    .font(.subheadline)
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    VStack(spacing: 16) {
                        Button {
                            if authentication.prepareSignIn() { showingSignIn = true }
                        } label: {
                            Label("Sign in with RxLab", systemImage: "person.crop.circle")
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.poster)

                        Text("Your stickers stay in your RxLab account.")
                            .font(.footnote)
                            .foregroundStyle(AppColors.muted)
                            .multilineTextAlignment(.center)

                        if let error = authentication.error { ErrorBanner(message: error) }

                        Link(destination: StickerShareRoute.appStoreURL) {
                            Label("Get the full app", systemImage: "arrow.up.right")
                                .frame(minHeight: 44)
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppColors.ink)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Text(PosterIcon.mark).foregroundStyle(AppColors.coral).accessibilityHidden(true)
            Text("Sticker Factory")
        }
        .font(.headline.weight(.heavy))
    }

    private var clipBadge: some View {
        Text("App Clip")
            .posterLabelStyle(10)
            .posterChip()
    }
}
