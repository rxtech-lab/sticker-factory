import SwiftUI
import UIKit

/// The same horizontal preview-card presentation used to compare sticker revisions.
struct PlanVersionsSheet: View {
    let versions: [PlanRecord]
    let selectedID: String
    let assets: [String: UIImage]
    let api: StickerAPIClientProtocol
    let onSelect: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var history = StickerAssetStore()
    @State private var attemptedAssetIDs: Set<String> = []
    @State private var selectingID: String?
    @State private var selectionError: String?

    var body: some View {
        StickerBackground {
            ScrollView {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                                versionCard(version, number: index + 1)
                                    .id(version.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plan-version-carousel")
                    .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
                }
            }
        }
        .navigationTitle("Plan versions")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-versions-sheet")
        .interactiveDismissDisabled(selectingID != nil)
        .modifier(ChatErrorAlert(message: selectionError) { selectionError = nil })
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    Haptics.tap(.light)
                    dismiss()
                }
                    .disabled(selectingID != nil)
            }
        }
    }

    private func versionCard(_ version: PlanRecord, number: Int) -> some View {
        PosterCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Version \(number)")
                        .font(.headline)
                    Spacer()
                    if version.id == selectedID {
                        Text("Current")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                referencePreview(version)
                    .frame(width: 260, height: 260)
                    .clipShape(.rect(cornerRadius: 14))
                Text(version.plan.title)
                    .font(.posterDisplay(19, weight: .bold))
                Text(version.plan.summary)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    selectingID = version.id
                    Task {
                        defer { selectingID = nil }
                        do {
                            try await onSelect(version.id)
                            dismiss()
                        } catch {
                            selectionError = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        if selectingID == version.id { ProgressView().controlSize(.small) }
                        Label(
                            version.id == selectedID ? LocalizedStringKey("Selected") : LocalizedStringKey("Select"),
                            systemImage: version.id == selectedID ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.posterSecondary)
                .disabled(selectingID != nil)
                .accessibilityIdentifier("select-plan-version-\(number)")
            }
            .frame(width: 260, alignment: .leading)
        }
    }

    @ViewBuilder
    private func referencePreview(_ version: PlanRecord) -> some View {
        if let assetID = version.conceptAssetId {
            Group {
                if let image = assets[assetID] ?? history.images[assetID] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if attemptedAssetIDs.contains(assetID) {
                    VStack(spacing: 8) {
                        Text("Reference unavailable")
                            .font(.caption)
                        Button("Retry") { Task { await loadReference(assetID) } }
                            .buttonStyle(.posterSecondary)
                    }
                } else {
                    ProgressView("Loading reference…")
                }
            }
            .task(id: assetID) {
                if assets[assetID] == nil { await loadReference(assetID) }
            }
        } else {
            PlanLayoutPreview(layers: version.plan.layers)
        }
    }

    private func loadReference(_ assetID: String) async {
        attemptedAssetIDs.remove(assetID)
        await history.load(assetID: assetID, api: api)
        guard !Task.isCancelled else { return }
        attemptedAssetIDs.insert(assetID)
    }
}
