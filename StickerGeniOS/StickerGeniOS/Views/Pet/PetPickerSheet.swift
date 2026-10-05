import SwiftUI

/// Chooses the pet from every controllable sticker the account can pose.
///
/// The server filters the candidates and groups them the way the library does, so a member of an
/// installed pack sits under its pack's name. Tapping one adopts it and closes the sheet.
struct PetPickerSheet: View {
    @Bindable var model: PetModel

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Choose a Pet")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search controllable stickers")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            Haptics.tap(.light)
                            dismiss()
                        }
                        .accessibilityIdentifier("pet-picker-cancel-button")
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let errorMessage = model.errorMessage {
                        ErrorBanner(message: errorMessage).padding(.horizontal)
                    }
                }
                .task(id: query) {
                    await model.loadCandidates(query: query, debounce: query.isEmpty ? .zero : .milliseconds(300))
                }
                .overlay {
                    if let activity = model.activity { PetActivityOverlay(activity: activity) }
                }
                .animation(.snappy(duration: 0.2), value: model.activity)
        }
        .interactiveDismissDisabled(model.activity != nil)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingCandidates && model.sections.isEmpty {
            PosterProgress(message: String(localized: "Loading stickers…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.candidateSections.isEmpty {
            EmptyStateView(
                title: query.isEmpty
                    ? String(localized: "No controllable stickers")
                    : String(localized: "No matches"),
                message: query.isEmpty
                    ? String(localized: "Create an animated sticker with controls, or install a pack that has one.")
                    : String(localized: "No controllable sticker matches “\(query)”.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.candidateSections) { section in
                        candidates(in: section)
                    }
                }
                .padding()
            }
            .refreshable { await model.loadCandidates(query: query, debounce: .zero) }
        }
    }

    private func candidates(in section: LibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.kind == .mine ? String(localized: "My Stickers") : section.title)
                .font(.posterDisplay(15, weight: .bold))
                .foregroundStyle(AppColors.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                ForEach(section.stickers) { sticker in
                    Button {
                        Haptics.selection()
                        Task {
                            if await model.adopt(sticker) { dismiss() }
                        }
                    } label: {
                        PickableSticker(sticker: sticker, api: model.api, isSelected: sticker.id == model.pet?.sticker.id)
                    }
                    // Undecorated, like the pack picker: the selection haptic answers the tap, and
                    // the overlay answers the request.
                    .buttonStyle(.plain)
                    .disabled(model.activity != nil)
                    .accessibilityIdentifier("pet-candidate-\(sticker.id)")
                }
            }
        }
    }
}
