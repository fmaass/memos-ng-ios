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

/// Attaching a photograph to a memo that already exists.
///
/// Until now an edit could change the words and the date and nothing else: the sheet showed only
/// the date row, so a memo posted without its picture could never be given one from the app. The
/// picker is on the edit sheet now, and what it picks rides the submission to a foreground upload
/// (`TimelineStore.edit(attaching:)`) rather than the outbox, which owns new captures.
@MainActor
@Suite("Attaching media on an edit")
struct ComposeMediaEditTests {
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

    @Test("an edit sheet still says nothing about who can see the memo")
    func theEditSheetOffersNoVisibility() {
        let editing = ScreenProbe.labels(of: ComposeView(mode: mode()) { _ in .saved })
        let creating = ScreenProbe.labels(of: ComposeView(mode: .create) { _ in .saved })

        // Who can see a memo is its own deliberate action on the memo, not something that changes
        // as a side effect of fixing a typo.
        #expect(
            !editing.contains { $0.hasPrefix("Visibility:") },
            "an edit sheet offered to change the visibility: \(editing)"
        )
        // The control: a NEW memo does choose one, so the absence above is a decision rather than
        // a control the probe cannot see.
        #expect(
            creating.contains { $0.hasPrefix("Visibility:") },
            "the probe cannot see the visibility control at all: \(creating)"
        )
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

        let (saved, pressed) = await PressProbe.withScreen(
            ComposeView(mode: mode(), imports: imports) { _ in .failed(.transport(sent: true)) },
            height: 852
        ) { screen in
            let saved = screen.press("Save")
            // Pressed against a save that has really come back, or the case is not the case.
            await screen.settle(turns: 100, until: { imports.items.first?.uploadFailed != nil })
            let pressed = screen.press("Remove")
            await screen.settle()
            return (saved, pressed)
        }

        #expect(saved, "the sheet's own Save could not be pressed")
        #expect(pressed, "the x was not on the row to be pressed after the save came back")
        #expect(
            imports.ordered.map(\.label) == ["a.jpg"],
            "the picture left a list the server may already be holding")
    }

    /// The control the case above is worth nothing without: an answer that never left the device
    /// took nothing to the server, so there is nothing to keep the list still for.
    @Test("a picture can still be taken off after a save that never reached the server")
    func theXStillWorksAfterASaveThatNeverLeft() async {
        let imports = ComposeImports(readCapture: { _ in .empty })
        await imports.load(["a"], stamp: imports.selected()) { _ in .file(picked("a.jpg")) }
        await settleTasks()

        let (saved, pressed) = await PressProbe.withScreen(
            ComposeView(mode: mode(), imports: imports) { _ in .failed(.transport(sent: false)) },
            height: 852
        ) { screen in
            let saved = screen.press("Save")
            await screen.settle(turns: 100, until: { imports.items.first?.uploadFailed != nil })
            let pressed = screen.press("Remove")
            await screen.settle()
            return (saved, pressed)
        }

        #expect(saved, "the sheet's own Save could not be pressed")
        #expect(pressed, "the x was not on the row to be pressed after the save came back")
        #expect(
            imports.ordered.isEmpty,
            "the x is dead after a save that never left: \(imports.ordered.map(\.label))")
    }
}
