import PhotosUI
import SwiftUI
import TipKit
import UIKit

struct CreateStickerView: View {
    @Bindable var store: StickerStore
    /// Generation always continues in the project's chat; the caller owns that navigation.
    var onCreated: (Sticker) -> Void
    var tutorialMode: TutorialAction?
    @State private var appliedTutorialMode = false
    @State private var flow = CreationWizardState()
    @State private var loadingCatalog = false
    @State private var catalogError: String?
    @Environment(\.locale) private var locale
    @State private var kind: StickerKind = .static
    /// Asks for a character the recipient can pose and change the mood of, without the user having
    /// to work out that they need to say "moods I can switch between" to the agent to get one.
    /// Animated only — a still has no clips to switch between — so `generate` reads it through
    /// `wantsControls` rather than on its own.
    @State private var controllable = false
    @State private var motion = false
    @State private var posePreset: PosePreset = .medium
    @State private var prompt = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var references: [PendingMediaAttachment] = []
    @State private var isGenerating = false
    @State private var localError: String?
    /// The photo waiting for the user to choose a subject in it, when the lift flow is on.
    @State private var pendingLift: PendingLift?
    private let liftTip = LiftSubjectTip()

    /// Only one thumbnail may carry the tip: a popover on each of eight references at once would
    /// stack them on the same spot. The first photo that has not been lifted yet is the one the tip
    /// is about, so a row of finished cut-outs asks nothing.
    private var liftTipTarget: UUID? {
        guard AppConfiguration.subjectLiftEnabled else { return nil }
        return references.first { $0.sequence == nil }?.id
    }

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Step \(stepNumber) of \(flow.steps(kind: kind).count)")
                        .font(.posterLabel(11)).foregroundStyle(AppColors.muted)
                    page
                    if let error = localError ?? store.errorMessage { ErrorBanner(message: error) }
                }
                .padding().frame(maxWidth: 760).frame(maxWidth: .infinity)
                .id(flow.step)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) { navigation }
        .navigationTitle("Create")
        .task { await loadCatalog() }
        .onAppear {
            guard !appliedTutorialMode else { return }
            appliedTutorialMode = true
            if let tutorialMode { _ = handleTutorialAction(tutorialMode) }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing")
                && ProcessInfo.processInfo.arguments.contains("--ui-creation-reference"),
                let url = Bundle.main.url(forResource: "creation-mascot-happy", withExtension: "png"),
                let data = try? Data(contentsOf: url) {
                references = [.init(data: data, filename: "mascot.png", mimeType: "image/png")]
            }
        }
        .onChange(of: kind) { _, _ in flow.animationReviewed = false }
        .onChange(of: pickerItems) { _, items in Task { await loadReferences(items) } }
        .subjectLiftSheet(pending: $pendingLift, references: $references, basename: "capture")
        .telemetryScreen("create_sticker")
    }

    private var stepNumber: Int { (flow.steps(kind: kind).firstIndex(of: flow.step) ?? 0) + 1 }
    private var validIdea: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.count <= 4_000 }
    private var canContinue: Bool {
        switch flow.step {
        case .idea: validIdea
        case .catalog: false
        case .preset(let id): flow.catalog?.groups.first(where: { $0.id == id }).map { flow.valid($0) } ?? false
        case .overview: validIdea && flow.canSubmit && (kind == .static || flow.animationReviewed)
        default: true
        }
    }

    @ViewBuilder private var page: some View {
        switch flow.step {
        case .idea: ideaPage
        case .kind: kindPage
        case .catalog: catalogPage
        case .preset(let id):
            if let group = flow.catalog?.groups.first(where: { $0.id == id }) {
                CreationPresetPage(group: group, flow: $flow, animated: kind == .animated)
            }
            if flow.requiresCatalogRefresh { catalogPage }
        case .references: referencesPage
        case .animation: animationPage
        case .overview: overviewPage
        }
    }

    private var ideaPage: some View {
        VStack(spacing: 18) {
            PosterCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Describe your sticker")
                        .font(.posterDisplay(18, weight: .bold))
                        .foregroundStyle(AppColors.ink)
                    TextField(
                        "A joyful corgi in a raincoat, thick white sticker outline…",
                        text: $prompt,
                        axis: .vertical
                    )
                    .lineLimit(4...8)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .rounded))
                    .padding(14)
                    // The field is a surface of its own inside the card — paper rather
                    // than cream, so it reads as somewhere to write.
                    .posterSurface(
                        cornerRadius: Poster.tileRadius,
                        fill: AppColors.paper,
                        lineWidth: Poster.hairline,
                        offset: .zero
                    )
                    .accessibilityIdentifier("sticker-prompt")
                    Text("\(prompt.count)/4,000")
                        .font(.posterLabel(10))
                        .foregroundStyle(prompt.count > 4_000 ? AppColors.coral : AppColors.faint)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    /// Its own step, after the style and theme pages.
    ///
    /// References used to sit under the prompt on the first screen, which asked the user to pick
    /// artwork to match a look they had not chosen yet. Coming after the preset groups, the
    /// choice is made against a style and theme they have already seen.
    private var referencesPage: some View {
        VStack(spacing: 18) {
            PosterCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reference images")
                                .font(.posterDisplay(18, weight: .bold))
                                .foregroundStyle(AppColors.ink)
                            Text("Optional · up to 8")
                                .posterLabelStyle(9, color: AppColors.faint)
                        }
                        Spacer()
                        PhotosPicker(
                            selection: $pickerItems,
                            maxSelectionCount: 8,
                            // Live Photos are offered only when the lift flow is on: without
                            // it there is nothing that could use the motion, and picking one
                            // would silently behave exactly like picking a still.
                            matching: AppConfiguration.subjectLiftEnabled
                                ? .any(of: [.images, .livePhotos])
                                : .images,
                            preferredItemEncoding: .compatible
                        ) {
                            Label("Add", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.posterSecondaryCompact)
                        .accessibilityIdentifier("add-reference-images")
                    }

                    Label(
                        """
                        Personal photos are uploaded privately to create or edit this sticker. \
                        Sources, chat, and revisions remain until you delete the project.
                        """,
                        systemImage: "hand.raised.fill"
                    )
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(AppColors.muted)

                    if !references.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(references) { reference in
                                    ReferenceThumbnail(
                                        reference: reference,
                                        lift: AppConfiguration.subjectLiftEnabled
                                            ? {
                                                // Invalidated here rather than in the thumbnail
                                                // so opening a lift from any photo retires the
                                                // tip, not only from the one showing it.
                                                liftTip.invalidate(reason: .actionPerformed)
                                                Task { pendingLift = await SubjectLiftPresenter.lift(from: reference) }
                                            } : nil,
                                        tip: reference.id == liftTipTarget ? liftTip : nil,
                                        remove: {
                                            Haptics.selection()
                                            references.removeAll { $0.id == reference.id }
                                        }
                                    )
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.never)
                    }
                }
            }
        }
    }

    private var kindPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What are we making?").font(.posterDisplay(26, weight: .heavy))
            CreationDemoPreview(animated: kind == .animated)
                .frame(height: 280).frame(maxWidth: .infinity)
            Label(
                "Just an example of this sticker type — your own sticker won’t look like this.",
                systemImage: "info.circle"
            )
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(AppColors.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            Picker("Sticker type", selection: $kind) {
                ForEach(StickerKind.allCases) { value in Label(value.label, systemImage: value.symbol).tag(value) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("sticker-kind-picker")
            Text(
                kind == .static
                    ? String(localized: "A single expressive sticker.")
                    : String(localized: "Bring your sticker to life with looping motion.")
            )
            .foregroundStyle(AppColors.muted)
            TutorialButton(
                chapter: kind == .static ? .static : .animated,
                title: TutorialCopy.text("How to make this sticker"), onAction: handleTutorialAction)
            if kind == .animated {
                Text("You’ll review a static visual reference before we build the animation.").font(.footnote).foregroundStyle(
                    AppColors.muted)
            }
        }
    }

    private var catalogPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if loadingCatalog { ProgressView("Loading sticker options…") }
            if let catalogError { ErrorBanner(message: catalogError) }
            if !loadingCatalog {
                Button {
                    Task { await loadCatalog(force: flow.requiresCatalogRefresh) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }.buttonStyle(.posterSecondaryCompact).accessibilityIdentifier("creation-catalog-retry")
            }
        }
    }

    private var animationPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Make it move").font(.posterDisplay(26, weight: .heavy))
            CreationSelectedPreview(
                options: (flow.catalog?.visibleGroups ?? []).flatMap { group in
                    group.options.filter { flow.selections[group.id, default: []].contains($0.id) }
                }, controllable: controllable, preset: posePreset)
            PosterCard {
                VStack(alignment: .leading, spacing: 16) {
                    PosterToggleRow(
                        title: String(localized: "Switchable moods and poses"),
                        isOn: $controllable, identifier: "sticker-controllable-toggle"
                    )
                    .onChange(of: controllable) { _, _ in ControllableCreationTip().invalidate(reason: .actionPerformed) }
                    if controllable {
                        Picker("Pose variety", selection: $posePreset) {
                            ForEach(PosePreset.allCases, id: \.self) { Text($0.creationLabel).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("sticker-pose-preset-picker")
                        Text("\(posePreset.poseCount) selectable poses per character")
                            .font(.subheadline.weight(.semibold)).accessibilityIdentifier("creation-pose-count")
                        Text("Higher presets add more selectable poses per character and cost more to generate.")
                            .font(.footnote).foregroundStyle(AppColors.muted)
                    } else {
                        ControllableTutorialHelp(kind: .creation)
                    }
                    TutorialButton(
                        chapter: .controllable, title: TutorialCopy.text("Learn about moods and poses"),
                        onAction: handleTutorialAction)
                }
            }
            // Off by default. A character that drifts around underneath its own pose and mood
            // controls fights them, so travel is something to ask for rather than something every
            // animated sticker arrives with.
            PosterCard {
                VStack(alignment: .leading, spacing: 10) {
                    PosterToggleRow(
                        title: String(localized: "Move around the canvas"),
                        isOn: $motion, identifier: "sticker-motion-toggle"
                    )
                    Text("Off means the sticker stays in one place — it can still breathe, blink and react.")
                        .font(.footnote).foregroundStyle(AppColors.muted)
                }
            }
        }
    }

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to create?").font(.posterDisplay(26, weight: .heavy))
            Text("Review your choices. Tap any section to change it.").foregroundStyle(AppColors.muted)
            overviewRow(String(localized: "Your idea"), value: prompt, step: .idea)
            overviewRow(String(localized: "Sticker type"), value: kind.label, step: .kind)
            ForEach(flow.catalog?.visibleGroups ?? []) { group in
                let names = group.options.filter { flow.selections[group.id, default: []].contains($0.id) }.map {
                    $0.title.localized(locale)
                }
                overviewRow(
                    group.title.localized(locale),
                    value: names.isEmpty ? String(localized: "None") : names.joined(separator: ", "), step: .preset(group.id))
            }
            overviewRow(
                String(localized: "Reference images"),
                value: references.isEmpty
                    ? String(localized: "None")
                    : String(localized: "\(references.count) selected"),
                step: .references
            ) {
                if !references.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(references) { reference in
                                if let image = UIImage(data: reference.data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                                        .posterSurface(
                                            cornerRadius: 12,
                                            fill: AppColors.card,
                                            lineWidth: Poster.hairline,
                                            offset: .zero
                                        )
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onTapGesture { flow.edit(.references); Haptics.selection() }
                    .accessibilityLabel(String(localized: "Reference images"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("creation-overview-references")
                }

            }
            if kind == .animated {
                overviewRow(
                    String(localized: "Animation"),
                    value: (controllable
                        ? String(localized: "Switchable moods and poses") + " · " + posePreset.creationLabel
                        : String(localized: "Looping animation"))
                        + " · " + (motion ? String(localized: "Moves around") : String(localized: "Stays in place")),
                    step: .animation)
            }
            if flow.requiresCatalogRefresh { catalogPage }
        }
    }

    private func overviewRow(_ title: String, value: String, step: CreationWizardState.Step) -> some View {
        overviewRow(title, value: value, step: step) { EmptyView() }
    }

    /// `extra` rides inside the row's card, under the value — so attachments belonging to a choice
    /// read as part of it rather than floating between rows. It stays *outside* the button: a
    /// button's label collapses into one accessibility element, which would swallow whatever
    /// identifiers and traits the attachment carries.
    private func overviewRow<Extra: View>(
        _ title: String, value: String, step: CreationWizardState.Step, @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                flow.edit(step); Haptics.selection()
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.posterLabel(11)).foregroundStyle(AppColors.muted)
                        Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(AppColors.ink)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(AppColors.ink)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("creation-overview-\(overviewID(step))")
            extra()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .posterSurface(cornerRadius: Poster.tileRadius, fill: AppColors.paper, offset: .zero)
    }
    private func overviewID(_ step: CreationWizardState.Step) -> String {
        switch step {
        case .idea: "idea"
        case .kind: "kind"
        case .animation: "animation"
        case .references: "references"
        case .preset(let id): id
        default: "settings"
        }
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            if flow.step != .idea || flow.editingOverview {
                Button {
                    flow.back(kind: kind); dismissKeyboard()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.posterSecondaryCompact).disabled(isGenerating)
                .accessibilityIdentifier("creation-back")
            }
            Button {
                dismissKeyboard()
                if flow.step == .overview { Task { await generate() } } else { flow.advance(kind: kind); Haptics.selection() }
            } label: {
                HStack {
                    if isGenerating { PosterSpinner(color: AppColors.ink, size: 16) }
                    Text(
                        flow.step == .overview
                            ? (isGenerating
                                ? String(localized: "Starting securely…") : String(localized: "Generate one candidate"))
                            : (flow.editingOverview ? String(localized: "Done") : String(localized: "Next")))
                    Image(systemName: flow.step == .overview ? "wand.and.stars" : "arrow.right")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.poster).disabled(isGenerating || !canContinue)
            .accessibilityIdentifier(flow.step == .overview ? "generate-sticker-button" : "creation-next")
        }
        .padding().frame(maxWidth: 760).frame(maxWidth: .infinity).background(AppColors.paper)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func loadCatalog(force: Bool = false) async {
        guard !loadingCatalog else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            let catalog = try await store.api.creationPresets(refresh: force)
            flow.apply(catalog, review: force, kind: kind)
            catalogError = nil
        } catch {
            catalogError = String(localized: "Couldn’t load sticker options. Your idea and photos are saved here. Try again.")
        }
    }

    private func handleTutorialAction(_ action: TutorialAction) -> Bool {
        guard case .create(let animated, let hasControls) = action else { return false }
        kind = animated ? .animated : .static
        controllable = hasControls
        if appliedTutorialMode { flow.step = hasControls ? .animation : .kind }
        return true
    }

    /// Picking a photo attaches it. Nothing else.
    ///
    /// Lifting a subject used to happen here, which meant choosing one photo opened a second sheet
    /// before the user had asked for anything — and if no subject was found, the photo they picked
    /// was unusable. Attaching first makes the lift an optional refinement of something that
    /// already works, reached by tapping the thumbnail.
    private func loadReferences(_ items: [PhotosPickerItem]) async {
        // Emptied immediately, and never read as the source of truth again. A picker's `selection`
        // binding remembers everything ever chosen, so leaving items in it means a photo the user
        // later removed is still "selected" — and the next pick re-delivers it and it reappears,
        // which is exactly what made deletions look like they had not taken. Clearing it re-enters
        // this method with an empty array, which the guard drops.
        guard !items.isEmpty else { return }
        pickerItems = []

        var loaded: [PendingMediaAttachment] = []
        for (index, item) in items.prefix(max(0, 8 - references.count)).enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                var attachment = try MediaNormalizer.reference(
                    data: data,
                    basename: "reference-\(references.count + index + 1)"
                )
                attachment.source = item
                loaded.append(attachment)
            } catch {
                localError = error.localizedDescription
            }
        }
        // Appended rather than assigned, now that the picker no longer holds the whole set.
        references.append(contentsOf: loaded)
        if !loaded.isEmpty { Haptics.selection() }
    }

    /// The switch only means anything on an animated sticker, and it stays on screen across a
    /// change of type — so a user who turns it on, switches to Static and generates sends a request
    /// the server would refuse rather than one it silently ignores.
    private var wantsControls: Bool { kind == .animated && controllable }

    /// Same reasoning as `wantsControls`: the server refuses `motion` on a static sticker, and the
    /// switch stays on screen across a change of type.
    private var wantsMotion: Bool { kind == .animated && motion }

    private func generate() async {
        guard canContinue, let presets = flow.submission else { return }
        isGenerating = true
        defer { isGenerating = false }
        do {
            let sticker = try await store.create(
                kind: kind,
                prompt: prompt,
                controllable: wantsControls,
                posePreset: wantsControls ? posePreset : nil,
                motion: wantsMotion,
                references: references,
                presets: presets
            )
            Haptics.success()
            onCreated(sticker)
            localError = nil
        } catch {
            if let envelope = error as? APIErrorEnvelope, envelope.error.code == "CREATION_PRESETS_CHANGED" {
                flow.requiresCatalogRefresh = true
                localError = String(localized: "Sticker options changed. Review your choices before generating.")
                await loadCatalog(force: true)
            } else {
                localError = error.localizedDescription
            }
            Haptics.failure()
        }
    }
}

private struct ReferenceThumbnail: View {
    let reference: PendingMediaAttachment
    /// Tapping the photo reopens the lift flow on it. Nil hides the affordance entirely.
    var lift: (() -> Void)?
    /// Set on the one thumbnail that should explain the tap. Nil on every other.
    var tip: LiftSubjectTip?
    let remove: () -> Void

    private var isCapture: Bool { reference.sequence != nil }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                lift?()
            } label: {
                ZStack(alignment: .bottomLeading) {
                    if let image = UIImage(data: reference.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 84, height: 84)
                            .clipShape(.rect(cornerRadius: 16, style: .continuous))
                            .posterSurface(
                                cornerRadius: 16,
                                fill: AppColors.paper,
                                lineWidth: Poster.hairline,
                                offset: CGSize(width: 2, height: 2)
                            )
                    }
                    // Two jobs. A capture is already cut out, so its thumbnail is mostly transparent
                    // and reads as a failed load without a badge saying otherwise. And a plain
                    // reference gives no sign that tapping it does anything at all — which is
                    // precisely why the lift went unnoticed — so it advertises the action instead.
                    if lift != nil {
                        PosterSymbol(isCapture ? "livephoto" : "person.and.background.dotted")
                            .font(.caption2.bold())
                            .foregroundStyle(AppColors.ink)
                            .padding(4)
                            .background(AppColors.lime, in: Circle())
                            .overlay(Circle().strokeBorder(AppColors.ink, lineWidth: 1))
                            .padding(5)
                    }
                }
            }
            .buttonStyle(.posterPlain)
            .disabled(lift == nil)
            .popoverTip(tip, arrowEdge: .top)
            .accessibilityLabel(
                isCapture
                    ? "Lifted subject. Tap to choose a different one."
                    : "Reference photo. Tap to lift a subject out of it."
            )

            // A real SF Symbol, not PosterSymbol: that one substitutes a plain "×" text glyph with
            // no circle behind it, which disappeared against the card.
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(AppColors.card, AppColors.coral)
                    .shadow(color: AppColors.ink.opacity(0.35), radius: 1.5, y: 1)
            }
            .accessibilityLabel("Remove reference")
            .offset(x: 5, y: -5)
        }
        .padding(5)
    }
}
