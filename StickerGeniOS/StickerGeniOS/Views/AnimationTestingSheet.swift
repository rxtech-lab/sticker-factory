import AnimatedView
import SwiftUI

nonisolated struct AnimationTestingSettings: Codable, Sendable { var engine: ControllableEngineID }
nonisolated struct PetSceneResponse: Codable, Sendable { var artKey: String; var scene: SVGSceneDocument? }

struct AnimationTestingSheet: View {
    let api: any StickerAPIClientProtocol
    @Environment(\.dismiss) private var dismiss
    @State private var engine: ControllableEngineID = .svg
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Animation engine", selection: $engine) {
                        Text("SVG").tag(ControllableEngineID.svg)
                        Text("Legacy").tag(ControllableEngineID.legacy)
                    }
                    .disabled(loading)
                    .onChange(of: engine) { _, _ in if !loading { Haptics.tap(.light) } }
                } footer: {
                    Text("Applies to newly generated controllable stickers, rooms, and places. Existing artwork keeps its engine.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Animation Testing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Haptics.tap(.light); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        Haptics.tap(.medium); loading = true
                        Task {
                            do {
                                try await api.setAnimationEngine(engine)
                                Haptics.success()
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                                loading = false
                                Haptics.failure()
                            }
                        }
                    }.disabled(loading)
                }
            }
            .task {
                do { engine = try await api.animationEngine() } catch { self.error = error.localizedDescription }
                loading = false
            }
        }
    }
}
