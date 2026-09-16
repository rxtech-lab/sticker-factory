import Foundation

nonisolated enum MockCreationPresetCatalog {
    static func load(changed: Bool) throws -> CreationPresetCatalog {
        guard let url = Bundle.main.url(forResource: "creation-presets-preview", withExtension: "json") else {
            throw StickerAPIError.invalidResponse
        }
        var catalog = try JSONDecoder().decode(CreationPresetCatalog.self, from: Data(contentsOf: url)).validated()
        if changed {
            catalog.version += ".updated"
            catalog.groups[0].options.removeAll { $0.id == "clay" }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-creation-future-group") {
            var group = catalog.groups[1]
            group.id = "occasion"; group.title = .init(en: "Occasion")
            group.description = .init(en: "Choose an occasion")
            group.minSelections = 0; group.maxSelections = 1
            catalog.groups.append(group)
        }
        let base = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-creation-covers=") })
            .flatMap { URL(string: String($0.dropFirst("--ui-creation-covers=".count))) }
        for g in catalog.groups.indices {
            for o in catalog.groups[g].options.indices {
                if let base {
                    catalog.groups[g].options[o].cover =
                        URL(string: catalog.groups[g].options[o].cover.relativeString, relativeTo: base)!.absoluteURL
                    try catalog.groups[g].options[o].preview?.resolveURLs(relativeTo: base)
                } else if let example = Bundle.main.url(forResource: "creation-cat-happy", withExtension: "png") {
                    catalog.groups[g].options[o].cover = example
                    if let preview = catalog.groups[g].options[o].preview {
                        guard let bundled = preview.bundled() else { throw StickerAPIError.invalidResponse }
                        catalog.groups[g].options[o].preview = bundled
                    }
                }
            }
        }
        return catalog
    }
}
