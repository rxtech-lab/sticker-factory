import Foundation
import Observation
import SwiftUI

/// One "what's new" card. The `id` is a permanent slug: the device remembers which ids it has
/// acknowledged, so unread = `all` minus acknowledged. Appending a card with a fresh slug surfaces
/// it to existing users; changing a slug shows its card again. Never reuse or renumber one.
struct FeatureAnnouncement: Identifiable, Equatable {
    let id: String
    let icon: String
    let accent: Color
    let title: String
    let message: String

    var imageName: String? {
        switch id {
        case "whatsapp-sticker-import": "FeatureWhatsApp"
        case "telegram-sticker-import": "FeatureTelegram"
        case "controllable-animation": "FeatureControllableAnimation"
        case "tutorial-library": "FeatureTutorial"
        default: nil
        }
    }

    static func == (lhs: FeatureAnnouncement, rhs: FeatureAnnouncement) -> Bool { lhs.id == rhs.id }

    /// Every card ever shipped, oldest first. Append; never reorder or remove.
    static let all: [FeatureAnnouncement] = [
        .init(
            id: "whatsapp-sticker-import",
            icon: "💬",
            accent: MessengerDestination.whatsapp.accent,
            title: String(localized: "Your packs, in WhatsApp"),
            message: String(localized: """
                Open any pack under Sticker Packs and tap Add to WhatsApp. \
                Still and animated stickers become separate packs, and a big pack is split evenly, \
                so every one fits WhatsApp's rules. Pick each sticker's emoji before you send.
                """)
        ),
        .init(
            id: "telegram-sticker-import",
            icon: "✈️",
            accent: MessengerDestination.telegram.accent,
            title: String(localized: "Your packs, in Telegram"),
            message: String(localized: """
                The same pack screen sends to Telegram: \
                stills go as PNG, animations as transparent video, sped up when they run past Telegram's three seconds. \
                Telegram asks for the pack's name when it opens.
                """)
        ),
        .init(
            id: "controllable-animation",
            icon: "🎛️",
            accent: AppColors.indigo,
            title: String(localized: "Controllable animation"),
            message: String(localized: """
                Change the animation after you make it. Try a new move, fine-tune the timing, or keep the version that feels just right.
                """)
        ),
        .init(
            id: "tutorial-library",
            icon: "📖",
            accent: AppColors.lime,
            title: TutorialCopy.text("Learn with tutorials"),
            message: TutorialCopy.text(
                "Real app screenshots, little steps, and ideas to try. Learn to create, animate and share your stickers."
            )
        ),
        .init(
            id: "pet-on-apple-watch",
            icon: "🐾",
            accent: AppColors.coral,
            title: String(localized: "Your pet, on your wrist"),
            message: String(localized: """
                Choose a controllable sticker in the Pet tab. See it on your Apple Watch and widgets, \
                and send stickers in Messages to let its mood change.
                """)
        )
    ]
}

/// Which cards this device has acknowledged.
///
/// Kept in `UserDefaults` on its own key, so it survives app updates and sign-in changes alike: a
/// feature is new to a phone once, whoever is signed in and whichever build introduced it.
@MainActor
@Observable
final class FeatureAnnouncementStore {
    static let readIDsKey = "sticker-factory.feature-cards.v1.read-ids"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var readIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.readIDsKey) ?? [])
    }

    /// The cards still to show, in shipping order.
    var unread: [FeatureAnnouncement] {
        unread(from: FeatureAnnouncement.all)
    }

    func unread(from cards: [FeatureAnnouncement]) -> [FeatureAnnouncement] {
        let read = readIDs
        return cards.filter { !read.contains($0.id) }
    }

    /// Marks one card read. Called per card as it is acknowledged, so a flow interrupted halfway
    /// keeps the rest unread.
    func markRead(_ id: String) {
        var read = readIDs
        guard read.insert(id).inserted else { return }
        defaults.set(Array(read).sorted(), forKey: Self.readIDsKey)
    }

    /// Whether to put the cards up at all.
    ///
    /// Suppressed under UI automation, where an unexpected sheet fails every test after it, unless
    /// a test asks for them by flag — the same rule the welcome tour follows.
    static func shouldPresent(unreadCount: Int, isUITesting: Bool, force: Bool = false) -> Bool {
        force || (unreadCount > 0 && !isUITesting)
    }
}

/// One step of the launch flow, shown in order inside a single sheet.
enum LaunchStep {
    case welcome
    case featureCards([FeatureAnnouncement])
}

/// One showing of the launch flow: what the sheet is handed, so it cannot come up empty.
struct LaunchFlowPresentation: Identifiable {
    let id = UUID()
    let steps: [LaunchStep]
}

/// The welcome tour, then the feature cards, in one sheet that advances rather than dismissing
/// and re-presenting — the same shape as debate-bot's launch flow. The tour's completion and each
/// card's acknowledgement are reported as they happen, so an interrupted flow keeps whatever was
/// not reached for next time.
struct LaunchFlowView: View {
    let steps: [LaunchStep]
    var allowsWelcomeTutorial = false
    var onReadTutorial: () -> Void = {}
    var onWelcomeSeen: () -> Void
    var onCardAcknowledged: (String) -> Void
    var onFinished: () -> Void

    @State private var index = 0

    var body: some View {
        Group {
            if index < steps.count {
                switch steps[index] {
                case .welcome:
                    StickerWelcomeSheet(onContinue: {
                        onWelcomeSeen()
                        advance()
                    }, onReadTutorial: allowsWelcomeTutorial ? {
                        onWelcomeSeen(); onReadTutorial()
                    } : nil)
                case .featureCards(let cards):
                    FeatureAnnouncementSheet(
                        cards: cards,
                        onAcknowledge: onCardAcknowledged,
                        onFinished: advance,
                        onReadTutorial: onReadTutorial
                    )
                }
            } else {
                Color.clear.onAppear(perform: onFinished)
            }
        }
        .interactiveDismissDisabled(true)
    }

    private func advance() {
        if index + 1 < steps.count {
            withAnimation { index += 1 }
        } else {
            onFinished()
        }
    }
}

/// The cards, paged, in the welcome tour's clothes.
///
/// Each Next or Got it acknowledges the card it was tapped on and nothing else, so quitting the
/// app on card two leaves cards two and three for next time. Not dismissable by swipe for the same
/// reason: a swipe would either lose the acknowledgement or fake it.
struct FeatureAnnouncementSheet: View {
    let cards: [FeatureAnnouncement]
    var onAcknowledge: (String) -> Void
    var onFinished: () -> Void
    var onReadTutorial: () -> Void = {}

    @State private var index = 0

    private var isLast: Bool { index >= cards.count - 1 }

    var body: some View {
        StickerBackground {
            VStack(spacing: 24) {
                Text("What's new")
                    .posterLabelStyle(11, color: AppColors.muted)
                    .padding(.top, 28)

                TabView(selection: $index) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { offset, card in
                        VStack(spacing: 22) {
                            if let imageName = card.imageName {
                                Image(imageName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 180, height: 180)
                                    .accessibilityHidden(true)
                            } else {
                                StickerBlobIcon(icon: card.icon, fill: card.accent, tilt: offset.isMultiple(of: 2) ? -7 : 6)
                                    .frame(width: 132, height: 132)
                            }

                            Text(card.title)
                                .font(.posterDisplay(30, weight: .heavy))
                                .foregroundStyle(AppColors.ink)
                                .multilineTextAlignment(.center)

                            Text(card.message)
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
                        .accessibilityIdentifier("feature-card-\(card.id)")
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: cards.count > 1 ? .always : .never))

                if isLast {
                    Button {
                        if cards.indices.contains(index) { onAcknowledge(cards[index].id) }
                        onReadTutorial()
                    } label: {
                        Label(TutorialCopy.text("Read tutorials"), systemImage: "book.closed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.posterSecondary)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("feature-read-tutorials")
                }
                Button {
                    guard cards.indices.contains(index) else { onFinished(); return }
                    onAcknowledge(cards[index].id)
                    if isLast {
                        onFinished()
                    } else {
                        withAnimation { index += 1 }
                    }
                } label: {
                    Text(isLast ? LocalizedStringKey("Got it") : LocalizedStringKey("Next"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(isLast ? .posterLime : .poster)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
                .accessibilityIdentifier("feature-card-next-button")
            }
        }
        .interactiveDismissDisabled(true)
        .presentationDragIndicator(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feature-cards-sheet")
    }
}

#Preview("Feature cards") {
    FeatureAnnouncementSheet(cards: FeatureAnnouncement.all, onAcknowledge: { _ in }, onFinished: {})
}
