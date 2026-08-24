import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// Locates the fixture inside the test bundle. Swift Testing has no test class to hand
/// `Bundle(for:)`, so this token supplies one.
private final class BundleToken {}

/// The parity gate, anchored to the renderer the app ships.
///
/// Each case carries its own Markdown input, so this suite never needs the SPA running: it
/// prepares the input exactly as `MemoMarkdownView` does, parses it with the renderer the view
/// renders with, and asserts the projection memos-ng committed. A renderer that flattens a list,
/// loses a task's state, keeps a `javascript:` link tappable or leaves `~~struck~~` unstyled
/// cannot produce a matching projection — and neither can a MarkdownUI release that changes what
/// it parses, which is the failure a second, hand-written parser cannot see.
@MainActor
@Suite("markdown parity with the SPA renderer")
struct MarkdownRenderParityTests {
    // `nonisolated`, because the `@Test` macro reads these where it builds the argument list —
    // outside the suite's MainActor isolation. Both values are `Sendable` and never mutated.
    nonisolated static let fixture: MarkdownParityFixture = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "markdown-parity", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? MarkdownParityFixture.decode(from: data)
        else {
            fatalError("markdown-parity.json is not in the test bundle — check project.yml")
        }
        return decoded
    }()

    /// Cases `renderHTML()` cannot answer for, each with the reason and each still asserted
    /// against the block model in `MarkdownParityTests` (MemosCoreTests).
    ///
    /// - `raw-html-literal`: cmark's HTML renderer is safe by default since cmark-gfm 0.29
    ///   (`CMARK_OPT_DEFAULT` has `CMARK_OPT_UNSAFE` clear) and replaces raw HTML with
    ///   `<!-- raw HTML omitted -->`. The VIEW keeps it: `BlockNode.htmlBlock` renders as a
    ///   paragraph and `AttributedStringInlineRenderer` renders an inline HTML node as its literal
    ///   characters, which is what the SPA's `html: false` produces too.
    /// - `table`: MarkdownUI's `renderHTML()` rebuilds a cmark document from its block model and
    ///   renders it with no extension list, so the table extension emits the rows without their
    ///   cell tags — `<tr>tiersizenote</tr>`. The VIEW renders cells from the same block model
    ///   through `TableView` and loses nothing. What is missing is in the HTML, not on screen.
    nonisolated static let unreadableFromHTML: Set<String> = ["raw-html-literal", "table"]

    /// Cases where the app and the SPA GENUINELY render differently today. Each is pinned by a
    /// test of its own below, so the difference cannot change unnoticed, and each is a ticket
    /// rather than something this phase invented a workaround for.
    ///
    /// - `task-list-basic`: cmark-gfm makes the whole list a task list as soon as ONE item is a
    ///   task, and `TaskListView` draws a marker for every item in it, so `- plain item` after a
    ///   `- [x] …` shows an (empty) checkbox where the SPA shows a bullet. Visual only: the
    ///   interactive task rows on the detail screen come from `MemoPresentation.tasks`.
    nonisolated static let divergentIds: Set<String> = ["task-list-basic"]

    nonisolated static let excludedIds = unreadableFromHTML.union(divergentIds)

    @Test("the vendored fixture is schema 1 and has enough cases to be worth anything")
    func fixtureShape() {
        #expect(Self.fixture.schema == 1)
        #expect(Self.fixture.cases.count >= 15)
    }

    @Test("every excluded id is a real case, so a typo cannot quietly skip the gate")
    func exclusionsAreReal() {
        let ids = Set(Self.fixture.cases.map(\.id))
        #expect(Self.excludedIds.isSubset(of: ids))
        // Three, and no more: an exclusion is a debt, not a way to make the gate quiet.
        #expect(Self.excludedIds.count == 3)
    }

    @Test(
        "every case renders as the SPA does",
        arguments: Self.fixture.cases.map(\.id).filter { !Self.excludedIds.contains($0) }
    )
    func renderingMatches(id: String) throws {
        let testCase = try #require(Self.fixture.cases.first { $0.id == id })
        let projected = ProductionMarkdownProjection.ignoringInvisibleParagraphs(
            ProductionMarkdownProjection.project(testCase.markdown)
        )
        let expected = ProductionMarkdownProjection.ignoringInvisibleParagraphs(
            testCase.projection
        )
        let rendered = ProductionMarkdownProjection.html(testCase.markdown)
        #expect(projected == expected, "case \(id), rendered as:\n\(rendered)")
    }

    /// The parity gate has to be able to fail on the THEME as well as on the parse, or "the app
    /// renders this markdown the way the SPA does" is only a claim about a string. A memo line is
    /// measured against a `.body` line: a theme that names any other size makes this red.
    /// (`DynamicTypeFittingTests` holds the same size against Dynamic Type; here it is the parity
    /// guard's own tripwire.)
    @Test("a memo body is painted at the platform's body size")
    func bodyIsTheBodySize() {
        let width: CGFloat = 320
        let memo = LayoutProbe.size(
            MemoMarkdownView(content: "Hello"), width: width, typeSize: .large
        ).height
        let body = LayoutProbe.size(
            Text("Hello").font(.body), width: width, typeSize: .large
        ).height
        #expect(body > 0)
        #expect(
            abs(memo - body) < 0.5,
            "a memo line is \(memo)pt against a body line of \(body)pt"
        )
    }

    /// The fixture says a single newline is a line break (`breaks: true` in the SPA). MarkdownUI
    /// defaults to treating one as a space, which turns a three-line memo into one run-on line, so
    /// the view asks for `.lineBreak` — and this measures that it got it.
    @Test("a single newline breaks the line, as it does in the SPA")
    func softBreaksAreLineBreaks() {
        let width: CGFloat = 320
        let oneLine = LayoutProbe.size(
            MemoMarkdownView(content: "line one"), width: width, typeSize: .large
        ).height
        let twoLines = LayoutProbe.size(
            MemoMarkdownView(content: "line one\nline two"), width: width, typeSize: .large
        ).height
        #expect(oneLine > 0)
        #expect(
            twoLines > oneLine * 1.5,
            "two lines measured \(twoLines)pt against one line of \(oneLine)pt"
        )
    }

    /// The `task-list-basic` divergence, pinned rather than papered over.
    ///
    /// cmark-gfm turns the whole list into a task list as soon as one item is a task, and
    /// MarkdownUI draws a marker for every item of one, so the plain item comes out with an empty
    /// checkbox where the SPA gives it a bullet. This test states what the app does TODAY: it goes
    /// red when that is fixed (or when it gets worse), which is what keeps the exclusion above
    /// honest.
    @Test("a plain item in a task list is drawn as a task — today's divergence, pinned")
    func plainItemsInATaskListAreCheckboxes() {
        let blocks = ProductionMarkdownProjection.project("- [x] done\n- plain item")
        #expect(blocks.map(\.type) == [.task, .task])
        #expect(blocks.map(\.checked) == [true, false])
        #expect(blocks.map(\.text) == ["done", "plain item"])
    }
}

/// What a reference-style link does in the app.
///
/// markdown-it validates a link reference definition where it is defined and refuses to register
/// an unsafe one, so the SPA renders `[click][evil]` and its `[evil]: javascript:…` line as text.
/// cmark-gfm has no such rule: it resolves the reference and hands the view a live `javascript:`
/// destination. Without `MemoMarkdownSource` neutralising the definition, every scheme rule the
/// inline form obeys is one alternative spelling away from being bypassed — these tests are what
/// says it is not.
@MainActor
@Suite("reference-style links answer to the same scheme rule as inline ones")
struct ReferenceLinkTests {
    private func projection(_ markdown: String) -> [MarkdownBlock] {
        ProductionMarkdownProjection.ignoringInvisibleParagraphs(
            ProductionMarkdownProjection.project(markdown)
        )
    }

    @Test(
        "an unsafe destination is not a link in any spelling",
        arguments: [
            ("full", "[click][evil]\n\n[evil]: javascript:alert(1)"),
            ("collapsed", "[evil][]\n\n[evil]: javascript:alert(1)"),
            ("shortcut", "[evil]\n\n[evil]: javascript:alert(1)"),
            ("definition first", "[evil]: javascript:alert(1)\n\nsee [click][evil]"),
            ("destination on the next line", "[evil]:\njavascript:alert(1)\n\n[click][evil]"),
            ("data url", "[click][evil]\n\n[evil]: data:text/html,hi"),
            ("vbscript", "[click][evil]\n\n[evil]: vbscript:msgbox(1)"),
            ("file url", "[click][evil]\n\n[evil]: file:///etc/passwd"),
            ("angle brackets", "[click][evil]\n\n[evil]: <javascript:alert(1)>"),
            ("label case folded", "[click][EVIL]\n\n[evil]: javascript:alert(1)"),
            ("inside a quote", "> [click][evil]\n\n> [evil]: javascript:alert(1)"),
        ]
    )
    func unsafeReferencesAreNotLinks(name: String, markdown: String) {
        let blocks = projection(markdown)
        #expect(blocks.allSatisfy { $0.links.isEmpty }, "\(name): \(blocks)")
    }

    /// The other half of the same rule: the label's own line is what markdown-it leaves on screen
    /// when it refuses the definition, and the reference that names it stays as the characters the
    /// author typed rather than quietly disappearing.
    @Test("the refused definition and the reference that names it stay on screen as text")
    func refusedDefinitionsStayVisible() {
        let blocks = projection("[click][evil]\n\n[evil]: javascript:alert(1)")
        #expect(blocks.map(\.text) == ["[click][evil]", "[evil]: javascript:alert(1)"])
    }

    @Test("a reference link to an allowed scheme is still a link")
    func safeReferencesSurvive() {
        let blocks = projection("[site][home]\n\n[home]: https://example.com/a?b=1")
        #expect(blocks.count == 1)
        #expect(
            blocks.first?.links
                == [MarkdownLink(href: "https://example.com/a?b=1", text: "site")]
        )
        #expect(blocks.first?.text == "site")
    }

    @Test("a mailto reference and a collapsed reference both survive")
    func otherAllowedSpellings() {
        let mail = projection("[write][mail]\n\n[mail]: mailto:memo@example.com")
        #expect(mail.first?.links.map(\.href) == ["mailto:memo@example.com"])
        let collapsed = projection("[home][]\n\n[home]: https://example.com/")
        #expect(collapsed.first?.links.map(\.href) == ["https://example.com/"])
    }

    /// `img` is not in the sanitiser's allowlist, so the SPA shows nothing for an image in any
    /// spelling. A reference image that survived would not only diverge, it would make the app
    /// fetch a URL out of memo text that the SPA never requests.
    @Test("a reference image is dropped whole, exactly like an inline one")
    func referenceImagesAreDropped() {
        let blocks = projection("![shot][pic]\n\n[pic]: https://example.com/red.png")
        #expect(blocks.isEmpty, "\(blocks)")
        let inParagraph = projection(
            "before ![shot][pic] after\n\n[pic]: https://example.com/a.png"
        )
        #expect(inParagraph.map(\.text) == ["before after"])
    }

    @Test("a reference that names nothing is left alone, in text and in an image")
    func unresolvedReferencesAreLeftAlone() {
        #expect(
            projection("[missing][nope] stays text").map(\.text)
                == ["[missing][nope] stays text"]
        )
        #expect(projection("![alt][nope] stays text").map(\.text) == ["![alt][nope] stays text"])
        #expect(projection("a [bracket] and (parens)").map(\.text) == ["a [bracket] and (parens)"])
    }

    @Test("a definition inside a code block is code, not a definition")
    func definitionsInsideCodeAreLeftAlone() {
        let fenced = projection("```\n[evil]: javascript:alert(1)\n```")
        #expect(fenced.map(\.text) == ["[evil]: javascript:alert(1)\n"])
        let indented = projection("    [evil]: javascript:alert(1)")
        #expect(indented.map(\.text) == ["[evil]: javascript:alert(1)\n"])
    }

    /// The end of the pipeline, past the projection: what the reader's eye can tell apart. A link
    /// is painted in the accent, ordinary text is not, so counting the accent-coloured pixels in a
    /// rendered memo answers "is this tappable" without an `href` to read — which matters here
    /// because cmark's HTML renderer blanks an unsafe `href` while the view keeps it.
    @Test("an unsafe reference is painted as text, a real link is painted in the accent")
    func linkColourInTheRenderedView() throws {
        let live = try accentPixels(in: "[click][home]\n\n[home]: https://example.com/")
        let neutralised = try accentPixels(in: "[click][evil]\n\n[evil]: javascript:alert(1)")
        #expect(live > 0, "a real link was not painted in the accent at all")
        #expect(neutralised == 0, "\(neutralised) accent pixels — the reference stayed a link")
    }

    /// Accent-coloured means green-dominant: the accent is `#3E7C4F` in light appearance, while
    /// body text and every antialiased shade of it have equal channels.
    private func accentPixels(in content: String) throws -> Int {
        let size = CGSize(width: 260, height: 80)
        let view = MemoMarkdownView(content: content)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let grid = try #require(PixelGrid.of(view, size: size), "the view did not render")
        return grid.reduce(0) { total, row in
            total
                + row.count { pixel in
                    Int(pixel.g) >= Int(pixel.r) + 25 && Int(pixel.g) >= Int(pixel.b) + 25
                }
        }
    }
}
