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
