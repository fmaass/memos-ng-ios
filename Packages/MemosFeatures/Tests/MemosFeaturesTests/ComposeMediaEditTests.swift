import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// A save the test can read back — the same shape `MemoEditWiringTests` uses, kept local so the
/// two suites cannot come to disagree about what a recorder is.
@MainActor
private final class MediaSubmissionRecorder {
    private(set) var last: ComposeSubmission?

    func save(_ mode: ComposeView.Mode, _ submission: ComposeSubmission) async -> ComposeOutcome {
        last = submission
        return .saved
    }
}

/// A save the test holds open: it records what it was handed and does not answer until released.
///
/// The suspension is the point. What the sheet carries up was decided when Save was pressed, so
/// everything the row does AFTERWARDS happens against a submission that is already fixed.
@MainActor
private final class HeldSave {
    private(set) var submission: ComposeSubmission?
    private var waiter: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func take(_ submission: ComposeSubmission) async -> ComposeOutcome {
        self.submission = submission
        if !isReleased {
            await withCheckedContinuation { waiter = $0 }
        }
        return .saved
    }

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}

/// A save that answers each attempt in turn, and counts what it has answered.
///
/// The second attempt is the case: what a sheet does with an answer depends on what it was told
/// before it, so the two have to arrive through one screen in order.
@MainActor
private final class FailureSequence {
    private var remaining: [ComposeFailure]
    private(set) var answered = 0

    init(_ failures: [ComposeFailure]) { remaining = failures }

    func answer() -> ComposeOutcome {
        let failure =
            remaining.isEmpty ? ComposeFailure.transport(sent: false) : remaining.removeFirst()
        answered += 1
        return .failed(failure)
    }
}

/// Attaching a photograph to a memo that already exists.
///
/// Until now an edit could change the words and the date and nothing else: the sheet showed only
/// the date row, so a memo posted without its picture could never be given one from the app. The
/// picker is on the edit sheet now, and what it picks rides the submission to
/// `TimelineStore.edit(attaching:)`, which writes it to the outbox as an edit job (MEMNG-954).
@MainActor
@Suite("Attaching media on an edit")
struct ComposeMediaEditTests {
    /// An edit the store refuses because the memo still owes an edit job (MEMNG-954) says so in
    /// plain words on the sheet, and marks no tile: nothing about the files went wrong.
    @Test("an edit refused behind a queued edit job says the last change is still sending")
    func editPendingSentence() {
        #expect(
            ComposeFailurePresentation.sentence(for: .editPending)
                == "This memo is still sending your last change. Edit it once it's in.")
        #expect(ComposeFailurePresentation.tileCategory(for: .editPending) == nil)
    }

    private let created = Date(timeIntervalSince1970: 1_750_000_000)

    private func mode() -> ComposeView.Mode {
        .edit(uid: "m1", content: "the boiler man", createdAt: created, attachments: [])
    }

    private func picked(_ name: String) -> PickedMedia {
        PickedMedia(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            filename: name,
            mime: "image/jpeg"
        )
    }

    @Test("an edit sheet really offers the photo picker and the date")
    func theEditSheetOffersThePicker() {
        let labels = ScreenProbe.labels(of: ComposeView(mode: mode()) { _ in .saved })

        // The positive control: without it, a missing picker below would only prove the probe saw
        // nothing whatsoever.
        #expect(
            labels.contains { $0.contains("Save") },
            "the probe found nothing of the sheet at all: \(labels)"
        )
        #expect(
            labels.contains("Add photos or videos"),
            "an edit still cannot attach anything: \(labels)"
        )
        #expect(labels.contains("Memo date"), "the date row left the edit sheet: \(labels)")
    }

    @Test("an edit sheet offers the memo's own visibility (MEMNG-969)")
    func theEditSheetOffersItsVisibility() {
        let editing = ScreenProbe.labels(of: ComposeView(mode: mode()) { _ in .saved })
        let widest = ScreenProbe.labels(
            of: ComposeView(
                mode: .edit(
                    uid: "m1", content: "the boiler man", createdAt: created, attachments: [],
                    visibility: .public)
            ) { _ in .saved })

        // Who can see a memo is changed where the memo is edited; narrowing goes as it is and
        // widening asks once (VisibilityChange).
        #expect(
            editing.contains("Visibility: Private"),
            "an edit sheet did not offer the memo's visibility: \(editing)"
        )
        // The control: the menu shows the memo's OWN audience, not a fixed default.
        #expect(widest.contains("Visibility: Public"), "\(widest)")
        #expect(!widest.contains("Visibility: Private"), "\(widest)")
    }

    @Test("the files picked in the sheet reach the save whole")
    func theFilesReachTheSave() async {
        let flow = MemoEditFlow()
        let recorder = MediaSubmissionRecorder()
        flow.begin(mode())

        let closed = await flow.submit(
            ComposeSubmission(
                content: "the boiler man, and here he is",
                visibility: nil,
                attachments: [picked("a.jpg"), picked("b.jpg")]
            ),
            save: recorder.save
        )

        #expect(closed.isSaved)
        // Dropped here, the upload would never happen and the memo would save its new text with
        // the photograph silently missing — the one half-edit nobody can see has gone wrong.
        #expect(recorder.last?.attachments.map(\.filename) == ["a.jpg", "b.jpg"])
    }

    /// The whole wiring, pressed: the row `ComposeView` builds, the closure it really hands that
    /// row, the forwarding on to each picked tile, and the control itself. Every link is a place
    /// the x can be dead while a test of `ComposeImports.remove(id:)` alone stays green — and a
    /// dead x is a picture somebody thinks they took off a memo they are about to post.
    @Test("pressing the x on a picked picture takes it off the sheet")
    func theXOnAPickedPictureTakesItOff() async {
        let imports = ComposeImports()
        await imports.load(["a"], stamp: imports.selected()) { _ in .file(picked("a.jpg")) }

        // The sheet's own height: the row sits under the words, and a viewport shorter than the
        // sheet is a control that was never drawn rather than one that is not wired.
        let pressed = PressProbe.withElement(
            labelled: "Remove",
            in: ComposeView(mode: mode(), imports: imports) { _ in .saved },
            height: 852
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the x on a picked tile did not accept an activation")
        #expect(
            imports.ordered.isEmpty,
            "the picture is still attached after its x was pressed: \(imports.ordered.map(\.label))"
        )
    }

    /// The other half of the same wiring: what the x must NOT do.
    ///
    /// The submission is built when Save is pressed and the upload is already on its way, so a
    /// picture taken off the row after that is a picture the save still carries — it goes up, and
    /// the sheet closes on a memo holding the very thing somebody had just removed. The refusal
    /// lives in the closure, not in a disabled control: a control that is grey is a hint, and the
    /// tap that beat the redraw is the one that does the damage.
    @Test("a picture cannot be taken off while the save that carries it is on the wire")
    func theXIsRefusedWhileASaveIsOnTheWire() async {
        // A capture read that answers at once: a file still being read refuses the Save itself
        // (`ComposeAttachments.postRefusal`), and this case is about a save that really went.
        let imports = ComposeImports(readCapture: { _ in .empty })
        await imports.load(["a"], stamp: imports.selected()) { _ in .file(picked("a.jpg")) }
        await settleTasks()
        let save = HeldSave()

        let (saved, onTheWire, claimed, pressed) = await PressProbe.withScreen(
            ComposeView(mode: mode(), imports: imports) { await save.take($0) },
            height: 852
        ) { screen in
            let saved = screen.press("Save")
            // Pressed against a save that is really in flight, or the case is not the case.
            await screen.settle(turns: 100, until: { save.submission != nil })
            let onTheWire = save.submission != nil
            // The claim the sheet makes on the list itself, which is what everything else that
            // could change the attachments is refused on — the picker and the camera included,
            // neither of which can be answered from here.
            let claimed = imports.isSubmitting
            let pressed = screen.press("Remove")
            await screen.settle()
            return (saved, onTheWire, claimed, pressed)
        }

        #expect(saved, "the sheet's own Save could not be pressed")
        #expect(onTheWire, "the save never reached the wire, so the x was pressed against nothing")
        #expect(
            claimed, "the sheet sent the submission without claiming the list it was built from")
        #expect(pressed, "the x was not on the row to be pressed while the save was running")
        #expect(
            imports.ordered.map(\.label) == ["a.jpg"],
            "the picture left the row while the save carrying it was still on the wire")
        save.release()
        await settleTasks()
        #expect(
            save.submission?.attachments.map(\.filename) == ["a.jpg"],
            "what went up and what the row showed had come apart")
    }

    @Test("what the save sends up is the picked file, in the shape an upload takes")
    func stagedSourcesCarryTheFile() {
        let staged = picked("holiday.jpg").stagedSource

        #expect(staged.filename == "holiday.jpg")
        #expect(staged.mime == "image/jpeg")
        #expect(staged.url.lastPathComponent == "holiday.jpg")
    }

    /// A save whose answer says nothing about what the server did fixes the list as firmly as a
    /// save still on the wire does.
    ///
    /// The retry that follows one of those is safe only because it goes out under the same edit
    /// key — and that key is minted from the files the attempt carried
    /// (`TimelineStore.editKey(for:)`). Take one off in between and the key changes with it: the
    /// server's replay lookup misses, the patch is read as an edit it has never seen, and its
    /// files are added to the ones the first attempt may already have committed. The row would
    /// show one picture and the memo would end up with two.
    @Test("a picture cannot be taken off after a save the server may have applied")
    func theXIsRefusedAfterASaveThatMayHaveLanded() async {
        let imports = ComposeImports(readCapture: { _ in .empty })
        await imports.load(["a"], stamp: imports.selected()) { _ in .file(picked("a.jpg")) }
        await settleTasks()

        let (saved, marked, pressed) = await PressProbe.withScreen(
            ComposeView(mode: mode(), imports: imports) { _ in .failed(.transport(sent: true)) },
            height: 852
        ) { screen in
            let saved = screen.press("Save")
            // Read against the save's ANSWER, not against the save: `isSubmitting` is already
            // true the instant Save is pressed, and settling on that reads the tiles before the
            // failure has landed on them — a case that passes whatever the marking does.
            await screen.settle(turns: 100, until: { imports.mayHaveLanded })
            // Read before the x, while the tiles are still there to be read.
            let marked = imports.items.contains { $0.uploadFailed != nil }
            let pressed = screen.press("Remove")
            await screen.settle()
            return (saved, marked, pressed)
        }

        #expect(saved, "the sheet's own Save could not be pressed")
        #expect(pressed, "the x was not on the row to be pressed after the save came back")
        #expect(
            imports.ordered.map(\.label) == ["a.jpg"],
            "the picture left a list the server may already be holding")
        // And the tiles say nothing, because there is nothing they could offer: a marked tile
        // carries a "Try again" that this very freeze refuses.
        #expect(!marked, "a tile was marked failed by a save whose files may have gone up fine")
    }

    /// The control the case above is worth nothing without: an answer that never left the device
    /// took nothing to the server, so there is nothing to keep the list still for.
    @Test("a picture can still be taken off after a save that never reached the server")
    func theXStillWorksAfterASaveThatNeverLeft() async {
        let imports = ComposeImports(readCapture: { _ in .empty })
        await imports.load(["a"], stamp: imports.selected()) { _ in .file(picked("a.jpg")) }
        await settleTasks()

        let (saved, marked, said, pressed) = await PressProbe.withScreen(
            ComposeView(mode: mode(), imports: imports) { _ in .failed(.transport(sent: false)) },
            height: 852
        ) { screen in
            let saved = screen.press("Save")
            await screen.settle(turns: 100, until: { imports.items.first?.uploadFailed != nil })
            let marked = imports.items.contains { $0.uploadFailed != nil }
            let said = screen.says(
                ComposeFailurePresentation.sentence(for: .transport(sent: false)))
            let pressed = screen.press("Remove")
            await screen.settle()
            return (saved, marked, said, pressed)
        }

        #expect(saved, "the sheet's own Save could not be pressed")
        #expect(pressed, "the x was not on the row to be pressed after the save came back")
        // The control for the sentence too: nothing has frozen this row, so the answer speaks for
        // itself and says the one thing only an unsent request may say.
        #expect(said, "the sheet did not say that nothing had been changed")
        #expect(
            imports.ordered.isEmpty,
            "the x is dead after a save that never left: \(imports.ordered.map(\.label))")
        // The control for the case above: a save that reached nothing left the files unsent, and
        // the tile that says so carries a "Try again" the sheet really takes.
        #expect(marked, "nothing on the row said the files had not gone up")
    }

    /// The freeze lasts for the rest of the sheet's life, and so does the sentence that bought it.
    ///
    /// A second attempt can come back saying it never left the device. About THIS set that is not
    /// something anybody knows — an earlier attempt may already have committed it — so the row is
    /// held exactly as it was, no tile is marked, and the sheet goes on saying what it said.
    @Test("a later failure changes neither the row nor the sentence once a save may have landed")
    func aFrozenRowKeepsItsSentenceAndItsTiles() async {
        let imports = ComposeImports(readCapture: { _ in .empty })
        await imports.load(["a"], stamp: imports.selected()) { _ in .file(picked("a.jpg")) }
        await settleTasks()

        let answers = FailureSequence([.transport(sent: true), .transport(sent: false)])
        let lost = ComposeFailurePresentation.sentence(for: .transport(sent: true))
        let never = ComposeFailurePresentation.sentence(for: .transport(sent: false))

        let read = await PressProbe.withScreen(
            ComposeView(mode: mode(), imports: imports) { _ in await answers.answer() },
            height: 852
        ) { screen in
            _ = screen.press("Save")
            await screen.settle(turns: 100, until: { imports.mayHaveLanded })
            // The probe's own control: the first answer's sentence is there to be read.
            let saidFirst = screen.says(lost)
            let markedFirst = imports.items.contains { $0.uploadFailed != nil }

            _ = screen.press("Save")
            await screen.settle(turns: 200, until: { answers.answered == 2 })
            await screen.settle()
            return (
                saidFirst: saidFirst, markedFirst: markedFirst, answered: answers.answered,
                saysLost: screen.says(lost), saysNever: screen.says(never),
                marked: imports.items.contains { $0.uploadFailed != nil }
            )
        }

        #expect(read.saidFirst, "the first answer's sentence was not on the sheet to be read")
        #expect(!read.markedFirst, "a tile was marked by a save whose files may have gone up fine")
        #expect(read.answered == 2, "the second save was never made")
        #expect(read.saysLost, "the sheet stopped saying what the row is being held for")
        #expect(!read.saysNever, "the sheet said nothing had changed about a set that may be up")
        #expect(!read.marked, "a tile was marked on a row nothing can be done to")
        #expect(imports.mayHaveLanded, "a later answer lifted the freeze")
    }
}
