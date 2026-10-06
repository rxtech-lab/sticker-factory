import SwiftUI

/// Hovers above the mic button while the owner talks to the pet: a soundwave of what the
/// microphone hears, and the words as the on-device speech model writes them down. Tapping the
/// mic again stops listening and sends; the pet answers on the tab, in its dialogue box.
struct PetTalkPopover: View {
    let listener: PetSpeechListener

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(AppColors.muted)
                .contentTransition(.opacity)

            Group {
                if listener.state == .listening {
                    PetSoundwave(levels: listener.levels)
                } else {
                    ProgressView()
                        .tint(AppColors.ink)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44)

            transcript
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .truncationMode(.head)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The paper over its offset ink shadow, as the poster cards draw it.
            ZStack {
                PetTalkBubbleShape()
                    .fill(AppColors.ink)
                    .offset(x: 3, y: 4)
                PetTalkBubbleShape().fill(AppColors.paper)
            }
        }
        .overlay { PetTalkBubbleShape().stroke(AppColors.ink, lineWidth: 3) }
        .padding(.bottom, PetTalkBubbleShape.arrowHeight)
        .animation(.snappy(duration: 0.2), value: listener.state)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pet-talk-popover")
    }

    private var title: LocalizedStringKey {
        switch listener.state {
        case .preparing: "GETTING READY…"
        case .listening: "LISTENING · TAP SEND WHEN DONE"
        case .finishing, .idle: "SENDING…"
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if listener.transcript.isEmpty {
            Text(listener.state == .listening ? "Say something to your pet." : "Your words never leave your iPhone.")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.faint)
                .accessibilityIdentifier("pet-talk-placeholder")
        } else {
            // What the model is still unsure of trails off in a lighter ink.
            (Text(listener.settledText).foregroundStyle(AppColors.ink)
                + Text(listener.tentativeText).foregroundStyle(AppColors.muted))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .contentTransition(.opacity)
                .accessibilityIdentifier("pet-talk-transcript")
        }
    }
}

/// Bars that rise and fall with the microphone, newest on the right, mirrored about the middle.
private struct PetSoundwave: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let count = CGFloat(max(levels.count, 1))
            let barWidth = max(2, (proxy.size.width - spacing * (count - 1)) / count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == levels.count - 1 ? AppColors.coral : AppColors.ink)
                        .frame(width: barWidth, height: height(for: levels[index], in: proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.12), value: levels)
        .accessibilityHidden(true)
    }

    /// Never quite flat, so silence still reads as a line of dots waiting for sound.
    private func height(for level: Float, in maxHeight: CGFloat) -> CGFloat {
        max(4, CGFloat(level) * maxHeight)
    }
}

/// A rounded card with a small arrow under its middle, pointing down at the mic.
private nonisolated struct PetTalkBubbleShape: Shape {
    static let arrowHeight: CGFloat = 10

    /// One outline, so the stroke runs round the arrow instead of across its base.
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 14
        let tipX = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: tipX + 10, y: rect.maxY))
        path.addLine(to: CGPoint(x: tipX, y: rect.maxY + Self.arrowHeight))
        path.addLine(to: CGPoint(x: tipX - 10, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// The mic beside the pet's actions. The first tap hangs the talk popover above it and starts
/// listening; the next stops and sends what was heard.
struct PetTalkButton: View {
    let model: PetModel
    /// The popover is up: from the first tap until the words are sent or dropped.
    @Binding var isTalking: Bool
    /// Stretches across a narrow column, as in landscape.
    let fillsWidth: Bool

    @State private var listener = PetSpeechListener()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        // While talking, the other actions step aside: Cancel, and the mic across the rest.
        HStack(spacing: 12) {
            if isTalking {
                Button("Cancel") {
                    Haptics.tap(.light)
                    stopTalking()
                }
                .buttonStyle(.posterSecondary)
                .disabled(listener.state == .finishing)
                .accessibilityIdentifier("pet-talk-cancel")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            mic
        }
        .animation(.snappy(duration: 0.25), value: isTalking)
        // The microphone must not stay on behind another tab, or with the app in the background.
        .onDisappear { stopTalking() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stopTalking() }
        }
        .alert(
            "Can't Listen",
            isPresented: Binding(
                get: { listener.problem != nil },
                set: { if !$0 { listener.problem = nil } }
            ),
            presenting: listener.problem
        ) { problem in
            if problem == .microphoneDenied {
                Button("Open Settings") {
                    Haptics.tap(.light)
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) { Haptics.tap(.light) }
            } else {
                Button("OK", role: .cancel) { Haptics.tap(.light) }
            }
        } message: { problem in
            Text(problem.message)
        }
    }

    /// Talk to the pet; while talking, Send, stretched across the row.
    private var mic: some View {
        Button(action: tapMic) {
            Group {
                if isTalking {
                    Label("Send", systemImage: "paperplane.fill")
                } else {
                    Image(systemName: "mic.fill")
                }
            }
            .symbolEffect(.pulse, options: .repeating, isActive: listener.state == .listening)
            .frame(maxWidth: fillsWidth || isTalking ? .infinity : nil)
        }
        .buttonStyle(.posterSecondary)
        .disabled(!isTalking && (model.isAnswering || model.activity != nil))
        .disabled(listener.state == .finishing)
        .accessibilityLabel(isTalking ? Text("Send to Your Pet") : Text("Talk to Your Pet"))
        .accessibilityIdentifier("pet-talk-button")
        // A flat strip along the button's top edge: the bubble stands on it, so it always hangs
        // above the mic and never over it.
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottom) {
                    if isTalking {
                        PetTalkPopover(listener: listener)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                            .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                    }
                }
        }
    }

    /// The mic: the first tap opens the popover and starts listening, the next stops and sends
    /// what was heard. Tapping while the microphone is still getting ready gives up on it.
    private func tapMic() {
        switch listener.state {
        case .idle:
            Haptics.tap(.light)
            isTalking = true
            Task {
                await listener.start()
                // It could not start, or was given up on while getting ready.
                if listener.state == .idle { isTalking = false }
            }
        case .preparing:
            stopTalking()
        case .listening:
            Haptics.tap(.medium)
            Task {
                await listener.stop()
                let words = listener.transcript
                isTalking = false
                await listener.cancel()
                // Nothing heard, or the pet is busy: the popover closes with a buzz instead.
                if !model.talk(words) { Haptics.failure() }
            }
        case .finishing:
            break
        }
    }

    /// Closes the popover, turning the microphone off and dropping what was heard.
    private func stopTalking() {
        guard isTalking else { return }
        isTalking = false
        Task { await listener.cancel() }
    }
}
