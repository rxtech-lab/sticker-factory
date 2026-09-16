import AnimatedView
import SwiftUI
import UIKit

/// Prepared artwork and a real configurable document. No generation, network, or saved user
/// playback preferences are involved in trying this example.
@MainActor struct CreationDemo {
    let document: AnimatedDocument
    let images: [String: UIImage]
    static let shared: CreationDemo? = try? load()
    static var bundledOption: CreationPresetOption? {
        guard let url = Bundle.main.url(forResource: "creation-presets-preview", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let catalog = try? JSONDecoder().decode(CreationPresetCatalog.self, from: data),
            var option = catalog.groups.first?.options.first,
            let preview = option.preview?.bundled()
        else { return nil }
        option.preview = preview
        return option
    }
    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "creation-demo", withExtension: "json") else {
            throw StickerAPIError.invalidResponse
        }
        let document = try JSONDecoder().decode(AnimatedDocument.self, from: Data(contentsOf: url)).validated()
        var images: [String: UIImage] = [:]
        guard let assetURL = bundle.url(forResource: "creation-demo-assets", withExtension: "json") else {
            throw StickerAPIError.invalidResponse
        }
        let files = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: assetURL))
        for (id, name) in files {
            guard let url = bundle.url(forResource: name, withExtension: "png"),
                let image = UIImage(contentsOfFile: url.path)
            else { throw StickerAPIError.invalidResponse }
            images[id] = image
        }
        return .init(document: document, images: images)
    }
    func document(for preset: PosePreset) -> AnimatedDocument {
        var result = document
        guard var configuration = result.configuration,
            let index = configuration.controls.firstIndex(where: { $0.id == "pose" })
        else { return result }
        let options = Array((configuration.controls[index].options ?? []).prefix(preset.poseCount))
        let allowed = Set(options.map(\.id))
        configuration.controls[index].options = options
        configuration.variants.removeAll { variant in variant.selections["pose"].map { !allowed.contains($0) } ?? false }
        result.configuration = configuration
        return result
    }
}

struct CreationDemoPreview: View {
    var animated: Bool
    var body: some View {
        CreationPresetImage(
            url: Bundle.main.url(
                forResource: animated ? "creation-type-animated" : "creation-type-static",
                withExtension: animated ? "gif" : "png"), animated: animated)
            .frame(maxWidth: .infinity).frame(height: 250)
            .accessibilityLabel(
                animated ? String(localized: "Animated sticker preview") : String(localized: "Static sticker preview"))
            .accessibilityIdentifier(animated ? "creation-animated-preview" : "creation-static-preview")
            .padding(12)
            .posterSurface(cornerRadius: Poster.tileRadius, fill: AppColors.paper)
    }
}
