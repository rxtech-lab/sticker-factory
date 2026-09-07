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

            if environment.subscription.isReady {
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
                Button {
                    onShowWelcome()
                } label: {
                    Label {
                        Text(howItWorksTitle)
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
                .accessibilityIdentifier("show-welcome-button")

                Button(action: onShowFeatures) {
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

            Section {
                Button("Sign Out", role: .destructive) {
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
            Button("Sign Out", role: .destructive) { Task { await environment.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shared credentials and cached iMessage stickers will be removed from this device.")
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
                Text(subscription.activePlanName ?? String(localized: "Free"))
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("subscription-plan")

            LabeledContent("Credits") {
                if let credits = subscription.credits {
                    Text(credits, format: .number)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    // Nothing loaded yet, or the read failed. Either way a number here would be a
                    // guess, and a wrong balance is worse than no balance.
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityIdentifier("subscription-credits")

            Button {
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
                isManagingSubscription = true
            } label: {
                Label("Manage Subscription", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("manage-subscription-button")
            .manageSubscriptionsSheet(isPresented: $isManagingSubscription)

            Button {
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
            .disabled(isRestoring)
            .accessibilityIdentifier("restore-purchases-button")

            if let restoreMessage {
                Text(restoreMessage)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(AppColors.muted)
            }
        } header: {
            PosterListHeader("Subscription")
        } footer: {
            Text("Manage Subscription opens Apple's own sheet, where a plan can be changed or cancelled. Changes can take a moment to reach this screen.")
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
