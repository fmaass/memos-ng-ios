import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// Select mode's Delete, from the screen's side (MEMNG-589): the question, what it is asked about,
/// what the answer is allowed to start, and what the screen says afterwards.
///
/// The run itself is `MediaLibraryStore.delete`, asserted over the wire in MemosCoreTests. Here it
/// is handed in as a closure that records what it was asked to delete, which is exactly the seam
/// the screen uses.
@MainActor
@Suite("Library delete flow")
struct LibraryDeleteFlowTests {
    private typealias Flow = LibraryDeleteFlow

    private static func outcome(
        deleted: [String],
        failed: String? = nil,
        notAttempted: [String] = [],
        stoppedForSessionChange: Bool = false
    ) -> LibraryDeleteOutcome {
        LibraryDeleteOutcome(
            deleted: deleted,
            failed: failed,
            notAttempted: notAttempted,
            stoppedForSessionChange: stoppedForSessionChange
        )
    }

    // MARK: - the machine

    @Test("nothing is deleted without a question that was actually asked")
    func noPathFromIdleToDeleting() {
        #expect(Flow.next(.idle, on: .confirmed) == .idle)
        #expect(Flow.next(.idle, on: .cancelled) == .idle)
        #expect(Flow.next(.idle, on: .returned) == .idle)
        #expect(Flow.next(.idle, on: .tapped([])) == .idle, "an empty selection opened a question")
        #expect(Flow.next(.idle, on: .tapped(["b", "a"])) == .asking(["b", "a"]))
        #expect(Flow.next(.asking(["b", "a"]), on: .confirmed) == .deleting(["b", "a"]))
        #expect(Flow.deletes(.deleting(["b", "a"])) == ["b", "a"])
        #expect(Flow.deletes(.asking(["b", "a"])) == nil)
        #expect(Flow.deletes(.idle) == nil)
    }

    @Test("every other event from every other stage")
    func theRestOfTheTransitionTable() {
        // A repeat tap cannot move an open question, or a run, onto another selection.
        #expect(Flow.next(.asking(["a"]), on: .tapped(["a", "b"])) == .asking(["a"]))
        #expect(Flow.next(.deleting(["a"]), on: .tapped(["b"])) == .deleting(["a"]))
        // Cancel answers no; once the run is out it cannot be recalled.
        #expect(Flow.next(.asking(["a"]), on: .cancelled) == .idle)
        #expect(Flow.next(.deleting(["a"]), on: .cancelled) == .deleting(["a"]))
        #expect(Flow.next(.deleting(["a"]), on: .confirmed) == .deleting(["a"]))
        #expect(Flow.next(.deleting(["a"]), on: .returned) == .idle)
        #expect(Flow.next(.asking(["a"]), on: .returned) == .asking(["a"]))
    }

    @Test("a confirmation from idle starts nothing and reaches nothing")
    func aConfirmationFromIdleStartsNothing() async {
        let flow = Flow()
        var asked: [[String]] = []

        #expect(!flow.claim(.confirmed))
        let outcome = await flow.perform { uids in
            asked.append(uids)
            return Self.outcome(deleted: uids)
        }

        #expect(outcome == nil)
        #expect(asked.isEmpty, "a run went out with no question asked")
        #expect(flow.stage == .idle)
    }

    @Test("the pictures asked about are the ones deleted, in the order they were chosen")
    func theAskedAboutPicturesAreTheOnesDeleted() async {
        let flow = Flow()
        var asked: [[String]] = []
        let run: @MainActor ([String]) async -> LibraryDeleteOutcome? = { uids in
            asked.append(uids)
            return Self.outcome(deleted: uids)
        }

        #expect(!flow.claim(.tapped(["c", "a"])), "the tap itself started a run")
        #expect(flow.asking == ["c", "a"])
        #expect(await flow.perform(delete: run) == nil, "a question alone reached the store")
        #expect(asked.isEmpty)

        #expect(flow.claim(.confirmed))
        #expect(flow.isDeleting)
        let outcome = await flow.perform(delete: run)

        #expect(asked == [["c", "a"]])
        #expect(outcome?.deleted == ["c", "a"])
        #expect(flow.stage == .idle)
        #expect(flow.message == nil, "a run that deleted everything reported a failure")
    }

    // MARK: - only my pictures (MEMNG-684)

    private static func row(_ uid: String, mine: Bool = true) -> LibraryRow {
        LibraryRow(
            attachment: MemoAttachment(uid: uid, mime: "image/jpeg", status: .ready),
            takenAt: nil,
            mine: mine,
            filename: "\(uid).jpg"
        )
    }

    /// A selection made, in this order, of `chosen` out of `rows`.
    private static func selection(_ chosen: [String], of rows: [LibraryRow]) -> LibrarySelection {
        var selection = LibrarySelection()
        selection.begin()
        for uid in chosen {
            if let row = rows.first(where: { $0.id == uid }) { selection.toggle(row) }
        }
        return selection
    }

    /// The toolbar's Delete builds its event with `tap`, and the run is handed what the question
    /// was asked about: so the uids sent are the ones `tap` took — my pictures, never another
    /// member's, however the selection interleaves them.
    @Test("a mixed selection asks about my pictures only, and only they are sent")
    func aMixedSelectionSendsOnlyMine() async {
        let theirs = [Self.row("x", mine: false), Self.row("y", mine: false)]
        let rows = [Self.row("a"), Self.row("c")] + theirs
        let chosen = Self.selection(["x", "c", "y", "a"], of: rows)
        let flow = Flow()
        var asked: [[String]] = []

        let event = Flow.tap(chosen, in: rows)
        #expect(event == .tapped(["c", "a"], skipped: 2))
        flow.claim(event)
        #expect(flow.asking == ["c", "a"])
        #expect(flow.skipping == 2)
        #expect(flow.claim(.confirmed))
        await flow.perform { uids in
            asked.append(uids)
            return Self.outcome(deleted: uids)
        }

        #expect(asked == [["c", "a"]], "another member's picture reached the delete request")
        #expect(flow.skipping == 0, "the skipped count outlived its question")
    }

    @Test("a selection of none of my pictures opens no question and sends nothing")
    func aSelectionOfNoneOfMineAsksNothing() async {
        let rows = [Self.row("x", mine: false), Self.row("y", mine: false)]
        let flow = Flow()
        var asked: [[String]] = []

        let event = Flow.tap(Self.selection(["y", "x"], of: rows), in: rows)
        #expect(event == .tapped([], skipped: 2))
        #expect(!flow.claim(event))
        #expect(flow.asking == nil, "a question opened about pictures that are not mine")
        #expect(!flow.claim(.confirmed))
        await flow.perform { uids in
            asked.append(uids)
            return Self.outcome(deleted: uids)
        }

        #expect(asked.isEmpty)
        #expect(flow.stage == .idle)
    }

    /// The alert's yes and a repeated Delete tap can land in one turn: a mixed selection is still
    /// one run, sent once, about the own pictures the first tap named.
    @Test("a repeated tap and a repeated yes over a mixed selection are one run of my pictures")
    func aRepeatedTapAndYesAreOneRun() async {
        let rows = [Self.row("a"), Self.row("x", mine: false), Self.row("b")]
        let flow = Flow()
        var asked: [[String]] = []

        flow.claim(Flow.tap(Self.selection(["a", "x"], of: rows), in: rows))
        flow.claim(Flow.tap(Self.selection(["a", "x", "b"], of: rows), in: rows))
        #expect(flow.claim(.confirmed))
        #expect(!flow.claim(.confirmed), "a second yes started a second run")
        await flow.perform { uids in
            asked.append(uids)
            return Self.outcome(deleted: uids)
        }
        await flow.perform { uids in
            asked.append(uids)
            return Self.outcome(deleted: uids)
        }

        #expect(asked == [["a"]])
    }

    @Test("cancel closes the question and deletes nothing")
    func cancelDeletesNothing() async {
        let flow = Flow()
        var asked: [[String]] = []

        flow.claim(.tapped(["a"]))
        flow.claim(.cancelled)
        flow.claim(.confirmed)
        await flow.perform { uids in
            asked.append(uids)
            return Self.outcome(deleted: uids)
        }

        #expect(flow.stage == .idle)
        #expect(asked.isEmpty)
    }

    @Test("a failed run leaves its report; the next question clears it, and so does a dismissal")
    func aFailedRunReports() async {
        let flow = Flow()
        flow.claim(.tapped(["a", "b", "c"]))
        flow.claim(.confirmed)
        await flow.perform { _ in Self.outcome(deleted: ["a"], failed: "b", notAttempted: ["c"]) }

        #expect(flow.message == "1 deleted, 2 failed")
        flow.claim(.tapped(["b", "c"]))
        #expect(flow.message == nil, "the last run's report stood over a new question")

        flow.claim(.confirmed)
        await flow.perform { _ in Self.outcome(deleted: [], failed: "b", notAttempted: ["c"]) }
        #expect(flow.message == "0 deleted, 2 failed")
        flow.dismissMessage()
        #expect(flow.message == nil)
    }

    @Test("a run the store refused says nothing and closes")
    func aRefusedRunSaysNothing() async {
        let flow = Flow()
        flow.claim(.tapped(["a"]))
        flow.claim(.confirmed)

        let outcome = await flow.perform { _ in nil }

        #expect(outcome == nil)
        #expect(flow.stage == .idle)
        #expect(flow.message == nil)
    }

    /// Select mode ends while the run is out, and opens again with a new question. The old run's
    /// answer arrives after that: it must neither close the new question nor put its report over
    /// it.
    @Test("a run that ends after select mode was left changes nothing on screen")
    func anAbandonedRunChangesNothing() async {
        let flow = Flow()
        flow.claim(.tapped(["a", "b"]))
        flow.claim(.confirmed)

        let outcome = await flow.perform { _ in
            flow.abandon()
            flow.claim(.tapped(["z"]))
            return Self.outcome(deleted: ["a"], failed: "b")
        }

        #expect(outcome?.failed == "b", "control: the run did report a failure")
        #expect(flow.stage == .asking(["z"]), "the late run moved the new question")
        #expect(flow.message == nil, "the late run's report surfaced over a new select mode")
    }

    @Test("abandoning closes an open question and clears the report")
    func abandonClosesTheQuestion() async {
        let flow = Flow()
        flow.claim(.tapped(["a"]))
        flow.claim(.confirmed)
        await flow.perform { _ in Self.outcome(deleted: [], failed: "a") }
        flow.claim(.tapped(["a"]))

        flow.abandon()

        #expect(flow.stage == .idle)
        #expect(flow.message == nil)
    }

    // MARK: - the words

    @Test("the question names the count, in the singular for one")
    func theQuestionNamesTheCount() {
        #expect(Flow.question(count: 1) == "Delete 1 Item?")
        #expect(Flow.question(count: 3) == "Delete 3 Items?")
        #expect(Flow.confirmTitle == "Delete")
        let explanation =
            "They are deleted from the server and from any memo they belong to. "
            + "This can't be undone."
        #expect(Flow.explanation == explanation)
    }

    @Test("the question over only my pictures names their count and nothing else")
    func theQuestionAllMine() {
        #expect(Flow.question(count: 3, skipped: 0) == "Delete 3 Items?")
        #expect(Flow.question(count: 1, skipped: 0) == "Delete 1 Item?")
    }

    @Test("the question over a mixed selection names what goes and what stays")
    func theQuestionMixed() {
        #expect(
            Flow.question(count: 3, skipped: 2)
                == "Delete 3 Items? 2 others belong to another member and stay.")
        #expect(
            Flow.question(count: 1, skipped: 1)
                == "Delete 1 Item? 1 other belongs to another member and stays.")
    }

    @Test("the sentence over none of my pictures says nothing is to be deleted, and why")
    func theQuestionNoneMine() {
        #expect(
            Flow.question(count: 0, skipped: 2)
                == "Nothing to delete: 2 items belong to another member.")
        #expect(
            Flow.question(count: 0, skipped: 1)
                == "Nothing to delete: 1 item belongs to another member.")
    }

    @Test("the question over an empty selection is the plain count")
    func theQuestionEmpty() {
        #expect(Flow.question(count: 0, skipped: 0) == "Delete 0 Items?")
        #expect(Flow.question(count: 0) == Flow.question(count: 0, skipped: 0))
    }

    @Test("the report says how many went and how many did not, and only when something failed")
    func theReport() {
        #expect(Flow.resultText(Self.outcome(deleted: ["a", "b"])) == nil)
        #expect(Flow.resultText(Self.outcome(deleted: [])) == nil)
        let stoppedByAFailure = Self.outcome(deleted: ["a"], failed: "b", notAttempted: ["c", "d"])
        #expect(Flow.resultText(stoppedByAFailure) == "1 deleted, 3 failed")
        let failedLast = Self.outcome(deleted: ["a", "b"], failed: "c")
        #expect(Flow.resultText(failedLast) == "2 deleted, 1 failed")
        // Somebody else signed in: nothing of the old run is the new account's to read.
        let stopped = Self.outcome(
            deleted: ["a"], notAttempted: ["b"], stoppedForSessionChange: true
        )
        #expect(Flow.resultText(stopped) == nil)
    }

    @Test("share and delete take a tap only with something chosen and nothing running")
    func theToolbarGate() {
        typealias Presentation = LibrarySelectionPresentation
        #expect(Presentation.actionsEnabled(count: 2, isSharing: false, isDeleting: false))
        #expect(!Presentation.actionsEnabled(count: 0, isSharing: false, isDeleting: false))
        #expect(!Presentation.actionsEnabled(count: 2, isSharing: true, isDeleting: false))
        #expect(!Presentation.actionsEnabled(count: 2, isSharing: false, isDeleting: true))
    }

    /// MEMNG-684: Delete is a question about my pictures; a selection holding none of them
    /// leaves it off while Share stays on.
    @Test("delete takes a tap only with one of my pictures chosen and nothing running")
    func theDeleteGate() {
        typealias Presentation = LibrarySelectionPresentation
        #expect(Presentation.deleteEnabled(ownCount: 1, isSharing: false, isDeleting: false))
        #expect(!Presentation.deleteEnabled(ownCount: 0, isSharing: false, isDeleting: false))
        #expect(!Presentation.deleteEnabled(ownCount: 2, isSharing: true, isDeleting: false))
        #expect(!Presentation.deleteEnabled(ownCount: 2, isSharing: false, isDeleting: true))
    }
}
