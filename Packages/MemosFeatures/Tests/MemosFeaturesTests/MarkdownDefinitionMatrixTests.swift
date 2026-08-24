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
