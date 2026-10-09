import MemosCore
import Testing

/// The pinned trip's tag, added to a new memo with the server's reading of what a tag is.
///
/// The vectors mirror memos-ng's `TAG_RE = re.compile(r"#(\w+)")` with `findall` over the whole
/// content: Unicode `\w`, greedy, no boundary before `#`, exact and case-sensitive.
@Suite("Pinned tag")
struct PinnedTagTests {
    @Test("the server's reading: every #word, greedy, no boundary before the #")
    func serverReading() {
        #expect(serverHashtags(in: "") == [])
        #expect(serverHashtags(in: "no tags here") == [])
        #expect(serverHashtags(in: "#a #b") == ["a", "b"])
        #expect(serverHashtags(in: "#a#b") == ["a", "b"])
        #expect(serverHashtags(in: "##a") == ["a"])
        #expect(serverHashtags(in: "x#portugal2026") == ["portugal2026"])
        #expect(serverHashtags(in: "(#portugal2026)") == ["portugal2026"])
        #expect(serverHashtags(in: "#portugal2026x") == ["portugal2026x"])
        #expect(serverHashtags(in: "#port-ugal") == ["port"])
        #expect(serverHashtags(in: "# heading") == [])
        #expect(serverHashtags(in: "#snake_case") == ["snake_case"])
        #expect(serverHashtags(in: "#a #a") == ["a", "a"])
    }

    @Test("Unicode word characters are tag characters; a combining mark ends the tag")
    func unicodeWords() {
        #expect(serverHashtags(in: "#zürich") == ["zürich"])
        #expect(serverHashtags(in: "#東京") == ["東京"])
        #expect(serverHashtags(in: "#½") == ["½"])
        // u + U+0308: Python's \w does not take a combining mark, so the server reads "zu".
        #expect(serverHashtags(in: "#zu\u{0308}rich") == ["zu"])
    }

    @Test("a tag already anywhere in the text is carried; near misses are not")
    func carries() {
        #expect(contentCarriesTag("Lisbon\n#portugal2026", tag: "portugal2026"))
        #expect(contentCarriesTag("#portugal2026 at the start", tag: "portugal2026"))
        #expect(contentCarriesTag("x#portugal2026", tag: "portugal2026"))
        #expect(contentCarriesTag("(#portugal2026)", tag: "portugal2026"))
        #expect(contentCarriesTag("in #zürich today", tag: "zürich"))
        #expect(!contentCarriesTag("portugal2026 without a hash", tag: "portugal2026"))
        #expect(!contentCarriesTag("#Portugal2026", tag: "portugal2026"))
        #expect(!contentCarriesTag("#portugal2026x", tag: "portugal2026"))
        #expect(!contentCarriesTag("#portugal", tag: "portugal2026"))
        #expect(!contentCarriesTag("", tag: "portugal2026"))
        #expect(!contentCarriesTag("#portugal2026", tag: ""))
        // The precomposed tag is not carried by a decomposed spelling the server reads as "zu".
        #expect(!contentCarriesTag("#zu\u{0308}rich", tag: "zürich"))
    }

    @Test("the tag goes on a line of its own at the end")
    func appends() {
        #expect(appendingPinnedTag("portugal2026", to: "Lisbon") == "Lisbon\n#portugal2026")
        #expect(
            appendingPinnedTag("portugal2026", to: "two\nlines") == "two\nlines\n#portugal2026")
        #expect(appendingPinnedTag("zürich", to: "lake") == "lake\n#zürich")
    }

    @Test("empty content is the tag alone; trailing blanks never become a blank line")
    func edges() {
        #expect(appendingPinnedTag("portugal2026", to: "") == "#portugal2026")
        #expect(appendingPinnedTag("portugal2026", to: "  \n\n") == "#portugal2026")
        #expect(appendingPinnedTag("portugal2026", to: "Lisbon\n") == "Lisbon\n#portugal2026")
        #expect(appendingPinnedTag("portugal2026", to: "Lisbon\n\n") == "Lisbon\n#portugal2026")
        #expect(appendingPinnedTag("portugal2026", to: "Lisbon  \t") == "Lisbon\n#portugal2026")
        #expect(appendingPinnedTag("", to: "Lisbon\n") == "Lisbon\n")
    }

    @Test("a text that already carries the tag is left exactly as it is")
    func idempotent() {
        for carried in [
            "Lisbon\n#portugal2026", "#portugal2026 first", "x#portugal2026", "(#portugal2026)",
            "trailing #portugal2026\n",
        ] {
            #expect(
                appendingPinnedTag("portugal2026", to: carried) == carried,
                "appended to a text that already carries the tag: \(carried.debugDescription)")
        }
        let once = appendingPinnedTag("portugal2026", to: "Lisbon")
        #expect(appendingPinnedTag("portugal2026", to: once) == once)
    }

    @Test("near misses are not the tag, so the line is still added")
    func nearMissesStillAppend() {
        #expect(
            appendingPinnedTag("portugal2026", to: "portugal2026 rocks")
                == "portugal2026 rocks\n#portugal2026")
        #expect(
            appendingPinnedTag("portugal2026", to: "#Portugal2026")
                == "#Portugal2026\n#portugal2026")
        #expect(
            appendingPinnedTag("portugal2026", to: "#portugal2026x")
                == "#portugal2026x\n#portugal2026")
    }

    @Test("the timeline card still hides the appended line")
    func cardHidesTheLine() {
        let appended = appendingPinnedTag("portugal2026", to: "Lisbon at dusk")
        #expect(stripTagOnlyLines(appended) == "Lisbon at dusk")
    }
}
