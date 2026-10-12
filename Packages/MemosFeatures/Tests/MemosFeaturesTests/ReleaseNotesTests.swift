import Foundation
import Testing

@testable import MemosFeatures

/// The notes file as the What's new screen reads it: its sections, and the running build's first.
/// The file is the one the TestFlight cut sends, so the reading is the cut loader's
/// (`fastlane/lib/release_notes.rb`), held here by the same kinds of vector.
@Suite("Release notes")
struct ReleaseNotesTests {
    private static let three = """
        # TestFlight notes

        A preamble that belongs to no section.

        ## 3.0 (3)

        - Three.

        ## 2.0 (2)

        - Two.
        ### A deeper heading stays in its section

        ## 1.0 (1)
        - One.
        """

    private func versions(_ sections: [ReleaseNotes.Section]) -> [String] {
        sections.map(\.version)
    }

    @Test("an empty file has no sections, and orders to none")
    func anEmptyFile() {
        #expect(ReleaseNotes.sections(markdown: "").isEmpty)
        #expect(ReleaseNotes.sections(markdown: "# TestFlight notes\n\nNothing yet.\n").isEmpty)
        #expect(ReleaseNotes.ordered([], running: "1.0 (1)").isEmpty)
    }

    @Test("one section is its heading and the Markdown under it, trimmed")
    func oneSection() {
        let sections = ReleaseNotes.sections(
            markdown: "## 2.2.3 (45)\n\n- A footer.\n- A screen.\n\n")
        #expect(sections == [.init(version: "2.2.3 (45)", body: "- A footer.\n- A screen.")])
    }

    @Test("sections come in file order; the preamble is none of them and a deeper heading stays")
    func fileOrder() {
        let sections = ReleaseNotes.sections(markdown: Self.three)
        #expect(versions(sections) == ["3.0 (3)", "2.0 (2)", "1.0 (1)"])
        #expect(sections[1].body == "- Two.\n### A deeper heading stays in its section")
        #expect(!sections.contains { $0.body.contains("preamble") })
    }

    @Test("the running version in the middle comes first, the rest in file order")
    func runningInTheMiddle() {
        let ordered = ReleaseNotes.ordered(
            ReleaseNotes.sections(markdown: Self.three), running: "2.0 (2)")
        #expect(versions(ordered) == ["2.0 (2)", "3.0 (3)", "1.0 (1)"])
        #expect(ordered.first?.body.hasPrefix("- Two.") == true)
    }

    @Test("a running version the file does not name leaves file order, nothing dropped")
    func runningAbsent() {
        let sections = ReleaseNotes.sections(markdown: Self.three)
        for running in ["4.0 (4)", "Unknown", "2.0", "2.0 (2) ", ""] {
            #expect(ReleaseNotes.ordered(sections, running: running) == sections, "\(running)")
        }
        // The control: a version that IS named moves.
        #expect(versions(ReleaseNotes.ordered(sections, running: "1.0 (1)")).first == "1.0 (1)")
    }

    @Test("a heading inside a code fence is text, not a section", arguments: ["```", "~~~"])
    func aFencedHeadingIsText(fence: String) {
        let markdown = "## 2.0 (2)\n\n\(fence)\n## 9.9 (99)\n# 8.8 (88)\n\(fence)\n- After.\n"
        let sections = ReleaseNotes.sections(markdown: markdown)
        #expect(versions(sections) == ["2.0 (2)"])
        #expect(sections.first?.body.contains("## 9.9 (99)") == true)
        #expect(sections.first?.body.hasSuffix("- After.") == true)
        // The control: the same heading after the fence closes is a section again.
        let reopened = ReleaseNotes.sections(markdown: markdown + "## 9.9 (99)\n- Real.\n")
        #expect(versions(reopened) == ["2.0 (2)", "9.9 (99)"])
    }

    /// CommonMark: a fence closes only on the character that opened it, repeated at least as
    /// many times. A three-backtick line inside a four-backtick fence is text, and so is the
    /// heading after it; the four-backtick line closes it, and the heading after THAT is real.
    @Test("a shorter or different fence line does not close the fence that is open")
    func aFenceClosesOnlyOnItsOwnRun() {
        let longer = ReleaseNotes.sections(
            markdown: "## 2.0 (2)\n````\n```\n## 9.9 (99)\n````\n## 1.0 (1)\n- One.\n")
        #expect(versions(longer) == ["2.0 (2)", "1.0 (1)"])
        #expect(longer.first?.body == "````\n```\n## 9.9 (99)\n````")
        #expect(longer.last?.body == "- One.")

        let other = ReleaseNotes.sections(
            markdown: "## 2.0 (2)\n~~~\n```\n## 9.9 (99)\n~~~\n## 1.0 (1)\n- One.\n")
        #expect(versions(other) == ["2.0 (2)", "1.0 (1)"])
    }

    @Test("two identical headings stay two sections, and only the first moves forward")
    func duplicateHeadingsArePreserved() {
        let sections = ReleaseNotes.sections(
            markdown: "## 3.0 (3)\n- Three.\n## 2.0 (2)\n- First.\n## 2.0 (2)\n- Second.\n")
        #expect(versions(sections) == ["3.0 (3)", "2.0 (2)", "2.0 (2)"])
        let ordered = ReleaseNotes.ordered(sections, running: "2.0 (2)")
        #expect(ordered.map(\.body) == ["- First.", "- Three.", "- Second."])
    }

    @Test("a level-1 heading ends a section and opens none; a bare ## names nothing")
    func levelOneEndsASection() {
        let sections = ReleaseNotes.sections(
            markdown: "## 2.0 (2)\n- Two.\n# Archive\n- Loose.\n##\n- Loose too.\n"
                + "## 1.0 (1)\n- One.")
        #expect(versions(sections) == ["2.0 (2)", "1.0 (1)"])
        #expect(sections.first?.body == "- Two.")
    }

    @Test("CRLF line ends split like LF")
    func crlf() {
        let sections = ReleaseNotes.sections(
            markdown: "## 2.0 (2)\r\n- Two.\r\n## 1.0 (1)\r\n- One.\r\n")
        #expect(versions(sections) == ["2.0 (2)", "1.0 (1)"])
        #expect(sections.first?.body == "- Two.")
    }

    /// The file this build carries: copied into the Features bundle, and naming the build it ships
    /// in — the gate's `notes` step holds project.yml to the same, this holds the packaging.
    @Test("the bundled notes name the running build")
    func theBundledNotesNameThisBuild() {
        let running = AboutInfo.versionLine(from: .main)
        #expect(running != "Unknown", "precondition: the host app declares its version")
        #expect(ReleaseNotes.bundled.count > 1, "the notes file was not bundled whole")
        #expect(ReleaseNotes.bundled.contains { $0.version == running }, "no section \(running)")
    }
}
