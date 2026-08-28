import SwiftUI

private struct StickerRenameAlertModifier: ViewModifier {
    @Bindable var store: StickerStore
    let stickerID: String
    let currentTitle: String
    @Binding var isPresented: Bool
    @Binding var title: String

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func body(content: Content) -> some View {
        content
            .alert("Rename sticker", isPresented: $isPresented) {
                TextField("Sticker name", text: $title)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("rename-sticker-title-field")
                Button("Rename") {
                    let submittedTitle = trimmedTitle
                    Task {
                        if await store.rename(stickerID: stickerID, title: submittedTitle) {
                            Haptics.success()
                        } else {
                            Haptics.failure()
                        }
                    }
                }
                .disabled(trimmedTitle.isEmpty || trimmedTitle == currentTitle)
                .accessibilityIdentifier("confirm-rename-sticker")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose the name shown in your Library and sticker detail.")
            }
            .onChange(of: title) { _, value in
                if value.count > 100 { title = String(value.prefix(100)) }
            }
    }
}

extension View {
    func stickerRenameAlert(
        store: StickerStore,
        stickerID: String,
        currentTitle: String,
        isPresented: Binding<Bool>,
        title: Binding<String>
    ) -> some View {
        modifier(StickerRenameAlertModifier(
            store: store,
            stickerID: stickerID,
            currentTitle: currentTitle,
            isPresented: isPresented,
            title: title
        ))
    }
}
