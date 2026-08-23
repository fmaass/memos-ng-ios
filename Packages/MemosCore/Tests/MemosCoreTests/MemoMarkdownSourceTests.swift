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
}
