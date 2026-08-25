import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// One document per place a link reference definition is allowed to sit, in every line ending
/// CommonMark recognises and with both kinds of whitespace after a list marker.
struct MarkdownContextCase: Sendable, CustomTestStringConvertible {
    let name: String
    let markdown: String

    nonisolated var testDescription: String { name }

    nonisolated static func matrix(
        definition: String,
        use: String
    ) -> [MarkdownContextCase] {
        var cases: [MarkdownContextCase] = []
        var seen: Set<String> = []
        // All three are line endings in CommonMark; a memo written on any device is the same memo.
        for (endingName, ending) in [("lf", "\n"), ("crlf", "\r\n"), ("cr", "\r")] {
            for (spacingName, spacing) in [("space", " "), ("tab", "\t")] {
                for (context, lines) in contexts(definition, use, spacing) {
                    let markdown = lines.joined(separator: ending)
                    guard seen.insert(markdown).inserted else { continue }
                    cases.append(
                        MarkdownContextCase(
                            name: "\(context)/\(endingName)/\(spacingName)",
                            markdown: markdown
                        )
                    )
                }
            }
        }
        return cases
    }

    /// Every container a definition can be written inside. cmark registers a definition written in
    /// any of them for the WHOLE document, so a reference anywhere below resolves against it.
    nonisolated private static func contexts(
        _ definition: String,
        _ use: String,
        _ spacing: String
    ) -> [(String, [String])] {
        [
            ("top level", [definition, "", use]),
            ("blockquote", ["> " + definition, "", use]),
            ("list item", ["-" + spacing + definition, "", use]),
            ("ordered item", ["1." + spacing + definition, "", use]),
            ("quoted list", ["> -" + spacing + definition, "", use]),
            ("after indented code", ["    code line", definition, "", use]),
            ("after quoted indented code", [">     code line", "> " + definition, "", use]),
            ("marker-only item", ["-", "  " + definition, "", use]),
        ]
    }
}

/// The class this phase keeps being reviewed for, as a table: line ending × container × spacing.
///
/// The assertion is the security property itself rather than the shape of the text, because the
/// shape differs in every one of these places and the property does not: nothing the renderer
/// resolves may be a destination the app would open, and no image may reach it at all.
@MainActor
@Suite("a definition answers to the scheme rule wherever it sits")
struct MarkdownDefinitionMatrixTests {
    // `nonisolated`, because the `@Test` macro reads these where it builds the argument list —
    // outside the suite's MainActor isolation. The cases are immutable value types.
    nonisolated static let unsafeLinks = MarkdownContextCase.matrix(
        definition: "[evil]: javascript:alert(1)",
        use: "[click][evil]"
    )
    nonisolated static let remoteImages = MarkdownContextCase.matrix(
        definition: "[pic]: https://example.com/red.png",
        use: "![shot][pic]"
    )
    nonisolated static let safeLinks = MarkdownContextCase.matrix(
        definition: "[home]: https://example.com/",
        use: "[site][home]"
    )

    @Test(
        "an unsafe destination never becomes something the app would open",
        arguments: unsafeLinks
    )
    func unsafeDestinationsNeverSurvive(testCase: MarkdownContextCase) {
        let resolved = ProductionMarkdownProjection.destinations(in: testCase.markdown)
        let openable = resolved.filter { MemoRenderPolicy.mayOpen(destination: $0) }
        #expect(
            resolved.allSatisfy { !$0.lowercased().hasPrefix("javascript:") },
            "\(testCase.name): the renderer resolved \(resolved)"
        )
        #expect(openable.isEmpty, "\(testCase.name): the app would open \(openable)")
    }

    @Test("no image ever reaches the renderer", arguments: remoteImages)
    func imagesNeverReachTheRenderer(testCase: MarkdownContextCase) {
        let html = ProductionMarkdownProjection.html(testCase.markdown)
        #expect(!html.contains("<img"), "\(testCase.name): \(html)")
        #expect(!html.contains("example.com/red.png"), "\(testCase.name): \(html)")
    }

    /// The control that keeps the rule from being "neutralise everything": a legitimate link
    /// written in any of those same places still resolves.
    @Test("a legitimate link still resolves in every one of those places", arguments: safeLinks)
    func safeLinksStillResolve(testCase: MarkdownContextCase) {
        let resolved = ProductionMarkdownProjection.destinations(in: testCase.markdown)
        #expect(
            resolved.contains("https://example.com/"),
            "\(testCase.name): resolved \(resolved)"
        )
    }

    /// The other control: code is the author's, character for character. An escape written into a
    /// fenced or indented block would show up as a backslash on screen.
    @Test(
        "code keeps the characters the author typed",
        arguments: [("lf", "\n"), ("crlf", "\r\n"), ("cr", "\r")]
    )
    func codeIsNeverRewritten(endingName: String, ending: String) {
        let fenced = ["```", "[evil]: javascript:alert(1)", "```"].joined(separator: ending)
        let fencedHTML = ProductionMarkdownProjection.html(fenced)
        #expect(fencedHTML.contains("[evil]: javascript:alert(1)"), "\(endingName): \(fencedHTML)")
        #expect(!fencedHTML.contains("\\["), "\(endingName): a backslash leaked: \(fencedHTML)")

        let indented = ["    [evil]: javascript:alert(1)", "", "text"].joined(separator: ending)
        let indentedHTML = ProductionMarkdownProjection.html(indented)
        #expect(!indentedHTML.contains("\\["), "\(endingName): a backslash leaked: \(indentedHTML)")
    }
}

/// The other half of the rule: what must NOT be touched.
///
/// Every finding here was an OVER-refusal — the scanner read a block boundary where CommonMark
/// has none, registered a label from text that was never a definition, and then deleted a
/// `![alt][pic]` a reader was meant to see. cmark and markdown-it agree on all three, so there is
/// no parity to trade: the literal characters simply have to survive.
@MainActor
@Suite("literal content the scanner must leave alone")
struct MarkdownLiteralContentTests {
    private func texts(_ markdown: String) -> [String] {
        ProductionMarkdownProjection.ignoringInvisibleParagraphs(
            ProductionMarkdownProjection.project(markdown)
        )
        .flatMap { block in
            [block.text] + (block.items ?? []) + (block.rows?.flatMap { $0 } ?? [])
        }
    }

    /// A fenced block opened inside a list item stays open across the item's continuation lines —
    /// they carry no marker of their own, and reading their depth as zero closes the fence early,
    /// turns the code inside it into a definition and deletes the image reference below.
    @Test("a fence opened in a list item keeps its content as code")
    func fencesInsideListItemsStayOpen() {
        let markdown = "- ~~~\n  [pic]: https://example.com/red.png\n  ~~~\n\n![alt][pic]"
        let shown = texts(markdown)
        #expect(shown.contains { $0.contains("![alt][pic]") }, "the image reference went: \(shown)")
        // Byte for byte, read off the renderer's own output rather than the projection, which
        // normalises whitespace: the code block still holds the line the author wrote, newline
        // included, with no escape inside it.
        let html = ProductionMarkdownProjection.html(markdown)
        #expect(
            html.contains("<pre><code>[pic]: https://example.com/red.png\n</code></pre>"),
            "the code was rewritten:\n\(html)"
        )
    }

    /// An empty list item cannot interrupt a paragraph, and neither can an ordered marker whose
    /// number is not 1. `2.` on a line of its own in the middle of a paragraph is text, the line
    /// after it is text, and nothing there is a definition.
    @Test("an empty marker in the middle of a paragraph starts nothing")
    func emptyMarkersDoNotInterruptAParagraph() {
        let markdown = "paragraph\n2.\n[pic]: https://example.com/red.png\n\n![alt][pic]"
        let shown = texts(markdown)
        #expect(shown.contains { $0.contains("![alt][pic]") }, "the image reference went: \(shown)")
        #expect(
            shown.contains { $0.contains("[pic]: https://example.com/red.png") },
            "the paragraph lost its text: \(shown)"
        )
    }

    /// A definition's destination may sit on the following line, but only while that line is part
    /// of the same block. A list marker opens one of its own, so `- https://…` is a list item and
    /// the `[pic]:` above it never became a definition.
    @Test("a line that opens a list is not the destination of the line above")
    func containersAreNotDestinationContinuations() {
        let markdown = "[pic]:\n- https://example.com/red.png\n\n![alt][pic]"
        let shown = texts(markdown)
        #expect(shown.contains { $0.contains("![alt][pic]") }, "the image reference went: \(shown)")
        #expect(shown.contains { $0.contains("[pic]:") }, "the paragraph went: \(shown)")
    }

    /// The controls for the three above, so the fixes cannot be "stop registering anything": with
    /// the container or the blank line that CommonMark needs, these ARE definitions, and the
    /// image the SPA drops is dropped here too.
    @Test(
        "the same shapes, one blank line different, still register",
        arguments: [
            (
                "a list of its own",
                "paragraph\n\n2.\n[pic]: https://example.com/red.png\n\n![alt][pic]"
            ),
            (
                "an unindented line after the fence",
                "- ~~~\n\n[pic]: https://example.com/red.png\n\n![alt][pic]"
            ),
        ]
    )
    func theSameShapesWithABlankLineStillRegister(name: String, markdown: String) {
        let html = ProductionMarkdownProjection.html(markdown)
        #expect(!html.contains("<img"), "\(name): \(html)")
    }
}
