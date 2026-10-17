import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// Select mode's memo actions, from the screen's side (MEMNG-788): the rows' wording, the
/// visibility question and what it discloses, the synchronous claim and its fences, and what the
/// banner says after a run. The runs themselves are `MemoActionStore`'s, asserted over the wire in
/// MemosCoreTests; here they are handed in as closures, the seam the screens use.
@MainActor
@Suite("Memo action flow")
struct MemoActionFlowTests {
    private typealias Flow = MemoActionFlow

    @Test("the rows and the question count memos, one memo in the singular")
    func theWording() {
        #expect(Flow.visibilityRowTitle(2) == "Set visibility for 2 memos")
        #expect(Flow.visibilityRowTitle(1) == "Set visibility for 1 memo")
        #expect(Flow.question(3, to: .public) == "Change 3 memos to Public?")
        #expect(Flow.question(1, to: .protected) == "Change 1 memo to Just us?")
        #expect(Flow.confirmTitle == "Change")
        #expect(Flow.addRowTitle == "Add to trip")
        #expect(Flow.choices == [.public, .protected])
    }

    @Test("one chosen picture of a protected memo with an unselected sibling: 1 memo, disclosed")
    func theDisclosure() {
        // p1 chosen, its sibling p2 on the same memo not; the memo also has text. The question
        // names the ONE memo, and the message says the whole memo changes.
        let chosen = [MemoActionPicture(uid: "p1", memoUID: "m1", mine: true)]
        let memos = MemoActionPicture.memos(of: chosen)
        let flow = Flow()
        flow.ask(memos: memos, visibility: .public, generation: 1, filter: "all")
        let asked = try? #require(flow.asking)
        #expect(asked?.memos == ["m1"])
        #expect(Flow.question(asked?.memos.count ?? 0, to: .public) == "Change 1 memo to Public?")
        #expect(
            Flow.explanation
                == "The memos these pictures belong to change as a whole — their text and every "
                + "other picture on them.")
    }

    @Test("others' memos and orphans are not counted: nothing to ask about")
    func nothingToAsk() {
        let chosen = [
            MemoActionPicture(uid: "p1", memoUID: "m9", mine: false),
            MemoActionPicture(uid: "p2", memoUID: nil, mine: true),
        ]
        let flow = Flow()
        flow.ask(
            memos: MemoActionPicture.memos(of: chosen), visibility: .public, generation: 1,
            filter: "all")
        #expect(flow.asking == nil, "a choice of no memo of the caller's asked")
        flow.ask(memos: [], visibility: .protected, generation: 1, filter: "all")
        #expect(flow.asking == nil, "an empty choice asked")
    }

    @Test("the answer is claimed once, synchronously; another session or filter sends nothing")
    func theClaimAndItsFences() {
        let flow = Flow()
        flow.ask(memos: ["m1"], visibility: .public, generation: 1, filter: "all")
        #expect(flow.claim(generation: 1, filter: "all")?.memos == ["m1"])
        #expect(flow.claim(generation: 1, filter: "all") == nil, "a second answer found one")

        flow.ask(memos: ["m1"], visibility: .public, generation: 1, filter: "all")
        #expect(flow.claim(generation: 2, filter: "all") == nil, "another session sent it")
        #expect(flow.asking == nil)

        flow.ask(memos: ["m1"], visibility: .public, generation: 1, filter: "all")
        #expect(flow.claim(generation: 1, filter: "images") == nil, "another filter sent it")

        flow.ask(memos: ["m1"], visibility: .public, generation: 1, filter: "all")
        flow.void()
        #expect(flow.claim(generation: 1, filter: "all") == nil)
    }

    @Test("a finished run says N of M and the grid is read again; a refusal says so, no re-read")
    func theBannerAndTheReread() async {
        let flow = Flow()
        var rereads = 0
        await flow.perform(reread: { rereads += 1 }) {
            .finished(.init(action: .visibility(.public), asked: 2, changed: 1))
        }
        #expect(flow.message == "1 of 2 changed")
        #expect(rereads == 1)

        await flow.perform(reread: { rereads += 1 }) { .refused }
        #expect(flow.message == "Another change is still running")
        #expect(rereads == 1, "a refused call re-read the grid")

        flow.dismissMessage()
        await flow.perform(reread: { rereads += 1 }) { .superseded }
        #expect(flow.message == nil, "a run of an ended session spoke")
        #expect(rereads == 1, "a run of an ended session re-read the grid")
    }

    @Test("Add to trip's banner: N of M added, and the pictures the outbox held back")
    func theAddBanner() {
        #expect(
            Flow.resultText(.init(action: .addToTrip("t1"), asked: 5, changed: 2))
                == "2 of 5 added")
        #expect(
            Flow.resultText(.init(action: .addToTrip("t1"), asked: 3, changed: 2, heldByOutbox: 1))
                == "2 of 3 added — 1 waits for an edit this phone is still sending")
        #expect(
            Flow.resultText(
                .init(action: .addToTrip("t1"), asked: 2, changed: 0, failure: "No tag."))
                == "0 of 2 added. No tag.")
    }

    @Test("a run whose select mode ended while it was out says nothing and reads nothing")
    func anAbandonedRun() async {
        let flow = Flow()
        var rereads = 0
        await flow.perform(reread: { rereads += 1 }) {
            flow.abandon()
            return .finished(.init(action: .visibility(.public), asked: 1, changed: 1))
        }
        #expect(flow.message == nil)
        #expect(rereads == 0)
    }
}
