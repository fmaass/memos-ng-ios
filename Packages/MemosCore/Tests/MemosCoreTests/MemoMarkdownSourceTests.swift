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

    /// A destination markdown-it's `validateLink` REFUSES never becomes a link at all, so the
    /// characters the author typed stay on screen — brackets, destination and all.
    @Test("leaves a destination markdown-it refuses as literal markdown")
    func neutralisesUnsafeLinks() {
        #expect(
            MemoMarkdownSource.prepare("[js](javascript:alert(1))")
                == "\\[js](javascript:alert(1))"
        )
        #expect(
            MemoMarkdownSource.prepare("[d](data:text/html,hi)") == "\\[d](data:text/html,hi)"
        )
        #expect(
            MemoMarkdownSource.prepare("[v](vbscript:msgbox(1))")
                == "\\[v](vbscript:msgbox(1))"
        )
    }

    /// The other verdict (MEMNG-144): markdown-it BUILDS the link, and `memo_target_policy` then
    /// drops the anchor and keeps the label's own tokens. So the destination disappears and the
    /// label stays — emphasis included, and with linkify off inside it the way markdown-it has it.
    @Test("reduces a link the SPA will not open to its label alone")
    func refusedTargetsBecomeLabels() {
        #expect(MemoMarkdownSource.prepare("[f](ftp://example.com)") == "f")
        #expect(MemoMarkdownSource.prepare("[the host](//example.com/path)") == "the host")
        #expect(MemoMarkdownSource.prepare("[the doc](/docs/readme.md)") == "the doc")
        #expect(MemoMarkdownSource.prepare("[**bold**](ftp://example.com)") == "**bold**")
        #expect(
            MemoMarkdownSource.prepare("[see example.com](ftp://e.example)") == "see example.com"
        )
    }

    @Test("removes an image whole, alt text included")
    func removesImages() {
        #expect(MemoMarkdownSource.prepare("![A red square](https://example.com/red.png)") == "")
        let source = "before ![alt](https://e.com/a.png) after"
        #expect(MemoMarkdownSource.prepare(source) == "before  after")
    }

    /// An image whose source is not a scheme this client will open keeps its alt as PLAIN text —
    /// what `renderInlineAsText` builds, so markup is reduced to what it says, and escaped so the
    /// words cannot open a construct of their own once they are back in the source.
    @Test("an image with a refused source leaves its alt text behind")
    func refusedImagesKeepTheirAlt() {
        #expect(
            MemoMarkdownSource.prepare("![A red square](javascript:alert(1))") == "A red square"
        )
        #expect(MemoMarkdownSource.prepare("![*bold* alt](data:text/html,hi)") == "bold alt")
        #expect(
            MemoMarkdownSource.prepare("![# not a heading](javascript:x)") == "\\# not a heading"
        )
    }

    /// markdown-it runs linkify-it with its stock TLD table, so a bare host name is a link with
    /// the `http://` linkify-it prepends — and nothing else is.
    @Test("linkifies a bare host name, and only a real one")
    func linkifiesBareDomains() {
        #expect(
            MemoMarkdownSource.prepare("Visit example.com for the docs.")
                == "Visit [example.com](<http://example.com>) for the docs."
        )
        for text in [
            "Ask example.internal for it.", "Open notes.txt now.", "Shipped 1.2.3 today.",
            "Read /var/log/example.com now.", "Mail memo@example.com today.",
            "Bare https://example.com/a?b=1 stays.", "`~/trips/2026.md` is code.",
        ] {
            #expect(MemoMarkdownSource.prepare(text) == text, "\(text)")
        }
    }

    /// cmark-gfm makes the whole list a task list as soon as one item carries a checkbox, and
    /// MarkdownUI's block model has no room for the difference — so a mixed list is split into
    /// consecutive lists here, by the one thing CommonMark uses to tell two lists apart.
    @Test("splits a list that mixes tasks with plain items")
    func splitsMixedTaskLists() {
        #expect(
            MemoMarkdownSource.prepare("- [ ] a\n- [x] b\n- plain")
                == "- [ ] a\n- [x] b\n* plain"
        )
        #expect(
            MemoMarkdownSource.prepare("- plain one\n- [ ] task\n- plain two")
                == "- plain one\n* [ ] task\n- plain two"
        )
        #expect(
            MemoMarkdownSource.prepare("1. plain\n2. [ ] task") == "1. plain\n2) [ ] task"
        )
    }

    /// The other half: a list of one kind, a list already split by its markers, and a list written
    /// inside a fence are all the author's characters.
    @Test(
        "a list that does not mix is left alone",
        arguments: [
            "- alpha\n- beta", "- [x] a\n- [ ] b", "- alpha\n* [ ] task",
            "```\n- [x] done\n- plain\n```", "- [x] outer\n  - [ ] inner\n- [ ] last",
        ]
    )
    func unmixedListsAreUntouched(source: String) {
        #expect(MemoMarkdownSource.prepare(source) == source)
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

    /// A definition markdown-it REFUSES is not a definition at all. Its `reference` rule returns
    /// false, the paragraph rule takes the line instead, and a link reference definition cannot
    /// interrupt a paragraph — so the duplicate below it never registers either, and the
    /// reference image that names the label is literal text in the SPA. Registering it here
    /// deletes a line the reader was meant to see.
    ///
    /// Probed against markdown-it 14 (`html: false`, `linkify: true`, `breaks: true`), which
    /// renders both definition lines as ONE paragraph and leaves `![alt][pic]` on screen.
    @Test("a duplicate definition under a refused one never resolves")
    func aRefusedDefinitionOpensAParagraph() {
        let source = "[pic]: javascript:alert(1)\n[pic]: https://e.com/red.png\n\n![alt][pic]"
        #expect(
            MemoMarkdownSource.prepare(source)
                == "\\[pic]: javascript:alert(1)\n[pic]: https://e.com/red.png\n\n![alt][pic]"
        )
    }

    /// The same rule read from the other end: a definition cannot interrupt a paragraph, so a
    /// definition-shaped line that follows prose registers nothing — and neither does the one
    /// after THAT, which is where a scanner that keeps its block-start state through a
    /// definition-shaped line goes wrong.
    @Test("a definition-shaped line inside a paragraph registers nothing")
    func definitionsInsideAParagraphRegisterNothing() {
        let source = "paragraph\n[a]: https://e.com/a\n[pic]: https://e.com/red.png\n\n![alt][pic]"
        #expect(MemoMarkdownSource.prepare(source) == source)
    }

    /// The control for both, so the fix cannot be "stop registering anything": with the blank line
    /// CommonMark needs, the later definition IS registered — markdown-it renders an `<img>`
    /// there and the sanitiser drops it, so the reference image has to go here too.
    @Test("a duplicate definition in a block of its own still registers")
    func aDuplicateInItsOwnBlockStillRegisters() {
        let source = "[pic]: javascript:alert(1)\n\n[pic]: https://e.com/red.png\n\n![alt][pic]"
        #expect(
            MemoMarkdownSource.prepare(source)
                == "\\[pic]: javascript:alert(1)\n\n[pic]: https://e.com/red.png\n\n"
        )
    }

    /// Code is the author's, character for character. markdown-it parses no inline at all inside a
    /// code block, so neither the escape nor the image deletion may reach one — a backslash would
    /// be on screen and a deleted line would simply be gone. Only a three-backtick fence used to
    /// survive here, and only by accident: its backticks toggled the code-span flag.
    @Test(
        "code keeps every character, whatever it says",
        arguments: [
            ("tilde fence", "[pic]: https://e.com/red.png\n\n~~~\n![alt][pic]\n~~~"),
            ("four-backtick fence", "[pic]: https://e.com/red.png\n\n````\n![alt][pic]\n````"),
            ("indented code", "[pic]: https://e.com/red.png\n\n    ![alt][pic]"),
            ("fence in a list item", "[pic]: https://e.com/red.png\n\n- ~~~\n  ![alt][pic]\n  ~~~"),
            ("fence in a quote", "[pic]: https://e.com/red.png\n\n> ~~~\n> ![alt][pic]\n> ~~~"),
            ("tilde fence, unsafe link", "~~~\n[x](javascript:alert(1))\n~~~"),
            ("quoted fence, unsafe link", "> ~~~\n> [x](javascript:alert(1))\n> ~~~"),
            ("list fence, unsafe link", "- ~~~\n  [x](javascript:alert(1))\n  ~~~"),
            ("indented code, unsafe link", "    [x](javascript:alert(1))"),
            ("indented code after a heading", "# Heading\n    [x](javascript:alert(1))"),
            // A closing fence cannot carry a container prefix its opener did not have, so a line
            // that strips to backticks at a DEEPER depth is code, not the closer. Reading it as
            // one hands the rest of the block to the prose walk, which writes a backslash into
            // the author's code. (markdown-it renders all three of these as one code block.)
            ("quoted closer", "```\ncode one\n> ```\n[x](javascript:alert(1))\n```"),
            ("quoted tilde closer", "~~~\ncode one\n> ~~~\n[x](javascript:alert(1))\n~~~"),
            ("deeper closer", "> ```\n> code one\n> > ```\n> [x](javascript:alert(1))\n> ```"),
            // A quote holds a line only while that line carries its marker — a fenced block is
            // not a paragraph, so it cannot be lazily continued. An unquoted line therefore ENDS
            // the quote at any indentation, and the fence it opens is a new one whose content is
            // the author's code. Indentation of 1-3 columns used to make this line look like a
            // list item's continuation, which closed the quoted fence and escaped inside code.
            ("one-space unquoted line", "> ```\n> code\n ```\n[x](javascript:alert(1))"),
            ("three-space unquoted line", "> ```\n> code\n   ```\n[x](javascript:alert(1))"),
            ("one-space tilde marker", "> ```\n> code\n ~~~\n[x](javascript:alert(1))"),
        ]
    )
    func codeIsNeverRewritten(name: String, source: String) {
        #expect(MemoMarkdownSource.prepare(source) == source, "\(name)")
    }

    /// The control for the rule above, so "a fence only closes at its own depth" cannot become
    /// "a fence never closes": a longer closer at the same depth closes, a quoted closer closes a
    /// quoted fence, and the continuation line of a list item closes the fence opened in it —
    /// that line carries no marker of its own, so its depth reads as zero while it is still
    /// inside the item. All three end the block in markdown-it too.
    @Test("the closers that are real still close the block")
    func realClosersStillClose() {
        // A longer closer at the same depth.
        #expect(
            MemoMarkdownSource.prepare("```\ncode one\n`````\n[x](javascript:alert(1))")
                == "```\ncode one\n`````\n\\[x](javascript:alert(1))"
        )
        // A quoted closer for a fence opened in the same quote.
        #expect(
            MemoMarkdownSource.prepare("> ```\n> code one\n> ```\n\n[x](javascript:alert(1))")
                == "> ```\n> code one\n> ```\n\n\\[x](javascript:alert(1))"
        )
        // The continuation line of a list item, which carries no marker of its own.
        #expect(
            MemoMarkdownSource.prepare("- ~~~\n  code one\n  ~~~\n\n[x](javascript:alert(1))")
                == "- ~~~\n  code one\n  ~~~\n\n\\[x](javascript:alert(1))"
        )
    }

    /// The other side of that boundary, all three probed against markdown-it.
    ///
    /// Four columns of indent is not a fence marker at all, so after the quote ends the line is an
    /// indented code block and the line under it is prose again. At the SAME depth the tolerance
    /// is the spec's: a closer may be indented 0-3 columns, and at 4 it stops being a closer and
    /// stays content.
    @Test("indentation decides what the line after a quoted fence is")
    func indentationDecidesTheLineAfterAQuotedFence() {
        // Four columns: the quote still ends, the marker is indented code, the link is prose.
        #expect(
            MemoMarkdownSource.prepare("> ```\n> code\n    ```\n[x](javascript:alert(1))")
                == "> ```\n> code\n    ```\n\\[x](javascript:alert(1))"
        )
        // Three columns at the same depth: a closer, so what follows is prose.
        #expect(
            MemoMarkdownSource.prepare("```\ncode\n   ```\n[x](javascript:alert(1))")
                == "```\ncode\n   ```\n\\[x](javascript:alert(1))"
        )
        // Four columns at the same depth: not a closer, so the block runs on and holds the link.
        let unclosed = "```\ncode\n    ```\n[x](javascript:alert(1))"
        #expect(MemoMarkdownSource.prepare(unclosed) == unclosed)
    }

    /// The trace a review walked by hand, pinned so it stops being accidental: an unquoted line
    /// ends the quote AND the fence opened inside it, the lines after it are prose, and the next
    /// fence is a new one whose content is code. markdown-it renders exactly that — an empty code
    /// block in the quote, one paragraph, then a code block.
    @Test("an unquoted line ends the quoted fence, and the next fence starts fresh")
    func anUnquotedLineEndsAQuotedFence() {
        #expect(
            MemoMarkdownSource.prepare(
                "> ```\n[x](javascript:alert(1))\nplain\n```\n[y](javascript:alert(1))"
            ) == "> ```\n\\[x](javascript:alert(1))\nplain\n```\n[y](javascript:alert(1))"
        )
        let literal = "> ```\ncode\nplain\n```\nmore"
        #expect(MemoMarkdownSource.prepare(literal) == literal)
    }

    /// A backtick fence's info string may not contain a backtick — that line is not a fence at
    /// all, and markdown-it renders it as paragraph text with the line below it as more paragraph
    /// text. Opening a code region there leaves the prose under it unneutralised: a fidelity
    /// divergence, not a hole, because `MemoRenderPolicy` refuses the destination at render time
    /// whatever the parse did. A tilde fence's info may hold anything, backticks included.
    @Test("a backtick in a backtick fence's info string opens no code")
    func backtickInAnInfoStringIsNotAFence() {
        #expect(
            MemoMarkdownSource.prepare("```foo`bar\n[x](javascript:alert(1))\n```")
                == "```foo`bar\n\\[x](javascript:alert(1))\n```"
        )
        #expect(
            MemoMarkdownSource.prepare("```a`b\n[x](javascript:alert(1))")
                == "```a`b\n\\[x](javascript:alert(1))"
        )
        let tilde = "~~~foo`bar\n[x](javascript:alert(1))\n~~~"
        #expect(MemoMarkdownSource.prepare(tilde) == tilde)
        let plain = "```js\n[x](javascript:alert(1))\n```"
        #expect(MemoMarkdownSource.prepare(plain) == plain)
    }

    /// The control for that one: the SAME text one indent level out is prose, where the rule still
    /// applies. An indented line that merely continues a paragraph is prose too — markdown-it
    /// renders `paragraph\n    [x](…)` as one paragraph, not as code.
    @Test("prose that looks indented is still prose")
    func lazyContinuationsAreNotCode() {
        #expect(
            MemoMarkdownSource.prepare("paragraph\n    [x](javascript:alert(1))")
                == "paragraph\n    \\[x](javascript:alert(1))"
        )
    }

    /// The class between "refused" and "tappable", in REFERENCE spelling (MEMNG-165).
    ///
    /// markdown-it's `validateLink` ACCEPTS `ftp:`, a scheme-relative `//host` and a relative
    /// path, so the definition registers, the definition line is consumed like any other, and
    /// `memo_target_policy` then drops the anchor off the link it built — the label alone is
    /// what the SPA shows. Neutralising the definition instead (which is what a scanner that
    /// asks `isTappableScheme` here does) leaves the definition line AND the whole reference on
    /// screen as literal markup, which is not what a reader of the same memo sees on the web.
    @Test(
        "reduces a reference link the SPA will not open to its label alone",
        arguments: [
            (
                "ftp, in all three spellings",
                "[the file][f], a collapsed [f][] and a bare [f].\n\n[f]: ftp://example.com/pub",
                "the file, a collapsed f and a bare f.\n\n[f]: ftp://example.com/pub"
            ),
            (
                "scheme-relative and relative",
                "[the host][h] and [the page][p].\n\n[h]: //example.com/path\n[p]: /docs/a.md",
                "the host and the page.\n\n[h]: //example.com/path\n[p]: /docs/a.md"
            ),
            (
                "the label keeps its own emphasis",
                "[**bold**][f]\n\n[f]: ftp://example.com/pub",
                "**bold**\n\n[f]: ftp://example.com/pub"
            ),
            (
                "the destination on the line after the label",
                "[the file][f]\n\n[f]:\nftp://example.com/pub",
                "the file\n\n[f]:\nftp://example.com/pub"
            ),
        ]
    )
    func referenceTargetsBecomeLabels(name: String, source: String, expected: String) {
        #expect(MemoMarkdownSource.prepare(source) == expected, "\(name)")
    }

    /// The image half of the same rule: the image goes either way, and a source this client will
    /// not open leaves the alt behind as plain text — `renderInlineAsText`'s output, escaped so
    /// the words cannot open a construct of their own back in the source.
    @Test(
        "a reference image the SPA will not fetch leaves its alt text behind",
        arguments: [
            (
                "ftp",
                "![the chart][pic] and nothing else.\n\n[pic]: ftp://example.com/chart.png",
                "the chart and nothing else.\n\n[pic]: ftp://example.com/chart.png"
            ),
            (
                "a data image markdown-it accepts",
                "![the chart][pic]\n\n[pic]: data:image/png;base64,iVBORw0KGgo=",
                "the chart\n\n[pic]: data:image/png;base64,iVBORw0KGgo="
            ),
            (
                "the alt is reduced to what it says",
                "![*the* chart][pic]\n\n[pic]: ftp://example.com/chart.png",
                "the chart\n\n[pic]: ftp://example.com/chart.png"
            ),
            (
                "and escaped, so it opens nothing",
                "![# not a heading][pic]\n\n[pic]: ftp://example.com/chart.png",
                "\\# not a heading\n\n[pic]: ftp://example.com/chart.png"
            ),
        ]
    )
    func referenceImagesKeepTheirAlt(name: String, source: String, expected: String) {
        #expect(MemoMarkdownSource.prepare(source) == expected, "\(name)")
    }

    /// A definition whose destination markdown-it accepts is a definition, so its line is left
    /// exactly as the author wrote it — escaping the bracket would put the line back on screen
    /// as text, which is a line the SPA does not show.
    @Test("a definition the SPA will not open is still a definition")
    func acceptedDefinitionsAreNotNeutralised() {
        for source in [
            "[f]: ftp://example.com/pub", "[h]: //example.com/path", "[p]: /docs/a.md",
            "[pic]: data:image/png;base64,iVBORw0KGgo=",
        ] {
            #expect(MemoMarkdownSource.prepare(source) == source, "\(source)")
        }
    }

    /// CommonMark resolves the FIRST definition of a label and ignores every later one, and both
    /// renderers do. So the destination the policy is asked about is the first one: a reference
    /// whose first definition is `ftp:` is a label, however safe the duplicate below it looks.
    @Test("the first definition of a label is the one that decides")
    func theFirstDefinitionWins() {
        #expect(
            MemoMarkdownSource.prepare(
                "[f]: ftp://example.com/first\n[f]: https://example.com/second\n\n[the file][f]"
            ) == "[f]: ftp://example.com/first\n[f]: https://example.com/second\n\nthe file"
        )
        // The control, so this cannot become "a later definition never matters": with the safe
        // one FIRST the reference is a link, and its source stays as it was typed.
        let safeFirst =
            "[f]: https://example.com/first\n[f]: ftp://example.com/second\n\n[the file][f]"
        #expect(MemoMarkdownSource.prepare(safeFirst) == safeFirst)
    }

    /// Code is still the author's, whichever class the definition belongs to: a reference image
    /// written inside a fence is characters, not an image to drop.
    @Test(
        "an accepted definition does not reach into code either",
        arguments: [
            "[pic]: ftp://example.com/chart.png\n\n~~~\n![alt][pic]\n~~~",
            "[pic]: ftp://example.com/chart.png\n\n    ![alt][pic]",
            "[f]: ftp://example.com/pub\n\n~~~\n[the file][f]\n~~~",
        ]
    )
    func acceptedDefinitionsDoNotRewriteCode(source: String) {
        #expect(MemoMarkdownSource.prepare(source) == source)
    }

    /// A reference that names nothing is not a link in either renderer, whatever it looks like —
    /// so the characters stay, and nothing here may start resolving a label the document never
    /// defined.
    @Test("a reference that names nothing is left alone in both spellings")
    func danglingReferencesAreUntouched() {
        let source = "[missing][nope] and ![alt][nope] stay text."
        #expect(MemoMarkdownSource.prepare(source) == source)
    }

    // MARK: - the grammar a definition has to match before it is trusted (MEMNG-165 review)

    /// A label may not hold an UNESCAPED bracket. `scanBracketed` allows nesting because an
    /// inline link label may nest them; a definition's may not, and reading one as a definition
    /// hands cmark a line holding a live `javascript:` link that markdown-it renders as text.
    /// Probed on the SPA renderer: the whole line is one paragraph, no anchor anywhere.
    @Test("a label with an unescaped bracket is not a definition")
    func nestedBracketsAreNotALabel() {
        #expect(
            MemoMarkdownSource.prepare("[[x](javascript:alert(1))]: ftp://example.com")
                == "\\[\\[x](javascript:alert(1))]: ftp://example.com"
        )
        // The control: a label whose brackets ARE escaped is a label, and it registers.
        let escaped = "[a\\]b]: ftp://example.com"
        #expect(MemoMarkdownSource.prepare(escaped) == escaped)
    }

    /// A title has to CLOSE on the line it opens on. cmark refuses the definition when it does
    /// not and takes the line as a paragraph — where the `[x](javascript:…)` in the unterminated
    /// title is a live link cmark builds and markdown-it refuses.
    @Test("an unterminated title is not a definition")
    func unterminatedTitlesAreRefused() {
        #expect(
            MemoMarkdownSource.prepare(
                "[f]: ftp://example.com \"unterminated [x](javascript:alert(1))"
            ) == "\\[f]: ftp://example.com \"unterminated \\[x](javascript:alert(1))"
        )
        // The controls: every title form that IS terminated registers, and its line is the
        // parser's.
        for source in [
            "[f]: ftp://example.com \"a title\"",
            "[f]: ftp://example.com 'a title'",
            "[f]: ftp://example.com (a title)",
            "[f]: <ftp://example.com> \"a title\"",
        ] {
            #expect(MemoMarkdownSource.prepare(source) == source, "\(source)")
        }
    }

    /// A title may also sit on the line BELOW the destination — a spelling this scanner does not
    /// validate. So the definition is not registered and its line is neutralised: the app shows
    /// more literal text than the SPA there, which is the direction a grammar disagreement is
    /// allowed to fail in. What it may NOT do is leave the link below live, which is what the
    /// lone backtick in the title used to arrange.
    @Test("a title on the next line is refused, and takes nothing with it")
    func continuationTitlesAreRefused() {
        let source = "[f]: ftp://e.com\n\"a title with a ` backtick\"\n\n[x](javascript:alert(1))"
        let expected =
            "\\[f]: ftp://e.com\n\"a title with a ` backtick\"\n\n\\[x](javascript:alert(1))"
        #expect(MemoMarkdownSource.prepare(source) == expected)
        #expect(
            MemoMarkdownSource.prepare("[pic]: https://example.com/a.png\n(a title)\n\n![alt][pic]")
                == "\\[pic]: https://example.com/a.png\n(a title)\n\n![alt][pic]"
        )
    }

    /// The policy is asked about the destination the PARSER resolves, not the bytes the author
    /// typed: markdown-it applies backslash escapes and decodes entity references before
    /// `validateLink` ever sees it, and cmark resolves the link to the same string.
    @Test("the destination is classified as the parser resolves it")
    func destinationsAreDecodedBeforeTheyAreClassified() {
        // Entity-encoded colon: refused, so the definition is text and the reference with it.
        #expect(
            MemoMarkdownSource.prepare("[evil]: javascript&#x3A;alert(1)\n\n[click][evil]")
                == "\\[evil]: javascript&#x3A;alert(1)\n\n[click][evil]"
        )
        #expect(
            MemoMarkdownSource.prepare("[evil]: <javascript&#58;alert(1)>\n\n[click][evil]")
                == "\\[evil]: <javascript&#58;alert(1)>\n\n[click][evil]"
        )
        // Backslash-escaped colon: an ordinary https link, which stays one — the reference is
        // left exactly as it was typed rather than reduced to its label.
        let escapedColon = "[home]: https\\://example.com\n\n[site][home]"
        #expect(MemoMarkdownSource.prepare(escapedColon) == escapedColon)
        // An entity the table does not know is left alone, as markdown-it leaves it: the URL is
        // still an ordinary https destination.
        let unknown = "[f]: https://example.com/a?x=1&foo;y=2\n\n[the file][f]"
        #expect(MemoMarkdownSource.prepare(unknown) == unknown)
    }

    /// Nothing but whitespace or a title may follow the destination. `[f]: ftp://… [g]: …` is a
    /// paragraph in both renderers, so `f` resolves nowhere — registering it deletes or rewrites
    /// text the reader was meant to see.
    @Test("content after the destination means the line is not a definition")
    func trailingContentRefusesTheDefinition() {
        #expect(
            MemoMarkdownSource.prepare(
                "[f]: ftp://example.com [g]: javascript:alert(1)\n\n[click][f]"
            ) == "\\[f]: ftp://example.com [g]: javascript:alert(1)\n\n[click][f]"
        )
    }

    /// The rest of the definition grammar, each spelling refused rather than guessed at. All four
    /// are lines cmark does not register either; neutralising them costs a backslash that renders
    /// as nothing and buys the guarantee that this scanner never registers what it cannot parse.
    @Test(
        "a definition this grammar cannot validate is neutralised, never registered",
        arguments: [
            ("unbalanced parenthesis", "[f]: ftp://example.com/a(b\n\n[the file][f]"),
            ("empty angle destination", "[f]: <>\n\n[the file][f]"),
            ("no destination at all", "[f]:\n\n[the file][f]"),
            ("angle destination left open", "[f]: <ftp://example.com\n\n[the file][f]"),
        ]
    )
    func unvalidatableDefinitionsAreNeutralised(name: String, source: String) {
        let prepared = MemoMarkdownSource.prepare(source)
        #expect(
            prepared.hasPrefix("\\["),
            "\(name): the definition was left for cmark: \(prepared)"
        )
        #expect(prepared.hasSuffix("[the file][f]"), "\(name): the reference resolved: \(prepared)")
    }

    /// A code span is a backtick RUN closed by a run of the SAME length, not a flag every
    /// backtick flips. An unmatched backtick is an ordinary character in CommonMark, so
    /// everything after it is still prose the scheme rule applies to — the toggle handed the rest
    /// of the paragraph to the renderer untouched, which is a live `javascript:` link one stray
    /// backtick away.
    @Test("an unmatched backtick opens no code span")
    func unmatchedBackticksAreNotCodeSpans() {
        #expect(
            MemoMarkdownSource.prepare("a ` b [x](javascript:alert(1))")
                == "a ` b \\[x](javascript:alert(1))"
        )
        // A blank line ends the block, so a span cannot reach across one either.
        #expect(
            MemoMarkdownSource.prepare("a ` b\n\n[x](javascript:alert(1))")
                == "a ` b\n\n\\[x](javascript:alert(1))"
        )
        // The controls: a real span — on one line and across two — is still the author's.
        for source in [
            "`[js](javascript:alert(1))`",
            "`a\nb` and text",
            "``a ` b`` and text",
        ] {
            #expect(MemoMarkdownSource.prepare(source) == source, "\(source)")
        }
        // And a span that closes leaves what follows it neutralised.
        #expect(
            MemoMarkdownSource.prepare("`a` [x](javascript:alert(1))")
                == "`a` \\[x](javascript:alert(1))"
        )
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
