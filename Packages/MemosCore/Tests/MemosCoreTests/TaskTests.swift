import MemosCore
import Testing

// The same vectors as frontend/src/lib/__tests__/tasks.spec.ts. A document whose rendered
// checkboxes and regex-matchable lines disagree in BOTH directions: the fenced literal is matched
// by a naive regex but never rendered, the blockquoted and the ordered task are rendered but never
// matched.
private let mixed = [
    "```",  // 0
    "- [ ] fenced",  // 1 — code, not a checkbox
    "```",  // 2
    "",  // 3
    "> - [ ] quoted",  // 4 — checkbox 0
    "",  // 5
    "- [ ] plain",  // 6 — checkbox 1
    "",  // 7
    "1. [ ] ordered",  // 8 — checkbox 2
].joined(separator: "\n")

// The list marker sits on its own line; the checkbox lands on the item's first content line.
private let markerAlone = "-\n  [ ] first\n- [ ] second"

@Suite("taskCheckboxLines")
struct TaskCheckboxLinesTests {
    @Test("skips fenced literals and counts blockquoted and ordered tasks")
    func skipsFences() {
        #expect(taskCheckboxLines(mixed) == [4, 6, 8])
    }

    @Test("skips a tilde fence and an indented code block")
    func skipsOtherCode() {
        #expect(taskCheckboxLines("~~~\n- [ ] fenced\n~~~\n- [ ] real") == [3])
        #expect(taskCheckboxLines("    - [ ] indented\n\n- [ ] real") == [2])
    }

    @Test("skips list items the renderer does not turn into checkboxes")
    func skipsNonCheckboxes() {
        #expect(taskCheckboxLines("- [ ]nospace\n- [] empty\n- [ ]\n- [ ] ok") == [3])
    }

    @Test("counts nested tasks and every bullet style")
    func countsNestedAndBullets() {
        #expect(
            taskCheckboxLines("- [ ] parent\n  - [ ] child\n    - [ ] grandchild") == [0, 1, 2])
        #expect(taskCheckboxLines("* [ ] star\n\n+ [ ] plus") == [0, 2])
    }

    @Test("reports lines of the ORIGINAL source, not of the tag-stripped one")
    func reportsSourceLines() {
        #expect(taskCheckboxLines("```\n#tag\n- [ ] fenced\n```\n- [ ] real") == [4])
        #expect(taskCheckboxLines("#tag\n- [ ] after") == [1])
    }

    @Test("finds a checkbox whose list marker sits on the preceding line")
    func findsMarkerAlone() {
        #expect(taskCheckboxLines(markerAlone) == [1, 2])
    }

    @Test("leaves a would-be continuation the renderer does not draw as a checkbox")
    func skipsFalseContinuations() {
        #expect(taskCheckboxLines("-\n      [ ] first").isEmpty)
        #expect(taskCheckboxLines("-\n[ ] first").isEmpty)
    }
}

@Suite("toggleTask")
struct ToggleTaskTests {
    @Test("checks an unchecked task by index")
    func checks() {
        #expect(toggleTask("- [ ] a\n- [ ] b", at: 0) == "- [x] a\n- [ ] b")
    }

    @Test("unchecks a checked task by index")
    func unchecks() {
        #expect(toggleTask("- [ ] a\n- [x] b", at: 1) == "- [ ] a\n- [ ] b")
    }

    @Test("counts only task lines, leaving prose untouched")
    func skipsProse() {
        let source = "intro\n- [ ] one\nmiddle\n- [ ] two"
        #expect(toggleTask(source, at: 1) == "intro\n- [ ] one\nmiddle\n- [x] two")
    }

    @Test("is a no-op when the index is out of range")
    func outOfRange() {
        #expect(toggleTask("- [ ] a", at: 5) == "- [ ] a")
    }

    @Test("toggles past a fenced literal instead of editing the code block")
    func pastFence() {
        #expect(
            toggleTask("```\n- [ ] fenced\n```\n- [ ] real", at: 0)
                == "```\n- [ ] fenced\n```\n- [x] real"
        )
    }

    @Test("toggles a blockquoted task, preserving the quote prefix")
    func blockquoted() {
        #expect(toggleTask("> - [ ] q1\n> - [x] q2", at: 0) == "> - [x] q1\n> - [x] q2")
        #expect(toggleTask("> - [ ] q1\n> - [x] q2", at: 1) == "> - [ ] q1\n> - [ ] q2")
        #expect(toggleTask("> > - [ ] deep", at: 0) == "> > - [x] deep")
        #expect(toggleTask(">- [ ] tight", at: 0) == ">- [x] tight")
        #expect(toggleTask("- > - [ ] quoted-in-list", at: 0) == "- > - [x] quoted-in-list")
    }

    @Test("hits the right line in a fence + blockquote + list + ordered mix")
    func mixedDocument() {
        #expect(toggleTask(mixed, at: 0).components(separatedBy: "\n")[4] == "> - [x] quoted")
        #expect(toggleTask(mixed, at: 1).components(separatedBy: "\n")[6] == "- [x] plain")
        #expect(toggleTask(mixed, at: 2).components(separatedBy: "\n")[8] == "1. [x] ordered")
        #expect(toggleTask(mixed, at: 0).components(separatedBy: "\n")[1] == "- [ ] fenced")
    }

    @Test("keeps indentation and bullet style when toggling nested and non-dash tasks")
    func keepsStyle() {
        #expect(
            toggleTask("- [ ] parent\n  - [ ] child\n    - [ ] grandchild", at: 2)
                == "- [ ] parent\n  - [ ] child\n    - [x] grandchild"
        )
        #expect(toggleTask("* [ ] star\n\n+ [ ] plus", at: 1) == "* [ ] star\n\n+ [x] plus")
        #expect(toggleTask("1. [ ] one\n\n2) [ ] two", at: 1) == "1. [ ] one\n\n2) [x] two")
    }

    @Test("unchecks an uppercase mark")
    func uppercase() {
        #expect(toggleTask("- [X] upper", at: 0) == "- [ ] upper")
    }

    @Test("ignores list items that render as plain text")
    func ignoresPlainText() {
        #expect(
            toggleTask("- [ ]nospace\n- [] empty\n- [ ] ok", at: 0)
                == "- [ ]nospace\n- [] empty\n- [x] ok"
        )
    }

    @Test("counts source lines around a stripped tag-only line")
    func aroundStrippedTag() {
        #expect(toggleTask("#tag\n- [ ] after", at: 0) == "#tag\n- [x] after")
    }

    @Test("preserves CRLF line endings")
    func preservesCRLF() {
        #expect(toggleTask("- [ ] a\r\n- [ ] b", at: 1) == "- [ ] a\r\n- [x] b")
    }

    @Test("toggles a checkbox whose list marker sits on the preceding line")
    func markerAloneToggle() {
        #expect(toggleTask(markerAlone, at: 0) == "-\n  [x] first\n- [ ] second")
        #expect(toggleTask(markerAlone, at: 1) == "-\n  [ ] first\n- [x] second")
    }

    @Test("toggles a marker-alone checkbox through blockquote and ordered markers")
    func markerAloneVariants() {
        #expect(toggleTask("> -\n>   [ ] first", at: 0) == "> -\n>   [x] first")
        #expect(toggleTask("> > -\n> >   [ ] first", at: 0) == "> > -\n> >   [x] first")
        #expect(toggleTask("1.\n   [ ] first", at: 0) == "1.\n   [x] first")
        #expect(toggleTask("-\n  [x] first", at: 0) == "-\n  [ ] first")
    }

    @Test("leaves a would-be continuation alone")
    func leavesFalseContinuation() {
        #expect(toggleTask("-\n      [ ] first", at: 0) == "-\n      [ ] first")
        #expect(toggleTask("-\n[ ] first", at: 0) == "-\n[ ] first")
    }
}

// The bug this guards: the app indexes rendered checkboxes, so the source-side enumeration has to
// be the SAME list. Reading the rendered state back after each toggle is the only assertion that
// proves both sides agree, document by document.
private let corpus: [(name: String, source: String)] = [
    ("plain", "- [ ] a\n- [x] b"),
    ("fenceFirst", "```\n- [ ] fenced\n- [x] fenced2\n```\n- [ ] real\n- [x] real2"),
    ("tildeFence", "~~~\n- [ ] fenced\n~~~\n- [ ] real"),
    ("indentedCode", "    - [ ] indented\n\n- [ ] real"),
    ("blockquote", "intro\n\n> - [ ] q1\n> - [x] q2\n\n- [ ] plain"),
    ("nestedQuote", "> > - [ ] deep\n\n- [x] after"),
    ("quoteNoSpace", ">- [ ] tight\n\n- [ ] plain"),
    ("quoteInList", "- > - [ ] weird\n\n- [ ] plain"),
    ("listInQuote", "> - outer\n>   - [ ] inner\n\n- [ ] plain"),
    ("nested", "- [ ] parent\n  - [x] child\n    - [ ] grandchild"),
    ("bullets", "* [ ] star\n\n+ [x] plus\n\n- [ ] dash"),
    ("ordered", "1. [ ] one\n\n2) [x] two\n\n- [ ] dash"),
    ("nonTasks", "- [ ]nospace\n- [] empty\n- [ ]\n- [ ] ok"),
    ("tagOnlyInFence", "```\n#tag\n- [ ] fenced\n```\n#tag\n- [ ] real"),
    ("mixed", mixed),
    ("crlf", "- [ ] a\r\n- [x] b"),
    ("markerAlone", markerAlone),
    ("markerAloneQuoted", "> -\n>   [x] quoted\n\n- [ ] plain"),
    ("markerAloneOrdered", "1.\n   [ ] first\n\n- [x] plain"),
]

/// Checked state of every rendered checkbox — the app's equivalent of scraping the rendered DOM
/// for `input.task-list-item-checkbox` and reading each one's `checked` attribute.
private func renderedCheckedStates(_ source: String) -> [Bool] {
    taskCheckboxItems(source).map(\.checked)
}

@Suite("rendered checkboxes and source enumeration agree")
struct TaskAgreementTests {
    @Test("toggles exactly the clicked checkbox", arguments: corpus)
    func togglesExactlyOne(entry: (name: String, source: String)) {
        let before = renderedCheckedStates(entry.source)
        #expect(!before.isEmpty, "\(entry.name) renders no checkbox")
        #expect(taskCheckboxLines(entry.source).count == before.count, "\(entry.name)")
        for index in before.indices {
            let expected = before.enumerated().map { offset, state in
                offset == index ? !state : state
            }
            #expect(
                renderedCheckedStates(toggleTask(entry.source, at: index)) == expected,
                "\(entry.name) index \(index)"
            )
        }
    }
}
