import SwiftUI
import PhotosUI
import Observation

nonisolated struct QuickAllowance: Decodable {
    let used: Int
    let chargesPoints: Bool
    let limit: Int?
    let remaining: Int?
    let resetsAt: String?
    var resetDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
    }
}

@MainActor @Observable
final class QuickModeModel {
    var completedGeneration: UUID?
    var title = "Your sticker"
    var loadingDetail = false
    var prompt = ""
    var revision = ""
    var image: UIImage?
    var shareURL: URL?
    var busy = false
    var message = ""
    var error: String?
    var allowance: QuickAllowance?
    var stickerID: String?
    var references: [MessagesReferenceImage] = []
    private let baseURL: URL
    let appClip: Bool
    private let token: @MainActor (Bool) async throws -> String
    private let client: MessagesStickerCreationClient
    private let storagePrefix: String
    private var defaultsKey: String
    private struct PendingRequest: Codable {
        let key: String
        let stickerID: String?
        let text: String
        let referenceIDs: [String]
    }
    private var jobID: String?
    private var operationTask: Task<Void, Never>?

    init(baseURL: URL, appClip: Bool, token: @escaping @MainActor (Bool) async throws -> String) {
        self.baseURL = baseURL
        self.appClip = appClip
        self.token = token
        client = MessagesStickerCreationClient(baseURL: baseURL, transport: URLSessionStickerHTTPTransport(session: .shared), useQuickModeAllowance: appClip)
        storagePrefix = "quick-pending-\(appClip ? "clip" : "app")"
        defaultsKey = storagePrefix
    }

    func refreshAllowance() async {
        guard appClip else { return }
        do {
            allowance = try JSONDecoder().decode(QuickAllowance.self, from: await get("api/v1/app-clip/allowance"))
        } catch { self.error = error.localizedDescription }
    }

    func addPhoto(_ data: Data) {
        do { references = [try MessagesReferenceImageNormalizer.normalize(data, index: 0)] }
        catch { self.error = error.localizedDescription }
    }

    func start(revising: Bool = false) {
        guard !busy else { return }
        busy = true
        error = nil
        operationTask = Task {
            defer { busy = false; operationTask = nil }
            do {
                message = revising ? "Revising your sticker…" : "Making your sticker…"
                let accessToken = try await token(false)
                try selectStorage(accessToken)
                if revising, let stickerID {
                    try await submit(PendingRequest(key: UUID().uuidString, stickerID: stickerID, text: revision, referenceIDs: []))
                } else {
                    var ids: [String] = []
                    for reference in references {
                        let intent = try await client.createUploadIntent(reference: reference, accessToken: accessToken, idempotencyKey: UUID().uuidString)
                        try await client.upload(reference: reference, to: intent.upload)
                        try await client.completeUpload(assetID: intent.assetID, digest: intent.digest, accessToken: accessToken, idempotencyKey: UUID().uuidString)
                        ids.append(intent.assetID)
                    }
                    try await submit(PendingRequest(key: UUID().uuidString, stickerID: nil, text: prompt, referenceIDs: ids))
                }
                persist()
                try await finish()
            } catch { self.error = error.localizedDescription }
            await refreshAllowance()
        }
    }

    func resume() async {
        do { try selectStorage(try await token(false)) }
        catch { self.error = error.localizedDescription; return }
        await refreshAllowance()
        guard !busy else { return }
        let pending = UserDefaults.standard.stringArray(forKey: defaultsKey)
        let requestData = UserDefaults.standard.data(forKey: defaultsKey + "-request")
        guard pending?.count == 2 || requestData != nil else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if let requestData {
                try await submit(JSONDecoder().decode(PendingRequest.self, from: requestData))
            } else if let pending {
                stickerID = pending[0]; jobID = pending[1]
            }
            try await finish()
        }
        catch { self.error = error.localizedDescription }
        await refreshAllowance()
    }

    /// Local cache namespacing only; the server still verifies the token and authorizes all reads.
    private func selectStorage(_ accessToken: String) throws {
        let pieces = accessToken.split(separator: ".")
        guard pieces.count == 3 else { throw MessagesStickerCreationError.unauthorized }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = body["sub"] as? String, !subject.isEmpty else { throw MessagesStickerCreationError.unauthorized }
        defaultsKey = "\(storagePrefix)-\(baseURL.host ?? "")-\(subject)"
    }

    /// Save the exact request before sending it: a lost HTTP response or process restart reuses
    /// its idempotency key and uploaded assets instead of spending another daily allowance.
    private func submit(_ request: PendingRequest) async throws {
        UserDefaults.standard.set(try JSONEncoder().encode(request), forKey: defaultsKey + "-request")
        for attempt in 0...1 {
            do {
                let accessToken = try await token(attempt == 1)
                if let id = request.stickerID {
                    stickerID = id
                    jobID = try await client.revise(stickerID: id, prompt: request.text, accessToken: accessToken, idempotencyKey: request.key)
                } else {
                    let created = try await client.createSticker(kind: .staticSticker, prompt: request.text, referenceAssetIDs: request.referenceIDs, accessToken: accessToken, idempotencyKey: request.key)
                    stickerID = created.stickerID; jobID = created.jobID
                }
                persist()
                UserDefaults.standard.removeObject(forKey: defaultsKey + "-request")
                return
            } catch MessagesStickerCreationError.unauthorized where attempt == 0 { continue }
        }
        throw MessagesStickerCreationError.unauthorized
    }

    private func persist() {
        if let stickerID, let jobID { UserDefaults.standard.set([stickerID, jobID], forKey: defaultsKey) }
    }

    private func watch(_ id: String) async throws {
        let watcher = MessagesJobWatcher(baseURL: baseURL)
        let outcome = try await watcher.watch(jobID: id, accessToken: token(false)) { _ in }
        switch outcome {
        case .succeeded: break
        case .failed(let reason):
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            throw MessagesStickerCreationError.notPublished(reason)
        case .cancelled:
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            throw CancellationError()
        }
    }

    func openSticker(_ id: String) async {
        guard !busy else { return }
        loadingDetail = true
        image = nil
        shareURL = nil
        error = nil
        stickerID = id
        defer { loadingDetail = false }
        do {
            let snapshot = try await client.fetchSticker(stickerID: id, accessToken: token(false))
            try await loadResult(snapshot)
        } catch { self.error = error.localizedDescription }
        await refreshAllowance()
    }

    private func finish() async throws {
        guard let stickerID, let jobID else { return }
        message = "Making your sticker…"
        try await watch(jobID)
        var snapshot = try await client.fetchSticker(stickerID: stickerID, accessToken: token(false))
        // App Clip publication belongs to its generation job; normal app quick mode uses paid publish.
        if !appClip && (!snapshot.isPublished || snapshot.displayRevision?.candidateState == "candidate") {
            message = "Preparing your sticker to share…"
            let publishJob = try await client.publish(stickerID: stickerID, accessToken: token(false), idempotencyKey: "quick-publish-\(jobID)")
            self.jobID = publishJob; persist()
            try await watch(publishJob)
            snapshot = try await client.fetchSticker(stickerID: stickerID, accessToken: token(false))
        }
        try await loadResult(snapshot)
        revision = ""
        message = "Ready to share"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        completedGeneration = UUID()
    }

    private func loadResult(_ snapshot: MessagesStickerSnapshot) async throws {
        guard snapshot.isPublished, let assetID = snapshot.displayRevision?.previewAssetID else {
            throw MessagesStickerCreationError.invalidResponse
        }
        struct Download: Decodable { let url: URL }
        let download = try JSONDecoder().decode(Download.self, from: await get("api/v1/assets/\(assetID)/download"))
        guard download.url.scheme == "https" else { throw MessagesStickerCreationError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(from: download.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 12 * 1024 * 1024,
              let result = UIImage(data: data), let png = result.pngData() else { throw MessagesStickerCreationError.invalidResponse }
        title = snapshot.title
        image = result
        let file = FileManager.default.temporaryDirectory.appending(path: "sticker-\(snapshot.stickerID).png")
        try png.write(to: file, options: .atomic)
        shareURL = file
    }

    func get(_ path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw MessagesStickerCreationError.invalidResponse }
        for attempt in 0...1 {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer \(try await token(attempt == 1))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MessagesStickerCreationError.invalidResponse }
            if http.statusCode == 401 && attempt == 0 { continue }
            guard (200..<300).contains(http.statusCode) else {
                struct Failure: Decodable { struct Body: Decodable { let message: String }; let error: Body }
                throw MessagesStickerCreationError.server(statusCode: http.statusCode, message: (try? JSONDecoder().decode(Failure.self, from: data))?.error.message)
            }
            return data
        }
        throw MessagesStickerCreationError.unauthorized
    }
}

struct QuickModeView: View {
    enum Presentation { case standalone, composer, detail }
    @State var model: QuickModeModel
    var presentation: Presentation = .standalone
    @State private var photo: PhotosPickerItem?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if presentation == .standalone { introduction }
                    if presentation != .detail { allowanceCard }
                    if presentation != .composer, let image = model.image { resultCard(image) }
                    if model.loadingDetail { PosterProgress(message: "Loading your sticker…") }
                    if presentation != .detail { composer.disabled(model.busy) }
                    if model.busy {
                        PosterProgress(message: model.message)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("quick-progress")
                    }
                    if let error = model.error {
                        ErrorBanner(message: error).accessibilityIdentifier("quick-error")
                        Button { Task {
                            if presentation == .detail, !model.busy, let id = model.stickerID, model.image == nil {
                                await model.openSticker(id)
                            } else { await model.resume() }
                        } } label: {
                            Label("Try again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.posterSecondary)
                        .disabled(model.busy)
                    }
                    if model.appClip {
                        Link(destination: StickerShareRoute.appStoreURL) {
                            Label("Get the full app", systemImage: "arrow.up.right")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppColors.ink)
                    }
                }
                .padding(24)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(AppColors.ink)
        .navigationTitle(presentation == .detail ? model.title : presentation == .composer ? "New sticker" : "Quick mode")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(presentation == .detail && model.busy)
        .task {
            if presentation == .standalone { await model.resume() }
            else if presentation == .composer { await model.refreshAllowance() }
        }
        .task(id: model.allowance?.resetsAt) {
            guard let reset = model.allowance?.resetDate else { return }
            let delay = max(1, reset.timeIntervalSinceNow + 1)
            do { try await Task.sleep(for: .seconds(delay)); await model.refreshAllowance() }
            catch { /* The view closed or the server supplied a new reset time. */ }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refreshAllowance() } } }
        .onChange(of: photo) { _, value in Task { if let data = try? await value?.loadTransferable(type: Data.self) { model.addPhoto(data) } } }
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Make a sticker")
                    .font(.posterDisplay(30, weight: .heavy))
                    .tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)
                Text("Dream it up. We'll sticker it.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StickerBlobIcon(icon: PosterIcon.mark, fill: AppColors.lime)
                .frame(width: 62, height: 64)
        }
    }

    private var allowanceCard: some View {
        PosterCard(fill: model.appClip && exhausted ? AppColors.peach : AppColors.mint, shadow: Poster.smallShadow) {
            VStack(alignment: .leading, spacing: 8) {
                if model.appClip {
                    if let allowance = model.allowance {
                        if let remaining = allowance.remaining {
                            Text("\(remaining) generations remaining").font(.headline)
                        } else {
                            Text("Unlimited generations").font(.headline)
                        }
                        if let limit = allowance.limit {
                            Text("Plan allowance: \(limit) generations").font(.caption)
                        }
                        if let date = allowance.resetDate {
                            Text("Resets \(date, style: .relative)").font(.caption)
                        }
                        if allowance.remaining == 0 {
                            Text("More ideas? Come back after your allowance resets.")
                                .font(.subheadline)
                        }
                    } else {
                        Text("Checking your allowance…").font(.headline)
                    }
                    if let allowance = model.allowance {
                        Text(allowance.chargesPoints
                            ? "Starting a generation or revision uses one allowance. Points are charged on success."
                            : "Starting a generation or revision uses one allowance.").font(.caption)
                    }
                } else {
                    Label("Quick generation uses your points.", systemImage: "bolt.fill")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        PosterCard(padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                Text(presentation == .composer || model.image == nil ? "Your idea" : "Make another sticker")
                    .font(.title3.weight(.heavy))
                    .accessibilityAddTraits(.isHeader)
                TextField("Describe your sticker", text: $model.prompt, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(16)
                    .posterSurface(cornerRadius: 16, fill: AppColors.paper, offset: .zero)
                    .accessibilityIdentifier("quick-prompt")
                Text("Try “a happy cat riding a skateboard”")
                    .font(.footnote)
                    .foregroundStyle(AppColors.muted)
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Reference photo", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.posterSecondary)
                if let reference = model.references.first, let image = UIImage(data: reference.data) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(uiImage: image).resizable().scaledToFit().frame(height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Reference photo")
                        Button("Remove photo", systemImage: "xmark.circle") {
                            model.references = []; photo = nil
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                    }
                }
                Button { model.start() } label: {
                    Label("Generate sticker", systemImage: "wand.and.stars")
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.poster)
                .disabled(model.busy || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || exhausted)
            }
        }
    }

    private func resultCard(_ image: UIImage) -> some View {
        PosterCard(padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                Text(presentation == .detail ? model.title : "Your sticker, fresh off the press")
                    .font(.title3.weight(.heavy))
                    .accessibilityAddTraits(.isHeader)
                Image(uiImage: image)
                    .resizable().scaledToFit().frame(maxHeight: 280)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .posterSurface(cornerRadius: 18, fill: AppColors.sky.opacity(0.25), offset: .zero)
                    .accessibilityLabel("Generated sticker")
                if let url = model.shareURL {
                    ShareLink(item: url) {
                        Label("Share sticker", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.posterLime)
                }
                if presentation == .detail { allowanceCard }
                TextField("Describe a change", text: $model.revision, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(16)
                    .posterSurface(cornerRadius: 16, fill: AppColors.paper, offset: .zero)
                Button { model.start(revising: true) } label: {
                    Label("Revise", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.posterSecondary)
                .disabled(model.busy || model.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || exhausted)
            }
        }
    }

    private var exhausted: Bool { model.appClip && (model.allowance == nil || model.allowance?.remaining == 0) }
}
