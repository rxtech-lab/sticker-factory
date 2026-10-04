import SwiftUI

/// The pet, large, with what it last said and how long ago.
struct WatchPetView: View {
    @Bindable var model: WatchPetModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.snapshot?.title ?? String(localized: "Pet"))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.requestRefresh(userInitiated: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh")
                        .disabled(model.isRefreshing)
                    }
                }
                .overlay {
                    if model.isRefreshing { RefreshingOverlay() }
                }
                .animation(.snappy(duration: 0.2), value: model.isRefreshing)
                .animation(.snappy, value: model.snapshot)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.requestRefresh(userInitiated: false) }
        }
        .alert("Couldn’t Reach Your iPhone", isPresented: Binding(
            get: { model.refreshFailure != nil },
            set: { if !$0 { model.refreshFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.refreshFailure ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = model.snapshot {
            ScrollView {
                VStack(spacing: 8) {
                    PetPoseImage(data: model.pose)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .accessibilityLabel(snapshot.title)
                    if let caption = snapshot.caption {
                        Text("“\(caption)”")
                            .font(.system(.body, design: .rounded))
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Send a sticker from Messages to see how I feel.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let updated = snapshot.statusUpdatedAt {
                        Text("Updated \(updated, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else if model.hasHeardFromPhone {
            ContentUnavailableView(
                "No Pet Yet",
                systemImage: "pawprint",
                description: Text("Choose a pet in Winky on your iPhone.")
            )
        } else {
            ContentUnavailableView(
                "Waiting for iPhone",
                systemImage: "iphone.and.arrow.forward",
                description: Text("Open Winky on your iPhone to bring your pet here.")
            )
        }
    }
}

/// Covers the screen while a refresh the user asked for is on its way.
private struct RefreshingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 6) {
                ProgressView()
                Text("Asking your iPhone…")
                    .font(.footnote)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        }
        .transition(.opacity)
    }
}

#if DEBUG
private extension PetSnapshot {
    static func preview(caption: String?) -> PetSnapshot {
        PetSnapshot(stickerID: "preview", title: "Winky", caption: caption,
                    statusUpdatedAt: caption == nil ? nil : .now.addingTimeInterval(-15 * 60),
                    selectedAt: .now, poseKey: "preview")
    }
}

#Preview("Pet") {
    WatchPetView(model: WatchPetModel(previewSnapshot: .preview(caption: "That sticker made my whole day!")))
}

#Preview("Before First Sticker") {
    WatchPetView(model: WatchPetModel(previewSnapshot: .preview(caption: nil)))
}

#Preview("Refreshing") {
    WatchPetView(model: WatchPetModel(previewSnapshot: .preview(caption: "Feeling sleepy…"), isRefreshing: true))
}

#Preview("No Pet Yet") {
    WatchPetView(model: WatchPetModel(previewSnapshot: nil))
}

#Preview("Waiting for iPhone") {
    WatchPetView(model: WatchPetModel(previewSnapshot: nil, hasHeardFromPhone: false))
}
#endif
