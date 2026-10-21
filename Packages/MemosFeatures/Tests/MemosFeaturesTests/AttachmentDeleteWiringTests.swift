import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// Removing ONE picture from a memo, from the screen it is on.
///
/// The affordance is rendered from a projection and the request is started by a state machine, so
/// both are asserted here rather than inferred from a view body: what the screen OFFERS, on whose
/// memos, and what may actually reach the server.
@MainActor
@Suite("Attachment delete wiring")
struct AttachmentDeleteWiringTests {
    private func photo(_ uid: String) -> MemoAttachment {
        MediaViewerPageTests.image(uid)
    }

    private func clip(_ uid: String) -> MemoAttachment {
        MediaViewerPageTests.video(uid)
    }

    private func memo(_ attachments: [MemoAttachment], mine: Bool = true) -> Memo {
        MemoFixture.memo(uid: "m1", mine: mine, attachments: attachments)
    }

    // MARK: - the machine

    /// The load-bearing property, stated as the machine rather than as a screenshot of an alert:
    /// there is NO path from idle to deleting. A `confirmed` that arrives without a question having
    /// been asked — a stray event, a re-render, a repeat tap landing somewhere unexpected — is
    /// ignored rather than obeyed, and the server hard-deletes, so there is nothing to undo.
    @Test("nothing is deleted without a question that was actually asked")
    func noPathToDeleteWithoutConfirmation() {
        typealias Flow = AttachmentDeleteFlow
        #expect(Flow.next(.idle, on: .confirmed) == .idle)
        #expect(Flow.next(.idle, on: .cancelled) == .idle)
        #expect(Flow.next(.idle, on: .returned(true)) == .idle)
        // The only door into the request is asking first, then being answered yes — and the uid
        // travels with the stage, so the request cannot be aimed at another picture.
        #expect(Flow.next(.idle, on: .tapped("a1")) == .asking("a1"))
        #expect(Flow.next(.asking("a1"), on: .confirmed) == .deleting("a1"))
        #expect(Flow.deletes(.deleting("a1")) == "a1")
        #expect(Flow.deletes(.idle) == nil)
        #expect(Flow.deletes(.asking("a1")) == nil)
    }

    @Test("every other event from every other stage")
    func theRestOfTheTransitionTable() {
        typealias Flow = AttachmentDeleteFlow
        // A repeat tap is one question, about the picture it was first asked about — a second tap
        // on a DIFFERENT one cannot move an open question onto it.
        #expect(Flow.next(.asking("a1"), on: .tapped("a1")) == .asking("a1"))
        #expect(Flow.next(.asking("a1"), on: .tapped("a2")) == .asking("a1"))
        #expect(Flow.next(.deleting("a1"), on: .tapped("a2")) == .deleting("a1"))
        // A dismissal answers no — except once the request is gone, which cannot be recalled.
        #expect(Flow.next(.asking("a1"), on: .cancelled) == .idle)
        #expect(Flow.next(.deleting("a1"), on: .cancelled) == .deleting("a1"))
        // A confirmation has nothing to confirm once the request is already out.
        #expect(Flow.next(.deleting("a1"), on: .confirmed) == .deleting("a1"))
        // An answer is only meaningful for a request that was sent.
        #expect(Flow.next(.deleting("a1"), on: .returned(true)) == .idle)
        #expect(Flow.next(.deleting("a1"), on: .returned(false)) == .idle)
        #expect(Flow.next(.asking("a1"), on: .returned(true)) == .asking("a1"))
    }

    /// The words. A photo and a clip are different things to somebody about to remove one, and the
    /// file's own mime is what decides which — not the surface the row is drawn on.
    @Test("the row and the question say photo or video, by what the file is")
    func theLabelFollowsTheMime() {
        #expect(AttachmentDeleteFlow.title(for: photo("a1")) == "Delete Photo")
        #expect(AttachmentDeleteFlow.title(for: clip("v1")) == "Delete Video")
        #expect(AttachmentDeleteFlow.question(for: photo("a1")) == "Delete this photo?")
        #expect(AttachmentDeleteFlow.question(for: clip("v1")) == "Delete this video?")
        #expect(AttachmentAction.delete.title(for: clip("v1")) == "Delete Video")
        #expect(
            AttachmentDeleteFlow.explanation
                == "It is removed from the memo and from the server. This can't be undone."
        )
    }

    // MARK: - what the screen offers

    @Test("my own memo's pictures offer Delete, last; someone else's offer nothing")
    func theProjectionIsGatedOnMine() {
        let mine = MemoDetailPresentation.attachmentActions(for: memo([photo("a1")]))
        #expect(mine.contains(.delete), "no delete on my own memo's picture")
        #expect(mine.last == .delete, "the destructive action is not last: \(mine)")

        let theirs = MemoDetailPresentation.attachmentActions(
            for: memo([photo("a1")], mine: false)
        )
        #expect(theirs.isEmpty, "a memo that is not mine offered \(theirs)")
    }

    /// The capability the viewer's overlay reads. It is a fact about where the pages came from, so
    /// it is asserted on the projection that builds them rather than on the view.
    @Test("only a memo of mine opens a memo viewer that can delete; a list's answers per file")
    func theViewerCarriesTheCapabilityOnlyForMyOwnMemo() throws {
        let mine = try #require(
            MediaViewerPresentation.viewer(for: memo([photo("a1")]), startingAt: "a1")
        )
        #expect(mine.deletable(mine.startPage.attachment))

        let theirs = try #require(
            MediaViewerPresentation.viewer(
                for: memo([photo("a1")], mine: false), startingAt: "a1"
            )
        )
        #expect(
            !theirs.deletable(theirs.startPage.attachment),
            "somebody else's picture opened a viewer that can delete it")

        // A list viewer answers per file: one whose owner the payload never named is not mine.
        let library = try #require(
            MediaViewerPresentation.viewer(for: [photo("a1")], startingAt: "a1")
        )
        #expect(
            !library.deletable(library.startPage.attachment),
            "a file of nobody named offered to delete")
    }

    // MARK: - what the viewer does with the page that has gone

    @Test("the page that goes hands the reader its neighbour, or closes the viewer")
    func removingPicksTheNeighbour() {
        let pages = MediaViewerPresentation.pages(for: [photo("a1"), photo("a2"), photo("a3")])

        // The first: the next one slides into its place.
        let first = MediaViewerPager.removing("a1", from: pages, current: "a1")
        #expect(first.pages.map(\.id) == ["a2", "a3"])
        #expect(first.current == "a2")

        // The middle: the next one again.
        let middle = MediaViewerPager.removing("a2", from: pages, current: "a2")
        #expect(middle.pages.map(\.id) == ["a1", "a3"])
        #expect(middle.current == "a3")

        // The last: there is no next one, so the one before it.
        let last = MediaViewerPager.removing("a3", from: pages, current: "a3")
        #expect(last.pages.map(\.id) == ["a1", "a2"])
        #expect(last.current == "a2")

        // The only one: nothing is left to look at, and the viewer's answer to that is to close.
        let only = MediaViewerPager.removing("a1", from: Array(pages.prefix(1)), current: "a1")
        #expect(only.pages.isEmpty)
        #expect(only.current == nil)

        // A page the reader is not standing on leaves them exactly where they are.
        let elsewhere = MediaViewerPager.removing("a1", from: pages, current: "a3")
        #expect(elsewhere.pages.map(\.id) == ["a2", "a3"])
        #expect(elsewhere.current == "a3")
    }

    /// The reason the deleted ids are KEPT rather than merely taken out of `shown`: a memo's source
    /// is fixed and never shrinks, and the viewer recomputes its pages from it every evaluation.
    @Test("a fixed source cannot bring a deleted page back on the next evaluation")
    func visibleKeepsTheDeletedPageOut() {
        let source = MediaViewerPresentation.pages(for: [photo("a1"), photo("a2"), photo("a3")])
        let afterDelete = MediaViewerPager.removing("a3", from: source, current: "a3")

        // The control: without the set, the next evaluation adopts the source whole again.
        #expect(
            MediaViewerPager.extended(afterDelete.pages, with: source).map(\.id)
                == ["a1", "a2", "a3"],
            "the control no longer holds: `extended` did not re-adopt the fixed source"
        )

        let visible = MediaViewerPager.visible(
            shown: afterDelete.pages, source: source, removed: ["a3"]
        )
        #expect(visible.map(\.id) == ["a1", "a2"], "the deleted page came back")
    }

    // MARK: - the seam the screen acts on

    /// Driven through the REQUEST rather than around it: dropping it, sending two, or sending one
    /// aimed at another picture are all failures here.
    @Test("a confirmed delete sends exactly one request, for the picture that was asked about")
    func confirmSendsExactlyOneDelete() async {
        let flow = AttachmentDeleteFlow()
        let store = AttachmentDeleteRecorder(result: true)

        await flow.advance(.tapped("a2"), delete: store.delete)
        #expect(store.uids.isEmpty, "the tap that only asks sent a request")
        #expect(flow.stage == .asking("a2"))

        let gone = await flow.advance(.confirmed, delete: store.delete)

        #expect(gone)
        #expect(store.uids == ["a2"], "the store saw \(store.uids)")
        #expect(flow.stage == .idle)
        #expect(flow.lastError == nil)
    }

    @Test("nothing is sent without a confirmation")
    func nothingIsSentWithoutConfirmation() async {
        let cancelled = AttachmentDeleteRecorder(result: true)
        let flow = AttachmentDeleteFlow()
        await flow.advance(.tapped("a1"), delete: cancelled.delete)
        await flow.advance(.cancelled, delete: cancelled.delete)
        #expect(cancelled.uids.isEmpty, "a cancelled question deleted the picture anyway")
        #expect(flow.stage == .idle)

        // A confirmation out of nowhere — a stray event, a re-render — is ignored, not obeyed.
        let stray = AttachmentDeleteRecorder(result: true)
        let untouched = AttachmentDeleteFlow()
        await untouched.advance(.confirmed, delete: stray.delete)
        #expect(stray.uids.isEmpty, "a picture was deleted without anybody being asked")
    }

    /// The reflex the machine exists for: a second yes, arriving while the request is still out,
    /// sends nothing. The closure runs at exactly that moment.
    @Test("a second confirmation while the request is in flight sends nothing")
    func aSecondConfirmationInFlightSendsNothing() async {
        let flow = AttachmentDeleteFlow()
        let store = AttachmentDeleteRecorder(result: true)

        await flow.advance(.tapped("a1"), delete: store.delete)
        await flow.advance(.confirmed) { uid in
            #expect(flow.stage == .deleting("a1"), "the request ran outside the deleting stage")
            await flow.advance(.confirmed, delete: store.delete)
            return await store.delete(uid)
        }

        #expect(store.uids == ["a1"], "the store saw \(store.uids)")
        #expect(flow.stage == .idle)
    }

    /// The whole sequence the viewer runs: the answer comes back true, the page leaves the pager,
    /// and the source cannot put it back.
    @Test("a picture the server confirmed gone leaves the viewer and stays gone")
    func aConfirmedDeleteRemovesThePage() async {
        let source = MediaViewerPresentation.pages(for: [photo("a1"), photo("a2")])
        let flow = AttachmentDeleteFlow()
        let store = AttachmentDeleteRecorder(result: true)

        await flow.advance(.tapped("a1"), delete: store.delete)
        let gone = await flow.advance(.confirmed, delete: store.delete)

        #expect(gone)
        #expect(store.uids == ["a1"])
        let outcome = MediaViewerPager.removing("a1", from: source, current: "a1")
        #expect(outcome.current == "a2")
        #expect(
            MediaViewerPager.visible(shown: outcome.pages, source: source, removed: ["a1"])
                .map(\.id) == ["a2"]
        )
    }

    /// A delete that failed changes nothing and says so. The picture is still on the server, and
    /// the page it is on has not moved.
    @Test("a delete that failed keeps the picture and says why")
    func failureKeepsThePicture() async {
        let flow = AttachmentDeleteFlow()
        let store = AttachmentDeleteRecorder(result: false)

        await flow.advance(.tapped("a1"), delete: store.delete)
        let gone = await flow.advance(.confirmed, delete: store.delete)

        #expect(!gone)
        #expect(store.uids == ["a1"], "the request was not sent at all")
        #expect(flow.stage == .idle)
        #expect(flow.lastError == AttachmentDeleteFlow.failureMessage)

        // And asking again is not the last answer's failure.
        await flow.advance(.tapped("a1"), delete: store.delete)
        #expect(flow.lastError == nil)
    }
    // MARK: - the claim, and the order two events can arrive in

    /// The ordering bug the synchronous claim exists for.
    ///
    /// An alert's dismissal binding fires in the same turn as the button that dismissed it. While
    /// both events were wrapped in tasks they were two pieces of work with no order between them,
    /// and the cancellation winning put the machine back to `idle` — so the Delete somebody
    /// actually pressed found nothing to confirm and did nothing at all, in silence. The claim
    /// happens on the caller's own turn, so by the time the dismissal is delivered the request has
    /// already been claimed and a cancellation is the no-op it is supposed to be.
    @Test("a dismissal arriving after a confirmation was claimed does not swallow the delete")
    func aDismissalAfterTheClaimDoesNotSwallowIt() async {
        let flow = AttachmentDeleteFlow()
        let store = AttachmentDeleteRecorder(result: true)

        #expect(!flow.claim(.tapped("a1")), "the tap that only asks claimed a request")
        #expect(flow.claim(.confirmed), "the confirmation did not claim the request")
        // The alert going away, delivered after the claim — which is now the only order there is.
        #expect(!flow.claim(.cancelled))
        #expect(flow.stage == .deleting("a1"), "a dismissal recalled a request already claimed")

        let gone = await flow.perform(delete: store.delete)

        #expect(gone)
        #expect(store.uids == ["a1"], "the store saw \(store.uids)")
    }

    /// The other order, which must stay harmless: a question answered no, and a confirmation
    /// after it has nothing to confirm.
    @Test("a confirmation after a cancellation claims nothing and sends nothing")
    func aConfirmationAfterACancellationSendsNothing() async {
        let flow = AttachmentDeleteFlow()
        let store = AttachmentDeleteRecorder(result: true)

        flow.claim(.tapped("a1"))
        #expect(!flow.claim(.cancelled))
        #expect(flow.stage == .idle)
        #expect(!flow.claim(.confirmed), "a confirmation with no question open claimed a request")

        let gone = await flow.perform(delete: store.delete)

        #expect(!gone)
        #expect(store.uids.isEmpty, "the store saw \(store.uids)")
    }

    /// `perform` sends only from `deleting`, which only a claim reaches — so a view that forgets
    /// to claim sends nothing rather than deleting whatever was last asked about.
    @Test("performing without a claim sends nothing")
    func performWithoutAClaimSendsNothing() async {
        let flow = AttachmentDeleteFlow()
        let store = AttachmentDeleteRecorder(result: true)
        flow.claim(.tapped("a1"))

        let gone = await flow.perform(delete: store.delete)

        #expect(!gone)
        #expect(store.uids.isEmpty, "a request went out for a question nobody had answered")
    }

    /// What the viewer renders as its notice, and exactly when there is one to render. The viewer
    /// is a full-screen cover over a screen whose own notice belongs to a different flow, so this
    /// value is the only thing standing between a refused delete and silence.
    @Test("the failure message is there exactly after a refusal, and gone at the next question")
    func theFailureMessageAppearsOnlyOnARefusal() async {
        let flow = AttachmentDeleteFlow()
        let accepts = AttachmentDeleteRecorder(result: true)
        let refuses = AttachmentDeleteRecorder(result: false)
        #expect(flow.lastError == nil)

        await flow.advance(.tapped("a1"), delete: accepts.delete)
        #expect(flow.lastError == nil)
        await flow.advance(.confirmed, delete: accepts.delete)
        #expect(accepts.uids == ["a1"], "control: the accepted request was sent")
        #expect(flow.lastError == nil, "a delete that worked said something had gone wrong")

        await flow.advance(.tapped("a2"), delete: refuses.delete)
        await flow.advance(.confirmed, delete: refuses.delete)
        #expect(refuses.uids == ["a2"], "control: the refused request was sent")
        #expect(flow.lastError == AttachmentDeleteFlow.failureMessage)

        await flow.advance(.tapped("a2"), delete: refuses.delete)
        #expect(flow.lastError == nil, "the last refusal was still on screen under a new question")
    }
}

/// The store the delete is asserted against: which pictures were deleted, in order, and how many
/// times. Substituting the REQUEST is the point — the flow's own decision about when to send one is
/// the unit under test, and a test that fed it the answer instead would assert nothing at all.
@MainActor
final class AttachmentDeleteRecorder {
    private(set) var uids: [String] = []
    private let result: Bool

    init(result: Bool) { self.result = result }

    func delete(_ uid: String) async -> Bool {
        uids.append(uid)
        return result
    }
}
