import SwiftUI
import RxAuthSwift

struct AccountView: View {
    @Bindable var environment: AppEnvironment
    @State private var confirmingLogout = false

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(spacing: 18) {
                    GlassCard {
                        HStack(spacing: 16) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 54))
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(environment.authManager.currentUser?.name ?? "Sticker maker")
                                    .font(.title3.bold())
                                Text(environment.authManager.currentUser?.email ?? "Signed in with RxLab")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Private by default", systemImage: "hand.raised.fill")
                                .font(.headline)
                            Text("Prompts, personal-photo sources, masks, chat history, and immutable revisions remain private to your account until you delete the sticker project.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("Deleting a project starts a durable purge of its Turso records and private R2 media.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(role: .destructive) { confirmingLogout = true } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .accessibilityIdentifier("sign-out-button")
                }
                .padding()
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Account")
        .confirmationDialog("Sign out of Sticker Factory?", isPresented: $confirmingLogout) {
            Button("Sign Out", role: .destructive) { Task { await environment.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shared credentials and cached iMessage stickers will be removed from this device.")
        }
    }
}
