import SwiftUI

/// Who the pet is and what it knows of the world, opened from the button above the pet.
///
/// The identity half is fixed at adoption — class, temperament, tastes — so it reads like a
/// character sheet. The "World" half is what the server last read for it: weather, steps, a
/// headline, and when it will next drop by. While steps or location are not granted, the sheet
/// offers to connect them; the asking itself happens in `PetWorldSheet`, never here.
struct PetIdentitySheet: View {
    @Bindable var model: PetModel
    @State private var showingWorld = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let identity = model.pet?.identity {
                        PetIdentitySection(identity: identity)
                        Divider()
                    }
                    PetWorldRow(signals: model.pet?.signals, nextEventAt: model.pet?.nextEventAt)
                    if model.context.needsPermissions {
                        Button {
                            showingWorld = true
                        } label: {
                            Label("Connect weather & steps", systemImage: "location.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.posterSecondaryCompact)
                        .accessibilityIdentifier("pet-connect-world-button")
                    } else if model.isWeatherMissing {
                        // Allowed, but the phone has not found where it is yet — a fix that timed
                        // out, or Location Services turned off. Nothing to connect; only to retry.
                        Text("Location is on for Winky, but your phone hasn't found where you are yet, so your pet can't feel the weather.")
                            .font(.footnote)
                            .foregroundStyle(AppColors.muted)
                        Button {
                            Haptics.tap(.light)
                            Task { await model.retryWeather() }
                        } label: {
                            Label("Find My Weather", systemImage: "location.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.posterSecondaryCompact)
                        .disabled(model.activity != nil)
                        .accessibilityIdentifier("pet-retry-weather-button")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background { PosterPaper() }
            .navigationTitle("About Your Pet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Haptics.tap(.light); dismiss() }
                }
            }
            .sheet(isPresented: $showingWorld) {
                PetWorldSheet(model: model)
            }
            // Either may have changed in Settings since the app last looked.
            .task { await model.context.refreshPermissions() }
            .alert(
                "No Weather Yet",
                isPresented: Binding(get: { model.weatherProblem != nil }, set: { if !$0 { model.weatherProblem = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.weatherProblem ?? "")
            }
        }
        .overlay {
            if let activity = model.activity { PetActivityOverlay(activity: activity) }
        }
        .animation(.snappy(duration: 0.2), value: model.activity)
        .interactiveDismissDisabled(model.activity != nil)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("pet-identity-sheet")
    }
}

/// The character sheet: class, personality, likes and dislikes, favourite weather, stamina.
private struct PetIdentitySection: View {
    let identity: PetIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: identity.petClass.symbol)
                    .foregroundStyle(AppColors.indigo)
                Text(identity.petClass.displayName)
                    .font(.system(size: 16, weight: .heavy, design: .monospaced))
                Spacer()
                Label(identity.favoriteWeather.displayName, systemImage: identity.favoriteWeather.symbol())
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppColors.muted)
                    .accessibilityLabel(Text("Favorite weather: \(identity.favoriteWeather.displayName)"))
            }
            .foregroundStyle(AppColors.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pet-class")

            Text(identity.personality)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(AppColors.ink)

            if !identity.likes.isEmpty {
                PetTasteRow(title: "Likes", symbol: "hand.thumbsup.fill", color: AppColors.mint, items: identity.likes)
            }
            if !identity.dislikes.isEmpty {
                PetTasteRow(title: "Dislikes", symbol: "hand.thumbsdown.fill", color: AppColors.coral, items: identity.dislikes)
            }

            Label {
                Text(staminaText)
            } icon: {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
            }
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(AppColors.ink)
            .accessibilityIdentifier("pet-stamina")
        }
    }

    /// Above 1 every activity costs more energy; below 1, less.
    private var staminaText: String {
        let multiplier = identity.energyMultiplier.formatted(.number.precision(.fractionLength(1)))
        if identity.energyMultiplier > 1.05 { return String(localized: "Tires easily ×\(multiplier)") }
        if identity.energyMultiplier < 0.95 { return String(localized: "Tireless ×\(multiplier)") }
        return String(localized: "Steady ×\(multiplier)")
    }
}

/// A labelled run of small chips — the things the pet likes, or does not.
private struct PetTasteRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .labelStyle(PetStatLabelStyle(color: color))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(AppColors.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppColors.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(color.opacity(0.25), in: .capsule)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the pet last read of its owner's world, in one compact block.
struct PetWorldRow: View {
    let signals: PetSignals?
    let nextEventAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("World")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(AppColors.ink)
            HStack(spacing: 14) {
                if let weather = signals?.weather {
                    Label {
                        Text(temperature(weather.temperatureC))
                    } icon: {
                        Image(systemName: weather.kind.symbol(isDay: weather.isDay)).symbolRenderingMode(.multicolor)
                    }
                    .accessibilityLabel(Text("\(weather.kind.displayName), \(temperature(weather.temperatureC))"))
                }
                if let steps = signals?.stepsToday {
                    Label {
                        Text("\(steps.formatted()) steps")
                    } icon: {
                        Image(systemName: "figure.walk").foregroundStyle(AppColors.indigo)
                    }
                }
                if signals?.weather == nil && signals?.stepsToday == nil {
                    Text("Your pet hasn't felt the outside world yet.")
                        .foregroundStyle(AppColors.muted)
                }
            }
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(AppColors.ink)

            if let tomorrow = signals?.tomorrow {
                let low = temperature(tomorrow.minC)
                let high = temperature(tomorrow.maxC)
                let rain = tomorrow.precipitationChance.map { " · \($0)% rain" } ?? ""
                Label {
                    Text("Tomorrow \(low)–\(high)\(rain)")
                } icon: {
                    Image(systemName: tomorrow.kind.symbol(isDay: true)).symbolRenderingMode(.multicolor)
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppColors.muted)
                .accessibilityLabel(Text("Tomorrow: \(tomorrow.kind.displayName), \(low) to \(high)"))
                .accessibilityIdentifier("pet-tomorrow-forecast")
            }
            if let headline = signals?.headlines.first {
                Label(headline, systemImage: "newspaper.fill")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColors.muted)
                    .lineLimit(2)
            }
            if let nextEventAt {
                Label {
                    if nextEventAt > .now {
                        Text("Next visit \(nextEventAt, format: .relative(presentation: .named))")
                    } else {
                        Text("Next visit any moment now")
                    }
                } icon: {
                    Image(systemName: "clock.fill").foregroundStyle(AppColors.coral)
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppColors.muted)
                .accessibilityIdentifier("pet-next-visit")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pet-world")
    }

    private func temperature(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
