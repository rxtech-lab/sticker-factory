import SwiftUI

/// Renders Markdown coming from the server — assistant replies and the legal documents.
///
/// `Text` only interprets Markdown for string literals, and even then only the inline syntax —
/// a runtime string full of headings and bullets arrives as one paragraph of raw `##` and `-`.
/// So the block structure is parsed here and laid out as real views, and only the leaf runs go
/// through `AttributedString`'s inline parser for bold, italic, code spans and links.
///
/// The parser is deliberately forgiving: assistant text arrives a token at a time, so half a
/// fence or an unfinished bullet is the normal state of the string, not an error.
struct MarkdownText: View {
    /// What the text is: a line or two inside a bubble, or a whole page someone reads top to
    /// bottom. Only the typographic scale differs — the same document parses the same either way.
    enum Style {
        case chat
        case document
    }

    let markdown: String
    var style: Style = .chat

    var body: some View {
        let blocks = MarkdownBlockParser.parse(markdown)
        // A legal document is long enough that building every block up front is wasted work;
        // a chat bubble is not, and lazy stacks measure badly inside one.
        Group {
            if style == .document {
                LazyVStack(alignment: .leading, spacing: style.blockSpacing) {
                    ForEach(blocks) { block in view(for: block) }
                }
            } else {
                VStack(alignment: .leading, spacing: style.blockSpacing) {
                    ForEach(blocks) { block in view(for: block) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case let .paragraph(text):
            Text(MarkdownInline.attributed(text, font: .body))
                .lineSpacing(style.lineSpacing)

        case let .heading(level, text):
            Text(MarkdownInline.attributed(text, font: style.headingFont(level)))
                .font(style.headingFont(level))
                .padding(.top, block.id == 0 ? 0 : style.headingTopPadding)

        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    MarkdownListRow(item: item, lineSpacing: style.lineSpacing)
                }
            }

        case let .codeBlock(language, code):
            MarkdownCodeBlock(language: language, code: code)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppColors.coral)
                    .frame(width: 4)
                Text(MarkdownInline.attributed(text, font: .body))
                    .foregroundStyle(.secondary)
                    .lineSpacing(style.lineSpacing)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle()
                .fill(AppColors.line)
                .frame(height: 1.5)
                .padding(.vertical, 2)
        }
    }
}

extension MarkdownText.Style {
    /// In a bubble a heading stays close to body size — a `.largeTitle` `#` would read as a
    /// screen title rather than as a section of somebody's reply. A document gets the full scale.
    func headingFont(_ level: Int) -> Font {
        switch self {
        case .chat:
            switch level {
            case 1: .title3.weight(.bold)
            case 2: .headline
            default: .subheadline.weight(.semibold)
            }
        case .document:
            switch level {
            case 1: .title.bold()
            case 2: .title2.bold()
            default: .headline
            }
        }
    }

    var blockSpacing: CGFloat {
        switch self {
        case .chat: 8
        case .document: 14
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .chat: 0
        case .document: 4
        }
    }

    var headingTopPadding: CGFloat {
        switch self {
        case .chat: 2
        case .document: 10
        }
    }
}

private struct MarkdownListRow: View {
    let item: MarkdownListItem
    let lineSpacing: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(MarkdownInline.attributed(item.text, font: .body))
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(item.indent) * 12)
    }

    @ViewBuilder
    private var marker: some View {
        switch item.marker {
        case .bullet:
            Text(item.indent == 0 ? "•" : "◦")
        case let .ordered(number):
            Text("\(number).")
        case let .task(done):
            PosterSymbol(done ? "checkmark.square.fill" : "square")
                .font(.footnote)
                .foregroundStyle(done ? AppColors.accent : .secondary)
        }
    }
}

private struct MarkdownCodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // Code is the one place where a wrapped line changes the meaning, so it scrolls
            // sideways instead of reflowing.
            ScrollView(.horizontal) {
                Text(code)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.never)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .posterSurface(
            cornerRadius: 10,
            fill: AppColors.card,
            lineWidth: Poster.hairline,
            offset: .zero
        )
    }
}

#Preview("Markdown") {
    ScrollView {
        MarkdownText(
            markdown: """
            # Sticker plan
            Here is **what I changed**, with a `code span` and a [link](https://example.com).

            ## Layers
            - Base shape, recoloured
            - Outline
              - thinner at the ears
            1. Generate
            2. Composite

            - [x] Concept locked
            - [ ] Export

            > Reference images stay private.

            ```swift
            let sticker = StickerScene()
            ```

            ---
            Done.
            """
        )
        .padding()
    }
}
