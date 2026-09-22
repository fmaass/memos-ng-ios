import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// A save the test reads back, answering each attempt the way the case needs.
///
/// Local to this suite, like the recorders beside it: what a recorder is has to be decided once
/// per case, and a shared one would have to answer everything.
@MainActor
private final class PictureSubmissionRecorder {
    private(set) var last: ComposeSubmission?
    private let answer: ComposeOutcome

    init(answering answer: ComposeOutcome = .saved) { self.answer = answer }

    func save(_ submission: ComposeSubmission) async -> ComposeOutcome {
        last = submission
        return answer
    }
}

/// Taking one of the memo's OWN pictures off it, from the sheet that edits it.
///
/// Nothing here deletes anything: the x marks the picture, and the save states the list that is
/// left — kept uids and the files going up beside them — in the one patch. So these cases are
/// pressed through the whole sheet rather than asked of the marks: every link between the x and
/// what the submission carries is a place the control can be dead, or live when it must not be,
/// while a test of either end alone stays green.
@MainActor
@Suite("Taking a picture off a memo being edited")
struct ComposePictureRemovalTests {
    private let created = Date(timeIntervalSince1970: 1_750_000_000)

    private func attachment(_ uid: String) -> MemoAttachment {
        MemoAttachment(uid: uid, mime: "image/jpeg", status: .ready)
    }

    private func mode(_ content: String, _ attachments: [MemoAttachment]) -> ComposeView.Mode {
        .edit(uid: "m1", content: content, createdAt: created, attachments: attachments)
    }

    /// The list a save states is fixed when Save is pressed, exactly as the files are.
    ///
    /// A save whose answer says nothing about what the server did may have been applied, so the
    /// memo may already hold the shorter list this patch stated. Take another picture off after
    /// that and the retry — which goes out under the same edit key, minted from the attempt
    /// (`TimelineStore.editKey(for:)`) — would state a list the first attempt never mentioned:
    /// the key changes with it, the server reads a patch it has never seen, and the two lists
    /// are applied one after the other. The refusal is in the closure rather than in whether the
    /// x is drawn, because a control that has gone grey is a hint and the tap that beat the
    /// redraw is the one that does the damage.
    @Test("a picture the memo has cannot be taken off after a save that may have landed")
    func theExistingXIsRefusedAfterASaveThatMayHaveLanded() async {
        let imports = ComposeImports()
        let recorder = PictureSubmissionRecorder(answering: .failed(.transport(sent: true)))

        let (saved, pressed, stillShown) = await PressProbe.withScreen(
            ComposeView(mode: mode("the boiler man", [attachment("a1")]), imports: imports) {
                await recorder.save($0)
            },
            height: 852
        ) { screen in
            let saved = screen.press("Save")
            // Read against the save's ANSWER, not against the press: the freeze is what the
            // answer leaves behind, and a row read before it has landed passes whatever the
            // guard does.
            await screen.settle(turns: 100, until: { imports.mayHaveLanded })
            let pressed = screen.press("Remove")
            await screen.settle()
            let stillShown = screen.says("1 file attached")
            return (saved, pressed, stillShown)
        }

        #expect(saved, "the sheet's own Save could not be pressed")
        #expect(
            imports.mayHaveLanded,
            "the answer never froze the sheet, so the x was pressed against nothing")
        #expect(pressed, "the x was not on the memo's own tile to be pressed after the save")
        #expect(stillShown, "the picture left a list the server may already be holding")
        // And what went up said so: the freeze is worth nothing if the patch it protects had
        // already dropped the picture.
        #expect(
            recorder.last?.pictures == [.kept("a1")],
            "the save did not state the picture the row was showing when it went")
    }

    /// The control the case above is worth nothing without: a save the server refused outright
    /// changed nothing, so there is nothing to keep the list still for.
    @Test("a picture can still be taken off after a save the server refused outright")
    func theExistingXStillWorksAfterARejection() async {
        let imports = ComposeImports()
        let recorder = PictureSubmissionRecorder(answering: .failed(.rejection))

        let (saved, said, pressed, stillShown) = await PressProbe.withScreen(
            ComposeView(mode: mode("the boiler man", [attachment("a1")]), imports: imports) {
                await recorder.save($0)
            },
            height: 852
        ) { screen in
            let saved = screen.press("Save")
            await screen.settle(
                turns: 100,
                until: { screen.says(ComposeFailurePresentation.sentence(for: .rejection)) })
            let said = screen.says(ComposeFailurePresentation.sentence(for: .rejection))
            let pressed = screen.press("Remove")
            await screen.settle()
            let stillShown = screen.says("1 file attached")
            return (saved, said, pressed, stillShown)
        }

        #expect(saved, "the sheet's own Save could not be pressed")
        // The control for the freeze itself: the answer really landed on the sheet, and it left
        // the row free.
        #expect(said, "the sheet never said the save had been refused")
        #expect(
            !imports.mayHaveLanded, "a refusal that named what was wrong froze the row all the same"
        )
        #expect(pressed, "the x was not on the memo's own tile to be pressed after the refusal")
        #expect(!stillShown, "the x is dead after a save that the server definitely did not apply")
    }

    /// What is left on the row is what makes a memo, whether it was picked here or was already
    /// on the memo.
    @Test("a memo with no words saves while one of its own pictures is left")
    func savingStaysLiveWhileAPictureIsLeft() async {
        let recorder = PictureSubmissionRecorder()

        let (removed, saved) = await PressProbe.withScreen(
            ComposeView(mode: mode("", [attachment("a1"), attachment("a2")])) {
                await recorder.save($0)
            },
            height: 852
        ) { screen in
            let removed = screen.press("Remove")
            await screen.settle()
            let saved = screen.press("Save")
            await screen.settle(turns: 100, until: { recorder.last != nil })
            return (removed, saved)
        }

        #expect(removed, "the x was not on the first of the memo's tiles to be pressed")
        #expect(saved, "Save would not take a press on a memo that still holds a picture")
        // Both halves in one assertion, deliberately: Save being live is only worth having if
        // what it sends is the shorter list, and the uid names WHICH picture is left.
        #expect(
            recorder.last?.pictures == [.kept("a2")],
            "the save did not state exactly the picture still on the row")
    }

    /// The other side of the same rule, and the reason it is a rule: a memo has to hold
    /// something. An edit emptied of its words and of every picture is not a memo, and the
    /// create sheet refuses the same thing.
    @Test("a memo with no words and no pictures left has nothing to save")
    func savingStopsWhenTheLastPictureGoes() async {
        let recorder = PictureSubmissionRecorder()

        let (first, second) = await PressProbe.withScreen(
            ComposeView(mode: mode("", [attachment("a1"), attachment("a2")])) {
                await recorder.save($0)
            },
            height: 852
        ) { screen in
            let first = screen.press("Remove")
            await screen.settle()
            let second = screen.press("Remove")
            await screen.settle()
            _ = screen.press("Save")
            await screen.settle()
            return (first, second)
        }

        // The controls: both x's really were there and really were pressed, so the silence below
        // is the Save refusing rather than a row that was never touched.
        #expect(first, "the x was not on the first of the memo's tiles to be pressed")
        #expect(second, "the x was not on the second of the memo's tiles to be pressed")
        #expect(recorder.last == nil, "an edit left with no words and no pictures saved anyway")
    }
}
