import AnimatedView
import SwiftUI
import UIKit

struct StickerViewerExportRequest: Identifiable {
    let id = UUID()
    let document: AnimatedDocument
    let settings: StickerControlSettings
    let assets: StickerRenderAssets
}

struct StickerViewerExportSheet: View {
    let request: StickerViewerExportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var format: StickerExportFormat = .mp4
    @State private var background: ExportBackgroundChoice = .white
    @State private var work: Task<Void, Never>?
    @State private var busy = false
    @State private var progress = ""
    @State private var error: String?
    @State private var output: URL?
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            StickerBackground {
                Form {
                    Picker("Export as", selection: $format) {
                        Text("Video (MP4)").tag(StickerExportFormat.mp4)
                        Text("GIF").tag(StickerExportFormat.gif)
                        Text("WebP").tag(StickerExportFormat.webp)
                    }
                    .accessibilityIdentifier("viewer-export-format")
                    .disabled(busy)
                    if format == .mp4 {
                        Picker("MP4 background", selection: $background) {
                            ForEach(ExportBackgroundChoice.allCases) { Text($0.label).tag($0) }
                        }
                        .disabled(busy)
                    }
                    if busy {
                        ProgressView(progress.isEmpty ? String(localized: "Preparing files…") : progress)
                        Button("Cancel export", role: .cancel) { work?.cancel() }
                    } else {
                        Button(error == nil ? "Export" : "Retry export") { export() }
                            .accessibilityIdentifier("viewer-export-start")
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Export animation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { work?.cancel(); dismiss() } } }
        }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $sharing) {
            if let output { StickerViewerShareSheet(url: output) }
        }
        .onDisappear { work?.cancel(); removeOutput() }
        .onChange(of: format) { _, _ in if !busy { removeOutput() } }
        .onChange(of: background) { _, _ in if !busy { removeOutput() } }
    }

    private func export() {
        guard !busy else { return }
        removeOutput()
        busy = true; error = nil; progress = ""
        let selectedFormat = format
        let selectedBackground = background.background
        work = Task { @MainActor in
            defer { busy = false; work = nil }
            do {
                let result = try await StickerConfiguredExport.share(document: request.document,
                    settings: request.settings, assets: request.assets, format: selectedFormat,
                    background: selectedBackground, note: { progress = $0 })
                if Task.isCancelled { try? FileManager.default.removeItem(at: result.url); return }
                output = result.url
                sharing = true
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func removeOutput() {
        if let output { try? FileManager.default.removeItem(at: output) }
        output = nil
    }
}

private struct StickerViewerShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
