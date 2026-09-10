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
        // Every row asks for its own tap. A menu is drawn by UIKit, which never sees the app's
        // button styles — so this is the one place feedback cannot come from the style.
        Menu {
            if candidate != nil {
                Section {
                    Button {
                        Haptics.tap(.light)
                        onAcceptCandidate()
                    } label: {
                        PosterMenuLabel("Continue with this sticker", icon: .accept)
                    }
                        .accessibilityIdentifier("accept-candidate")
                    Button {
                        Haptics.tap(.light)
                        onCompare()
                    } label: {
                        PosterMenuLabel("Compare with previous", icon: .compare)
                    }
                    Button(role: .destructive) {
                        Haptics.tap(.medium)
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
                    Haptics.tap(.light)
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
                    Haptics.tap(.light)
                    onRename()
                } label: {
                    PosterMenuLabel("Rename sticker", icon: .rename)
                }
                    .accessibilityIdentifier("rename-sticker")
                Button {
                    Haptics.tap(.light)
                    versionsTip.invalidate(reason: .actionPerformed)
                    onViewVersions()
                } label: {
                    PosterMenuLabel("Version history", icon: .history)
                }
                    .accessibilityIdentifier("view-versions")
            }

            Section {
                Button(role: .destructive) {
                    Haptics.tap(.medium)
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
