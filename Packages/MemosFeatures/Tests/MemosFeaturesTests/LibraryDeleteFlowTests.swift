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
}
