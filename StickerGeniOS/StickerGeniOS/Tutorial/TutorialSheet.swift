import SwiftUI
import UIKit

/// A local presenter keeps the form underneath alive, including all unsaved fields and photos.
struct TutorialButton: View {
    var chapter: TutorialChapter?
    var step: String?
    var title: String = TutorialCopy.text("Read tutorials")
    var onAction: ((TutorialAction) -> Bool)?
    @Environment(\.tutorialCoordinator) private var coordinator
    @Environment(\.tutorialContext) private var context
    @State private var request: TutorialRequest?
    @State private var pendingAction: TutorialAction?
    @State private var destination: TutorialNavigation?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // An active presentation owns its request until it is explicitly closed.
                guard request == nil, destination == nil else { return }
                request = .init(chapter: chapter?.rawValue, step: step, context: context)
            } label: {
                Label(title, systemImage: "book.closed")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("tutorial-link-\(chapter?.rawValue ?? "index")")
        }
        .sheet(item: $destination) { route in
            if let coordinator { TutorialDestinationSheet(coordinator: coordinator, route: route) }
        }
        .sheet(item: $request, onDismiss: {
            guard let action = pendingAction else { return }
            pendingAction = nil
            if onAction?(action) != true { destination = .init(action: action, context: context) }
        }, content: { request in
            if let coordinator {
                TutorialSheet(coordinator: coordinator, request: request) { action in
                    pendingAction = action; self.request = nil
                }
            }
        })
    }
}
/// How much of the current lesson is still below the fold, measured from the reader's scroll view.
nonisolated struct TutorialScrollMetrics: Equatable, Sendable {
    var offset: CGFloat = 0
    var visible: CGFloat = 0
    var remaining: CGFloat = 0
    /// The whole distance this step can travel, which is what the paging step is divided out of.
    var scrollable: CGFloat = 0
    /// Content shorter than the viewport reports a negative remainder, which also counts as read.
    var isAtBottom: Bool { remaining <= 1 }
    init() {}
    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        visible = geometry.visibleRect.height
        remaining = geometry.contentSize.height - geometry.visibleRect.maxY
        scrollable = geometry.contentSize.height - geometry.visibleRect.height
    }
}

/// Native reader; no HTML, JavaScript, browser or web-to-native bridge.
struct TutorialSheet: View {
    let coordinator: TutorialCoordinator
    let request: TutorialRequest
    var onAction: (TutorialAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var document: TutorialDocument?
    @State private var chapterID: String?
    @State private var stepID: String?
    @State private var locale = TutorialLocation.locale(Locale.preferredLanguages)
    @State private var hasOpened = false
    @State private var failed = false
    @State private var reloadID = UUID()
    @State private var completionNotice: UUID?
    @State private var loadedContentKey: String?
    @State private var isLanguageMenuPresented = false
    @State private var isChapterMenuPresented = false
    @State private var navigationFooterHeight: CGFloat = 0
    @State private var scroll = TutorialScrollMetrics()
    @State private var scrollPosition = ScrollPosition()
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AccessibilityFocusState private var headingFocused: Bool
    private var isDropdownPresented: Bool { isLanguageMenuPresented || isChapterMenuPresented }
    private var reduceMotion: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return systemReduceMotion || (arguments.contains("--ui-testing") && arguments.contains("--reduce-motion"))
    }
    private var contentKey: String { "\(locale)/\(reloadID)" }
    private var chapter: TutorialDocument.Chapter? { document?.chapters.first { $0.id == chapterID } }
    private var step: TutorialDocument.Step? { chapter?.steps.first { $0.id == stepID } }
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ZStack {
                    PosterPaper()
                    if failed { unavailable } else if let document {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                if let chapter, let step { chapterView(chapter, step: step, document: document) } else { index(document) }
                            }
                            .padding(20)
                            .frame(maxWidth: 640)
                            .frame(maxWidth: .infinity)
                        }
                        .scrollPosition($scrollPosition)
                        .contentMargins(.bottom, chapter != nil && step != nil ? navigationFooterHeight : 0)
                        .onScrollGeometryChange(for: TutorialScrollMetrics.self) {
                            TutorialScrollMetrics($0)
                        } action: { _, value in
                            scroll = value
                        }
                        .onChange(of: stepID) { scrollToTop() }
                        .onChange(of: chapterID) { scrollToTop() }
                        .accessibilityIdentifier("tutorial-native-content")
                        .accessibilityHidden(isDropdownPresented)
                    } else { PosterProgress(message: TutorialCopy.text("Loading tutorials…")) }
                }
                if !failed, let document, let chapter, let step {
                    navigationFooter(chapter, step: step, document: document)
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.size.height
                        } action: { height in
                            navigationFooterHeight = height
                        }
                        .disabled(isDropdownPresented)
                        .accessibilityHidden(isDropdownPresented)
                }
            }
            .overlay(alignment: .top) {
                if completionNotice != nil, let document {
                    Label(document.copy("completed"), systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .padding(16)
                        .frame(maxWidth: 600)
                        .posterSurface(fill: AppColors.lime)
                        .padding(20)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("tutorial-completion-banner")
                }
            }
            .overlay {
                if isDropdownPresented {
                    GeometryReader { geometry in
                        ZStack(alignment: isLanguageMenuPresented ? .topTrailing : .topLeading) {
                            // Consume outside taps so they cannot activate the lesson underneath.
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture { closeDropdowns() }
                                .accessibilityHidden(true)
                            if isLanguageMenuPresented {
                                TutorialLanguageMenu(
                                    selectedLanguage: locale,
                                    accessibilityTitle: document?.copy("language") ?? TutorialCopy.text("Language"),
                                    onSelect: selectLanguage,
                                    onClose: closeDropdowns
                                )
                                .padding(.top, 8)
                                .padding(.trailing, 16)
                            } else if let document {
                                TutorialChapterMenu(
                                    document: document,
                                    selectedChapter: chapterID,
                                    completedChapters: coordinator.progress.progress.completed,
                                    onSelect: { chapter in
                                        closeDropdowns()
                                        Haptics.selection()
                                        open(chapter)
                                    },
                                    onClose: closeDropdowns
                                )
                                .frame(width: min(360, max(0, geometry.size.width - 32)),
                                       height: min(480, max(0, geometry.size.height - 24)))
                                .padding(.top, 8)
                                .padding(.leading, 16)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(AppColors.ink)
            .fontDesign(.rounded)
            .navigationTitle(document?.copy("title") ?? TutorialCopy.text("Tutorials"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TutorialCopy.text("Close")) { dismiss() }.accessibilityIdentifier("tutorial-close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap(.light)
                        isChapterMenuPresented = false
                        isLanguageMenuPresented.toggle()
                    } label: {
                        Image(systemName: "globe").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(document?.copy("language") ?? TutorialCopy.text("Language"))
                    .accessibilityValue(TutorialLanguageMenu.title(for: locale))
                    .accessibilityIdentifier("tutorial-language")
                }
            }
        }
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .task(id: contentKey) { await load() }
        .task(id: completionNotice) {
            guard completionNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            completionNotice = nil
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
        .accessibilityIdentifier("tutorial-sheet")
    }
    private var unavailable: some View {
        ContentUnavailableView {
            Label(TutorialCopy.text("Tutorials unavailable"), systemImage: "wifi.exclamationmark")
        } description: {
            Text(TutorialCopy.text("Connect to the internet and try again. Your reading progress is saved."))
        } actions: {
            Button(TutorialCopy.text("Retry")) { reloadID = UUID() }
                .buttonStyle(.poster).accessibilityIdentifier("tutorial-retry")
        }
    }
    @ViewBuilder private func index(_ document: TutorialDocument) -> some View {
        Image("FeatureTutorial").resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 150).accessibilityHidden(true)
        Text(document.copy("intro")).font(.title2.bold()).accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
        if let last = coordinator.progress.progress.lastChapter,
           let chapter = document.chapters.first(where: { $0.id == last }) {
            Button { open(chapter) } label: {
                Label(document.copy("resume"), systemImage: "book.pages")
            }.buttonStyle(.poster).accessibilityIdentifier("tutorial-continue")
        }
        ForEach(document.sections) { section in
            VStack(alignment: .leading, spacing: 12) {
                Text(section.title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                ForEach(document.chapters.filter { $0.section == section.id }) { chapter in
                    Button { open(chapter) } label: {
                        HStack(spacing: 12) {
                            Text(chapter.title).font(.headline).multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            if coordinator.progress.progress.completed.contains(chapter.id) {
                                Image(systemName: "checkmark.circle.fill").accessibilityLabel(document.copy("completed"))
                            } else { Image(systemName: "chevron.right").accessibilityHidden(true) }
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading).posterSurface()
                    }.buttonStyle(.plain).accessibilityIdentifier("tutorial-chapter-\(chapter.id)")
                }
            }
        }
    }
    @ViewBuilder private func chapterView(_ chapter: TutorialDocument.Chapter, step: TutorialDocument.Step, document: TutorialDocument) -> some View {
        let position = chapter.steps.firstIndex { $0.id == step.id } ?? 0
        HStack {
            Button(action: toggleChapterMenu) {
                Label(document.copy("index"), systemImage: "list.bullet")
            }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tutorial-index")
            Spacer()
            Menu {
                ForEach(chapter.steps) { step in Button(step.title) { select(chapter, step: step) } }
            } label: { Label("\(position + 1) / \(chapter.steps.count)", systemImage: "list.number") }
            .accessibilityLabel("\(document.copy("step")) \(position + 1) \(document.copy("of")) \(chapter.steps.count)")
        }.font(.callout.bold())
        VStack(alignment: .leading, spacing: 12) {
            Text(chapter.title).font(.subheadline.bold()).foregroundStyle(AppColors.muted)
            Text(step.title).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused).accessibilityIdentifier("tutorial-step-title")
            ProgressView(value: Double(position + 1), total: Double(chapter.steps.count)).tint(AppColors.ink)
                .accessibilityLabel(document.copy("step"))
                .accessibilityValue("\(position + 1) / \(chapter.steps.count)")
        }
        ForEach(Array(step.blocks.enumerated()), id: \.offset) { offset, block in
            blockView(block, number: position + 1, document: document).id("\(chapter.id)/\(step.id)/\(offset)")
        }
        Button { perform(step.action) } label: { Label(document.copy("tryIt"), systemImage: "arrow.up.forward.app") }
            .buttonStyle(.poster).accessibilityIdentifier("tutorial-try-it")
    }
    /// A full-width glass surface sits at the bottom of the reader's ZStack.
    /// Only the background extends below the safe area; buttons stay above the home indicator.
    private func navigationFooter(_ chapter: TutorialDocument.Chapter, step: TutorialDocument.Step, document: TutorialDocument) -> some View {
        let position = chapter.steps.firstIndex { $0.id == step.id } ?? 0
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { navigationButtons(chapter, position: position, document: document) }
                .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 12) { navigationButtons(chapter, position: position, document: document) }
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background {
            Color.clear
                .glassEffect(.regular, in: Rectangle())
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityIdentifier("tutorial-navigation-footer")
    }
    @ViewBuilder private func navigationButtons(_ chapter: TutorialDocument.Chapter, position: Int, document: TutorialDocument) -> some View {
        let isLast = position == chapter.steps.count - 1
        let finished = isLast && coordinator.progress.progress.completed.contains(chapter.id)
        let chapterPosition = document.chapters.firstIndex { $0.id == chapter.id } ?? 0
        let nextChapter = document.chapters.dropFirst(chapterPosition + 1).first
        // A step that still has text below the fold cannot be left yet: the primary button pages
        // down through the rest of the lesson first, and only then offers the forward action.
        let unread = !scroll.isAtBottom
        let label = !isLast ? "next" : !finished ? "done" : nextChapter != nil ? "nextChapter" : "index"
        let title = unread ? document.copy("scrollDown", fallback: TutorialCopy.text("Scroll down")) : document.copy(label)
        let symbol = unread ? "chevron.down"
            : !isLast ? "chevron.right"
            : !finished ? "checkmark"
            : nextChapter != nil ? "arrow.right" : "list.bullet"
        Button { select(chapter, step: chapter.steps[position - 1]) } label: { Label(document.copy("back"), systemImage: "chevron.left") }
            .buttonStyle(.poster).disabled(position == 0).accessibilityIdentifier("tutorial-back")
        Button {
            if unread { scrollDown() } else if !isLast { select(chapter, step: chapter.steps[position + 1]) } else if finished {
                completionNotice = nil
                if let nextChapter { select(nextChapter, step: nextChapter.steps[0]) } else { toggleChapterMenu() }
            } else {
                coordinator.progress.record(chapter: chapter.id, step: chapter.steps[position].id, completed: true)
                Haptics.success()
                completionNotice = UUID()
                UIAccessibility.post(notification: .announcement, argument: document.copy("completed"))
            }
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.poster)
        .accessibilityIdentifier(
            unread ? "tutorial-scroll-down"
                : finished ? (nextChapter != nil ? "tutorial-next-chapter" : "tutorial-all-chapters")
                : "tutorial-next"
        )
    }
    /// Two thirds of the step's travel per tap, so a short overhang clears in one or two and a long
    /// one in a handful. The cap keeps the longest steps short of a full screen, which reads as a
    /// jump rather than a scroll.
    private func scrollDown() {
        let distance = min(max(scroll.scrollable * 2 / 3, 200), scroll.visible * 0.65)
        let target = scroll.offset + distance
        if reduceMotion {
            scrollPosition.scrollTo(y: target)
        } else {
            withAnimation(.easeOut(duration: 0.3)) { scrollPosition.scrollTo(y: target) }
        }
    }
    private func scrollToTop() {
        scrollPosition.scrollTo(edge: .top)
        headingFocused = true
    }
    private func closeDropdowns() {
        isLanguageMenuPresented = false
        isChapterMenuPresented = false
    }
    private func toggleChapterMenu() {
        Haptics.tap(.light)
        completionNotice = nil
        isLanguageMenuPresented = false
        isChapterMenuPresented.toggle()
    }
    private func selectLanguage(_ code: String) {
        closeDropdowns()
        guard locale != code else { return }
        Haptics.selection()
        completionNotice = nil
        locale = code
    }
    @ViewBuilder private func blockView(_ block: TutorialDocument.Block, number: Int, document: TutorialDocument) -> some View {
        switch block.type {
        case .paragraph: richText(block.text ?? "").font(.body).lineSpacing(4)
        case .heading: richText(block.text ?? "").font(.title3.bold()).accessibilityAddTraits(.isHeader)
        case .callout:
            HStack(alignment: .top) {
                Image(systemName: "lightbulb").accessibilityHidden(true)
                richText(block.text ?? "")
            }.padding(18).posterSurface(fill: AppColors.lime)
        case .list:
            ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top) { Text(block.ordered == true ? "\(index + 1)." : "•"); richText(item) }
            }
        case .media:
            TutorialMediaView(block: block, number: number, document: document, baseURL: coordinator.baseURL)
        case .action:
            Button { if let url = block.url { perform(url) } } label: {
                Label(block.title ?? "", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.poster)
        }
    }
    private func richText(_ value: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: value, options: options)) ?? AttributedString(value))
    }
    private func open(_ chapter: TutorialDocument.Chapter) {
        let saved = coordinator.progress.progress.steps[chapter.id]
        select(chapter, step: chapter.steps.first { $0.id == saved } ?? chapter.steps[0])
    }
    private func select(_ chapter: TutorialDocument.Chapter, step: TutorialDocument.Step) {
        chapterID = chapter.id; stepID = step.id
        coordinator.progress.record(chapter: chapter.id, step: step.id, completed: false)
    }
    private func perform(_ value: String) {
        guard let url = URL(string: value), case .action(let action) = TutorialDeepLink(url: url) else { return }
        if let chapter, let step { coordinator.progress.record(chapter: chapter.id, step: step.id, completed: false) }
        onAction(action)
    }
    private func load() async {
        let key = contentKey
        // A menu closing or a view reappearing must not restart a successful content load.
        guard loadedContentKey != key || document == nil else { return }
        failed = false; document = nil
        do {
            let loaded = try await TutorialContentClient(baseURL: coordinator.baseURL).document(locale: locale)
            try Task.checkCancellation()
            guard contentKey == key else { return }
            if !hasOpened { chapterID = request.chapter; stepID = request.step }
            if let id = chapterID {
                guard let chapter = loaded.chapters.first(where: { $0.id == id }) else { throw TutorialContentError.invalid }
                if let explicit = stepID, !chapter.steps.contains(where: { $0.id == explicit }) { throw TutorialContentError.invalid }
                let saved = coordinator.progress.progress.steps[id]
                let step = chapter.steps.first { $0.id == stepID } ?? chapter.steps.first { $0.id == saved } ?? chapter.steps[0]
                select(chapter, step: step)
            } else if stepID != nil { throw TutorialContentError.invalid }
            document = loaded; hasOpened = true; loadedContentKey = key
        } catch is CancellationError { } catch { if !Task.isCancelled { failed = true } }
    }
}

struct TutorialDestinationSheet: View {
    let coordinator: TutorialCoordinator
    let route: TutorialNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var createdStickerID: String?
    @State private var createdPackID: String?
    var body: some View {
        Group {
            switch route.action {
            case .create(let animated, let controllable):
                NavigationStack {
                    CreateStickerView(
                        store: coordinator.store,
                        onCreated: { createdStickerID = $0.id },
                        tutorialMode: .create(animated: animated, controllable: controllable)
                    )
                    .navigationDestination(item: $createdStickerID) { StickerChatView(store: coordinator.store, stickerID: $0) }
                    .toolbar { closeButton }
                }
            case .newPack:
                NavigationStack {
                    PackComposerView(store: coordinator.marketplace, onCreated: { createdPackID = $0.id })
                        .navigationDestination(item: $createdPackID) { PackDetailView(store: coordinator.marketplace, packID: $0) }
                        .toolbar { closeButton }
                }
            case .packs(let mine):
                MarketplaceView(store: coordinator.marketplace, tutorialStartsInMyPacks: mine, onTutorialClose: { dismiss() })
            case .pack(let messenger):
                if let id = route.context.packID {
                    NavigationStack { PackDetailView(store: coordinator.marketplace, packID: id).toolbar { closeButton } }
                        .environment(\.tutorialMessenger, messenger)
                } else {
                    MarketplaceView(store: coordinator.marketplace, tutorialStartsInMyPacks: true, onTutorialClose: { dismiss() })
                        .environment(\.tutorialMessenger, messenger)
                        .safeAreaInset(edge: .top) {
                            Text(TutorialCopy.text("Choose a pack to try this feature."))
                                .font(.callout)
                                .padding(10)
                                .frame(maxWidth: .infinity)
                                .background(AppColors.lime)
                        }
                }
            case .sticker(let screen):
                if let id = route.context.stickerID {
                    NavigationStack { StickerChatView(store: coordinator.store, stickerID: id).toolbar { closeButton } }
                        .environment(\.tutorialStickerScreen, screen)
                } else { library(screen: screen) }
            case .library: library(screen: nil)
            }
        }
        .environment(\.tutorialCoordinator, coordinator)
        .accessibilityIdentifier("tutorial-feature-sheet")
    }
    private func library(screen: String?) -> some View {
        NavigationStack {
            LibraryView(store: coordinator.store, marketplace: coordinator.marketplace)
                .safeAreaInset(edge: .top) {
                    Text(TutorialCopy.text("Choose a sticker to try this feature."))
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(AppColors.lime)
                }
                .toolbar { closeButton }
        }
        .environment(\.tutorialStickerScreen, screen)
    }
    @ToolbarContentBuilder private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(TutorialCopy.text("Close")) { dismiss() }
                .accessibilityIdentifier("tutorial-feature-close")
        }
    }
}
