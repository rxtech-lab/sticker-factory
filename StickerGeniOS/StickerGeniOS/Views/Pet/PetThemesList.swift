import SwiftUI

/// The Places tab of the time-together sheet: the places the pet's agent discovered from its owner's
/// world, where the pet is now, and the one-time places that have passed. Tapping a place hands it
/// to `open`, which shows it in its own sheet, where the pet is taken there or brought home.
struct PetThemesList: View {
    @Bindable var model: PetModel
    /// Opens a place, with its thumbnail if it has loaded.
    let open: (PetTheme, UIImage?) -> Void
    @State private var thumbnails: [String: UIImage] = [:]

    /// How many times the tab looks again for places still being discovered before it waits.
    private static let discoveringChecks = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("""
                Places your pet found from where you are and what is going on. \
                It goes on its own when it feels like it, or you can take it.
                """)
                .foregroundStyle(AppColors.muted)
            if let themes = model.themes {
                status(themes)
                let open = themes.themes.filter { !$0.expired }
                let passed = themes.themes.filter(\.expired)
                if open.isEmpty {
                    empty(themes)
                } else {
                    section(String(localized: "Places"), themes: open, activeID: themes.activeThemeId)
                }
                if !passed.isEmpty {
                    section(String(localized: "Passed"), themes: passed, activeID: nil)
                }
            } else {
                ProgressView("Finding your pet's places…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .padding()
        .task {
            for _ in 0..<Self.discoveringChecks {
                await model.refreshThemes()
                await loadThumbnails()
                guard !Task.isCancelled, model.themes?.discovering == true else { return }
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
            }
        }
    }

    @ViewBuilder
    private func status(_ themes: PetThemes) -> some View {
        if themes.discovering {
            Label("Your pet is finding and drawing new places…", systemImage: "sparkle.magnifyingglass")
                .font(.footnote)
                .foregroundStyle(AppColors.muted)
                .accessibilityIdentifier("pet-themes-discovering")
        }
        if themes.traveling {
            Label("You're far from home, so your pet is looking for places on your trip.", systemImage: "airplane")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppColors.ink)
                .accessibilityIdentifier("pet-themes-traveling")
        } else if !themes.hasLocation {
            Label("Turn on Location Tracking in Weather & Steps to find places near you and on trips.", systemImage: "location.slash")
                .font(.footnote)
                .foregroundStyle(AppColors.muted)
                .accessibilityIdentifier("pet-themes-no-location")
        }
    }

    @ViewBuilder
    private func empty(_ themes: PetThemes) -> some View {
        if !themes.discovering {
            Text("Your pet hasn't found any places yet. New ones turn up every day.")
                .font(.footnote)
                .foregroundStyle(AppColors.muted)
        }
    }

    private func section(_ title: String, themes: [PetTheme], activeID: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 16, weight: .heavy, design: .monospaced))
            ForEach(themes) { theme in themeButton(theme, isActive: theme.id == activeID) }
        }
    }

    private func themeButton(_ theme: PetTheme, isActive: Bool) -> some View {
        Button {
            Haptics.tap(.light)
            open(theme, thumbnails[theme.id])
        } label: {
            HStack(spacing: 14) {
                PetRoomThumbnail(image: thumbnails[theme.id])
                    .frame(width: 64, height: 96)
                    .saturation(theme.expired ? 0 : 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(theme.title).font(.headline)
                    PetThemeCategoryLabel(theme: theme)
                    Text(theme.description)
                        .font(.caption)
                        .foregroundStyle(AppColors.muted)
                        .lineLimit(2)
                    PetEffectsRow(effects: theme.visitEffects)
                    PetThemeStatusLine(theme: theme, isActive: isActive)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.posterCard)
        .disabled(model.activity != nil)
        .accessibilityIdentifier("pet-theme-\(theme.id)")
    }

    private func loadThumbnails() async {
        guard let themes = model.themes else { return }
        for theme in themes.themes where thumbnails[theme.id] == nil {
            guard !Task.isCancelled else { return }
            if let image = try? await PetArtworkImageCache.shared.loadTheme(themeID: theme.id, artKey: theme.artKey, api: model.api) {
                thumbnails[theme.id] = image
            }
        }
    }
}

/// One place up close: its drawing, what being there does, its rules, and taking the pet there or
/// bringing it home.
struct PetThemeDetailSheet: View {
    @Bindable var model: PetModel
    let themeID: String
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    init(model: PetModel, themeID: String, preview: UIImage?) {
        self.model = model
        self.themeID = themeID
        _image = State(initialValue: preview)
    }

    /// Read from the model, so a trip made here shows at once.
    private var theme: PetTheme? { model.themes?.themes.first { $0.id == themeID } }

    private var isActive: Bool { model.themes?.activeThemeId == themeID }

    var body: some View {
        NavigationStack {
            Group {
                if let theme {
                    ScrollView { details(theme) }
                        .safeAreaInset(edge: .bottom) {
                            primaryButton(theme)
                                .padding(.horizontal)
                                .padding(.bottom, 12)
                        }
                } else {
                    ContentUnavailableView(
                        "Place Unavailable", systemImage: "mappin.slash",
                        description: Text("Your pet no longer knows this place.")
                    )
                }
            }
            .navigationTitle(theme?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Haptics.tap(.light); dismiss() }
                        .disabled(model.activity != nil)
                }
            }
            .safeAreaInset(edge: .top) {
                if let errorMessage = model.errorMessage {
                    ErrorBanner(message: errorMessage).padding(.horizontal)
                }
            }
        }
        .overlay {
            if let activity = model.activity { PetActivityOverlay(activity: activity) }
        }
        .animation(.snappy(duration: 0.2), value: model.activity)
        .interactiveDismissDisabled(model.activity != nil)
        .task {
            guard image == nil, let theme else { return }
            image = try? await PetArtworkImageCache.shared.loadTheme(themeID: theme.id, artKey: theme.artKey, api: model.api)
        }
    }

    private func details(_ theme: PetTheme) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PetRoomThumbnail(image: image)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
                .saturation(theme.expired ? 0 : 1)
            PetThemeCategoryLabel(theme: theme)
            Text(theme.description)
            VStack(alignment: .leading, spacing: 8) {
                Text("Each visit while your pet is here")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                PetEffectsRow(effects: theme.visitEffects)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Rules")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                rules(theme)
            }
            PetThemeStatusLine(theme: theme, isActive: isActive)
        }
        .padding()
    }

    @ViewBuilder
    private func rules(_ theme: PetTheme) -> some View {
        if theme.limited {
            if theme.expired {
                ruleRow("clock.badge.xmark", "A one-time place that has passed. Your pet can't go back.")
            } else if let expiresAt = theme.expiresAt {
                ruleRow("hourglass", "A one-time place, gone for good \(expiresAt, style: .relative) from now.")
            }
        }
        if let minutes = theme.rules.dailyMinutes {
            if let left = theme.minutesLeftToday {
                ruleRow("timer", "Up to \(minutes) minutes a day · \(left) left today")
            } else {
                ruleRow("timer", "Up to \(minutes) minutes a day")
            }
        }
        if let hours = theme.rules.hours {
            ruleRow("clock", "Open \(Self.hour(hours.from))–\(Self.hour(hours.to)) your time")
        }
        if let weather = theme.rules.weather, !weather.isEmpty {
            ruleRow("cloud.sun", "Only when it's \(weather.joined(separator: " or ")) where you are")
        }
        if let place = theme.rules.place {
            ruleRow("location", "Only while you're near \(place.label)")
        }
        if theme.rules.isEmpty && !theme.limited {
            ruleRow("checkmark.seal", "No limits. Your pet can go any time.")
        }
    }

    private func ruleRow(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(AppColors.ink)
    }

    private static func hour(_ value: Int) -> String {
        String(format: "%02d:00", value % 24)
    }

    @ViewBuilder
    private func primaryButton(_ theme: PetTheme) -> some View {
        if isActive {
            Button {
                Haptics.tap(.medium)
                Task { if await model.goTo(nil) { dismiss() } }
            } label: {
                Label("Bring Home", systemImage: "house.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.posterSecondary)
            .disabled(model.activity != nil)
            .accessibilityIdentifier("pet-theme-come-home")
        } else if !theme.expired {
            Button {
                Haptics.tap(.medium)
                Task { if await model.goTo(theme) { dismiss() } }
            } label: {
                Label("Go Here", systemImage: "figure.walk.departure")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.poster)
            .disabled(!theme.available || model.activity != nil)
            .accessibilityIdentifier("pet-theme-go")
        }
    }
}

/// A place's kind, with its symbol, and a tag when it is one-time.
struct PetThemeCategoryLabel: View {
    let theme: PetTheme

    var body: some View {
        HStack(spacing: 6) {
            Label(theme.category.displayName, systemImage: theme.category.symbol)
            if theme.limited {
                Text("One-time")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15), in: .capsule)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppColors.ink)
    }
}

/// Where the pet stands with a place right now: there, free to go, closed and why, or passed.
struct PetThemeStatusLine: View {
    let theme: PetTheme
    let isActive: Bool

    var body: some View {
        Group {
            if isActive {
                Label("Your pet is here", systemImage: "mappin.circle.fill")
                    .foregroundStyle(.green)
            } else if theme.expired {
                Label("Passed", systemImage: "clock.badge.xmark")
                    .foregroundStyle(AppColors.muted)
            } else if let reason = theme.unavailableReason {
                Label(reason, systemImage: "lock.fill")
                    .foregroundStyle(AppColors.muted)
            } else if let expiresAt = theme.expiresAt {
                Label("Ends \(expiresAt, style: .relative) from now", systemImage: "hourglass")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.weight(.bold))
    }
}

extension PetTheme {
    /// What being here does on each of the pet's visits, in the shape the effect chips draw.
    var visitEffects: PetActionEffects {
        PetActionEffects(happiness: effects.happiness, hp: effects.hp, energy: effects.energy, gold: 0)
    }
}
