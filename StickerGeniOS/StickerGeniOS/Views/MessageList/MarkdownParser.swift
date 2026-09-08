import Foundation
import SwiftUI

// Markdown parsing for `MarkdownText`, kept apart from the views because it is the part with
// behaviour worth testing: block structure and inline runs, no layout.

// MARK: - Inline

nonisolated enum MarkdownInline {
    /// Bold, italic, strikethrough, code spans and links, at the given base font.
    ///
    /// Falls back to the raw string rather than dropping the message: a half-written link from a
    /// stream mid-flight must still show the characters that have arrived.
    static func attributed(_ source: String, font: Font) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        // `Text` renders emphasis and strikethrough from the presentation intent on its own, but
        // leaves code spans at the body font — they have to be styled here to read as code.
        let codeRanges = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            attributed[range].font = font.monospaced()
        }
        return attributed
    }
}

// MARK: - Block parsing

nonisolated struct MarkdownBlock: Identifiable, Equatable {
    let id: Int
    let kind: Kind

    enum Kind: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case list([MarkdownListItem])
        case codeBlock(language: String?, code: String)
        case quote(String)
        case rule
    }
}

nonisolated struct MarkdownListItem: Identifiable, Equatable {
    let id: Int
    /// Nesting depth, already normalised from leading spaces.
    let indent: Int
    let marker: Marker
    let text: String

    enum Marker: Equatable {
        case bullet
        case ordered(Int)
        case task(done: Bool)
    }
}

/// Splits Markdown into the block elements assistants actually emit.
///
/// Not a CommonMark implementation — no reference links, no setext headings, no nested block
/// containers. It covers headings, lists (including task lists), fenced code, block quotes and
/// thematic breaks, and treats anything it does not recognise as a paragraph, which is the right
/// failure mode for text that is still being written.
nonisolated enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var nextID = 0
        func makeID() -> Int {
            defer { nextID += 1 }
            return nextID
        }

        var paragraph: [String] = []
        var listItems: [MarkdownListItem] = []
        var quote: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n")
            paragraph.removeAll()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(MarkdownBlock(id: makeID(), kind: .paragraph(text)))
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(MarkdownBlock(id: makeID(), kind: .list(listItems)))
            listItems.removeAll()
        }
        func flushQuote() {
            let text = quote.joined(separator: "\n")
            quote.removeAll()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(MarkdownBlock(id: makeID(), kind: .quote(text)))
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        let lines = source.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isFence(trimmed) {
                flushAll()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count, !isFence(lines[index].trimmingCharacters(in: .whitespaces)) {
                    code.append(lines[index])
                    index += 1
                }
                // An unclosed fence is what a stream mid-flight looks like; take what is there.
                if index < lines.count { index += 1 }
                blocks.append(
                    MarkdownBlock(
                        id: makeID(),
                        kind: .codeBlock(
                            language: language.isEmpty ? nil : language,
                            code: code.joined(separator: "\n")
                        )
                    )
                )
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                flushAll()
                blocks.append(MarkdownBlock(id: makeID(), kind: .rule))
                index += 1
                continue
            }

            if let heading = headingInfo(trimmed) {
                flushAll()
                blocks.append(
                    MarkdownBlock(id: makeID(), kind: .heading(level: heading.level, text: heading.text))
                )
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                quote.append(content)
                index += 1
                continue
            }

            if let item = listItemInfo(line) {
                flushParagraph()
                flushQuote()
                listItems.append(
                    MarkdownListItem(id: makeID(), indent: item.indent, marker: item.marker, text: item.text)
                )
                index += 1
                continue
            }

            // An indented line under a list item continues that item rather than starting a
            // paragraph, which is how wrapped bullets arrive.
            if !listItems.isEmpty, line.first == " " || line.first == "\t" {
                let last = listItems.removeLast()
                listItems.append(
                    MarkdownListItem(
                        id: last.id,
                        indent: last.indent,
                        marker: last.marker,
                        text: last.text + "\n" + trimmed
                    )
                )
                index += 1
                continue
            }

            flushList()
            flushQuote()
            paragraph.append(trimmed)
            index += 1
        }

        flushAll()
        return blocks
    }

    private static func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let stripped = trimmed.filter { !$0.isWhitespace }
        guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func headingInfo(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        // Closing hashes (`## Title ##`) are decoration, not content.
        let cleaned = rest.trimmingCharacters(in: .whitespaces).replacingOccurrences(
            of: "\\s*#+\\s*$",
            with: "",
            options: .regularExpression
        )
        return (hashes.count, cleaned)
    }

    private static func listItemInfo(
        _ line: String
    ) -> (indent: Int, marker: MarkdownListItem.Marker, text: String)? {
        var leadingSpaces = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            leadingSpaces += first == "\t" ? 4 : 1
            rest.removeFirst()
        }
        // Two spaces per level is the common shape; four-space indents simply nest twice as far,
        // which stays readable and keeps sibling items aligned with each other.
        let indent = min(leadingSpaces / 2, 4)

        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            let content = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if let task = taskInfo(content) {
                return (indent, .task(done: task.done), task.text)
            }
            return (indent, .bullet, content)
        }

        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let afterDigits = rest.dropFirst(digits.count)
            if let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
               afterDigits.dropFirst().first == " ",
               let number = Int(digits) {
                let content = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return (indent, .ordered(number), content)
            }
        }

        return nil
    }

    private static func taskInfo(_ content: String) -> (done: Bool, text: String)? {
        guard content.hasPrefix("[") else { return nil }
        let marker = content.dropFirst().prefix(1)
        guard content.dropFirst(2).hasPrefix("]"), marker == " " || marker.lowercased() == "x" else {
            return nil
        }
        let text = content.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return (marker.lowercased() == "x", text)
    }
}
