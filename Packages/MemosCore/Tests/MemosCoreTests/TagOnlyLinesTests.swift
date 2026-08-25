import MemosCore
import Testing

// The same vectors as frontend/src/lib/__tests__/markdown.tagstrip.spec.ts.
@Suite("stripTagOnlyLines")
struct TagOnlyLinesTests {
    @Test("drops a line that is only a tag")
    func dropsSingleTag() {
        #expect(stripTagOnlyLines("#curated") == "")
        #expect(stripTagOnlyLines("#curated ") == "")
    }

    @Test("drops a line of several tags")
    func dropsSeveralTags() {
        #expect(stripTagOnlyLines("#curated #trip") == "")
    }

    @Test("keeps prose that contains an inline tag")
    func keepsInlineTag() {
        #expect(stripTagOnlyLines("see #curated here") == "see #curated here")
    }

    @Test("keeps a real markdown heading (space after #)")
    func keepsHeading() {
        #expect(stripTagOnlyLines("# Heading") == "# Heading")
        #expect(stripTagOnlyLines("## Sub") == "## Sub")
    }

    @Test("removes only the tag line from mixed content")
    func removesOnlyTagLine() {
        #expect(stripTagOnlyLines("#curated\nMy trip photos") == "My trip photos")
    }

    /// A tag-only line written on a device that ends its lines with CRLF keeps its carriage
    /// return here, because it keeps it in the SPA: `TAG_ONLY_LINE` ends in `[ \t]*$` and
    /// JavaScript's `$` matches only at the end of the STRING unless the regex carries `/m`, so
    /// `#curated\r` does not match and the line is not dropped. Both clients then render it as
    /// body text. Stripping it here would be spec-tidier and a parity break, which is the wrong
    /// trade for this layer. (Probed against the SPA's own regex; MEMNG-144.)
    @Test("a trailing carriage return keeps the line, exactly as the SPA keeps it")
    func carriageReturnIsNotATagOnlyLine() {
        #expect(!isTagOnlyLine("#curated\r"))
        #expect(!isTagOnlyLine("#curated \r"))
        #expect(!isTagOnlyLine("#a #b\r"))
        #expect(stripTagOnlyLines("#curated\r\nHello") == "#curated\r\nHello")
        // The control: the same line without the carriage return IS dropped, in both clients.
        #expect(isTagOnlyLine("#curated"))
        #expect(stripTagOnlyLines("#curated\nHello") == "Hello")
    }

    @Test("isTagOnlyLine agrees with the SPA on the edge cases")
    func edgeCases() {
        #expect(isTagOnlyLine("#curated"))
        #expect(isTagOnlyLine("  #a\t#b  "))
        #expect(!isTagOnlyLine("#"))
        #expect(!isTagOnlyLine("# Heading"))
        #expect(!isTagOnlyLine("see #curated here"))
        #expect(!isTagOnlyLine(""))
        #expect(!isTagOnlyLine("#curated word"))
    }
}
