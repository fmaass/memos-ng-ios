import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// Select mode's memo actions, from the screen's side (MEMNG-788): the row's wording and what the
/// banner says after a run. The runs themselves are `MemoActionStore`'s, asserted over the wire in
/// MemosCoreTests; here they are handed in as closures, the seam the screens use.
@MainActor
@Suite("Memo action flow")
struct MemoActionFlowTests {
    private typealias Flow = MemoActionFlow

    @Test("the Add to trip row is named so")
    func theWording() {
        #expect(Flow.addRowTitle == "Add to trip")
    }

    @Test("a finished run says N of M and the grid is read again; a refusal says so, no re-read")
    func theBannerAndTheReread() async {
        let flow = Flow()
        let now = Generation()
        let reads = Reads()
        await flow.perform(issuedUnder: 1, current: { now.value }, rereads: [{ reads.one += 1 }]) {
            .finished(.init(action: .visibility(.public), asked: 2, changed: 1))
        }
        #expect(flow.message == "1 of 2 changed")
        #expect(flow.banner.message == "1 of 2 changed")
        #expect(reads.one == 1)

        await flow.perform(issuedUnder: 1, current: { now.value }, rereads: [{ reads.one += 1 }]) {
            .refused
        }
        #expect(flow.banner.message == "Another change is still running")
        #expect(reads.one == 1, "a refused call re-read the grid")

        flow.dismissMessage()
        await flow.perform(issuedUnder: 1, current: { now.value }, rereads: [{ reads.one += 1 }]) {
            .superseded
        }
        #expect(flow.banner.message == nil, "a run of an ended session spoke")
        #expect(reads.one == 1, "a run of an ended session re-read the grid")
    }

    @Test("a run that finished as its session changed says nothing and reads nothing")
    func theSessionMovedAtTheCompletion() async {
        let flow = Flow()
        let now = Generation()
        let reads = Reads()
        // The run returns a FINISHED outcome; the session moved on while it was out.
        await flow.perform(issuedUnder: 1, current: { now.value }, rereads: [{ reads.one += 1 }]) {
            now.value = 2
            return .finished(.init(action: .visibility(.public), asked: 1, changed: 1))
        }
        #expect(flow.banner.message == nil, "a banner spoke for a session that did not run it")
        #expect(reads.one == 0, "the grid was read again under another session")

        now.value = nil
        await flow.perform(issuedUnder: 2, current: { now.value }, rereads: [{ reads.one += 1 }]) {
            .refused
        }
        #expect(flow.banner.message == nil, "a refusal spoke after sign-out")
    }

    @Test("a session that changes between the trip's two reads stops the second")
    func theSessionMovedBetweenTheReads() async {
        let flow = Flow()
        let now = Generation()
        let reads = Reads()
        await flow.perform(
            issuedUnder: 1, current: { now.value },
            rereads: [
                {
                    reads.one += 1
                    now.value = 2
                },
                { reads.two += 1 },
            ]
        ) {
            .finished(.init(action: .visibility(.protected), asked: 1, changed: 1))
        }
        #expect(reads.one == 1)
        #expect(reads.two == 0, "the filtered read went out under another session")
    }

    @Test("the Library's two reads each take the session at issuance, never a newer one")
    func theLibraryReadsAreIssuedUnderTheirSession() async {
        let flow = Flow()
        let now = Generation()
        let wire = Wire()
        let current: LibraryRefresh.Current = {
            now.value.map { (SessionHandle(client: Self.client, generation: $0), Self.base) }
        }
        let list: LibraryRefresh.Read = { handle, _ in wire.list.append(handle.generation) }
        let counts: LibraryRefresh.Read = { handle, _ in wire.counts.append(handle.generation) }
        let changed = MemoActionResult.finished(
            .init(action: .visibility(.public), asked: 1, changed: 1))

        await flow.perform(
            issuedUnder: 1, current: { now.value },
            rereads: [
                {
                    await LibraryRefresh.both(
                        issuedUnder: 1, current: current, list: list, counts: counts)
                }
            ]
        ) { changed }
        #expect(wire.list == [1] && wire.counts == [1], "positive control: both reads went out")

        // The flow has checked the session; it moves before either read begins.
        wire.list = []
        wire.counts = []
        await flow.perform(
            issuedUnder: 1, current: { now.value },
            rereads: [
                {
                    now.value = 2
                    await LibraryRefresh.both(
                        issuedUnder: 1, current: current, list: list, counts: counts)
                }
            ]
        ) { changed }
        #expect(wire.list.isEmpty && wire.counts.isEmpty, "a read went out under another session")

        // It moves as the first read goes out, whichever that is: the other one stays home.
        now.value = 1
        wire.list = []
        wire.counts = []
        await LibraryRefresh.both(
            issuedUnder: 1, current: current,
            list: { handle, _ in
                wire.list.append(handle.generation)
                now.value = 2
            },
            counts: { handle, _ in
                wire.counts.append(handle.generation)
                now.value = 2
            })
        #expect(wire.list + wire.counts == [1], "a read went out under the session after it")
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
        #expect(
            Flow.resultText(
                .init(action: .addToTrip("t1"), asked: 2, changed: 1, heldUnchecked: 1))
                == "1 of 2 added — 1 not added, this phone's outbox can't be read")
    }

    @Test("a run whose select mode closed says nothing, but the grid is still read again")
    func anAbandonedRun() async {
        let flow = Flow()
        let now = Generation()
        let reads = Reads()
        await flow.perform(issuedUnder: 1, current: { now.value }, rereads: [{ reads.one += 1 }]) {
            flow.abandon()
            return .finished(.init(action: .visibility(.public), asked: 1, changed: 1))
        }
        #expect(flow.banner.message == nil, "a closed select mode spoke")
        #expect(reads.one == 1, "a batch that changed memos left the grid unread")

        // Closed AND signed out while it was out: nothing, not even the read.
        await flow.perform(issuedUnder: 1, current: { now.value }, rereads: [{ reads.one += 1 }]) {
            flow.abandon()
            now.value = nil
            return .finished(.init(action: .visibility(.public), asked: 1, changed: 1))
        }
        #expect(reads.one == 1, "the grid was read again under no session")
    }

    @Test("after a delete left a banner, an action's outcome and a refusal are the ones shown")
    func theLatestOutcomeIsShown() async {
        let results = SelectResults()
        func deleteWithAFailure() async {
            results.deleting.claim(.tapped(["p1", "p2"]))
            results.deleting.claim(.confirmed)
            await results.deleting.perform { _ in
                LibraryDeleteOutcome(
                    deleted: ["p1"], failed: nil, notAttempted: ["p2"],
                    stoppedForSessionChange: false)
            }
        }
        await deleteWithAFailure()
        #expect(results.banner.message == "1 deleted, 1 failed", "positive control")

        await results.acting.perform(issuedUnder: 1, current: { 1 }, rereads: []) {
            .finished(.init(action: .addToTrip("t1"), asked: 2, changed: 2))
        }
        #expect(results.banner.message == "2 of 2 added", "the delete's banner hid the outcome")

        await results.acting.perform(issuedUnder: 1, current: { 1 }, rereads: []) { .refused }
        #expect(results.banner.message == "Another change is still running")

        // A later delete is the latest; the action's flow retiring its own leaves it up.
        await deleteWithAFailure()
        results.acting.abandon()
        #expect(results.banner.message == "1 deleted, 1 failed", "retiring one took the other's")

        results.banner.dismiss()
        #expect(results.banner.message == nil)
    }
}

/// The screen's session generation, as `current` reads it; moved by a test.
@MainActor
private final class Generation {
    var value: Int? = 1
}

/// The generation each Library read went out under, in order.
@MainActor
private final class Wire {
    var list: [Int] = []
    var counts: [Int] = []
}

extension MemoActionFlowTests {
    fileprivate static let base = URL(string: "https://memos.example.invalid")!
    fileprivate static let client = MediaViewerPagerFreshURLTests.unusedClient
}

/// How often each re-read was asked for.
@MainActor
private final class Reads {
    var one = 0
    var two = 0
}
