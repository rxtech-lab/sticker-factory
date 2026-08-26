import SwiftUI

/// Every action that used to live on the sticker workspace, grouped into divider-separated
/// sections. Candidate decisions also appear inline in the transcript; this is the complete,
/// always-reachable copy.
struct StickerChatActionsMenu: View {
    let candidate: StickerRevision?
    let activeRevision: StickerRevision?
    let isBusy: Bool

    let onAcceptCandidate: () -> Void
    let onRejectCandidate: () -> Void
    let onCompare: () -> Void
    let onExport: () -> Void
    let onViewVersions: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            if candidate != nil {
                Section {
                    Button("Continue with this sticker", systemImage: "checkmark.circle") { onAcceptCandidate() }
                        .accessibilityIdentifier("accept-candidate")
                    Button("Compare with previous", systemImage: "rectangle.on.rectangle") { onCompare() }
                    Button("Reject candidate", systemImage: "xmark", role: .destructive) { onRejectCandidate() }
                        .accessibilityIdentifier("reject-candidate")
                }
                .disabled(isBusy)
            }

            Section {
                Button(
                    activeRevision?.canPublishExports == true ? "Export & Publish" : "Export",
                    systemImage: "shippingbox"
                ) { onExport() }
                    .disabled(activeRevision == nil)
                    .accessibilityIdentifier("export-sticker")
            }

            Section {
                Button("Version history", systemImage: "clock.arrow.circlepath") { onViewVersions() }
                    .accessibilityIdentifier("view-versions")
            }

            Section {
                Button("Delete project", systemImage: "trash", role: .destructive) { onDelete() }
                    .accessibilityIdentifier("delete-project")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Sticker actions")
        .accessibilityIdentifier("sticker-actions-menu")
    }
}
