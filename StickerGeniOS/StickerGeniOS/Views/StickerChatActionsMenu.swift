import SwiftUI
import TipKit

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
    let onRename: () -> Void
    let onViewVersions: () -> Void
    let onDelete: () -> Void
    private let versionsTip = VersionHistoryTip()

    var body: some View {
        Menu {
            if candidate != nil {
                Section {
                    Button {
                        onAcceptCandidate()
                    } label: {
                        PosterMenuLabel("Continue with this sticker", icon: .accept)
                    }
                        .accessibilityIdentifier("accept-candidate")
                    Button {
                        onCompare()
                    } label: {
                        PosterMenuLabel("Compare with previous", icon: .compare)
                    }
                    Button(role: .destructive) {
                        onRejectCandidate()
                    } label: {
                        PosterMenuLabel("Reject candidate", icon: .reject)
                    }
                        .accessibilityIdentifier("reject-candidate")
                }
                .disabled(isBusy)
            }

            Section {
                Button {
                    versionsTip.invalidate(reason: .actionPerformed)
                    onExport()
                } label: {
                    PosterMenuLabel(
                        activeRevision?.canPublishExports == true ? "Export & Publish" : "Export",
                        icon: .export
                    )
                }
                    .disabled(activeRevision == nil)
                    .accessibilityIdentifier("export-sticker")
            }

            Section {
                Button {
                    onRename()
                } label: {
                    PosterMenuLabel("Rename sticker", icon: .rename)
                }
                    .accessibilityIdentifier("rename-sticker")
                Button {
                    versionsTip.invalidate(reason: .actionPerformed)
                    onViewVersions()
                } label: {
                    PosterMenuLabel("Version history", icon: .history)
                }
                    .accessibilityIdentifier("view-versions")
            }

            Section {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    PosterMenuLabel("Delete project", icon: .delete)
                }
                    .accessibilityIdentifier("delete-project")
            }
        } label: {
            if isBusy {
                ProgressView()
                    .tint(AppColors.ink)
                    .accessibilityLabel("Saving sticker decision")
            } else {
                PosterSymbol("ellipsis.circle")
            }
        }
        .popoverTip(
            candidate == nil && activeRevision != nil ? versionsTip : nil,
            arrowEdge: .top
        )
        .accessibilityLabel("Sticker actions")
        .accessibilityIdentifier("sticker-actions-menu")
    }
}
