import Observation
import SwiftUI
import UIKit
import os

/// The Pet tab's state, owned by `MessagesViewController` and drawn by `MessagesPetView`.
///
/// The controller keeps the parts SwiftUI cannot reach — the conversation an `MSMessage` goes into,
/// the presentation style, `UIAlertController` — and hands them in as closures, so this type stays
/// about the pet: loading it, and running one send at a time.
@MainActor
@Observable
final class MessagesPetModel {
    enum Phase {
        case loading
        /// The account has no pet. Not an error: adopting one is something to do in the app.
        case noPet
        case failed(String)
        case loaded(MessagesPet, UIImage?)
    }

    private(set) var phase: Phase = .loading
    /// True while a share is in flight. Drives the status overlay and disables Send, so a second
    /// tap cannot record a second share or insert a second card.
    private(set) var isSending = false

    /// Puts the finished card into the conversation. Throws when there is none to put it in.
    @ObservationIgnored var insertCard: ((PetCardPayload, UIImage?) async throws -> Void)?
    /// Shows a native alert; the page has no alert of its own so every failure in the drawer reads
    /// the same way.
    @ObservationIgnored var presentFailure: ((String) -> Void)?
    @ObservationIgnored var openApp: (() -> Void)?

    @ObservationIgnored private let service: MessagesPetService?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "app.rxlab.stickerfactory.message", category: "pet")

    init(service: MessagesPetService?) {
        self.service = service
        if service == nil {
            phase = .failed(StickerLibraryError.invalidConfiguration.errorDescription ?? "")
        }
    }

    /// Fetches the pet. Keeps whatever is on screen while it does, so returning to the tab
    /// refreshes the card in place instead of flashing a spinner over it.
    func reload() {
        guard let service else { return }
        loadTask?.cancel()
        if case .loaded = phase {} else { phase = .loading }
        loadTask = Task { [weak self] in
            do {
                let loaded = try await service.load()
                guard !Task.isCancelled, let self else { return }
                if let loaded {
                    self.phase = .loaded(loaded.pet, loaded.pose.flatMap(UIImage.init(data:)))
                } else {
                    self.phase = .noPet
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.logger.error("pet load failed error=\(String(describing: error), privacy: .private)")
                // A card already on screen is still a true picture of a moment ago; replacing it
                // with an error because a refresh failed would take away something that works.
                if case .loaded = self.phase { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    /// Records the share, then inserts the card built from the pet *after* it.
    ///
    /// `accepted == false` (shared again within the server's ten-minute window) still sends the
    /// card: showing someone your pet is the point, and the flag only says the stats did not move
    /// this time. Nothing about that is the user's problem, so it is not reported.
    func sendPet() async {
        guard !isSending, let service, let insertCard else { return }
        isSending = true
        defer { isSending = false }
        do {
            let (share, poseData) = try await service.share()
            guard let pet = share.pet else { throw MessagesPetError.noPet }
            let pose = poseData.flatMap(UIImage.init(data:)) ?? currentPose
            phase = .loaded(pet, pose)
            logger.log("pet shared accepted=\(share.accepted)")
            try await insertCard(PetCardPayload(pet: pet), pose)
            Haptics.success()
        } catch is CancellationError {
            return
        } catch {
            logger.error("pet send failed error=\(String(describing: error), privacy: .private)")
            Haptics.failure()
            if case MessagesPetError.noPet = error { phase = .noPet }
            presentFailure?(Self.message(for: error))
        }
    }

    private var currentPose: UIImage? {
        if case .loaded(_, let pose) = phase { return pose }
        return nil
    }

    private static func message(for error: Error) -> String {
        if error is URLError { return String(localized: "Your pet needs a connection.") }
        return (error as? LocalizedError)?.errorDescription
            ?? String(localized: "Your pet couldn't be loaded. Try again.")
    }
}

/// The Pet tab: the owner's pet as a card, and one button that sends it into the conversation.
struct MessagesPetView: View {
    let model: MessagesPetModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Status of the send, over the page rather than in it, so nothing shifts while it runs.
            .overlay {
                if model.isSending {
                    PetStatusOverlay(text: String(localized: "Sending your pet…"))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.isSending)
            .accessibilityIdentifier("sticker-factory-pet-page")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView(String(localized: "Finding your pet…"))
                .accessibilityIdentifier("sticker-factory-pet-loading")
        case .noPet:
            ContentUnavailableView {
                Label(String(localized: "No Pet Yet"), systemImage: "pawprint")
            } description: {
                Text(String(localized: "Adopt a pet in the Winky app, then send it to friends from here."))
            } actions: {
                Button(String(localized: "Open App")) {
                    Haptics.tap()
                    model.openApp?()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("sticker-factory-pet-open-app")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(String(localized: "Pet Unavailable"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "Try Again")) {
                    Haptics.tap()
                    model.reload()
                }
                .buttonStyle(.bordered)
            }
        case .loaded(let pet, let pose):
            ScrollView {
                VStack(spacing: 16) {
                    PetCardView(payload: PetCardPayload(pet: pet), pose: pose, signals: pet.signals)
                    Button {
                        Haptics.tap(.medium)
                        Task { await model.sendPet() }
                    } label: {
                        Label(String(localized: "Send Pet"), systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isSending)
                    .accessibilityIdentifier("sticker-factory-pet-send")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable { model.reload() }
        }
    }
}

/// The pet as a card: pose, name, who it is, what it is saying, and how it is doing.
///
/// Shared by the owner's page and the recipient's view, so the card someone receives looks like
/// the card its owner chose to send.
struct PetCardView: View {
    let payload: PetCardPayload
    var pose: UIImage?
    var signals: MessagesPet.Signals?

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                poseView
                VStack(alignment: .leading, spacing: 4) {
                    Text(payload.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                    if let classLine = payload.classLine {
                        Text(classLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let caption = payload.caption {
                        SpeechBubble(text: caption)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 8) {
                StatBar(
                    title: String(localized: "Happiness"), systemImage: "heart.fill",
                    value: payload.happiness, maximum: 100, tint: .pink
                )
                StatBar(
                    title: String(localized: "HP"), systemImage: "cross.fill",
                    value: payload.hp, maximum: payload.maxHp, tint: .green
                )
                StatBar(
                    title: String(localized: "Energy"), systemImage: "bolt.fill",
                    value: payload.energy, maximum: 100, tint: .orange
                )
            }
            if let signalsLine {
                Label(signalsLine.text, systemImage: signalsLine.symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var poseView: some View {
        Group {
            if let pose {
                Image(uiImage: pose)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)
    }

    /// "18° · 4,210 steps today", from whichever signals the pet has read.
    private var signalsLine: (text: String, symbol: String)? {
        guard let signals else { return nil }
        var parts: [String] = []
        var symbol = "figure.walk"
        if let weather = signals.weather {
            let temperature = Measurement(value: weather.temperatureC, unit: UnitTemperature.celsius)
            parts.append(temperature.formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0)))))
            symbol = MessagesPet.weatherSymbol(weather.kind, isDay: weather.isDay)
        }
        if let steps = signals.stepsToday {
            parts.append(String(localized: "\(steps) steps today"))
        }
        return parts.isEmpty ? nil : (parts.joined(separator: " · "), symbol)
    }
}

private struct SpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 14))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatBar: View {
    let title: String
    let systemImage: String
    let value: Int
    let maximum: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .foregroundStyle(tint)
                .frame(width: 20)
            ProgressView(value: Double(min(value, maximum)), total: Double(max(maximum, 1)))
                .tint(tint)
            Text("\(value)/\(maximum)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(localized: "\(value) of \(maximum)"))
    }
}

/// The status of an action in progress, laid over whatever started it.
private struct PetStatusOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(text)
                    .font(.body)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("sticker-factory-pet-sending")
    }
}

/// A pet card someone sent, opened from the transcript. Read-only: the stats are a snapshot of
/// someone else's pet, and there is nothing a recipient could change about it.
struct ReceivedPetCardView: View {
    let payload: PetCardPayload
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PetCardView(payload: payload)
                    Text(String(localized: "A snapshot of their pet when it was sent."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationTitle(String(localized: "Pet Card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        Haptics.tap()
                        onDone()
                    }
                }
            }
        }
        .accessibilityIdentifier("sticker-factory-received-pet")
    }
}
