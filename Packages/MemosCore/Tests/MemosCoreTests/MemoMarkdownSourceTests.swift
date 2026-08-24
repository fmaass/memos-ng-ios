import MemosCore
import Testing

@Suite("MemoMarkdownSource.prepare")
struct MemoMarkdownSourceTests {
    @Test("drops tag-only lines")
    func dropsTagLines() {
        #expect(MemoMarkdownSource.prepare("#curated\nHello") == "Hello")
    }

    @Test("leaves an http, https or mailto link tappable")
    func keepsSafeLinks() {
        let source = "[a](https://example.com) [b](http://example.com) [c](mailto:a@example.com)"
        #expect(MemoMarkdownSource.prepare(source) == source)
    }

    @Test("neutralises a link the SPA would render as plain text")
    func neutralisesUnsafeLinks() {
        #expect(
            MemoMarkdownSource.prepare("[js](javascript:alert(1))")
                == "\\[js](javascript:alert(1))"
        )
        #expect(
            MemoMarkdownSource.prepare("[d](data:text/html,hi)") == "\\[d](data:text/html,hi)"
        )
        #expect(MemoMarkdownSource.prepare("[f](ftp://example.com)") == "\\[f](ftp://example.com)")
    }

    @Test("removes an image whole, alt text included")
    func removesImages() {
        #expect(MemoMarkdownSource.prepare("![A red square](https://example.com/red.png)") == "")
        let source = "before ![alt](https://e.com/a.png) after"
        #expect(MemoMarkdownSource.prepare(source) == "before  after")
    }

    @Test("leaves link syntax inside a code span alone")
    func leavesCodeSpans() {
        let source = "`[js](javascript:alert(1))`"
        #expect(MemoMarkdownSource.prepare(source) == source)
    }

    @Test("leaves prose that merely contains brackets alone")
    func leavesProse() {
        let source = "a [bracket] and (parens)"
        #expect(MemoMarkdownSource.prepare(source) == source)
    }

    /// Escaping the definition's own bracket is what markdown-it's refusal to register it looks
    /// like: the line stops being a definition and stays on screen, and every reference that named
    /// the label has nothing to resolve to, so it is literal text as well. What the renderer then
    /// does with that is asserted in `ReferenceLinkTests`; this is the string it is handed.
    @Test("neutralises the definition of a reference link the SPA would refuse")
    func neutralisesUnsafeReferenceDefinitions() {
        #expect(
            MemoMarkdownSource.prepare("[click][evil]\n\n[evil]: javascript:alert(1)")
                == "[click][evil]\n\n\\[evil]: javascript:alert(1)"
        )
        #expect(
            MemoMarkdownSource.prepare("[evil]:\njavascript:alert(1)")
                == "\\[evil]:\njavascript:alert(1)"
        )
        #expect(
            MemoMarkdownSource.prepare("[x]: <data:text/html,hi>") == "\\[x]: <data:text/html,hi>"
        )
        #expect(MemoMarkdownSource.prepare("> [e]: file:///etc") == "> \\[e]: file:///etc")
    }

    @Test("leaves the definition of an allowed scheme alone")
    func keepsSafeReferenceDefinitions() {
        let source = "[site][home]\n\n[home]: https://example.com/a?b=1"
        #expect(MemoMarkdownSource.prepare(source) == source)
        let titled = "[home]: https://example.com/ \"Home\""
        #expect(MemoMarkdownSource.prepare(titled) == titled)
    }

    /// A line inside a fence is code, and a backslash there would be visible.
    @Test("leaves a definition-shaped line inside a code block alone")
    func leavesFencedDefinitions() {
        let fenced = "```\n[evil]: javascript:alert(1)\n```"
        #expect(MemoMarkdownSource.prepare(fenced) == fenced)
        let indented = "    [evil]: javascript:alert(1)"
        #expect(MemoMarkdownSource.prepare(indented) == indented)
    }

    @Test("removes a reference image whole, and only when the label resolves")
    func removesReferenceImages() {
        #expect(
            MemoMarkdownSource.prepare("![shot][pic]\n\n[pic]: https://e.com/a.png")
                == "\n\n[pic]: https://e.com/a.png"
        )
        #expect(
            MemoMarkdownSource.prepare("![shot][]\n\n[shot]: https://e.com/a.png")
                == "\n\n[shot]: https://e.com/a.png"
        )
        // Nothing defines `nope`, so both renderers show the characters as they are.
        let unresolved = "![alt][nope] stays"
        #expect(MemoMarkdownSource.prepare(unresolved) == unresolved)
    }
}
