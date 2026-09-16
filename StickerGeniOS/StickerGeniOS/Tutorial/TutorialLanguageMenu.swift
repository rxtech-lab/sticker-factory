import SwiftUI

/// A dropdown drawn inside the existing reader. It does not present a UIKit context menu,
/// popover or second sheet, and its only navigation-related callback is an explicit selection.
struct TutorialLanguageMenu: View {
    let selectedLanguage: String
    let accessibilityTitle: String
    var onSelect: (String) -> Void
    var onClose: () -> Void
    @AccessibilityFocusState private var focusedLanguage: String?

    private struct Language: Identifiable {
        let id: String
        let title: String
    }
    private static let languages = [
        Language(id: "en", title: "English"),
        Language(id: "zh-CN", title: "简体中文"),
        Language(id: "zh-HK", title: "繁體中文")
    ]

    static func title(for code: String) -> String {
        languages.first { $0.id == code }?.title ?? "English"
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.languages) { language in
                if language.id != Self.languages.first?.id { Divider().padding(.horizontal, 14) }
                Button { onSelect(language.id) } label: {
                    HStack(spacing: 12) {
                        Text(language.title).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .opacity(language.id == selectedLanguage ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(language.id == selectedLanguage ? .isSelected : [])
                .accessibilityFocused($focusedLanguage, equals: language.id)
                .accessibilityIdentifier("tutorial-language-\(language.id)")
            }
        }
        .font(.body)
        .foregroundStyle(AppColors.ink)
        .frame(width: 260)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onClose() }
        .accessibilityIdentifier("tutorial-language-dropdown")
        .onAppear { focusedLanguage = selectedLanguage }
    }
}
