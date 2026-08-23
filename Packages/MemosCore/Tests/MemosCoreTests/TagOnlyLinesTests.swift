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
