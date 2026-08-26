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

    /// There is no second list. Every case the shipped renderer CAN be asked about is asserted
    /// below — no case is excluded for rendering differently from the SPA (MEMNG-144 settled the
    /// last one, `task-list-basic`, in favour of the SPA: a plain item beside a task is a bullet).
    nonisolated static let excludedIds = unreadableFromHTML

    @Test("the vendored fixture is schema 1 and has enough cases to be worth anything")
    func fixtureShape() {
        #expect(Self.fixture.schema == 1)
        #expect(Self.fixture.cases.count >= 15)
    }

    @Test("every excluded id is a real case, so a typo cannot quietly skip the gate")
    func exclusionsAreReal() {
        let ids = Set(Self.fixture.cases.map(\.id))
        #expect(Self.excludedIds.isSubset(of: ids))
        // Two, and no more, and both of them are limits of `renderHTML()` rather than of what the
        // app draws — `MarkdownParityTests` asserts each against the block model. An exclusion is
        // a debt, not a way to make the gate quiet.
        #expect(Self.excludedIds == Self.unreadableFromHTML)
        #expect(Self.excludedIds.count == 2)
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

    /// The class between "refused" and "tappable", read off the renderer the app ships
    /// (MEMNG-165). markdown-it ACCEPTS `ftp:`, a scheme-relative `//host` and a relative path,
    /// so the definition registers and its line is consumed; `memo_target_policy` then drops the
    /// anchor off the link it built, and the label alone is what the SPA shows. A client that
    /// asks the sanitiser's question at the DEFINITION instead renders the definition line and
    /// the whole reference as literal markup — the divergence this pins.
    @Test(
        "a reference target the app will not open renders as its label, and as nothing else",
        arguments: [
            ("ftp, full", "[the file][f]\n\n[f]: ftp://example.com/pub", "the file"),
            ("ftp, collapsed", "[f][]\n\n[f]: ftp://example.com/pub", "f"),
            ("ftp, shortcut", "[f]\n\n[f]: ftp://example.com/pub", "f"),
            ("scheme-relative", "[the host][h]\n\n[h]: //example.com/path", "the host"),
            ("relative path", "[the page][p]\n\n[p]: /docs/readme.md", "the page"),
            (
                "the first definition decides",
                "[f]: ftp://example.com/first\n[f]: https://example.com/second\n\n[the file][f]",
                "the file"
            ),
        ]
    )
    func acceptedButUnopenableReferencesBecomeLabels(
        name: String,
        markdown: String,
        expected: String
    ) {
        let blocks = projection(markdown)
        #expect(blocks.map(\.text) == [expected], "\(name)")
        #expect(blocks.allSatisfy { $0.links.isEmpty }, "\(name): \(blocks)")
    }

    /// The image half of the same rule: the image goes either way, and a source the app will not
    /// fetch leaves its alt behind as plain text rather than raw `![…][…]` markup.
    @Test(
        "a reference image the app will not fetch leaves its alt text as words",
        arguments: [
            ("ftp", "![the chart][pic]\n\n[pic]: ftp://example.com/chart.png"),
            ("a data image", "![the chart][pic]\n\n[pic]: data:image/png;base64,iVBORw0KGgo="),
        ]
    )
    func acceptedButUnfetchableReferenceImagesKeepTheirAlt(name: String, markdown: String) {
        #expect(projection(markdown).map(\.text) == ["the chart"], "\(name)")
        let html = ProductionMarkdownProjection.html(markdown)
        #expect(!html.contains("<img"), "\(name): the renderer was handed an image:\n\(html)")
        #expect(!html.contains("chart.png"), "\(name): the remote URL survived:\n\(html)")
    }

    /// The liveness half, read off the rendered pixels rather than off an `href`: a label the
    /// policy reduced to text must not be painted in the accent, or the reader is invited to tap
    /// a destination the app refuses to open.
    @Test("an accepted-but-unopenable reference is painted as text, not as a link")
    func acceptedButUnopenableReferencesAreNotPainted() throws {
        let painted = try accentPixels(in: "[click][f]\n\n[f]: ftp://example.com/pub")
        #expect(painted == 0, "\(painted) accent pixels — the reference stayed a link")
    }

    @Test("a definition inside a code block is code, not a definition")
    func definitionsInsideCodeAreLeftAlone() {
        let fenced = projection("```\n[evil]: javascript:alert(1)\n```")
        #expect(fenced.map(\.text) == ["[evil]: javascript:alert(1)\n"])
        let indented = projection("    [evil]: javascript:alert(1)")
        #expect(indented.map(\.text) == ["[evil]: javascript:alert(1)\n"])
    }

    // MARK: - where a definition is allowed to sit

    /// The same memo an LF editor would have written, with CRLF line endings.
    nonisolated static let crlfFenceMemo =
        "```\r\ncode\r\n```\r\n\r\n[evil]: javascript:alert(1)\r\n\r\n[click][evil]"

    /// Every text the projection shows, wherever it sits: a definition neutralised inside a list
    /// item lands in `items`, one in a paragraph lands in `text`.
    private func texts(_ markdown: String) -> [String] {
        projection(markdown).flatMap { block in
            [block.text] + (block.items ?? []) + (block.rows?.flatMap { $0 } ?? [])
        }
    }

    /// CommonMark registers a link reference definition written inside a LIST ITEM for the whole
    /// document, so `[click][evil]` anywhere below resolves against it. A prefix scanner that
    /// knows about `>` but not about `-`, `*`, `+` or `1.` never sees that line, and the scheme
    /// rule is bypassed by indenting the definition under a bullet.
    @Test(
        "a definition inside a list item answers to the scheme rule too",
        arguments: [
            ("bullet", "- [evil]: javascript:alert(1)\n\n[click][evil]"),
            ("star", "* [evil]: javascript:alert(1)\n\n[click][evil]"),
            ("plus", "+ [evil]: javascript:alert(1)\n\n[click][evil]"),
            ("ordered", "1. [evil]: javascript:alert(1)\n\n[click][evil]"),
            ("ordered with a paren", "1) [evil]: javascript:alert(1)\n\n[click][evil]"),
            ("quoted list", "> - [evil]: javascript:alert(1)\n\n[click][evil]"),
            ("continuation line", "- item\n\n  [evil]: javascript:alert(1)\n\n[click][evil]"),
        ]
    )
    func definitionsInsideListItems(name: String, markdown: String) {
        let shown = texts(markdown)
        #expect(
            shown.contains { $0.contains("[click][evil]") },
            "\(name): the reference resolved — \(shown)"
        )
        #expect(
            shown.contains { $0.contains("[evil]: javascript:alert(1)") },
            "\(name): the refused definition vanished — \(shown)"
        )
    }

    /// A memo written on a device that ends its lines with CRLF is the same memo. If the closing
    /// fence is compared with the `\r` still on it, the fence never closes, everything after it
    /// counts as code, and the definition below is never looked at — while cmark, which
    /// normalises line endings, closes the fence and resolves the reference.
    @Test("a CRLF memo neutralises what an LF memo neutralises")
    func carriageReturnsDoNotHideADefinition() {
        let shown = texts(Self.crlfFenceMemo)
        #expect(shown.contains { $0.contains("[click][evil]") }, "resolved — \(shown)")
        #expect(shown.contains { $0.contains("[evil]: javascript:alert(1)") }, "\(shown)")
        // And the fence itself is untouched: an escape inside code would be visible as a backslash.
        #expect(shown.contains("code\n"), "the fenced code was rewritten — \(shown)")
    }

    /// A blank line is not the only thing that ends a block: an indented code block ends at the
    /// first line that is not indented, and a definition on that line is a definition. Missing
    /// that means the label is never registered, so the reference image below it is not the
    /// app's to drop — and the renderer fetches a URL the SPA never requests.
    @Test("an image whose definition follows indented code is still dropped")
    func imagesResolvedAfterIndentedCodeAreDropped() {
        let markdown = "    code line\n[pic]: https://example.com/red.png\n\n![shot][pic]"
        // The renderer's own output, because a dropped image leaves nothing for the projection to
        // show either way — what matters is that it was never handed the picture.
        let html = ProductionMarkdownProjection.html(markdown)
        #expect(!html.contains("<img"), "the renderer was handed an image:\n\(html)")
        #expect(!html.contains("example.com/red.png"), "the remote URL survived:\n\(html)")
        // The code block is still code, and still says what the author wrote.
        #expect(html.contains("code line"), "the code block was rewritten:\n\(html)")
    }

    /// The liveness half of the two claims above, read off the rendered view rather than off an
    /// `href` cmark's HTML renderer would have blanked anyway.
    @Test(
        "neither spelling paints a live link",
        arguments: [
            ("in a list item", "- [evil]: javascript:alert(1)\n\n[click][evil]"),
            ("after a CRLF fence", Self.crlfFenceMemo),
        ]
    )
    func neitherSpellingIsPainted(name: String, markdown: String) throws {
        let painted = try accentPixels(in: markdown)
        #expect(painted == 0, "\(name): \(painted) accent pixels — the reference stayed a link")
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

/// The four decisions MEMNG-144 settled for both clients, one category at a time.
///
/// Every assertion is read off the block model the app's OWN renderer produced, so each goes red
/// when the renderer changes rather than when a second parser does. The parity fixture pins one
/// example of each; these hold the rule around it — what the decision does NOT do included, which
/// is where a rewrite of the source is most likely to go too far.
@MainActor
@Suite("the render-time decisions for targets the app will not open")
struct MarkdownTargetDecisionTests {
    private func projection(_ markdown: String) -> [MarkdownBlock] {
        ProductionMarkdownProjection.ignoringInvisibleParagraphs(
            ProductionMarkdownProjection.project(markdown)
        )
    }

    // MARK: - a task is a checkbox, the plain item beside it is not

    @Test("a plain item beside tasks is a list item, not an empty checkbox")
    func plainItemAfterTasks() {
        let blocks = projection("- [ ] unchecked item\n- [x] checked item\n- plain item")
        #expect(blocks.map(\.type) == [.task, .task, .list])
        #expect(blocks.map(\.checked) == [false, true, nil])
        #expect(blocks.map(\.text) == ["unchecked item", "checked item", ""])
        #expect(blocks.last?.items == ["plain item"])
        #expect(blocks.allSatisfy { $0.level == 0 && $0.ordered == false })
    }

    @Test("a single task between plain items splits the list on both sides of it")
    func taskBetweenPlainItems() {
        let blocks = projection("- plain one\n- [ ] the only task\n- plain two")
        #expect(blocks.map(\.type) == [.list, .task, .list])
        #expect(blocks.map(\.items) == [["plain one"], nil, ["plain two"]])
        #expect(blocks[1].text == "the only task")
        #expect(blocks[1].checked == false)
    }

    @Test("an ordered list splits the same way and keeps the numbers the author typed")
    func orderedMixedList() {
        let blocks = projection("1. plain\n2. [ ] the task\n3. plain again")
        #expect(blocks.map(\.type) == [.list, .task, .list])
        #expect(blocks.map(\.items) == [["plain"], nil, ["plain again"]])
        #expect(blocks.filter { $0.type == .list }.allSatisfy { $0.ordered == true })
    }

    /// A divergence this phase did NOT invent and cannot reach: `BlockNode.taskList` carries
    /// `isTight` and its items and nothing else, so the ordered-ness of the list a task was
    /// written in is gone before any view or projection sees it — an ordered task item is drawn,
    /// and projected, as an unordered one. No fixture case covers it (every task case the SPA
    /// pins is a bullet list), and closing it means not rendering task lists through MarkdownUI
    /// at all. Pinned so it stays visible and cannot change unnoticed.
    @Test("a task in an ordered list loses its numbering — today's divergence, pinned")
    func orderedTaskItemsProjectUnordered() {
        let blocks = projection("1. [ ] the task")
        #expect(blocks.map(\.type) == [.task])
        #expect(blocks.first?.ordered == false)
    }

    /// The other half of the rule: a list that does not mix is left exactly as it was, so the
    /// split cannot start breaking ordinary lists into pieces.
    @Test(
        "a list of one kind stays one list",
        arguments: [
            ("all plain", "- alpha\n- beta\n- gamma", [MarkdownBlock.Kind.list]),
            ("all tasks", "- [x] a\n- [ ] b", [MarkdownBlock.Kind.task, .task]),
            (
                "already two lists", "- alpha\n* [ ] task",
                [MarkdownBlock.Kind.list, .task]
            ),
        ]
    )
    func unmixedListsAreLeftAlone(name: String, markdown: String, kinds: [MarkdownBlock.Kind]) {
        #expect(projection(markdown).map(\.type) == kinds, "\(name)")
    }

    /// A list written inside a fence is the author's code, not a list — restyling a marker there
    /// would rewrite a line of someone's example.
    @Test("a mixed list inside a fence is code, character for character")
    func mixedListInsideAFenceIsCode() {
        let markdown = "```\n- [x] done\n- plain item\n```"
        let blocks = projection(markdown)
        #expect(blocks.map(\.type) == [.code])
        #expect(blocks.first?.text == "- [x] done\n- plain item\n")
    }

    // MARK: - a bare host name is a link, with the scheme linkify-it prepends

    @Test("a bare domain becomes an http link the policy still has to allow")
    func bareDomainIsLinkified() throws {
        let blocks = projection("Visit example.com for the docs.")
        #expect(blocks.map(\.text) == ["Visit example.com for the docs."])
        let link = try #require(blocks.first?.links.first)
        #expect(blocks.first?.links.count == 1)
        #expect(link == MarkdownLink(href: "http://example.com", text: "example.com"))
        // The point of the `http://` prefix: the render change is a projection, and the seam that
        // decides what a tap opens is untouched and still says yes to this and no to the rest.
        #expect(MemoRenderPolicy.mayOpen(destination: link.href))
        #expect(!MemoRenderPolicy.mayOpen(destination: "ftp://example.com"))
    }

    @Test("a bare domain carries its path and query into the destination")
    func bareDomainWithAPath() {
        let blocks = projection("See example.com/docs?a=1 first.")
        #expect(
            blocks.first?.links
                == [
                    MarkdownLink(
                        href: "http://example.com/docs?a=1", text: "example.com/docs?a=1"
                    )
                ]
        )
    }

    @Test(
        "what is not a bare domain stays text",
        arguments: [
            ("an unknown TLD", "Ask example.internal for it."),
            ("a file name", "Open notes.txt now."),
            ("inside a code span", "Notes in `~/trips/2026.md`."),
            ("part of a path", "Read /var/log/example.com now."),
            ("a version number", "Shipped 1.2.3 today."),
        ]
    )
    func notALink(name: String, markdown: String) {
        #expect(projection(markdown).allSatisfy { $0.links.isEmpty }, "\(name)")
    }

    /// markdown-it never linkifies inside a link, so a host name written in a label is text.
    @Test("a host name inside a link label is not a second link")
    func labelsAreNotLinkified() {
        let blocks = projection("[see example.com](https://example.com/a)")
        #expect(
            blocks.first?.links
                == [MarkdownLink(href: "https://example.com/a", text: "see example.com")]
        )
    }

    // MARK: - an image the app will not fetch leaves its alt text behind

    @Test("an image with a refused source shows its alt text as plain words")
    func unsafeImageKeepsItsAlt() {
        let blocks = projection(
            "![A red square](javascript:alert(1))\n\n![The chart](data:text/html,hi)"
        )
        #expect(blocks.map(\.type) == [.paragraph, .paragraph])
        #expect(blocks.map(\.text) == ["A red square", "The chart"])
        #expect(blocks.allSatisfy { $0.links.isEmpty })
        let html = ProductionMarkdownProjection.html("![A red square](javascript:alert(1))")
        #expect(!html.contains("<img"), "the renderer was handed an image:\n\(html)")
        #expect(!html.contains("javascript"), "the destination survived:\n\(html)")
    }

    /// `renderInlineAsText` is what the SPA builds the replacement from, and it reduces the alt to
    /// what it SAYS — an emphasised alt is not emphasised on screen.
    @Test("markup inside a refused alt is reduced to its text")
    func unsafeImageAltIsPlain() {
        let blocks = projection("![*bold* alt](javascript:alert(1))")
        #expect(blocks.map(\.text) == ["bold alt"])
        #expect(blocks.allSatisfy { $0.inline.isEmpty })
    }

    /// An alt that would open a block of its own if it were put back unescaped.
    @Test("a refused alt cannot open a construct of its own")
    func unsafeImageAltCannotEscapeItsParagraph() {
        let blocks = projection("![# not a heading](javascript:alert(1))")
        #expect(blocks.map(\.type) == [.paragraph])
        #expect(blocks.map(\.text) == ["# not a heading"])
    }

    /// The other half: an image whose source the SPA WOULD have kept is removed with its alt, the
    /// way a sanitiser removes a void element — and no image is ever fetched either way.
    @Test("an image with an allowed source is dropped whole, alt included")
    func allowedImageIsDroppedWhole() {
        #expect(projection("![A red square](https://example.com/red.png)").isEmpty)
        let source = URL(string: "https://example.com/red.png")
        #expect(MemoRenderPolicy.mayLoadImage(from: source) == false)
    }

    // MARK: - a link the app will not open is its label alone

    @Test("an ftp and a scheme-relative link render as their labels, with no anchor")
    func refusedTargetsAreLabels() {
        let markdown =
            "[the file](ftp://example.com/pub/readme.txt) and [the host](//example.com/path)"
            + " are not links."
        let blocks = projection(markdown)
        #expect(blocks.map(\.text) == ["the file and the host are not links."])
        #expect(blocks.allSatisfy { $0.links.isEmpty })
        let html = ProductionMarkdownProjection.html(markdown)
        #expect(!html.contains("<a "), "an anchor survived:\n\(html)")
        // The positive control for that 0-hit: the same shape with an allowed scheme IS an anchor.
        #expect(ProductionMarkdownProjection.html("[site](https://example.com/)").contains("<a "))
    }

    @Test("a relative path is a label too")
    func relativeTargetIsALabel() {
        let blocks = projection("[the doc](/docs/readme.md) is not a link.")
        #expect(blocks.map(\.text) == ["the doc is not a link."])
        #expect(blocks.allSatisfy { $0.links.isEmpty })
    }

    /// `memo_target_policy` drops the anchor and keeps the label's own tokens, so what the author
    /// emphasised is still emphasised.
    @Test("the emphasis inside a refused label survives it")
    func refusedLabelKeepsItsEmphasis() {
        let blocks = projection("[**bold**](ftp://example.com/x)")
        #expect(blocks.map(\.text) == ["bold"])
        #expect(blocks.first?.inline == [MarkdownSpan(type: .strong, text: "bold")])
        #expect(blocks.allSatisfy { $0.links.isEmpty })
    }

    /// The line between the two rules: markdown-it's `validateLink` refuses these before a link
    /// exists at all, so the characters the author typed stay on screen — brackets, destination
    /// and all. Reducing them to their label would be the wrong decision, and the fixture pins it.
    @Test("a destination markdown-it refuses stays literal markdown")
    func refusedDestinationsStayLiteral() {
        let blocks = projection("[js](javascript:alert(1)) and [data](data:text/html,hi) are not.")
        #expect(
            blocks.map(\.text)
                == ["[js](javascript:alert(1)) and [data](data:text/html,hi) are not."]
        )
        #expect(blocks.allSatisfy { $0.links.isEmpty })
    }
}
