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
