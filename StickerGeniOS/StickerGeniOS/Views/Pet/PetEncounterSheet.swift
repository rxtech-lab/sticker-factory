import SwiftUI

/// Something the pet ran into that needs its owner to decide, opened at half height when the Pet
/// tab comes up with one waiting. Picking a choice reveals what it led to here, in the sheet: a
/// right call rewards the pet, a wrong one costs it and may make it ill.
struct PetEncounterSheet: View {
    @Bindable var model: PetModel
    let encounter: PetEncounter

    @Environment(\.dismiss) private var dismiss
    /// What the pick led to, once the server has said. Nil while the owner is still deciding.
    @State private var outcome: PetEncounterOutcome?

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let outcome { result(outcome) } else { choices }
                }
                .padding()
                .animation(.snappy(duration: 0.35), value: outcome)
            }
            .background { PosterPaper() }
            .navigationTitle(encounter.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if outcome == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Later") {
                            Haptics.tap(.light)
                            dismiss()
                        }
                        .disabled(model.activity != nil)
                        .accessibilityIdentifier("pet-encounter-later")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Haptics.tap(.light)
                            dismiss()
                        }
                        .accessibilityIdentifier("pet-encounter-done")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let errorMessage = model.errorMessage, outcome == nil {
                    ErrorBanner(message: errorMessage).padding(.horizontal)
                }
            }
        }
        .overlay {
            if let activity = model.activity { PetActivityOverlay(activity: activity) }
        }
        .animation(.snappy(duration: 0.2), value: model.activity)
        .interactiveDismissDisabled(model.activity != nil)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 14) {
            PosterCard(padding: 14) {
                Text(encounter.prompt)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text("Choose carefully — a wrong call can cost your pet.")
                Spacer(minLength: 8)
                Image(systemName: "clock")
                Text(encounter.expiresAt, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(AppColors.muted)

            ForEach(encounter.choices) { choice in
                Button {
                    Haptics.tap(.medium)
                    Task {
                        if let landed = await model.decide(choice, in: encounter) { outcome = landed }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(choice.title).font(.headline)
                        Text(choice.description)
                            .font(.caption)
                            .foregroundStyle(AppColors.muted)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.posterSecondary)
                .disabled(model.activity != nil || model.isAnswering)
                .accessibilityIdentifier("pet-encounter-choice-\(choice.id)")
            }
        }
    }

    private func result(_ outcome: PetEncounterOutcome) -> some View {
        let chosen = encounter.choices.first { $0.id == outcome.choiceId }
        return VStack(spacing: 16) {
            Image(systemName: outcome.correct ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.system(size: 52))
                .foregroundStyle(outcome.correct ? AppColors.mint : AppColors.coral)
                .symbolEffect(.bounce, value: outcome.choiceId)
                .accessibilityHidden(true)
            Text(outcome.correct ? "Good call!" : "Oh no…")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(AppColors.ink)
            if let chosen {
                Text("You chose “\(chosen.title)”")
                    .font(.footnote)
                    .foregroundStyle(AppColors.muted)
            }
            PosterCard(padding: 14) {
                Text(verbatim: "“\(outcome.text)”")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                PetEffectsRow(effects: outcome.effects)
                if outcome.medicine > 0 {
                    Label {
                        Text(verbatim: "+\(outcome.medicine)")
                    } icon: {
                        Image(systemName: "pills.fill").foregroundStyle(.teal)
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.teal.opacity(0.12), in: .capsule)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Earned \(outcome.medicine) medicine"))
                }
            }
            if outcome.sickened {
                Label("Your pet fell ill. Medicine will cure it, or it gets better in a few days.", systemImage: "thermometer.medium")
                    .font(.footnote)
                    .foregroundStyle(AppColors.coral)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .accessibilityIdentifier("pet-encounter-result")
    }
}

/// The pet's health under its stats: ill or well, the medicine it has, and the way to give it some.
struct PetHealthRow: View {
    let illness: PetIllness?
    let medicine: Int
    var isBusy = false
    let onGiveMedicine: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: illness == nil ? "pills.fill" : "thermometer.medium")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(illness == nil ? Color.teal : AppColors.coral)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let illness {
                    Text("Ill with \(illness.name)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppColors.ink)
                } else {
                    Text("Feeling well")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppColors.ink)
                }
                Text(medicine == 0 && illness != nil
                     ? String(localized: "No medicine. Help your pet with its daily moments to earn some.")
                     : String(localized: "\(medicine) medicine"))
                    .font(.caption)
                    .foregroundStyle(AppColors.muted)
            }
            Spacer(minLength: 0)
            if illness != nil {
                Button("Give Medicine") {
                    Haptics.tap(.light)
                    onGiveMedicine()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.teal)
                .disabled(medicine == 0 || isBusy)
                .accessibilityIdentifier("pet-give-medicine")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pet-health")
    }
}
