import RxAuthSwift
import StoreKit
import SwiftUI

struct AccountView: View {
    @Bindable var environment: AppEnvironment
    var onShowWelcome: () -> Void = {}
    var onShowFeatures: () -> Void = {}
    @State private var confirmingLogout = false

    private var userName: String {
        environment.authManager.currentUser?.name ?? String(localized: "Sticker maker")
    }

    private var userEmail: String {
        environment.authManager.currentUser?.email ?? String(localized: "Signed in with RxLab")
    }

    private var avatarURL: URL? {
        environment.authManager.currentUser?.image.flatMap(URL.init(string:))
    }

    private var howItWorksTitle: String {
        String(localized: "How \(AppConfiguration.defaultAppName) works")
    }

    private var aboutTitle: String {
        String(localized: "About \(AppConfiguration.defaultAppName)")
    }

    private var signOutTitle: String {
        String(localized: "Sign out of \(AppConfiguration.defaultAppName)?")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    AccountAvatar(name: userName, url: avatarURL)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(userName)
                            .font(.posterDisplay(19, weight: .bold))
                            .foregroundStyle(AppColors.ink)
                        Text(userEmail)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(AppColors.muted)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Signed in as \(userName), \(userEmail)")
                .accessibilityIdentifier("signed-in-profile")
            } header: {
                PosterListHeader("Signed In")
            }

            if environment.subscription.isEnabled {
                SubscriptionSection(subscription: environment.subscription)
            }

            Section {
                NavigationLink(value: LegalDocument.privacy) {
                    Label("Privacy Policy", systemImage: LegalDocument.privacy.posterSymbol)
                }
                .accessibilityIdentifier("privacy-policy-link")

                NavigationLink(value: LegalDocument.terms) {
                    Label("Terms of Service", systemImage: LegalDocument.terms.posterSymbol)
                }
                .accessibilityIdentifier("terms-of-service-link")
            } header: {
                PosterListHeader("Legal")
            }

            Section {
                TutorialButton()
                Button {
                    Haptics.tap(.light)
                    onShowWelcome()
                } label: {
                    Label {
                        Text(howItWorksTitle)
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
                .accessibilityIdentifier("show-welcome-button")

                Button {
                    Haptics.tap(.light)
                    onShowFeatures()
                } label: {
                    Label("What's new", systemImage: "gift.fill")
                }
                .accessibilityIdentifier("show-feature-cards-button")
            } header: {
                PosterListHeader("Help")
            }

            Section {
                NavigationLink {
                    AboutPageView(
                        baseURL: environment.configuration.apiBaseURL,
                        appName: AppConfiguration.defaultAppName,
                        appVersion: environment.configuration.appVersion,
                        appBuild: environment.configuration.appBuild
                    )
                } label: {
                    Label {
                        Text(aboutTitle)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                    }
                }
                .accessibilityIdentifier("about-page-link")
            } header: {
                PosterListHeader("About")
            }

            DeleteAccountSection(environment: environment)

            Section {
                Button("Sign Out", role: .destructive) {
                    Haptics.tap(.medium)
                    confirmingLogout = true
                }
                .font(.posterDisplay(16, weight: .bold))
                .foregroundStyle(AppColors.coral)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("sign-out-button")
            } footer: {
                Text("Signing out removes shared credentials and cached iMessage stickers from this device.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(AppColors.faint)
            }
        }
        .navigationTitle("Account")
        // A `Form` paints its own grouped grey, which is the one surface in the app that is
        // neither paper nor card. Hidden, so the poster page shows through and each row sits on
        // cream instead.
        .scrollContentBackground(.hidden)
        .background { PosterPaper() }
        .listRowBackground(AppColors.card)
        .listRowSeparatorTint(AppColors.line)
        .task { environment.subscription.refresh() }
        .navigationDestination(for: LegalDocument.self) { document in
            LegalDocumentView(document: document, baseURL: environment.configuration.apiBaseURL)
        }
        .confirmationDialog(signOutTitle, isPresented: $confirmingLogout) {
            Button("Sign Out", role: .destructive) {
                Haptics.tap(.heavy)
                Task { await environment.signOut() }
            }
            Button("Cancel", role: .cancel) { Haptics.tap(.light) }
        } message: {
            Text("Shared credentials and cached iMessage stickers will be removed from this device.")
        }
        .telemetryScreen("account")
    }
}

/// Deleting the account, and — for the whole grace period — changing your mind.
///
/// Both halves matter. The deletion is real and takes everything with it, so the confirmation says
/// exactly what goes and what survives; and because it does not happen for a week, the way back has
/// to be at least as reachable as the way in. While a deletion is pending this section *is* the
/// pending notice, with the date the account actually disappears.
private struct DeleteAccountSection: View {
    @Bindable var environment: AppEnvironment
    @State private var state: AccountDeletionState = .none
    @State private var confirmingDeletion = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var isPending: Bool { state.pendingDeletion }

    private var scheduledDescription: String? {
        guard let scheduledAt = state.deletionScheduledAt else { return nil }
        // Formatted here rather than on the server so the date lands in the reader's own timezone.
        return scheduledAt.formatted(date: .long, time: .shortened)
    }

    var body: some View {
        Section {
            if isPending {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This account is scheduled for deletion")
                        .font(.posterDisplay(15, weight: .bold))
                        .foregroundStyle(AppColors.coral)
                    if let scheduledDescription {
                        Text("Everything will be permanently deleted on \(scheduledDescription).")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(AppColors.muted)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pending-deletion-notice")

                Button {
                    Haptics.tap(.medium)
                    perform { try await environment.store.api.cancelAccountDeletion() }
                } label: {
                    HStack {
                        Text("Keep My Account")
                        if isWorking {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .font(.posterDisplay(16, weight: .bold))
                .disabled(isWorking)
                .accessibilityIdentifier("cancel-account-deletion")
            } else {
                Button("Delete My Account", role: .destructive) {
                    Haptics.tap(.medium)
                    confirmingDeletion = true
                }
                .font(.posterDisplay(16, weight: .bold))
                .foregroundStyle(AppColors.coral)
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(isWorking)
                .accessibilityIdentifier("delete-account-button")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(AppColors.coral)
                    .accessibilityIdentifier("account-deletion-error")
            }
        } header: {
            PosterListHeader("Delete Account")
        } footer: {
            Text("""
                Your account is deleted 7 days after you ask, and you can cancel any time before then. \
                Your stickers and their media are deleted with it. Packs you already published stay in \
                the marketplace, credited to \u{201C}deleted-account\u{201D}.
                """)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(AppColors.faint)
        }
        .confirmationDialog(
            "Delete your \(AppConfiguration.defaultAppName) account?",
            isPresented: $confirmingDeletion
        ) {
            Button("Delete My Account", role: .destructive) {
                Haptics.tap(.heavy)
                perform { try await environment.store.api.requestAccountDeletion() }
            }
            Button("Cancel", role: .cancel) { Haptics.tap(.light) }
        } message: {
            Text("""
                Your account will be permanently deleted in 7 days, along with your stickers and \
                their media. You can cancel any time before then. Packs you already published stay \
                in the marketplace, credited to \u{201C}deleted-account\u{201D}.
                """)
        }
        .task {
            // A failed read falls back to "nothing pending" rather than disabling the button: the
            // request is idempotent, so a user who *is* pending and taps anyway gets their existing
            // schedule back and the section corrects itself. Refusing to act on a transient network
            // failure would be the worse answer.
            state = (try? await environment.store.api.accountDeletionState()) ?? .none
        }
    }

    private func perform(_ work: @escaping () async throws -> AccountDeletionState) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                state = try await work()
            } catch let envelope as APIErrorEnvelope
                where envelope.error.code == "ACCOUNT_DELETION_SCOPE_REQUIRED" {
                // The install was authorized before the app asked for `write:profile`. Only a fresh
                // sign-in can grant it, so say that instead of repeating the server's wording.
                errorMessage = String(localized: "Sign out and sign in again to confirm this change.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Plan, credit balance, and the two things App Review looks for: a way to manage the subscription
/// and a way to restore purchases.
private struct SubscriptionSection: View {
    @Bindable var subscription: SubscriptionStore
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    /// Presents StoreKit's own manage-subscriptions sheet.
    ///
    /// Deliberately the native sheet rather than a link to
    /// `apps.apple.com/account/subscriptions`: the web page only ever lists *production*
    /// subscriptions, so a TestFlight or sandbox subscriber following it finds nothing there and
    /// has no way to cancel. The sheet reads whichever environment the build is running in, which
    /// is the only in-app path to cancelling a sandbox subscription before its six automatic
    /// renewals run out.
    @State private var isManagingSubscription = false

    var body: some View {
        Section {
            LabeledContent("Plan") {
                Text(subscription.entitlements == nil ? "—" : subscription.activePlanName ?? String(localized: "Free"))
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("subscription-plan")

            LabeledContent("Credits") {
                if let credits = subscription.credits {
                    Text(credits, format: .number)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if subscription.isLoading || subscription.isConnecting {
                    // Nothing loaded yet, or the read failed. Either way a number here would be a
                    // guess, and a wrong balance is worse than no balance.
                    ProgressView().controlSize(.small)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("subscription-credits")

            Button {
                Haptics.tap(.light)
                subscription.presentPaywall()
            } label: {
                Label("View Plans", systemImage: "creditcard")
            }
            .accessibilityIdentifier("view-plans-button")

            // Offered whether or not the cache says there is a plan. `hasActiveSubscription` is
            // the *server's* answer, and the two disagree exactly when it matters: a purchase
            // StoreKit completed but the backend refused still leaves a live App Store
            // subscription the user is being charged for and must be able to cancel. Gating this
            // on the server's view would hide the only control that can end it.
            Button {
                Haptics.tap(.light)
                isManagingSubscription = true
            } label: {
                Label("Manage Subscription", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("manage-subscription-button")
            .manageSubscriptionsSheet(isPresented: $isManagingSubscription)

            Button {
                Haptics.tap(.light)
                restore()
            } label: {
                HStack {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                    if isRestoring {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isRestoring || !subscription.isReady)
            .accessibilityIdentifier("restore-purchases-button")

            if let restoreMessage {
                Text(restoreMessage)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(AppColors.muted)
            }
        } header: {
            PosterListHeader("Subscription")
        } footer: {
            Text("""
                Manage Subscription opens Apple's own sheet, where a plan can be changed or cancelled. \
                Changes can take a moment to reach this screen.
                """)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(AppColors.faint)
        }
        .onChange(of: isManagingSubscription) { _, isPresented in
            // The sheet reports no result, so a cancellation is only visible once StoreKit and the
            // server have caught up. Refreshing on dismissal keeps the plan row from advertising a
            // subscription the user just turned off.
            guard !isPresented else { return }
            subscription.refresh()
        }
    }

    private func restore() {
        isRestoring = true
        restoreMessage = nil
        Task {
            defer { isRestoring = false }
            do {
                try await subscription.restorePurchases()
                restoreMessage = String(localized: "Purchases restored.")
            } catch {
                restoreMessage = error.localizedDescription
            }
        }
    }
}

private struct AccountAvatar: View {
    let name: String
    let url: URL?

    private var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "S" : String(letters).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AppColors.lime)

            Text(initials)
                .font(.posterDisplay(22, weight: .heavy))
                .foregroundStyle(AppColors.ink)

            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    case .empty, .failure:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(.circle)
        .overlay {
            Circle().strokeBorder(AppColors.ink, lineWidth: Poster.border)
        }
        .background {
            Circle().fill(AppColors.ink).offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }
}
