import SwiftUI

/// Decorations stay outside the unmodified simulator capture. Only explicit Play loads motion.
struct TutorialMediaView: View {
    let block: TutorialDocument.Block
    let number: Int
    let document: TutorialDocument
    let baseURL: URL
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || (ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--reduce-motion")) }
    @Environment(\.scenePhase) private var scenePhase
    @State private var poster: UIImage?
    @State private var animation: StickerAnimation?
    @State private var playing = false
    @State private var failed = false
    @State private var retry = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)").font(.title3.bold()).padding(10).background(AppColors.lime, in: Circle()).accessibilityHidden(true)
                Text(block.caption ?? "").font(.headline)
                Spacer(minLength: 0)
                Image(systemName: "sparkles").foregroundStyle(AppColors.coral).accessibilityHidden(true)
            }
            if failed {
                VStack(spacing: 12) {
                    Text(document.copy("mediaError"))
                    Button(document.copy("retry")) { failed = false; retry = UUID() }
                }.frame(maxWidth: .infinity).padding()
            } else if let poster {
                Group {
                    if playing, !reduceMotion, scenePhase == .active, let animation { AnimatedStickerImage(animation: animation) }
                    else { Image(uiImage: poster).resizable().scaledToFit() }
                }
                .aspectRatio(poster.size.width / poster.size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(AppColors.ink, lineWidth: 2) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(block.caption ?? "")
                .accessibilityAddTraits(.isImage)
            } else { ProgressView().frame(maxWidth: .infinity).frame(height: 200) }
            if block.animation != nil, !reduceMotion {
                Button { playing.toggle() } label: {
                    Label(document.copy(playing ? "pause" : "play"), systemImage: playing ? "pause.fill" : "play.fill")
                }.buttonStyle(.poster).accessibilityIdentifier("tutorial-play-demo")
            }
        }
        .padding(16).posterSurface(fill: AppColors.card)
        .task(id: retry) { await loadPoster() }
        .task(id: playing) { if playing { await loadAnimation() } }
        .onChange(of: reduceMotion) { if reduceMotion { playing = false; animation = nil } }
        .onDisappear { playing = false; animation = nil }
    }
    private func mediaURL(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/tutorial/media/") else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
    private func loadPoster() async {
        guard let url = mediaURL(block.poster) else { failed = true; return }
        do {
            let data = try await TutorialContentClient(baseURL: baseURL).data(url: url, limit: 4 * 1024 * 1024, mimeType: "image/webp")
            guard let image = UIImage(data: data) else { throw TutorialContentError.invalid }
            try Task.checkCancellation(); poster = image; failed = false
        } catch { if !Task.isCancelled { failed = true } }
    }
    private func loadAnimation() async {
        guard animation == nil, !reduceMotion, let url = mediaURL(block.animation) else { return }
        do {
            let data = try await TutorialContentClient(baseURL: baseURL).data(url: url, limit: 12 * 1024 * 1024, mimeType: "image/webp")
            let decoded = await Task.detached(priority: .userInitiated) {
                StickerAnimationDecoder.decode(data, id: url.absoluteString, maxPixelSize: 960, byteBudget: 48 * 1024 * 1024)
            }.value
            try Task.checkCancellation()
            guard let decoded else { throw TutorialContentError.invalid }
            animation = decoded
        } catch { if !Task.isCancelled { playing = false; failed = true } }
    }
}
