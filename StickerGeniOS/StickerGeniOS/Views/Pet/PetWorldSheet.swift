import SwiftUI
import UIKit

/// Explains what the pet reads of its owner's world and asks for it, one source per tap.
///
/// The only place either permission is requested. Each button asks the system, then reads what was
/// allowed and sends it to the server at once, so the pet can react on its next visit. A source the
/// user refused cannot be asked again from the app, so its row points to Settings instead.
struct PetWorldSheet: View {
    @Bindable var model: PetModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var context: PetContextProvider { model.context }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // swiftlint:disable:next line_length
                    Text("Your pet can feel the weather where you are and notice how much you walk. It changes their mood and energy — a rainy day might delight one pet and sulk another.")
                        .foregroundStyle(AppColors.muted)

                    if context.isHealthAvailable {
                        sourceCard(
                            title: "Steps",
                            symbol: "figure.walk",
                            // swiftlint:disable:next line_length
                            detail: "Walking your pet gives back its energy and earns gold. Only today's step count is read from Health. Nothing is written.",
                            state: healthState,
                            identifier: "pet-world-health-button"
                        ) {
                            Task { await model.connect(.health) }
                        }
                    }

                    sourceCard(
                        title: "Weather",
                        symbol: "cloud.sun.fill",
                        // swiftlint:disable:next line_length
                        detail: "Your approximate location, to about a kilometre, is used to look up the weather. Only while you use the app.",
                        state: locationState,
                        identifier: "pet-world-location-button"
                    ) {
                        Task { await model.connect(.location) }
                    }

                    trackingCard

                    Text("You can change either at any time in Settings.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.muted)
                }
                .padding()
            }
            .background { PosterPaper() }
            .navigationTitle("Weather & Steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Haptics.tap(.light); dismiss() }
                        .disabled(model.activity != nil)
                        .accessibilityIdentifier("pet-world-done-button")
                }
            }
            .safeAreaInset(edge: .top) {
                if let errorMessage = model.errorMessage {
                    ErrorBanner(message: errorMessage).padding(.horizontal)
                }
            }
            .task { await context.refreshPermissions() }
        }
        .overlay {
            if let activity = model.activity { PetActivityOverlay(activity: activity) }
        }
        .animation(.snappy(duration: 0.2), value: model.activity)
        .interactiveDismissDisabled(model.activity != nil)
    }

    /// The owner's switch over sending their location at all, and in the background as they travel.
    private var trackingCard: some View {
        PosterCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { context.isLocationTrackingEnabled },
                    set: { enabled in
                        Haptics.tap(.medium)
                        Task { await model.setLocationTracking(enabled) }
                    }
                )) {
                    Label("Location Tracking", systemImage: "location.fill.viewfinder")
                        .font(.posterDisplay(17, weight: .bold))
                        .foregroundStyle(AppColors.ink)
                }
                .disabled(model.activity != nil || (!context.hasLocationAccess && !context.canAskForLocation))
                .accessibilityIdentifier("pet-world-tracking-toggle")
                Text(trackingDetail)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(AppColors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trackingDetail: LocalizedStringKey {
        if !context.isLocationTrackingEnabled {
            // swiftlint:disable:next line_length
            return "Off. Your location isn't sent, and your pet forgets where you were. It won't feel your weather or find places on your trips."
        }
        if context.hasBackgroundLocationAccess {
            // swiftlint:disable:next line_length
            return "On, even while the app is closed. Your pet notices when you travel and finds places on your trip. Only big moves are noticed, to save battery."
        }
        if context.hasLocationAccess {
            return "On while you use the app. Allow \"Always\" in Settings for your pet to notice trips while the app is closed."
        }
        return "Allow location above to let your pet notice when you travel."
    }

    private enum SourceState { case ask, connected, refused }

    /// Health hides whether reading was allowed, so once asked it counts as connected.
    private var healthState: SourceState { context.healthRequested ? .connected : .ask }

    private var locationState: SourceState {
        if context.hasLocationAccess { return .connected }
        return context.canAskForLocation ? .ask : .refused
    }

    private func sourceCard(
        title: LocalizedStringKey,
        symbol: String,
        detail: LocalizedStringKey,
        state: SourceState,
        identifier: String,
        ask: @escaping () -> Void
    ) -> some View {
        PosterCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.posterDisplay(17, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                Text(detail)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(AppColors.muted)
                switch state {
                case .ask:
                    Button {
                        ask()
                    } label: {
                        Text("Allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.poster)
                    .disabled(model.activity != nil)
                    .accessibilityIdentifier(identifier)
                case .connected:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppColors.ink)
                        .accessibilityIdentifier("\(identifier)-connected")
                case .refused:
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Text("Open Settings").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.posterSecondary)
                    .accessibilityIdentifier("\(identifier)-settings")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
