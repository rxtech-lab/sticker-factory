import SwiftUI
import TipKit

/// First-launch education and the TipKit eligibility shared by the workflow's real controls.
enum StickerOnboarding {
    static let welcomeStorageKey = "sticker-factory.welcome.v1.seen"
    private static let appName = AppConfiguration.defaultAppName

    static let slides: [StickerWelcomeSlide] = [
        .init(
            id: "welcome",
            icon: PosterIcon.welcome,
            title: String(localized: "Welcome to \(appName)"),
            message: String(localized: """
                Turn an idea or a favorite photo into an expressive sticker \
                you can keep, share, and use in Messages.
                """)
        ),
        .init(
            id: "generate",
            icon: PosterIcon.write,
            title: String(localized: "1. Generate"),
            message: String(localized: "Describe one sticker, choose static or animated, and add reference photos when they help.")
        ),
        .init(
            id: "confirm",
            icon: PosterIcon.review,
            title: String(localized: "2. Confirm"),
            message: String(localized: "Review the assistant’s plan before generation, then accept or reject the finished candidate.")
        ),
        .init(
            id: "versions",
            icon: PosterIcon.versions,
            title: String(localized: "3. Keep every version"),
            message: String(localized: """
                Accepted changes stay in version history, \
                where you can compare results and restore an earlier sticker.
                """)
        ),
        .init(
            id: "publish",
            icon: PosterIcon.publish,
            title: String(localized: "4. Publish"),
            message: String(localized: "Choose the export settings and publish an accepted version as Apple-compatible sticker files.")
        ),
        .init(
            id: "use",
            icon: PosterIcon.chat,
            title: String(localized: "5. Use it"),
            message: String(localized: """
                Open \(appName) from the Messages app drawer to send published stickers, \
                or share the exported files anywhere.
                """)
        )
    ]

    static func shouldPresentWelcome(
        hasSeenWelcome: Bool,
        isUITesting: Bool,
        forceWelcome: Bool = false
    ) -> Bool {
        forceWelcome || (!hasSeenWelcome && !isUITesting)
    }

    static func configureTips(isUITesting: Bool) {
        guard !isUITesting else { return }
        try? Tips.configure([
            .datastoreLocation(.applicationDefault),
            .displayFrequency(.immediate)
        ])
    }
}

struct StickerWelcomeSlide: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: String
    let message: String

    var imageName: String? {
        switch id {
        case "welcome": "WelcomeStickers"
        case "generate": "WelcomeGenerate"
        case "confirm": "WelcomeConfirm"
        case "versions": "WelcomeVersions"
        case "publish": "WelcomePublish"
        case "use": "WelcomeUse"
        default: nil
        }
    }
}

/// The same compact, paged first-launch pattern used by debate-bot, adapted to the complete
/// App workflow. It is intentionally non-dismissable the first time: finishing the
/// short tour is what unlocks the contextual tips that follow it.
struct StickerWelcomeSheet: View {
    var onContinue: () -> Void
    var onReadTutorial: (() -> Void)? = nil

    /// One per slide, cycled if the tour ever grows past them.
    private static let slideColors: [Color] = [
        AppColors.lime,
        AppColors.sky,
        AppColors.peach,
        AppColors.mint,
        AppColors.highlight,
        AppColors.sky
    ]

    @State private var index = 0

    private var isLastSlide: Bool { index >= StickerOnboarding.slides.count - 1 }

    var body: some View {
        StickerBackground {
            VStack(spacing: 24) {
                TabView(selection: $index) {
                    ForEach(Array(StickerOnboarding.slides.enumerated()), id: \.element.id) { offset, slide in
                        VStack(spacing: 22) {
                            if let imageName = slide.imageName {
                                Image(imageName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 180, height: 180)
                                    .accessibilityHidden(true)
                            } else {
                                StickerBlobIcon(
                                    icon: slide.icon,
                                    fill: Self.slideColors[offset % Self.slideColors.count],
                                    tilt: offset.isMultiple(of: 2) ? -7 : 6
                                )
                                .frame(width: 132, height: 132)
                            }

                            Text(slide.title)
                                .font(.posterDisplay(30, weight: .heavy))
                                .foregroundStyle(AppColors.ink)
                                .multilineTextAlignment(.center)

                            Text(slide.message)
                                .font(.cartoonBody)
                                .foregroundStyle(AppColors.ink.opacity(0.8))
                                .lineSpacing(4)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 32)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                if isLastSlide, let onReadTutorial {
                    Button(action: onReadTutorial) {
                        Label(TutorialCopy.text("Read tutorials"), systemImage: "book.closed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.posterSecondary)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("welcome-read-tutorials")
                }
                Button {
                    if isLastSlide {
                        onContinue()
                    } else {
                        withAnimation { index += 1 }
                    }
                } label: {
                    Text(isLastSlide ? LocalizedStringKey("Get started") : LocalizedStringKey("Next"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(isLastSlide ? .posterLime : .poster)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
                .accessibilityIdentifier("welcome-next-button")
            }
            .padding(.top, 40)
        }
        .interactiveDismissDisabled(true)
        .presentationDragIndicator(.hidden)
    }
}

/// Transient eligibility comes from the durable welcome flag on every launch; TipKit owns the
/// durable display and dismissal state for each individual tip.
enum StickerOnboardingTips {
    @Parameter(.transient) static var welcomeCompleted: Bool = false

    nonisolated static let acceptedRevisionAvailable = Tips.Event(
        id: "sticker-factory.onboarding.accepted-revision.v1"
    )

    static func setWelcomeCompleted(_ completed: Bool) {
        welcomeCompleted = completed
    }

    static func acceptedRevisionBecameAvailable() {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        acceptedRevisionAvailable.sendDonation()
    }
}

struct GenerateStickerTip: Tip {
    var id: String { "sticker-factory.onboarding.generate.v1" }
    var title: Text { Text("Generate your first sticker") }
    var message: Text? { Text("Start with a prompt and optional photos. The assistant will propose a plan before it generates anything.") }
    var image: Image? { Image("PosterSignIn") }
    var rules: [Rule] {
        #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 }
    }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

/// Anchored on an attached reference photo, because the badge on the thumbnail is the only other
/// thing saying that the photo is tappable at all — and a badge alone never said what the tap does.
struct LiftSubjectTip: Tip {
    var id: String { "sticker-factory.onboarding.lift-subject.v1" }
    var title: Text { Text("Lift the subject out") }
    var message: Text? {
        Text("""
            Tap a photo you attached to cut its subject away from the background, \
            so only the part you want reaches the sticker.
            """)
    }
    var image: Image? { Image("PosterSignIn") }
    var rules: [Rule] {
        #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 }
    }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

struct ConfirmPlanTip: Tip {
    var id: String { "sticker-factory.onboarding.confirm-plan.v1" }
    var title: Text { Text("Confirm before generation") }
    var message: Text? { Text("Check the layers, layout, and image count. Build only when the plan matches what you want.") }
    var image: Image? { Image("PosterSignIn") }
    var rules: [Rule] {
        #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 }
    }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

/// Shown inside the plan card rather than as a popover.
///
/// The card already has a popover on its Build button, and two of them arriving together on one
/// card would each cover the other's target. A mini tip sits in the flow instead, directly above
/// the row it is describing.
struct EditPlanTip: Tip {
    var id: String { "sticker-factory.onboarding.edit-plan.v1" }
    var title: Text { Text("Change the plan yourself") }
    var message: Text? {
        Text("""
            Tap the layer count or the timing to edit layers, motion and duration. \
            Every change is saved as a version you can switch back to.
            """)
    }
    var rules: [Rule] {
        #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 }
    }
    var options: [any TipOption] { Tips.MaxDisplayCount(2) }
}

struct ReviewCandidateTip: Tip {
    var id: String { "sticker-factory.onboarding.review-candidate.v1" }
    var title: Text { Text("Choose the next version") }
    var message: Text? { Text("Review the candidate, compare it with the current sticker, then accept or reject it.") }
    var image: Image? { Image("PosterSignIn") }
    var rules: [Rule] {
        #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 }
    }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

struct VersionHistoryTip: Tip {
    var id: String { "sticker-factory.onboarding.version-history.v1" }
    var title: Text { Text("Your versions are safe") }
    var message: Text? { Text("Open Sticker actions to compare versions, restore an earlier one, or publish the current version.") }
    var image: Image? { Image("PosterSignIn") }
    var rules: [Rule] {
        #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 }
        #Rule(StickerOnboardingTips.acceptedRevisionAvailable) { $0.donations.count > 0 }
    }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

struct PublishStickerTip: Tip {
    var id: String { "sticker-factory.onboarding.publish.v1" }
    var title: Text { Text("Publish for Messages") }
    var message: Text? { Text("Pick the sticker size and formats, then export and publish this accepted version to your Library.") }
    var image: Image? { Image("PosterSignIn") }
    var rules: [Rule] {
        #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 }
    }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

struct UseStickerTip: Tip {
    var id: String { "sticker-factory.onboarding.use.v1" }
    var title: Text { Text("Use it in Messages") }
    var message: Text? {
        Text(String(localized: """
            Open \(AppConfiguration.defaultAppName) in the Messages app drawer to send this sticker. \
            You can also share the exported files below.
            """))
    }
    var image: Image? { Image("PosterSignIn") }
    var rules: [Rule] {
        #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 }
    }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

/// One tip for the pair of messenger buttons rather than one each: they sit side by side, and two
/// popovers competing over the same row would each cover the other's button.
struct MessengerExportTip: Tip {
    var id: String { "sticker-factory.onboarding.messenger-export.v1" }
    var title: Text { Text("Send the pack to WhatsApp or Telegram") }
    var message: Text? {
        Text("""
            Every pack works in both. Stickers are converted for you, \
            and a pack too big for one messenger is split into parts it accepts.
            """)
    }
    var image: Image? { Image("FeatureWhatsApp") }
    var rules: [Rule] {
        #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 }
    }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

#Preview("Welcome") {
    StickerWelcomeSheet(onContinue: {})
}
