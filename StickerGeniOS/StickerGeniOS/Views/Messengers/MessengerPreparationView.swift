import SwiftUI

/// Encodes the WhatsApp and Telegram copies of a pack's members, and shows each one landing.
///
/// Pushed by the composer and the editor straight after a save that left a member without a
/// rendition. The run *is* the screen: it starts on arrival, every member is listed with what
/// became of it, and the only ways out are Cancel — which stops the run where it stands — and
/// Done once it has finished. There is no back button and no swipe-down, so an encode can never be
/// left running behind a screen that has forgotten about it, and nobody has to guess whether the
/// pack is sendable yet: when this screen lets them go, it is.
struct MessengerPreparationView: View {
    let preparer: MessengerRenditionPreparer
    let api: StickerAPIClientProtocol
    /// The members to prepare, in the order the run takes them.
    let stickers: [Sticker]
    /// Called once, on the way out — after Cancel or Done.
    var onFinished: () -> Void

    @State private var isFinished = false

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summary
                    if let progress = preparer.progress { progressCard(progress) }
                    if isFinished { resultCard }
                    membersCard
                }
                .padding(20)
            }
        }
        .navigationTitle("Preparing stickers")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled()
        .toolbar {
            if isFinished {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.tap(.light)
                        onFinished()
                    }
                    .accessibilityIdentifier("messenger-preparation-done")
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.tap(.light)
                        preparer.cancel()
                        onFinished()
                    }
                    .accessibilityIdentifier("messenger-preparation-cancel")
                }
            }
        }
        .task {
            await preparer.prepare(stickers).value
            isFinished = true
        }
        // Belt and braces: the toolbar is the only way off this screen, but if the sheet around it
        // is ever torn down some other way the encode must not carry on unwatched.
        .onDisappear { if !isFinished { preparer.cancel() } }
        .accessibilityIdentifier("messenger-preparation-sheet")
    }

    // MARK: - Header

    private var summary: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(spacing: -12) {
                ForEach(MessengerDestination.allCases) { destination in
                    Image(destination.logoAsset)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(stickers.count == 1
                    ? String(localized: "Preparing 1 sticker for WhatsApp and Telegram")
                    : String(localized: "Preparing \(stickers.count) stickers for WhatsApp and Telegram"))
                    .font(.posterDisplay(20, weight: .heavy))
                    .foregroundStyle(AppColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Each sticker is encoded once per messenger and saved with the pack, so nobody who adds it has to do this again. Keep the app open; stop now and the rest is prepared the next time you save this pack.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("messenger-preparation-summary")
    }

    private func progressCard(_ progress: MessengerPreparationProgress) -> some View {
        PosterCard(padding: 14, shadow: Poster.smallShadow) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().tint(AppColors.coral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progress.destination.map {
                            String(localized: "Preparing \(progress.completed + 1) of \(progress.total) for \($0.label)")
                        } ?? String(localized: "Preparing \(progress.completed + 1) of \(progress.total)"))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppColors.ink)
                            .lineLimit(1)
                        Text([progress.stickerTitle, progress.detail].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(AppColors.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                ProgressView(value: progress.fraction)
                    .tint(AppColors.coral)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("messenger-preparation-progress")
    }

    /// The members that finished short of at least one messenger.
    private var incomplete: [Sticker] {
        stickers.filter { !(preparer.outcomes[$0.id]?.failures.isEmpty ?? true) }
    }

    /// The members the run never reached — it was stopped, or they were dropped mid-way.
    private var untouched: [Sticker] {
        stickers.filter { preparer.outcomes[$0.id] == nil }
    }

    @ViewBuilder
    private var resultCard: some View {
        let failed = incomplete.count
        let skipped = untouched.count
        if failed == 0, skipped == 0 {
            NoticeBanner(message: String(localized: "Every sticker is ready for WhatsApp and Telegram."))
                .accessibilityIdentifier("messenger-preparation-complete")
        } else {
            ErrorBanner(message: failed > 0
                ? (failed == 1
                    ? String(localized: "1 sticker could not be prepared for every messenger. The reason is beside it; the rest can be sent.")
                    : String(localized: "\(failed) stickers could not be prepared for every messenger. The reasons are beside them; the rest can be sent."))
                : String(localized: "Not every sticker was prepared. Save this pack again to finish the rest."))
                .accessibilityIdentifier("messenger-preparation-incomplete")
        }
    }

    // MARK: - Members

    private var membersCard: some View {
        PosterCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(stickers) { sticker in
                    row(sticker)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messenger-preparation-members")
    }

    private func row(_ sticker: Sticker) -> some View {
        let status = status(for: sticker)
        return HStack(spacing: 12) {
            StickerThumbnail(sticker: sticker, api: api)
                .frame(width: 44, height: 44)
                .padding(4)
                .posterSurface(cornerRadius: Poster.chipRadius, fill: AppColors.paper, lineWidth: Poster.hairline, offset: Poster.noShadow)
            VStack(alignment: .leading, spacing: 3) {
                Text(sticker.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                    .lineLimit(1)
                Text(status.text)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(status.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("messenger-preparation-sticker-\(sticker.id)")
    }

    /// What the row under the title says: where the run is with this sticker, or how it ended.
    ///
    /// The snapshot the screen was handed says which messengers the sticker already had; the
    /// outcome says which it gained and which it missed. Together they answer the only question
    /// the row exists for — can this sticker be sent, and where.
    private func status(for sticker: Sticker) -> (text: String, color: Color) {
        if let progress = preparer.progress, progress.stickerID == sticker.id {
            if let destination = progress.destination {
                let heading = String(localized: "Preparing for \(destination.label)…")
                return (progress.detail.map { "\(heading) \($0)" } ?? heading, AppColors.muted)
            }
            return (String(localized: "Downloading artwork…"), AppColors.muted)
        }
        guard let outcome = preparer.outcomes[sticker.id] else {
            return isFinished
                ? (String(localized: "Not prepared. Save this pack again to try it."), AppColors.faint)
                : (String(localized: "Waiting…"), AppColors.faint)
        }
        let ready = MessengerDestination.allCases.filter { sticker.supports($0) || outcome.prepared.contains($0) }
        var lines: [String] = []
        if ready.count == MessengerDestination.allCases.count {
            lines.append(String(localized: "Ready for WhatsApp and Telegram"))
        } else if let only = ready.first {
            lines.append(String(localized: "Ready for \(only.label)"))
        }
        for destination in MessengerDestination.allCases {
            if let failure = outcome.failures[destination] {
                lines.append("\(destination.label): \(failure)")
            }
        }
        return (lines.joined(separator: "\n"), outcome.failures.isEmpty ? AppColors.muted : AppColors.coral)
    }
}

#Preview {
    NavigationStack {
        MessengerPreparationView(
            preparer: MessengerRenditionPreparer(api: MockStickerAPIClient()),
            api: MockStickerAPIClient(),
            stickers: [PreviewFixtures.borrowedSticker, PreviewFixtures.sticker],
            onFinished: {}
        )
    }
}
