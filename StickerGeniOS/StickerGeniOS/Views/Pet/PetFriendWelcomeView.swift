import SwiftUI

/// The welcome for a friend the pet made on its own, full screen with the rest of the tab put away:
/// the pet on the left, its new friend — a controllable sticker of their own — on the right, and
/// "Met new friends!" in big cartoon letters, with the same hello cycling through other languages.
///
/// The art is passed in, so the tab can stand the pet in its current pose and the preview can use
/// bundled pictures.
struct PetFriendWelcomeView<PetArt: View, FriendArt: View>: View {
    let friend: PetFriend
    let petTitle: String
    let onDone: () -> Void
    @ViewBuilder let petArt: () -> PetArt
    @ViewBuilder let friendArt: () -> FriendArt

    @State private var phraseIndex = 0
    @State private var hasArrived = false
    @State private var petHop = 0
    @State private var friendHop = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            PetFriendBackdrop(isSpinning: !reduceMotion)
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                PetCartoonText(String(localized: "Met new friends!"), size: 42, fill: AppColors.lime)
                    .rotationEffect(.degrees(-4))
                    .scaleEffect(hasArrived ? 1 : 0.3)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("pet-friend-headline")
                phrase
                    .frame(height: 48)
                pair
                greetingBubble
                Spacer(minLength: 0)
                Button {
                    Haptics.tap(.medium)
                    onDone()
                } label: {
                    Label {
                        Text("Say Hello to \(friend.name)")
                    } icon: {
                        Image(systemName: "hand.wave.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.poster)
                .accessibilityIdentifier("pet-friend-done")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
        }
        .task {
            Haptics.success()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { hasArrived = true }
            // A new hello in another language every beat, each landing with a soft tap.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    phraseIndex = (phraseIndex + 1) % PetFriendPhrase.all.count
                }
                Haptics.tap(.soft, intensity: 0.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pet-friend-welcome")
    }

    /// The same hello, in one language after another.
    private var phrase: some View {
        let current = PetFriendPhrase.all[phraseIndex]
        return PetCartoonText(current.text, size: 26, fill: current.color)
            .rotationEffect(.degrees(current.tilt))
            .environment(\.layoutDirection, current.isRightToLeft ? .rightToLeft : .leftToRight)
            .id(phraseIndex)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.4).combined(with: .opacity),
                removal: .scale(scale: 1.3).combined(with: .opacity)
            ))
            // Decorative: the headline already says it, once, in the owner's language.
            .accessibilityHidden(true)
    }

    /// The pet on the left and its new friend on the right, each with its name underneath.
    private var pair: some View {
        HStack(alignment: .bottom, spacing: 8) {
            portrait(title: petTitle, hop: $petHop, delay: 0.1, id: "pet-friend-pet") { petArt() }
            Image(systemName: "heart.fill")
                .font(.system(size: 30))
                .foregroundStyle(AppColors.coral)
                .shadow(color: AppColors.ink, radius: 0, x: 2, y: 2)
                .symbolEffect(.bounce, options: reduceMotion ? .nonRepeating : .repeating, value: hasArrived)
                .padding(.bottom, 70)
                .accessibilityHidden(true)
            portrait(title: friend.name, hop: $friendHop, delay: 0.25, id: "pet-friend-sticker") { friendArt() }
        }
    }

    private func portrait(
        title: String, hop: Binding<Int>, delay: Double, id: String, @ViewBuilder art: () -> some View
    ) -> some View {
        VStack(spacing: 8) {
            art()
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 170)
                .phaseAnimator([0, -18, 0], trigger: hop.wrappedValue) { content, offset in
                    content.offset(y: offset)
                } animation: { _ in .spring(response: 0.25, dampingFraction: 0.5) }
                .scaleEffect(hasArrived ? 1 : 0.2)
                .animation(.spring(response: 0.55, dampingFraction: 0.6).delay(delay), value: hasArrived)
                .contentShape(.rect)
                // A tap makes either one hop hello.
                .onTapGesture {
                    Haptics.tap(.light)
                    hop.wrappedValue += 1
                }
            Text(title)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(AppColors.ink)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(AppColors.card, in: .capsule)
                .overlay { Capsule().strokeBorder(AppColors.ink, lineWidth: 2.5) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Hops hello"))
        .accessibilityAction { hop.wrappedValue += 1 }
        .accessibilityIdentifier(id)
    }

    /// The pet introducing its friend, and how they met.
    private var greetingBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(friend.greeting)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.ink)
            Text(friend.story)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(AppColors.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppColors.card, in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(AppColors.ink, lineWidth: 3) }
        .opacity(hasArrived ? 1 : 0)
        .offset(y: hasArrived ? 0 : 20)
        .animation(.snappy(duration: 0.4).delay(0.4), value: hasArrived)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pet-friend-greeting")
    }
}

/// Chunky cartoon lettering: a bright fill inside a thick ink outline, dropped on an ink shadow.
struct PetCartoonText: View {
    let text: String
    var size: CGFloat = 32
    var fill: Color = AppColors.lime

    init(_ text: String, size: CGFloat = 32, fill: Color = AppColors.lime) {
        self.text = text
        self.size = size
        self.fill = fill
    }

    /// The outline is the text drawn in ink around itself, so it follows any script's shapes.
    private static let outline: [CGSize] = stride(from: 0.0, to: 360.0, by: 30.0).map {
        CGSize(width: cos($0 * .pi / 180), height: sin($0 * .pi / 180))
    }

    var body: some View {
        let stroke = max(2, size / 11)
        ZStack {
            ForEach(Self.outline.indices, id: \.self) { index in
                letters.foregroundStyle(AppColors.ink)
                    .offset(x: Self.outline[index].width * stroke, y: Self.outline[index].height * stroke + stroke)
            }
            ForEach(Self.outline.indices, id: \.self) { index in
                letters.foregroundStyle(AppColors.ink)
                    .offset(x: Self.outline[index].width * stroke, y: Self.outline[index].height * stroke)
            }
            letters.foregroundStyle(fill)
            // A glossy highlight across the top of the letters.
            letters.foregroundStyle(.white.opacity(0.45))
                .mask { LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center) }
        }
        .padding(stroke * 2)
        // One layer, so a fade dims the lettering as a whole rather than each outline copy through the next.
        .compositingGroup()
        // Read once, as the words, not once per outline copy.
        .accessibilityRepresentation { Text(verbatim: text) }
    }

    private var letters: some View {
        Text(verbatim: text)
            .font(.system(size: size, weight: .black, design: .rounded))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
    }
}

/// "Welcome, new friend!", "Meet new friends!" and the like, each in its own language, colour and tilt.
struct PetFriendPhrase {
    let text: String
    let color: Color
    let tilt: Double
    var isRightToLeft = false

    static let all: [PetFriendPhrase] = [
        .init(text: "Welcome, new friend!", color: AppColors.sky, tilt: -3),
        .init(text: "新しい友だち！", color: AppColors.peach, tilt: 3),
        .init(text: "认识新朋友！", color: AppColors.mint, tilt: -2),
        .init(text: "¡Nuevos amigos!", color: AppColors.coral, tilt: 4),
        .init(text: "새 친구를 만났어요!", color: AppColors.lime, tilt: -4),
        .init(text: "Meet new friends!", color: AppColors.highlight, tilt: 2),
        .init(text: "歡迎新朋友！", color: AppColors.sky, tilt: -3),
        .init(text: "Bienvenue, nouvel ami !", color: AppColors.mint, tilt: 3),
        .init(text: "Neue Freunde!", color: AppColors.peach, tilt: -2),
        .init(text: "はじめまして！", color: AppColors.coral, tilt: 4),
        .init(text: "Ciao, nuovo amico!", color: AppColors.lime, tilt: -3),
        .init(text: "新朋友來啦！", color: AppColors.highlight, tilt: 2),
        .init(text: "Olá, novo amigo!", color: AppColors.sky, tilt: -4),
        .init(text: "Привет, новый друг!", color: AppColors.mint, tilt: 3),
        .init(text: "Say hi to my buddy!", color: AppColors.peach, tilt: -2),
        .init(text: "Hallo, nieuwe vriend!", color: AppColors.coral, tilt: 3),
        .init(text: "เพื่อนใหม่มาแล้ว!", color: AppColors.lime, tilt: -3),
        .init(text: "Xin chào bạn mới!", color: AppColors.highlight, tilt: 4),
        .init(text: "Selamat datang, teman baru!", color: AppColors.sky, tilt: -2),
        .init(text: "नमस्ते, नए दोस्त!", color: AppColors.mint, tilt: 2),
        .init(text: "مرحبًا يا صديقي الجديد!", color: AppColors.peach, tilt: -3, isRightToLeft: true),
        .init(text: "Hej, ny vän!", color: AppColors.coral, tilt: 3),
        .init(text: "Yeni arkadaşlar!", color: AppColors.lime, tilt: -4),
        .init(text: "Witaj, nowy przyjacielu!", color: AppColors.highlight, tilt: 2)
    ]
}

/// A sunburst behind the pair, turning slowly, with a few sparkles scattered over it.
private struct PetFriendBackdrop: View {
    var isSpinning: Bool

    var body: some View {
        ZStack {
            AppColors.highlight.ignoresSafeArea()
            TimelineView(.animation(paused: !isSpinning)) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60) * 6
                Sunburst(rays: 16)
                    .fill(AppColors.peach.opacity(0.7))
                    .scaleEffect(2.2)
                    .rotationEffect(.degrees(angle))
            }
            .ignoresSafeArea()
            GeometryReader { proxy in
                ForEach(Self.sparkles.indices, id: \.self) { index in
                    let sparkle = Self.sparkles[index]
                    Image(systemName: "sparkle")
                        .font(.system(size: sparkle.size, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: AppColors.ink, radius: 0, x: 1.5, y: 1.5)
                        .position(x: sparkle.x * proxy.size.width, y: sparkle.y * proxy.size.height)
                        .symbolEffect(.pulse, options: .repeating, isActive: isSpinning)
                        .accessibilityHidden(true)
                }
            }
            .ignoresSafeArea()
        }
        .accessibilityHidden(true)
    }

    private static let sparkles: [(x: Double, y: Double, size: CGFloat)] = [
        (0.1, 0.12, 22), (0.88, 0.18, 28), (0.06, 0.55, 18), (0.93, 0.5, 20), (0.15, 0.82, 26), (0.85, 0.85, 18)
    ]
}

/// Wedges fanning out from the centre, every other one filled.
private struct Sunburst: Shape {
    var rays: Int

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = hypot(rect.width, rect.height)
        let step = 2 * Double.pi / Double(rays * 2)
        for ray in 0..<rays {
            let start = Double(ray * 2) * step
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start)))
            path.addLine(to: CGPoint(x: center.x + radius * cos(start + step), y: center.y + radius * sin(start + step)))
            path.closeSubpath()
        }
        return path
    }
}

#Preview("New friend") {
    PetFriendWelcomeView(
        friend: .preview,
        petTitle: "Mochi",
        onDone: {},
        petArt: { Image("FeaturePetWatch").resizable().scaledToFit() },
        friendArt: { Image("FeatureControllableAnimation").resizable().scaledToFit() }
    )
}

#Preview("Long names") {
    PetFriendWelcomeView(
        friend: {
            var friend = PetFriend.preview
            friend.name = "Sir Bartholomew Puddleton"
            friend.greeting = "This is Sir Bartholomew! He taught me to jump over every single puddle on the street today."
            return friend
        }(),
        petTitle: "Mochi the Magnificent",
        onDone: {},
        petArt: { Image("FeaturePetWatch").resizable().scaledToFit() },
        friendArt: { Image("FeatureControllableAnimation").resizable().scaledToFit() }
    )
}

#Preview("Cartoon text") {
    ScrollView {
        VStack(spacing: 12) {
            ForEach(PetFriendPhrase.all.indices, id: \.self) { index in
                let phrase = PetFriendPhrase.all[index]
                PetCartoonText(phrase.text, size: 28, fill: phrase.color)
                    .rotationEffect(.degrees(phrase.tilt))
            }
        }
        .padding()
    }
    .background(AppColors.highlight)
}

extension PetFriend {
    /// A friend met on a rainy afternoon, for previews.
    static let preview = PetFriend(
        id: "4f6b2a5e-8c1d-4f3a-9b7e-2d5c8a1f0e93",
        name: "Puddle",
        story: "We met splashing by the window when the rain started.",
        greeting: "This is Puddle! We splashed together all afternoon.",
        sticker: PreviewFixtures.sticker,
        metAt: .now
    )
}
