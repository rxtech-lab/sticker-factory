import Foundation
import Observation
import SwiftUI

nonisolated enum TutorialChapter: String, CaseIterable, Codable, Sendable {
    case `static`, animated, controllable, finish, packs, newPack = "new-pack", whatsapp, telegram
}
nonisolated struct TutorialContext: Equatable, Sendable {
    var stickerID: String?
    var packID: String?
}
nonisolated struct TutorialRequest: Identifiable, Equatable, Sendable {
    var id = UUID()
    var chapter: String?
    var step: String?
    var context = TutorialContext()
}
nonisolated enum TutorialAction: Equatable, Sendable {
    case create(animated: Bool, controllable: Bool)
    case library
    case packs(mine: Bool)
    case newPack
    case sticker(screen: String)
    case pack(destination: String)
}
nonisolated enum TutorialDeepLink: Equatable, Sendable {
    case tutorial(TutorialRequest)
    case action(TutorialAction)

    static func validSlug(_ value: String) -> Bool {
        value.count <= 80 && value.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }
    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "stickerfactory", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil,
              !parts.percentEncodedPath.lowercased().contains("%2f"),
              !parts.percentEncodedPath.lowercased().contains("%5c") else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return nil }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let path = url.path.split(separator: "/").map(String.init)
        switch parts.host?.lowercased() {
        case "tutorial":
            guard path.count <= 1, path.allSatisfy(Self.validSlug), Set(query.keys).isSubset(of: ["step"]),
                  query["step"].map(Self.validSlug) ?? true else { return nil }
            self = .tutorial(.init(chapter: path.first, step: query["step"]))
        case "open":
            switch path {
            case ["create"]:
                guard Set(query.keys).isSubset(of: ["kind", "controllable"]),
                      ["static", "animated"].contains(query["kind"] ?? "static"),
                      ["0", "1"].contains(query["controllable"] ?? "0"),
                      query["controllable"] != "1" || query["kind"] == "animated" else { return nil }
                self = .action(.create(animated: query["kind"] == "animated", controllable: query["controllable"] == "1"))
            case ["library"] where query.isEmpty: self = .action(.library)
            case ["packs"]:
                guard Set(query.keys).isSubset(of: ["tab"]), ["browse", "mine"].contains(query["tab"] ?? "browse") else { return nil }
                self = .action(.packs(mine: query["tab"] == "mine"))
            case ["packs", "new"] where query.isEmpty: self = .action(.newPack)
            case ["sticker"]:
                guard Set(query.keys) == ["action"], let screen = query["action"], ["plan", "controls", "export"].contains(screen) else { return nil }
                self = .action(.sticker(screen: screen))
            case ["pack"]:
                guard Set(query.keys) == ["action"], let destination = query["action"], ["whatsapp", "telegram"].contains(destination) else { return nil }
                self = .action(.pack(destination: destination))
            default: return nil
            }
        default: return nil
        }
    }
}
nonisolated struct TutorialProgress: Codable, Equatable, Sendable {
    var lastChapter: String?
    var lastStep: String?
    var steps: [String: String] = [:]
    var completed: [String] = []
}
@MainActor @Observable final class TutorialProgressStore {
    static let key = "winky.tutorial.progress.v1"
    private let defaults: UserDefaults
    private(set) var progress: TutorialProgress
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        progress = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(TutorialProgress.self, from: $0) } ?? .init()
    }
    func record(chapter: String, step: String, completed: Bool) {
        guard TutorialDeepLink.validSlug(chapter), TutorialDeepLink.validSlug(step),
              progress.steps[chapter] != nil || progress.steps.count < 100 else { return }
        progress.lastChapter = chapter; progress.lastStep = step; progress.steps[chapter] = step
        if completed && !progress.completed.contains(chapter) { progress.completed.append(chapter) }
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: Self.key) }
    }
}
nonisolated struct TutorialNavigation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let action: TutorialAction
    var context = TutorialContext()
}
@MainActor @Observable final class TutorialCoordinator {
    let baseURL: URL
    let store: StickerStore
    let marketplace: MarketplaceStore
    let progress = TutorialProgressStore()
    var navigation: TutorialNavigation?
    var creationRequest: TutorialNavigation?
    var packRequest: TutorialNavigation?
    var stickerRequest: TutorialNavigation?
    var selectionNotice: String?
    init(baseURL: URL, store: StickerStore, marketplace: MarketplaceStore) {
        self.store = store; self.marketplace = marketplace
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let value = ProcessInfo.processInfo.environment["TUTORIAL_BASE_URL"], let url = URL(string: value) {
            self.baseURL = url
        } else { self.baseURL = baseURL }
        #else
        self.baseURL = baseURL
        #endif
    }
    func open(_ action: TutorialAction, context: TutorialContext = .init()) {
        navigation = .init(action: action, context: context)
    }
}
extension EnvironmentValues {
    @Entry var tutorialCoordinator: TutorialCoordinator? = nil
    @Entry var tutorialContext = TutorialContext()
    @Entry var tutorialStickerScreen: String? = nil
    @Entry var tutorialMessenger: String? = nil
}
nonisolated enum TutorialCopy {
    static func text(_ value: String.LocalizationValue) -> String { String(localized: value, table: "Tutorials") }
}
nonisolated enum TutorialLocation {
    static func locale(_ languages: [String]) -> String {
        for language in languages {
            let value = language.lowercased()
            if value.hasPrefix("zh-hant") || value.hasPrefix("zh-hk") || value.hasPrefix("zh-tw") || value.hasPrefix("zh-mo") { return "zh-HK" }
            if value == "zh" || value.hasPrefix("zh-") { return "zh-CN" }
            if value == "en" || value.hasPrefix("en-") { return "en" }
        }
        return "en"
    }
    static func url(base: URL, request: TutorialRequest, progress: TutorialProgress, languages: [String] = Locale.preferredLanguages) -> URL {
        var url = base.appending(path: "tutorial").appending(path: locale(languages))
        if let chapter = request.chapter { url.append(path: chapter) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let chapter = request.chapter, let step = request.step ?? progress.steps[chapter] {
            components.queryItems = [.init(name: "step", value: step)]
        }
        return components.url!
    }
}
