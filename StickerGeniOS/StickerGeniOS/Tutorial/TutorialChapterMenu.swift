import SwiftUI

/// Chapter navigation stays inside the reader, like the language dropdown.
struct TutorialChapterMenu: View {
    let document: TutorialDocument
    let selectedChapter: String?
    let completedChapters: [String]
    var onSelect: (TutorialDocument.Chapter) -> Void
    var onClose: () -> Void
    @AccessibilityFocusState private var focusedChapter: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(document.sections) { section in
                        Text(section.title)
                            .font(.caption.bold())
                            .foregroundStyle(AppColors.muted)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(document.chapters.filter { $0.section == section.id }) { chapter in
                            chapterRow(chapter).id(chapter.id)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onAppear {
                if let selectedChapter { proxy.scrollTo(selectedChapter, anchor: .center) }
                focusedChapter = selectedChapter ?? document.chapters.first?.id
            }
        }
        .font(.body)
        .foregroundStyle(AppColors.ink)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(document.copy("index"))
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onClose() }
        .accessibilityIdentifier("tutorial-chapter-dropdown")
    }

    private func chapterRow(_ chapter: TutorialDocument.Chapter) -> some View {
        let selected = chapter.id == selectedChapter
        let completed = completedChapters.contains(chapter.id)
        return Button { onSelect(chapter) } label: {
            HStack(spacing: 12) {
                Text(chapter.title)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark" : "checkmark.circle")
                    .opacity(selected || completed ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppColors.lime.opacity(0.35) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(completed ? document.copy("completed") : "")
        .accessibilityFocused($focusedChapter, equals: chapter.id)
        .accessibilityIdentifier("tutorial-chapter-\(chapter.id)")
    }
}
