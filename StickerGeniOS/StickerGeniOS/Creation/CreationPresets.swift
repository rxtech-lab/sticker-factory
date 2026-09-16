import Foundation

nonisolated struct PresetText: Codable, Hashable, Sendable {
    var en: String
    var simplified: String?
    var traditional: String?
    enum CodingKeys: String, CodingKey { case en, simplified = "zh-Hans", traditional = "zh-Hant" }
    func localized(_ locale: Locale = .current) -> String {
        let language = locale.language
        guard language.languageCode?.identifier == "zh" else { return en }
        let traditionalScript =
            language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(locale.region?.identifier ?? "")
        return (traditionalScript ? traditional : simplified) ?? en
    }
}

nonisolated struct CreationPresetOption: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: PresetText
    var cover: URL
    var preview: CreationPresetPreview?
}

nonisolated struct CreationPresetPreview: Codable, Hashable, Sendable {
    struct Choice: Codable, Hashable, Identifiable, Sendable { var id: String; var title: PresetText }
    struct Variant: Codable, Hashable, Sendable { var pose: String; var mood: String; var url: URL }
    var url: URL
    var defaultPose: String
    var defaultMood: String
    var poses: [Choice]
    var moods: [Choice]
    var variants: [Variant]
    func animation(pose: String, mood: String) -> URL? {
        variants.first { $0.pose == pose && $0.mood == mood }?.url
    }
    var isValid: Bool {
        let poseIDs = Set(poses.map(\.id)); let moodIDs = Set(moods.map(\.id))
        let pairs = Set(variants.map { "\($0.pose)/\($0.mood)" })
        return (2...8).contains(poses.count) && (1...8).contains(moods.count)
            && poseIDs.count == poses.count && moodIDs.count == moods.count
            && poseIDs.contains(defaultPose) && moodIDs.contains(defaultMood)
            && pairs.count == poses.count * moods.count && pairs.count == variants.count
            && variants.allSatisfy { poseIDs.contains($0.pose) && moodIDs.contains($0.mood) }
    }
    func bundled(in bundle: Bundle = .main) -> Self? {
        var result = self
        guard let primary = bundle.url(forResource: "creation-preview-\(defaultPose)-\(defaultMood)", withExtension: "gif")
        else { return nil }
        result.url = primary
        for index in variants.indices {
            let variant = variants[index]
            guard let url = bundle.url(forResource: "creation-preview-\(variant.pose)-\(variant.mood)", withExtension: "gif")
            else { return nil }
            result.variants[index].url = url
        }
        return result
    }
    mutating func resolveURLs(relativeTo base: URL) throws {
        func resolved(_ url: URL) throws -> URL {
            guard let absolute = URL(string: url.relativeString, relativeTo: base)?.absoluteURL,
                ["https", "http"].contains(absolute.scheme ?? "")
            else { throw StickerAPIError.invalidResponse }
            return absolute
        }
        url = try resolved(url)
        for index in variants.indices { variants[index].url = try resolved(variants[index].url) }
    }
}

nonisolated struct CreationPresetGroup: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var type: String
    var title: PresetText
    var description: PresetText
    var minSelections: Int
    var maxSelections: Int
    var options: [CreationPresetOption]
    var isSupported: Bool { type == "single_choice" || type == "multiple_choice" }
    func accepts(_ ids: Set<String>) -> Bool {
        isSupported && ids.count >= minSelections && ids.count <= maxSelections
            && ids.isSubset(of: Set(options.map(\.id)))
    }
}

nonisolated struct CreationPresetCatalog: Codable, Hashable, Sendable {
    var version: String
    var groups: [CreationPresetGroup]
    var visibleGroups: [CreationPresetGroup] { groups.filter { $0.isSupported || $0.minSelections > 0 } }
    func validated() throws -> Self {
        guard !version.isEmpty, groups.count <= 20,
            Set(groups.map(\.id)).count == groups.count,
            groups.allSatisfy({ group in
                guard !group.id.isEmpty, group.minSelections >= 0 else { return false }
                // Unknown controls need only their requirement to decide skip versus app update.
                guard group.isSupported else { return true }
                return group.maxSelections >= max(1, group.minSelections)
                    && group.maxSelections <= 12 && group.maxSelections <= group.options.count
                    && (group.type != "single_choice" || group.maxSelections == 1)
                    && Set(group.options.map(\.id)).count == group.options.count
                    && group.options.allSatisfy { !$0.id.isEmpty && ($0.preview?.isValid ?? true) }
            })
        else { throw StickerAPIError.invalidResponse }
        return self
    }
}

nonisolated struct CreationPresetSubmission: Codable, Hashable, Sendable {
    struct Selection: Codable, Hashable, Sendable { var groupId: String; var optionIds: [String] }
    var catalogVersion: String
    var selections: [Selection]
}

nonisolated struct CreationPresetDisplay: Codable, Hashable, Sendable {
    struct Selection: Codable, Hashable, Identifiable, Sendable {
        var groupId: String
        var title: PresetText
        var options: [CreationPresetOption]
        var id: String { groupId }
    }
    var catalogVersion: String
    var selections: [Selection]
}

/// Navigation and choices live above individual pages, so changing steps never loses the draft.
nonisolated struct CreationWizardState {
    enum Step: Hashable { case idea, kind, catalog, preset(String), animation, overview }
    var step: Step = .idea
    var catalog: CreationPresetCatalog?
    var selections: [String: Set<String>] = [:]
    var editingOverview = false
    var animationReviewed = false
    var requiresCatalogRefresh = false

    func steps(kind: StickerKind) -> [Step] {
        [.idea, .kind] + (catalog.map { $0.visibleGroups.map { .preset($0.id) } } ?? [.catalog])
            + (kind == .animated ? [.animation] : []) + [.overview]
    }
    func valid(_ group: CreationPresetGroup) -> Bool { group.accepts(selections[group.id] ?? []) }
    var firstInvalidGroup: CreationPresetGroup? { catalog?.visibleGroups.first { !valid($0) } }
    var canSubmit: Bool { catalog != nil && !requiresCatalogRefresh && firstInvalidGroup == nil }
    var submission: CreationPresetSubmission? {
        guard let catalog, canSubmit else { return nil }
        return .init(
            catalogVersion: catalog.version,
            selections: catalog.groups.filter(\.isSupported).map { group in
                .init(
                    groupId: group.id,
                    optionIds: group.options.filter { selections[group.id, default: []].contains($0.id) }.map(\.id))
            })
    }
    mutating func toggle(_ option: String, in group: CreationPresetGroup) {
        var ids = selections[group.id] ?? []
        if ids.contains(option) {
            ids.remove(option)
        } else if group.maxSelections == 1 {
            ids = [option]
        } else if ids.count < group.maxSelections {
            ids.insert(option)
        }
        selections[group.id] = ids
    }
    mutating func apply(_ updated: CreationPresetCatalog, review: Bool, kind: StickerKind = .static) {
        catalog = updated
        selections = Dictionary(
            uniqueKeysWithValues: updated.groups.map { group in
                (group.id, (selections[group.id] ?? []).intersection(Set(group.options.map(\.id))))
            })
        requiresCatalogRefresh = false
        if review || step == .catalog {
            editingOverview = false
            step = updated.visibleGroups.first.map { .preset($0.id) } ?? (kind == .animated ? .animation : .overview)
        } else if case .preset(let id) = step, !updated.visibleGroups.contains(where: { $0.id == id }) {
            step = updated.visibleGroups.first.map { .preset($0.id) } ?? (kind == .animated ? .animation : .overview)
        }
    }
    mutating func edit(_ destination: Step) { editingOverview = true; step = destination }
    mutating func advance(kind: StickerKind) {
        if step == .animation { animationReviewed = true }
        if editingOverview {
            if let invalid = firstInvalidGroup {
                step = .preset(invalid.id)
            } else if kind == .animated && !animationReviewed {
                step = .animation
            } else {
                step = .overview; editingOverview = false
            }
            return
        }
        let all = steps(kind: kind)
        guard let index = all.firstIndex(of: step), index + 1 < all.count else { return }
        step = all[index + 1]
    }
    mutating func back(kind: StickerKind) {
        if editingOverview { step = .overview; editingOverview = false; return }
        let all = steps(kind: kind)
        guard let index = all.firstIndex(of: step), index > 0 else { return }
        step = all[index - 1]
    }
}

nonisolated extension PosePreset {
    var creationLabel: String { self == .low ? String(localized: "Min") : label }
    var poseCount: Int {
        switch self {
        case .low: 2
        case .medium: 3
        case .high: 5
        case .ultra: 8
        }
    }
}
