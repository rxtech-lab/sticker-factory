import Foundation
import SwiftUI
import Testing

@testable import StickerGeniOS

/// The block splitter behind assistant replies and the legal documents.
///
/// Worth testing directly because the input is model output arriving a token at a time: the
/// interesting cases are the half-written ones, which are hard to catch by watching the app.
@Suite("Markdown block parser")
struct MarkdownBlockParserTests {

    private func kinds(_ source: String) -> [MarkdownBlock.Kind] {
        MarkdownBlockParser.parse(source).map(\.kind)
    }

    @Test("Headings carry their level and drop the hashes")
    func headings() {
        #expect(kinds("# Title") == [.heading(level: 1, text: "Title")])
        #expect(kinds("### Deep") == [.heading(level: 3, text: "Deep")])
        #expect(kinds("## Closed ##") == [.heading(level: 2, text: "Closed")])
    }

    @Test("A hash without a space is not a heading")
    func hashtagIsNotAHeading() {
        #expect(kinds("#1 sticker") == [.paragraph("#1 sticker")])
        #expect(kinds("####### too deep") == [.paragraph("####### too deep")])
    }

    @Test("Consecutive bullets become one list")
    func bulletList() {
        let blocks = kinds(
            """
            - one
            * two
            + three
            """
        )
        guard case let .list(items) = blocks.first, blocks.count == 1 else {
            Issue.record("expected a single list, got \(blocks)")
            return
        }
        #expect(items.map(\.text) == ["one", "two", "three"])
        #expect(items.allSatisfy { $0.marker == .bullet })
        #expect(items.allSatisfy { $0.indent == 0 })
    }

    @Test("Ordered markers keep their own numbers")
    func orderedList() {
        guard case let .list(items) = kinds("1. first\n2) second\n7. seventh").first else {
            Issue.record("expected a list")
            return
        }
        #expect(items.map(\.marker) == [.ordered(1), .ordered(2), .ordered(7)])
        #expect(items.map(\.text) == ["first", "second", "seventh"])
    }

    @Test("Indented bullets nest")
    func nestedList() {
        guard case let .list(items) = kinds("- outer\n  - inner\n    - deeper").first else {
            Issue.record("expected a list")
            return
        }
        #expect(items.map(\.indent) == [0, 1, 2])
    }

    @Test("Task list markers record their checked state")
    func taskList() {
        guard case let .list(items) = kinds("- [x] done\n- [ ] pending\n- [X] also done").first else {
            Issue.record("expected a list")
            return
        }
        #expect(items.map(\.marker) == [.task(done: true), .task(done: false), .task(done: true)])
        #expect(items.map(\.text) == ["done", "pending", "also done"])
    }

    @Test("A wrapped bullet stays part of its item")
    func listContinuation() {
        guard case let .list(items) = kinds("- first line\n  continued here\n- second").first else {
            Issue.record("expected a list")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].text == "first line\ncontinued here")
    }

    @Test("Fenced code keeps its language and indentation")
    func fencedCode() {
        let blocks = kinds(
            """
            ```swift
            if x {
                y()
            }
            ```
            """
        )
        #expect(blocks == [.codeBlock(language: "swift", code: "if x {\n    y()\n}")])
    }

    @Test("An unclosed fence still renders what has arrived")
    func unterminatedFence() {
        #expect(kinds("```\nlet a = 1") == [.codeBlock(language: nil, code: "let a = 1")])
    }

    @Test("Markdown inside a fence is not treated as markdown")
    func fenceSuppressesBlockSyntax() {
        #expect(kinds("```\n# not a heading\n- not a bullet\n```")
            == [.codeBlock(language: nil, code: "# not a heading\n- not a bullet")])
    }

    @Test("Quote lines merge into one block")
    func quote() {
        #expect(kinds("> first\n> second") == [.quote("first\nsecond")])
    }

    @Test("Thematic breaks are recognised in their several spellings")
    func thematicBreak() {
        #expect(kinds("---") == [.rule])
        #expect(kinds("***") == [.rule])
        #expect(kinds("- - -") == [.rule])
        #expect(kinds("__") == [.paragraph("__")])
    }

    @Test("A blank line separates paragraphs; a single newline does not")
    func paragraphs() {
        #expect(kinds("one\ntwo\n\nthree") == [.paragraph("one\ntwo"), .paragraph("three")])
    }

    @Test("Plain prose survives untouched")
    func plainText() {
        let text = "Here is a plan for your sticker."
        #expect(kinds(text) == [.paragraph(text)])
    }

    @Test("Empty and whitespace-only input produce nothing")
    func emptyInput() {
        #expect(MarkdownBlockParser.parse("").isEmpty)
        #expect(MarkdownBlockParser.parse("   \n\n  ").isEmpty)
    }

    @Test("Blocks come back in source order")
    func mixedDocument() {
        let blocks = kinds(
            """
            # Plan
            Intro line.

            - step one
            - step two

            > note

            ---
            """
        )
        #expect(blocks.count == 5)
        #expect(blocks.first == .heading(level: 1, text: "Plan"))
        #expect(blocks[1] == .paragraph("Intro line."))
        if case .list = blocks[2] {} else { Issue.record("expected a list at index 2") }
        #expect(blocks[3] == .quote("note"))
        #expect(blocks[4] == .rule)
    }

    @Test("Block ids are unique so the list identifies rows correctly")
    func uniqueIDs() {
        let blocks = MarkdownBlockParser.parse("# A\n\n- one\n- two\n\nprose")
        let listItemIDs = blocks.flatMap { block -> [Int] in
            if case let .list(items) = block.kind { return items.map(\.id) }
            return []
        }
        let ids = blocks.map(\.id) + listItemIDs
        #expect(Set(ids).count == ids.count)
    }
}

@Suite("Markdown inline")
struct MarkdownInlineTests {

    @Test("Emphasis markers are consumed, not shown")
    func emphasis() {
        let attributed = MarkdownInline.attributed("a **bold** word", font: .body)
        #expect(String(attributed.characters) == "a bold word")
    }

    @Test("A code span is styled monospaced at the base font")
    func codeSpan() {
        let attributed = MarkdownInline.attributed("call `render()` now", font: .body)
        #expect(String(attributed.characters) == "call render() now")
        let monospacedRuns = attributed.runs.filter { $0.font != nil }
        #expect(monospacedRuns.count == 1)
        #expect(String(attributed[monospacedRuns[0].range].characters) == "render()")
    }

    @Test("A link keeps its label and its destination")
    func link() {
        let attributed = MarkdownInline.attributed("see [docs](https://example.com)", font: .body)
        #expect(String(attributed.characters) == "see docs")
        #expect(attributed.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    @Test("Unfinished syntax from a stream mid-flight still shows its characters")
    func partialSyntax() {
        #expect(String(MarkdownInline.attributed("half **bol", font: .body).characters) == "half **bol")
        #expect(String(MarkdownInline.attributed("see [docs](htt", font: .body).characters) == "see [docs](htt")
    }
}
