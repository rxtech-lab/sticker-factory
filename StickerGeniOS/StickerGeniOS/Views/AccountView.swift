import RxAuthSwift
import SwiftUI

struct AccountView: View {
    @Bindable var environment: AppEnvironment
    var onShowWelcome: () -> Void = {}
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
            Section("Signed In") {
                HStack(spacing: 16) {
                    AccountAvatar(name: userName, url: avatarURL)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(userName)
                            .font(.headline)
                        Text(userEmail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Signed in as \(userName), \(userEmail)")
                .accessibilityIdentifier("signed-in-profile")
            }

            Section("Legal") {
                NavigationLink(value: LegalDocument.privacy) {
                    Label("Privacy Policy", systemImage: LegalDocument.privacy.systemImage)
                }
                .accessibilityIdentifier("privacy-policy-link")

                NavigationLink(value: LegalDocument.terms) {
                    Label("Terms of Service", systemImage: LegalDocument.terms.systemImage)
                }
                .accessibilityIdentifier("terms-of-service-link")
            }

            Section("Help") {
                Button(howItWorksTitle, systemImage: "sparkles") {
                    onShowWelcome()
                }
                .accessibilityIdentifier("show-welcome-button")
            }

            Section("About") {
                NavigationLink {
                    AboutPageView(
                        baseURL: environment.configuration.apiBaseURL,
                        appName: AppConfiguration.defaultAppName,
                        appVersion: environment.configuration.appVersion,
                        appBuild: environment.configuration.appBuild
                    )
                } label: {
                    Label(aboutTitle, systemImage: "info.circle.fill")
                }
                .accessibilityIdentifier("about-page-link")
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    confirmingLogout = true
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("sign-out-button")
            } footer: {
                Text("Signing out removes shared credentials and cached iMessage stickers from this device.")
            }
        }
        .navigationTitle("Account")
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
                .fill(AppColors.accent.gradient)

            Text(initials)
                .font(.title2.bold())
                .foregroundStyle(.white)

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
            Circle().stroke(.white.opacity(0.35), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
