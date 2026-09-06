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

    /// Puts a view on a real screen, lets it lay out, and takes it down again.
    ///
    /// For the assertions that are about what the view MEASURED rather than what it says: a
    /// SwiftUI view reports geometry only once something has actually laid it out, so a probe that
    /// never hosts it reads nothing at all — and a test built on rectangles it computed for itself
    /// would keep passing after the view stopped reporting any.
    static func settle(_ view: some View, size: CGSize = CGSize(width: 402, height: 874)) {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Geometry is reported on a later turn of the run loop than the first layout, and the
        // state it writes takes another to come back round.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.isHidden = true
        window.rootViewController = nil
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

        #expect(closed.isSaved)
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

        #expect(!closed.isSaved)
        #expect(recorder.count == 1)
        // The words someone just wrote are still on the screen, and the screen now says why.
        #expect(flow.editing != nil)
        #expect(flow.lastError == ComposeFailurePresentation.sentence(for: .rejection))
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
        #expect(!closed.isSaved)
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

    /// The seam the screen acts on, driven through the REQUEST rather than around it.
    ///
    /// Every assertion below counts what actually reached the store: dropping the request, sending
    /// two, or sending one aimed at another memo are all failures here, and none of them were
    /// visible when the test fed the flow its own `.returned(true)`.
    @Test("a confirmed delete sends exactly one request, for the memo on screen")
    func confirmSendsExactlyOneDelete() async {
        let flow = opened()
        let store = DeleteRecorder(result: true)

        await flow.advanceDelete(.tapped, delete: store.delete)
        #expect(store.uids.isEmpty, "the tap that only asks sent a request")
        #expect(flow.deleteStage == .asking)

        await flow.advanceDelete(.confirmed, delete: store.delete)

        #expect(store.uids == ["m1"], "the store saw \(store.uids)")
        #expect(flow.deleteStage == .idle)
        #expect(flow.editing == nil, "the sheet stayed open over a memo that no longer exists")
        #expect(flow.memoDeleted, "nothing told the detail screen to go")
        #expect(flow.lastError == nil)
    }

    /// The load-bearing half: a question that was answered no, or never answered at all, reaches
    /// the server not at all.
    @Test("nothing is sent without a confirmation")
    func nothingIsSentWithoutConfirmation() async {
        let cancelled = DeleteRecorder(result: true)
        let flow = opened()
        await flow.advanceDelete(.tapped, delete: cancelled.delete)
        await flow.advanceDelete(.cancelled, delete: cancelled.delete)
        #expect(cancelled.uids.isEmpty, "a cancelled question deleted the memo anyway")
        #expect(flow.deleteStage == .idle)
        #expect(!flow.memoDeleted)

        // A confirmation out of nowhere — a stray event, a re-render — is ignored, not obeyed.
        let stray = DeleteRecorder(result: true)
        let untouched = opened()
        await untouched.advanceDelete(.confirmed, delete: stray.delete)
        #expect(stray.uids.isEmpty, "a memo was deleted without anybody being asked")
        #expect(untouched.editing != nil)
    }

    /// The reflex this machine exists for: tapping a destructive row twice is one question, and
    /// answering it once is one request.
    @Test("a double tap is still one question and one delete")
    func doubleTapSendsOneDelete() async {
        let flow = opened()
        let store = DeleteRecorder(result: true)

        await flow.advanceDelete(.tapped, delete: store.delete)
        await flow.advanceDelete(.tapped, delete: store.delete)
        #expect(flow.deleteStage == .asking)
        #expect(store.uids.isEmpty)

        await flow.advanceDelete(.confirmed, delete: store.delete)
        // A second confirmation, arriving after the first has settled, has no question to answer.
        await flow.advanceDelete(.confirmed, delete: store.delete)

        #expect(store.uids == ["m1"], "the store saw \(store.uids)")
    }

    /// A delete that failed changes nothing and says so — through the same `lastError` a failed
    /// save uses, on the same screen, with the sheet still open.
    @Test("a delete that failed keeps the sheet open and says so")
    func failureKeepsTheSheet() async {
        let flow = opened()
        let store = DeleteRecorder(result: false)

        await flow.advanceDelete(.tapped, delete: store.delete)
        await flow.advanceDelete(.confirmed, delete: store.delete)

        #expect(store.uids == ["m1"], "the request was not sent at all")
        #expect(flow.deleteStage == .idle)
        #expect(flow.editing != nil, "a failed delete threw away the sheet anyway")
        #expect(!flow.memoDeleted, "a failed delete told the screen to pop")
        #expect(flow.lastError == MemoEditFlow.deleteFailureMessage)
        #expect(
            flow.lastError != ComposeFailurePresentation.sentence(for: .rejection),
            "a delete said it was a save")
    }

    /// The uid is the flow's own, not one the caller supplies, so a delete cannot be aimed at a
    /// memo other than the one the sheet is open on.
    @Test("the request carries the uid of the memo the sheet is open on")
    func theRequestCarriesTheSheetsUid() async {
        let flow = MemoEditFlow()
        flow.begin(.edit(uid: "m9", content: "x", createdAt: created))
        let store = DeleteRecorder(result: true)

        await flow.advanceDelete(.tapped, delete: store.delete)
        await flow.advanceDelete(.confirmed, delete: store.delete)

        #expect(store.uids == ["m9"])
    }

    /// A sheet that was dismissed has nothing to delete — the request cannot outlive the screen
    /// that asked for it.
    @Test("a dismissed sheet cannot still delete")
    func dismissedSheetCannotDelete() async {
        let flow = opened()
        let store = DeleteRecorder(result: true)
        await flow.advanceDelete(.tapped, delete: store.delete)
        flow.sheet.wrappedValue = nil

        await flow.advanceDelete(.confirmed, delete: store.delete)

        #expect(store.uids.isEmpty, "a closed sheet deleted a memo")
    }

    /// WHEN the screen is told the memo has gone, relative to the sheet closing.
    ///
    /// Observation notifies its observers SYNCHRONOUSLY, before the value they are watching has
    /// finished changing — so this reads the exact state the memo's screen is woken in. It has to
    /// be a sheet that has already closed: a `dismiss()` issued by a view that is still presenting
    /// one goes to the sheet, not to the screen, and the person who deleted the memo is left on
    /// the detail view of a memo that no longer exists (the bug on build 4).
    @Test("the screen is not told the memo has gone until the editor has closed")
    func theScreenIsToldOnlyAfterTheSheetCloses() async {
        let flow = opened()
        let store = DeleteRecorder(result: true)
        let told = Box(false)
        let sheetStillOpen = Box(false)

        withObservationTracking {
            _ = flow.memoDeleted
        } onChange: {
            MainActor.assumeIsolated {
                told.value = true
                sheetStillOpen.value = flow.editing != nil
            }
        }

        await flow.advanceDelete(.tapped, delete: store.delete)
        await flow.advanceDelete(.confirmed, delete: store.delete)

        #expect(store.uids == ["m1"], "the delete never reached the store")
        // The control: an assertion about WHEN nothing was ever told would hold vacuously.
        #expect(told.value, "nothing was ever told the memo had gone")
        #expect(!sheetStillOpen.value, "the screen was told to go while its own sheet was open")
    }

    /// The decision itself, one case per way an editor can close, driven through the real flow
    /// rather than fed its own answer.
    @Test("what the memo's screen does once its editor has closed")
    func theExitIsDecidedByWhetherTheMemoIsGone() async {
        typealias Exit = MemoDetailPresentation.EditorExit

        let saved = MemoEditFlow()
        saved.begin(.edit(uid: "m1", content: "before", createdAt: created))
        _ = await saved.submit(
            ComposeSubmission(content: "after", visibility: nil),
            save: SubmissionRecorder(result: true).save
        )
        let afterSaved = MemoDetailPresentation.popDecision(
            memoDeleted: saved.memoDeleted, sheetClosed: true
        )
        #expect(afterSaved == Exit.stay)

        let cancelled = MemoEditFlow()
        cancelled.begin(.edit(uid: "m1", content: "before", createdAt: created))
        cancelled.sheet.wrappedValue = nil
        let afterCancel = MemoDetailPresentation.popDecision(
            memoDeleted: cancelled.memoDeleted, sheetClosed: true
        )
        #expect(afterCancel == Exit.stay)

        let deleted = MemoEditFlow()
        let store = DeleteRecorder(result: true)
        deleted.begin(.edit(uid: "m1", content: "before", createdAt: created))
        await deleted.advanceDelete(.tapped, delete: store.delete)
        await deleted.advanceDelete(.confirmed, delete: store.delete)
        #expect(store.uids == ["m1"], "the delete never reached the store")
        let afterDelete = MemoDetailPresentation.popDecision(
            memoDeleted: deleted.memoDeleted, sheetClosed: true
        )
        #expect(afterDelete == Exit.popToOverview)

        // A delete that failed is not a delete: the memo is still there and so is its screen.
        let failed = MemoEditFlow()
        let refuser = DeleteRecorder(result: false)
        failed.begin(.edit(uid: "m1", content: "before", createdAt: created))
        await failed.advanceDelete(.tapped, delete: refuser.delete)
        await failed.advanceDelete(.confirmed, delete: refuser.delete)
        #expect(refuser.uids == ["m1"], "the delete never reached the store")
        let afterFailed = MemoDetailPresentation.popDecision(
            memoDeleted: failed.memoDeleted, sheetClosed: true
        )
        #expect(afterFailed == Exit.stay)
    }

    @Test("opening the sheet again starts the conversation over")
    func beginResetsTheDeleteState() async {
        let flow = opened()
        let store = DeleteRecorder(result: false)
        await flow.advanceDelete(.tapped, delete: store.delete)
        await flow.advanceDelete(.confirmed, delete: store.delete)
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
            ) { _ in .saved }
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
        let creating = ScreenProbe.labels(of: ComposeView(mode: .create) { _ in .saved })
        // Cancel rather than Post as the control: Post is disabled on an empty capture, and a
        // control that may be missing for its own reasons controls nothing.
        #expect(
            creating.contains { $0.contains("Cancel") },
            "the probe found nothing of the new-memo sheet: \(creating)"
        )
        #expect(!creating.contains("Delete memo"), "a new memo offered to delete itself")
    }
}

/// When the memo's screen leaves, across both orders the two events can arrive in.
///
/// The screen goes when the memo is confirmed gone AND its editor has closed, on whichever of the
/// two is second. Both orders are real and both have been wrong: popping on the memo alone asks a
/// view that is still presenting its sheet to dismiss, and the dismissal is spent on the sheet;
/// popping only when the editor closes strands whoever swiped the editor away while the request
/// was still out, because the server then answers to a sheet that has already gone.
///
/// The events are fed in by hand because a modal presentation never completes under
/// `xcodebuild test` — measured across four shapes of run-loop wait, in a scene-attached key
/// window as much as a bare one — so a test that put the real screen up would be red about the
/// harness rather than about the code. `MemoDetailView` calls exactly these three and nothing
/// else: `editorOpened()` from the Edit button, `editorClosed(memoDeleted:)` from the sheet's
/// `onDismiss`, and `memoDeletedChanged(_:)` from `.onChange(of: edit.memoDeleted)`.
///
/// Every test counts POPS rather than reading a flag, because "at most one, and at least one" is
/// the property — a screen that leaves twice is as wrong as one that never leaves.
@MainActor
@Suite("Memo detail exit")
struct MemoDetailExitTests {
    private let created = Date(timeIntervalSince1970: 1_750_000_000)

    private func editorOpened(_ exit: MemoDetailExit) -> MemoEditFlow {
        exit.editorOpened()
        let flow = MemoEditFlow()
        flow.begin(.edit(uid: "m1", content: "before", createdAt: created))
        return flow
    }

    /// The race: Delete is confirmed, and the editor is swiped away while the request is still
    /// out. `onDismiss` has been and gone by the time the server answers, so nothing would ask
    /// again — and the person is left on the memo they have just deleted.
    @Test("an editor swiped away mid-delete still takes the screen with it, once")
    func dismissedMidDeleteStillPops() async {
        let exit = MemoDetailExit()
        let flow = editorOpened(exit)
        let store = DeleteRecorder(result: true)
        let pops = Box(0)

        await flow.advanceDelete(.tapped, delete: store.delete)
        // The closure runs at exactly the in-flight moment: the request is out, the answer is not
        // back. That is where the swipe lands.
        await flow.advanceDelete(.confirmed) { uid in
            flow.sheet.wrappedValue = nil
            #expect(flow.deleteStage == .deleting, "a dismissal aborted a request already sent")
            if exit.editorClosed(memoDeleted: flow.memoDeleted) { pops.value += 1 }
            #expect(pops.value == 0, "the screen left before the server had answered")
            return await store.delete(uid)
        }

        #expect(store.uids == ["m1"], "the delete never reached the store: \(store.uids)")
        #expect(flow.memoDeleted)
        if exit.memoDeletedChanged(flow.memoDeleted) { pops.value += 1 }
        #expect(pops.value == 1, "the deleted memo's screen was left up: \(pops.value) pops")
    }

    /// The ordinary order: the answer comes back to an editor that is still on screen, so the
    /// memo is reported gone first and the sheet finishes closing second.
    @Test("a delete confirmed with the editor still up takes the screen once, on the close")
    func confirmedDeletePopsOnTheClose() async {
        let exit = MemoDetailExit()
        let flow = editorOpened(exit)
        let store = DeleteRecorder(result: true)
        let pops = Box(0)

        await flow.advanceDelete(.tapped, delete: store.delete)
        await flow.advanceDelete(.confirmed, delete: store.delete)
        #expect(store.uids == ["m1"])

        if exit.memoDeletedChanged(flow.memoDeleted) { pops.value += 1 }
        #expect(pops.value == 0, "the screen left while its editor was still on the way out")

        if exit.editorClosed(memoDeleted: flow.memoDeleted) { pops.value += 1 }
        #expect(pops.value == 1, "the deleted memo's screen was left up")
    }

    /// An editor closed with nothing deleted leaves the memo's screen where it is, whichever
    /// event arrives and however often.
    @Test("an editor closed without a delete never takes the screen")
    func closingWithoutADeleteNeverPops() async {
        let exit = MemoDetailExit()
        let flow = editorOpened(exit)
        let store = DeleteRecorder(result: false)
        let pops = Box(0)

        // Cancelled outright.
        flow.sheet.wrappedValue = nil
        if exit.editorClosed(memoDeleted: flow.memoDeleted) { pops.value += 1 }
        if exit.memoDeletedChanged(flow.memoDeleted) { pops.value += 1 }
        #expect(pops.value == 0, "a cancelled edit threw the memo's screen away")

        // And a delete the server refused is not a delete either.
        let refused = editorOpened(exit)
        await refused.advanceDelete(.tapped, delete: store.delete)
        await refused.advanceDelete(.confirmed, delete: store.delete)
        #expect(store.uids == ["m1"], "the delete never reached the store")
        #expect(!refused.memoDeleted)
        if exit.memoDeletedChanged(refused.memoDeleted) { pops.value += 1 }
        if exit.editorClosed(memoDeleted: refused.memoDeleted) { pops.value += 1 }
        #expect(pops.value == 0, "a delete that failed threw the memo's screen away")
    }

    /// Both events fire in every real run, and either may repeat. One screen leaves once.
    @Test("both events, and repeats of them, still take the screen exactly once")
    func repeatedEventsPopOnlyOnce() async {
        let exit = MemoDetailExit()
        let flow = editorOpened(exit)
        let store = DeleteRecorder(result: true)
        let pops = Box(0)

        await flow.advanceDelete(.tapped, delete: store.delete)
        await flow.advanceDelete(.confirmed, delete: store.delete)

        for _ in 0..<3 {
            if exit.memoDeletedChanged(flow.memoDeleted) { pops.value += 1 }
            if exit.editorClosed(memoDeleted: flow.memoDeleted) { pops.value += 1 }
        }

        #expect(pops.value == 1, "the screen left \(pops.value) times")
    }

    /// A cancelled editor must not arm the NEXT one: `sheetClosed` is about the editor that is on
    /// screen now. Without the reset, the second delete would pop while its own sheet was still
    /// up, and that dismissal would be spent on the sheet — the original bug, returned.
    @Test("a cancelled editor does not arm the next delete")
    func reopeningTheEditorDisarmsTheClose() async {
        let exit = MemoDetailExit()
        let cancelled = editorOpened(exit)
        let pops = Box(0)

        cancelled.sheet.wrappedValue = nil
        if exit.editorClosed(memoDeleted: cancelled.memoDeleted) { pops.value += 1 }
        #expect(exit.sheetClosed, "the editor closed and nothing recorded it")

        let flow = editorOpened(exit)
        #expect(!exit.sheetClosed, "the second editor opened onto the first one's closure")
        let store = DeleteRecorder(result: true)
        await flow.advanceDelete(.tapped, delete: store.delete)
        await flow.advanceDelete(.confirmed, delete: store.delete)

        if exit.memoDeletedChanged(flow.memoDeleted) { pops.value += 1 }
        #expect(pops.value == 0, "the screen left while its second editor was still up")

        if exit.editorClosed(memoDeleted: flow.memoDeleted) { pops.value += 1 }
        #expect(pops.value == 1, "the deleted memo's screen was left up")
    }
}

/// The store the delete is asserted against: which memos were deleted, in order, and how many
/// times. Substituting the REQUEST is the point — the flow's own decision about when to send one
/// is the unit under test, and a test that fed it the answer instead would assert nothing at all.
@MainActor
final class DeleteRecorder {
    private(set) var uids: [String] = []
    private let result: Bool

    init(result: Bool) { self.result = result }

    func delete(_ uid: String) async -> Bool {
        uids.append(uid)
        return result
    }
}

/// The counting store the wiring is asserted against: what was submitted, on which memo, how often.
@MainActor
final class SubmissionRecorder {
    private(set) var count = 0
    private(set) var lastMode: ComposeView.Mode?
    private(set) var lastSubmission: ComposeSubmission?
    private let result: ComposeOutcome

    /// `result: false` is the ordinary failure this suite is about — the server answered no. The
    /// categories are `ComposeFailureTests`' subject, not this one's.
    init(result: Bool) { self.result = result ? .saved : .failed(.rejection) }

    func save(_ mode: ComposeView.Mode, _ submission: ComposeSubmission) async -> ComposeOutcome {
        count += 1
        lastMode = mode
        lastSubmission = submission
        return result
    }
}
