import SwiftUI
import TipKit

struct ControllableCreationTip: Tip {
    var id: String { "winky.controllable.create.v1" }
    var title: Text { Text(TutorialCopy.text("Give your sticker choices")) }
    var message: Text? { Text(TutorialCopy.text("Switch this on for moods and poses you can change after generation.")) }
    var rules: [Rule] { #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 } }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    var actions: [Action] { Action(id: "tutorial", title: TutorialCopy.text("Read tutorials")) }
}
struct PoseVarietyTutorialTip: Tip {
    var id: String { "winky.controllable.variety.v1" }
    var title: Text { Text(TutorialCopy.text("More poses, more possibilities")) }
    var message: Text? { Text(TutorialCopy.text("Higher presets add poses and use more credits. Start with Medium.")) }
    var rules: [Rule] { #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 } }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    var actions: [Action] { Action(id: "tutorial", title: TutorialCopy.text("Read tutorials")) }
}
struct StickerControlsTutorialTip: Tip {
    var id: String { "winky.controllable.controls.v1" }
    var title: Text { Text(TutorialCopy.text("Make it feel just right")) }
    var message: Text? { Text(TutorialCopy.text("Try a mood or pose, adjust motion, then Apply to keep your choices.")) }
    var rules: [Rule] { #Rule(StickerOnboardingTips.$welcomeCompleted) { $0 } }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    var actions: [Action] { Action(id: "tutorial", title: TutorialCopy.text("Read tutorials")) }
}
/// Inline guidance leaves the actual controls available while the reader experiments.
struct ControllableTutorialHelp: View {
    enum Kind { case creation, variety, controls }
    let kind: Kind
    @State private var showingTutorial = false
    @State private var pendingAction: TutorialAction?
    @State private var destination: TutorialNavigation?
    @Environment(\.tutorialCoordinator) private var coordinator
    @Environment(\.tutorialContext) private var context
    var body: some View {
        Group {
            switch kind {
            case .creation: TipView(ControllableCreationTip()) { _ in showingTutorial = true }
            case .variety: TipView(PoseVarietyTutorialTip()) { _ in showingTutorial = true }
            case .controls: TipView(StickerControlsTutorialTip()) { _ in showingTutorial = true }
            }
        }
        .tipViewStyle(.miniTip)
        .sheet(item: $destination) { route in
            if let coordinator { TutorialDestinationSheet(coordinator: coordinator, route: route) }
        }
        .sheet(isPresented: $showingTutorial, onDismiss: {
            // This tip already sits on the relevant controls; returning must keep their draft alive.
            if let action = pendingAction {
                pendingAction = nil
                if case .create = action, kind == .creation || kind == .variety { return }
                if case .sticker(let screen) = action, screen == "controls", kind == .controls { return }
                destination = .init(action: action, context: context)
            }
        }) {
            if let coordinator { TutorialSheet(coordinator: coordinator, request: .init(chapter: TutorialChapter.controllable.rawValue, step: kind == .controls ? "controls" : kind == .variety ? "variety" : "enable", context: context)) { action in
                pendingAction = action; showingTutorial = false
            } }
        }
    }
}
