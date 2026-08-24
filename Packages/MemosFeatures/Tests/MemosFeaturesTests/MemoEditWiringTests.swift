import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Rendering a screen into a real window and reading its accessibility tree back.
///
/// A toolbar item is not in the view's own body — the hosting environment installs it into a
/// navigation bar — so measuring the body proves nothing about it. The only honest way to ask
/// "is that button actually on the screen?" is to put the screen up and look, which is also
/// exactly what a screen reader does.
@MainActor
enum ScreenProbe {
    static func labels(
        of view: some View,
        size: CGSize = CGSize(width: 393, height: 852)
    ) -> [String] {
        let host = UIHostingController(rootView: NavigationStack { view })
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // SwiftUI installs toolbar content on a later turn of the run loop than the first layout.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.view.layoutIfNeeded()

        var found: [String] = []
        collect(window, into: &found)
        window.isHidden = true
        window.rootViewController = nil
        return found
    }

    private static func collect(_ node: Any, into found: inout [String]) {
        if let element = node as? NSObject {
            if let label = element.accessibilityLabel, !label.isEmpty {
                found.append(label)
            }
            if let children = element.accessibilityElements {
                for child in children { collect(child, into: &found) }
            }
        }
        if let view = node as? UIView {
            for subview in view.subviews { collect(subview, into: &found) }
        }
    }
}

/// The Edit affordance, end to end: that it is on the screen at all, that it is on MY memos only,
/// and that the sheet it opens actually saves.
@MainActor
@Suite("Memo edit wiring")
struct MemoEditWiringTests {
    private let created = Date(timeIntervalSince1970: 1_750_000_000)

    /// No `SessionStore` in the environment on purpose: the detail view reads it only when a task
    /// is ticked or an edit is saved, and this bundle cannot build one — `SessionStore`'s default
    /// arguments reach into MemosAPI, which Features does not link (Features -> Core -> API).
    private func detail(_ memo: Memo) -> some View {
        MemoDetailView(uid: memo.uid, initial: memo, timeline: TimelineStore())
    }

    @Test("my own memo's screen really shows the Edit button")
    func ownMemoShowsEdit() {
        let memo = MemoFixture.memo(uid: "m1", content: "the boiler man comes Thursday")
        let labels = ScreenProbe.labels(of: detail(memo))

        // The positive control: if the probe cannot see this, it cannot see anything, and the
        // absence of "Edit memo" below would prove nothing at all.
        #expect(
            labels.contains { $0.contains("the boiler man") },
            "the probe found nothing of the memo itself: \(labels)"
        )
        #expect(labels.contains("Edit memo"), "no Edit affordance on the screen: \(labels)")
    }

    @Test("someone else's memo's screen shows no Edit button")
    func otherMemoHidesEdit() {
        let memo = MemoFixture.memo(
            uid: "m2", content: "the boiler man comes Thursday", mine: false)
        let labels = ScreenProbe.labels(of: detail(memo))

        #expect(labels.contains { $0.contains("the boiler man") })
        #expect(!labels.contains("Edit memo"), "an Edit affordance on a memo that is not mine")
    }

    // MARK: - what the pencil opens, and what Save does

    @Test("the pencil opens the sheet on THIS memo")
    func beginOpensTheSheetOnTheMemo() {
        let flow = MemoEditFlow()
        #expect(flow.editing == nil)

        flow.begin(
            MemoDetailPresentation.editMode(
                for: MemoFixture.memo(
                    uid: "m3", content: "ring the plumber", createdAt: created
                )))

        #expect(flow.editing == .edit(uid: "m3", content: "ring the plumber", createdAt: created))
    }

    @Test("a memo that is not mine opens nothing, even asked directly")
    func beginRefusesANotMineMemo() {
        let flow = MemoEditFlow()
        flow.begin(MemoDetailPresentation.editMode(for: MemoFixture.memo(uid: "m4", mine: false)))
        #expect(flow.editing == nil)
    }

    @Test("Save runs the save, closes the sheet and says nothing went wrong")
    func submitSavesAndCloses() async {
        let flow = MemoEditFlow()
        let recorder = SubmissionRecorder(result: true)
        flow.begin(.edit(uid: "m5", content: "before", createdAt: created))

        let closed = await flow.submit(
            ComposeSubmission(content: "after", visibility: nil), save: recorder.save
        )

        #expect(closed)
        #expect(recorder.count == 1, "the sheet's Save did not reach the save at all")
        #expect(recorder.lastSubmission?.content == "after")
        #expect(recorder.lastMode == .edit(uid: "m5", content: "before", createdAt: created))
        #expect(flow.editing == nil, "a saved edit closes the sheet")
        #expect(flow.lastError == nil)
    }

    @Test("a save that fails keeps the sheet open and says so")
    func submitKeepsTheSheetOnFailure() async {
        let flow = MemoEditFlow()
        let recorder = SubmissionRecorder(result: false)
        flow.begin(.edit(uid: "m6", content: "before", createdAt: created))

        let closed = await flow.submit(
            ComposeSubmission(content: "after", visibility: nil), save: recorder.save
        )

        #expect(!closed)
        #expect(recorder.count == 1)
        // The words someone just wrote are still on the screen, and the screen now says why.
        #expect(flow.editing != nil)
        #expect(flow.lastError == MemoEditFlow.failureMessage)
    }

    @Test("opening the sheet again clears the last failure")
    func beginClearsTheFailure() async {
        let flow = MemoEditFlow()
        flow.begin(.edit(uid: "m7", content: "before", createdAt: created))
        _ = await flow.submit(
            ComposeSubmission(content: "after", visibility: nil),
            save: SubmissionRecorder(result: false).save
        )
        #expect(flow.lastError != nil)

        flow.begin(.edit(uid: "m7", content: "before", createdAt: created))
        #expect(flow.lastError == nil)
    }

    @Test("dismissing the sheet without saving saves nothing")
    func dismissDoesNotSave() async {
        let flow = MemoEditFlow()
        let recorder = SubmissionRecorder(result: true)
        flow.begin(.edit(uid: "m8", content: "before", createdAt: created))

        flow.sheet.wrappedValue = nil

        #expect(flow.editing == nil)
        let closed = await flow.submit(
            ComposeSubmission(content: "after", visibility: nil), save: recorder.save
        )
        #expect(!closed)
        #expect(recorder.count == 0, "a dismissed sheet must not still be able to save")
    }
}

/// Deleting a memo from the sheet it is being edited in.
///
/// The edit screen could change a memo and could not remove one, so the only way to delete was a
/// swipe on its card back in the timeline. The affordance now lives where somebody who has opened a
/// memo to deal with it is already looking — behind a question, because it is the one act on this
/// screen that cannot be taken back.
///
/// Mine-gating is INHERENT and deliberately not re-tested here: the sheet is opened only by
/// `MemoEditFlow.begin(MemoDetailPresentation.editMode(for:))`, which is nil for a memo that is not
/// mine (`beginRefusesANotMineMemo`, above). There is no way to reach a delete affordance on
/// somebody else's memo without first defeating that gate.
@MainActor
@Suite("Memo delete wiring")
struct MemoDeleteWiringTests {
    private let created = Date(timeIntervalSince1970: 1_750_000_000)

    private func opened() -> MemoEditFlow {
        let flow = MemoEditFlow()
        flow.begin(.edit(uid: "m1", content: "before", createdAt: created))
        return flow
    }

    /// The load-bearing property, stated as the machine rather than as a screenshot of an alert:
    /// there is NO path from idle to deleting. A `confirmed` that arrives without a question
    /// having been asked — a stray event, a re-render, a second tap landing somewhere unexpected —
    /// is ignored rather than obeyed.
    @Test("nothing is deleted without a question that was actually asked")
    func noPathToDeleteWithoutConfirmation() {
        typealias Flow = MemoEditFlow
        #expect(Flow.nextDelete(.idle, on: .confirmed) == .idle)
        #expect(Flow.nextDelete(.idle, on: .cancelled) == .idle)
        #expect(Flow.nextDelete(.idle, on: .returned(true)) == .idle)
        // The only door into the request is asking first, then being answered yes.
        #expect(Flow.nextDelete(.idle, on: .tapped) == .asking)
        #expect(Flow.nextDelete(.asking, on: .confirmed) == .deleting)
        // And the request is the only stage that may talk to the server.
        #expect(Flow.deletes(.deleting))
        #expect(!Flow.deletes(.idle))
        #expect(!Flow.deletes(.asking))
    }

    @Test("a repeat tap is one question, and cannot restart a request in flight")
    func tapIsIdempotent() {
        typealias Flow = MemoEditFlow
        #expect(Flow.nextDelete(.asking, on: .tapped) == .asking)
        #expect(Flow.nextDelete(.deleting, on: .tapped) == .deleting)
        // A dismissal answers no — except once the request is gone, which cannot be recalled.
        #expect(Flow.nextDelete(.asking, on: .cancelled) == .idle)
        #expect(Flow.nextDelete(.deleting, on: .cancelled) == .deleting)
        // An answer is only meaningful for a request that was sent.
        #expect(Flow.nextDelete(.deleting, on: .returned(true)) == .idle)
        #expect(Flow.nextDelete(.deleting, on: .returned(false)) == .idle)
        #expect(Flow.nextDelete(.asking, on: .returned(true)) == .asking)
    }

    /// The seam the screen acts on: once the server says the memo is gone, the sheet closes AND
    /// the flow says the memo is gone, which is what `MemoDetailView` pops the detail screen on.
    /// Landing back on a detail view of a memo that no longer exists is the bug this prevents.
    @Test("a delete that worked closes the sheet and says the screen must go too")
    func successClosesBoth() {
        let flow = opened()
        #expect(!flow.memoDeleted)

        flow.advanceDelete(.tapped)
        #expect(flow.deleteStage == .asking)
        flow.advanceDelete(.confirmed)
        #expect(flow.deleteStage == .deleting)
        flow.advanceDelete(.returned(true))

        #expect(flow.deleteStage == .idle)
        #expect(flow.editing == nil, "the sheet stayed open over a memo that no longer exists")
        #expect(flow.memoDeleted, "nothing told the detail screen to go")
        #expect(flow.lastError == nil)
    }

    /// A delete that failed changes nothing and says so — through the same `lastError` a failed
    /// save uses, on the same screen, with the sheet still open.
    @Test("a delete that failed keeps the sheet open and says so")
    func failureKeepsTheSheet() {
        let flow = opened()
        flow.advanceDelete(.tapped)
        flow.advanceDelete(.confirmed)
        flow.advanceDelete(.returned(false))

        #expect(flow.deleteStage == .idle)
        #expect(flow.editing != nil, "a failed delete threw away the sheet anyway")
        #expect(!flow.memoDeleted, "a failed delete told the screen to pop")
        #expect(flow.lastError == MemoEditFlow.deleteFailureMessage)
        #expect(flow.lastError != MemoEditFlow.failureMessage, "a delete said it was a save")
    }

    @Test("the delete acts on the memo the sheet is open on")
    func theUidComesFromTheSheet() {
        let flow = MemoEditFlow()
        #expect(flow.editingUID == nil)
        flow.begin(.edit(uid: "m9", content: "x", createdAt: created))
        #expect(flow.editingUID == "m9")
    }

    @Test("opening the sheet again starts the conversation over")
    func beginResetsTheDeleteState() {
        let flow = opened()
        flow.advanceDelete(.tapped)
        flow.advanceDelete(.confirmed)
        flow.advanceDelete(.returned(false))
        #expect(flow.lastError != nil)

        flow.begin(.edit(uid: "m1", content: "before", createdAt: created))
        #expect(flow.deleteStage == .idle)
        #expect(!flow.memoDeleted)
        #expect(flow.lastError == nil)
    }

    // MARK: - the affordance itself

    /// That the row is on the screen at all. It is a body element rather than a toolbar item, but
    /// the probe is the same one the Edit button uses and the positive control is the same idea:
    /// if this cannot see the sheet's own Save, its silence about Delete would prove nothing.
    @Test("an edit sheet with a delete really shows it, and one without does not")
    func theDeleteRowIsOnTheSheet() {
        let mode = ComposeView.Mode.edit(uid: "m1", content: "the boiler man", createdAt: created)
        let withDelete = ScreenProbe.labels(
            of: ComposeView(
                mode: mode,
                delete: ComposeDelete(isAsking: false, send: { _ in })
            ) { _ in true }
        )
        #expect(
            withDelete.contains { $0.contains("Save") },
            "the probe found nothing of the sheet at all: \(withDelete)"
        )
        #expect(
            withDelete.contains("Delete memo"),
            "no Delete affordance on the edit sheet: \(withDelete)"
        )

        // A NEW memo has nothing to delete, and says nothing about deleting.
        let creating = ScreenProbe.labels(of: ComposeView(mode: .create) { _ in true })
        // Cancel rather than Post as the control: Post is disabled on an empty capture, and a
        // control that may be missing for its own reasons controls nothing.
        #expect(
            creating.contains { $0.contains("Cancel") },
            "the probe found nothing of the new-memo sheet: \(creating)"
        )
        #expect(!creating.contains("Delete memo"), "a new memo offered to delete itself")
    }
}

/// The counting store the wiring is asserted against: what was submitted, on which memo, how often.
@MainActor
final class SubmissionRecorder {
    private(set) var count = 0
    private(set) var lastMode: ComposeView.Mode?
    private(set) var lastSubmission: ComposeSubmission?
    private let result: Bool

    init(result: Bool) { self.result = result }

    func save(_ mode: ComposeView.Mode, _ submission: ComposeSubmission) async -> Bool {
        count += 1
        lastMode = mode
        lastSubmission = submission
        return result
    }
}
