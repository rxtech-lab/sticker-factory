import SwiftUI

/// Talks to the pet out loud. What the owner says is written down by the on-device speech model as
/// they speak; sending it closes the sheet, and the pet answers on the tab, in its dialogue box.
struct PetTalkSheet: View {
    @Bindable var model: PetModel

    @State private var listener = PetSpeechListener()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var isBusy: Bool { listener.state == .preparing || listener.state == .finishing }
    private var canSend: Bool { !listener.transcript.isEmpty && !isBusy && !model.isAnswering }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Say something to your pet. Your words are written down on your iPhone and never leave it.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(AppColors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                PosterCard(padding: 14) {
                    ScrollView {
                        transcript
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(minHeight: 72, maxHeight: 140)
                }

                Spacer(minLength: 0)

                PetMicButton(state: listener.state) {
                    switch listener.state {
                    case .idle:
                        Haptics.tap(.light)
                        Task { await listener.start() }
                    case .listening:
                        Haptics.tap(.light)
                        Task { await listener.stop() }
                    case .preparing, .finishing:
                        break
                    }
                }
            }
            .padding()
            .background { PosterPaper() }
            // Under the toolbar rather than over it, so Cancel still works while the speech model
            // downloads the first time.
            .overlay {
                if isBusy { PetTalkOverlay(state: listener.state) }
            }
            .navigationTitle("Talk to Your Pet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.tap(.light)
                        dismiss()
                    }
                    .accessibilityIdentifier("pet-talk-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(!canSend)
                        .accessibilityIdentifier("pet-talk-send")
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: listener.state)
        // Listening starts as soon as the sheet is up: opening it is asking to talk.
        .task { await listener.start() }
        .onDisappear { Task { await listener.cancel() } }
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
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { problem in
            Text(problem.message)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if listener.transcript.isEmpty {
            Text(listener.state == .listening ? "Listening…" : "Tap the microphone and start talking.")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.faint)
                .accessibilityIdentifier("pet-talk-placeholder")
        } else {
            // What the model is still unsure of trails off in a lighter ink.
            (Text(listener.settledText).foregroundStyle(AppColors.ink)
                + Text(listener.tentativeText).foregroundStyle(AppColors.muted))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .contentTransition(.opacity)
                .accessibilityIdentifier("pet-talk-transcript")
        }
    }

    /// Stops listening if it still is, then hands what was said to the pet and closes.
    private func send() {
        Haptics.tap(.medium)
        Task {
            if listener.state == .listening { await listener.stop() }
            if model.talk(listener.transcript) {
                dismiss()
            } else {
                Haptics.failure()
            }
        }
    }
}

/// The big round microphone: lime to start, coral while listening, pulsing as it hears.
private struct PetMicButton: View {
    let state: PetSpeechListener.State
    let action: () -> Void

    private var isListening: Bool { state == .listening }

    var body: some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                    .symbolEffect(.pulse, options: .repeating, isActive: isListening)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 88, height: 88)
                    .background(isListening ? AppColors.coral : AppColors.lime, in: .circle)
                    .overlay { Circle().strokeBorder(AppColors.ink, lineWidth: 3) }
                    .background { Circle().fill(AppColors.ink).offset(x: 3, y: 4) }
            }
            .buttonStyle(.plain)
            .disabled(state == .preparing || state == .finishing)
            .accessibilityLabel(isListening ? Text("Stop Listening") : Text("Start Listening"))
            .accessibilityIdentifier("pet-talk-mic")

            Text(isListening ? "Listening… tap to stop" : "Tap to talk")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(AppColors.muted)
        }
        .animation(.snappy(duration: 0.25), value: isListening)
    }
}

/// Covers the sheet while the microphone is being readied or the last words are written down.
private struct PetTalkOverlay: View {
    let state: PetSpeechListener.State

    var body: some View {
        ZStack {
            // Stays inside the safe area, clear of the toolbar.
            Color.black.opacity(0.35)
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                Group {
                    if state == .finishing {
                        Text("Catching your last words…")
                    } else {
                        Text("Getting ready to listen…")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        }
        .transition(.opacity)
        .accessibilityIdentifier("pet-talk-overlay")
    }
}
