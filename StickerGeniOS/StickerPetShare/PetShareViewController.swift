import SwiftUI
import UIKit

final class PetShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let root = PetShareView(inputItems: extensionContext?.inputItems ?? []) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } openCreation: { [weak self] url in
            self?.openContainingApp(url) ?? false
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// Share extensions cannot use UIApplication.shared. Follow the host responder to open the
    /// containing app after the prompt has been staged in the App Group container.
    private func openContainingApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenMethod = @convention(c) (NSObject, Selector, NSURL, NSDictionary, Any?) -> Void
                let implementation = application.method(for: selector)
                let open = unsafeBitCast(implementation, to: OpenMethod.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                extensionContext?.completeRequest(returningItems: nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}

private enum PetShareOpenError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Sticker Factory couldn't open. Try again from the share sheet." }
}

private struct PetShareView: View {
    let inputItems: [Any]
    let done: () -> Void
    let openCreation: (URL) -> Bool

    @State private var payload: PetSharePayload?
    @State private var isLoading = true
    @State private var isSending = false
    @State private var isOpeningApp = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let payload {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Shared content", systemImage: "square.and.arrow.up")
                                .font(.headline)
                            Text(payload.previewTitle).font(.title3.bold())
                            Text(payload.previewText)
                                .font(.body)
                                .lineLimit(8)
                                .foregroundStyle(.secondary)
                            if let url = payload.url {
                                Text(url).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .safeAreaInset(edge: .bottom) {
                        HStack(spacing: 12) {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                Task { await send(payload) }
                            } label: {
                                Label("Send to Pet", systemImage: "paperplane.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                createSticker(from: payload)
                            } label: {
                                Label("Create Sticker", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                        .disabled(isSending || isOpeningApp)
                    }
                } else {
                    Color.clear
                }
            }
            .navigationTitle("Sticker Factory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        done()
                    }
                        .disabled(isSending || isOpeningApp)
                }
            }
            .overlay {
                if isLoading || isSending || isOpeningApp {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        ProgressView(isOpeningApp ? "Opening Sticker Factory…" : isSending ? "Sending to your pet…" : "Reading share…")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .alert("Couldn't use this share", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { if payload == nil { done() } }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                guard isLoading else { return }
                do { payload = try await PetSharePayloadLoader.load(inputItems) }
                catch {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
    }

    private func send(_ payload: PetSharePayload) async {
        isSending = true
        defer { isSending = false }
        do {
            let service = try PetShareService()
            try await service.send(payload)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            done()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            errorMessage = error.localizedDescription
        }
    }

    private func createSticker(from payload: PetSharePayload) {
        isOpeningApp = true
        do {
            let url = try SharedStickerCreationHandoff.stage(prompt: payload.creationPrompt)
            guard openCreation(url) else { throw PetShareOpenError.unavailable }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            isOpeningApp = false
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            errorMessage = error.localizedDescription
        }
    }
}
