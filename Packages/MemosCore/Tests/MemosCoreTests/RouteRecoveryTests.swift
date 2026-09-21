import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let whoamiOperation = "whoami_api_auth_user_get"
private let routeAddress = "memos.example.invalid"
private let routeToken = "memos_pat_route_secret"

/// The monitor's two halves, scripted separately.
///
/// That separation is the whole point of the double: the count is what a check reads synchronously
/// as it is ISSUED, and a regain is a delivery that can arrive long afterwards. A loss counted
/// between a request and its answer is not a delivery at all, and no double that folded the two
/// together could stage it.
final class RouteMonitorDouble: RouteStatusMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var losses = 0
    private let events: AsyncStream<RouteRegain>.Continuation
    let regains: AsyncStream<RouteRegain>

    init() {
        var events: AsyncStream<RouteRegain>.Continuation!
        regains = AsyncStream<RouteRegain> { events = $0 }
        self.events = events
    }

    func lossesSeen() -> Int {
        lock.withLock { losses }
    }

    /// A route loss, counted where the monitor counts it — under the lock, delivering nothing.
    @discardableResult
    func countLoss() -> Int {
        lock.withLock {
            losses += 1
            return losses
        }
    }

    /// The regain that closes a counted loss, delivered now.
    func deliverRegain(closing ordinal: Int) {
        events.yield(RouteRegain(lossOrdinal: ordinal))
    }
}

/// What a change of status means, with no framework in the way.
@Suite("Counting route losses and the regains that close them")
struct RouteStatusLedgerTests {
    @Test("a flap down, down, up is one loss and one regain")
    func aFlapIsOneRegain() {
        var ledger = RouteStatusLedger(routed: true)

        #expect(ledger.adopt(satisfied: false) == nil, "a loss is not a regain")
        #expect(ledger.adopt(satisfied: false) == nil, "the same status again is not a change")
        #expect(ledger.losses == 1, "one outage was counted twice")
        #expect(ledger.adopt(satisfied: true) == RouteRegain(lossOrdinal: 1))
    }

    /// The control the case above is worth nothing without: two outages are two regains, each
    /// carrying its own ordinal, and a repeated callback on a route that never moved is neither.
    @Test("up, down, up, down, up is one regain per regain and not one per callback")
    func aRegainPerOutage() {
        var ledger = RouteStatusLedger(routed: true)

        #expect(ledger.adopt(satisfied: true) == nil, "an up on a route that never went down")
        #expect(ledger.adopt(satisfied: false) == nil)
        #expect(ledger.adopt(satisfied: true) == RouteRegain(lossOrdinal: 1))
        #expect(ledger.adopt(satisfied: false) == nil)
        #expect(ledger.adopt(satisfied: true) == RouteRegain(lossOrdinal: 2))
        #expect(ledger.losses == 2)
    }

    /// The path this process STARTED on. Nothing was lost, so there is nothing to give back.
    @Test("the first satisfied path a process ever sees is a baseline and not a regain")
    func theInitialPathIsNotARegain() {
        var ledger = RouteStatusLedger(routed: false)

        #expect(ledger.adopt(satisfied: true) == nil)
        #expect(ledger.losses == 0)
    }
}

/// One trigger, one path, ONE read of the list and ONE recovery per regained route — in every
/// order the events can reach the session in.
///
/// Every witness counts what went out on the WIRE through the stub transport: the verification
/// requests and the page reads. The screens' half of the path is `reloadsOnRecovery`, which
/// performs once per CHANGE of the counter (`ReloadsOnRecoveryTests` holds the modifier to exactly
/// that); `reloadsOwed` below is that contract, driving the real store against the real transport.
@MainActor
@Suite("A regained route asks for one recovery, whatever order the events arrive in")
struct RouteRecoveryTests {
    private let clock = ManualClock()
    private let ladder = ParkingSleeper()
    private let notice = ParkingSleeper()
    private let routes = RouteMonitorDouble()
    private let whoamis = Counter()
    private let pages = Counter()

    /// `countingALossOnWhoami` is the one seam a single case needs: the whoami of that number
    /// counts a route loss as it ANSWERS, which is the only way to stage a loss falling between a
    /// check being issued and its confirmation being recorded.
    private func makeSession(countingALossOnWhoami: Int? = nil) -> SessionStore {
        SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { [whoamis, pages, routes] _, token in
                Stub.client(token: token) { _, _, operation in
                    guard operation == whoamiOperation else {
                        pages.increment()
                        return Stub.json(Stub.memoList([], nextCursor: nil))
                    }
                    whoamis.increment()
                    if whoamis.count == countingALossOnWhoami { routes.countLoss() }
                    return Stub.json(Stub.user)
                }
            },
            sleeper: { [ladder] in await ladder.sleep($0) },
            noticeSleeper: { [notice] in await notice.sleep($0) },
            now: { [clock] in clock.now },
            routes: routes
        )
    }

    /// Pumps the main actor until a scheduled task has had its turn, or gives up — a condition
    /// that never comes true is a failure rather than a hung suite.
    private func settle(until condition: () -> Bool, turns: Int = 400) async {
        for _ in 0..<turns where !condition() { await Task.yield() }
    }

    private func signedIn(countingALossOnWhoami: Int? = nil) async -> SessionStore {
        let session = makeSession(countingALossOnWhoami: countingALossOnWhoami)
        await session.enteredForeground()
        await session.signIn(serverAddress: routeAddress, token: routeToken)
        return session
    }

    private func timeline(reporting session: SessionStore) -> TimelineStore {
        let timeline = TimelineStore()
        timeline.reports(to: session)
        return timeline
    }

    /// The reload each recovery owes, exactly as the screens perform it: once per CHANGE of the
    /// counter, on the real store and the real wire.
    private func reloadsOwed(
        _ session: SessionStore,
        _ timeline: TimelineStore,
        seen: inout Int
    ) async {
        while session.reachabilityRecoveries > seen {
            seen += 1
            await timeline.refresh(using: session.activeHandle!, baseURL: Stub.baseURL)
        }
    }

    /// Takes the session out of confirmation the way a failed request does, and returns the
    /// counters as they stood before the case began.
    private func unconfirm(_ session: SessionStore) -> (whoamis: Int, pages: Int) {
        session.noteTransportFailure(.offline, issuedUnder: session.activeHandle!.generation)
        return (whoamis.count, pages.count)
    }

    // MARK: - (a) and (b): the two states a regain can arrive in

    @Test("a regain while the session awaits confirmation asks once and reads the list once")
    func aRegainWhileAwaitingConfirmation() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let session = await signedIn()
        let list = timeline(reporting: session)
        let before = unconfirm(session)
        var reloaded = 0
        let ordinal = routes.countLoss()

        routes.deliverRegain(closing: ordinal)
        await settle(until: { session.verification == .verified })
        await reloadsOwed(session, list, seen: &reloaded)

        #expect(whoamis.count == before.whoamis + 1, "the regain asked more than once")
        #expect(pages.count == before.pages + 1, "the recovery read the list more than once")
        #expect(session.reachabilityRecoveries == 1)

        // The rung the ladder was asleep on has nothing left to ask: releasing it asks nothing.
        ladder.releaseAll()
        await settle(until: { self.whoamis.count > before.whoamis + 1 }, turns: 60)
        #expect(whoamis.count == before.whoamis + 1, "the ladder's sleeper was left to fire")
    }

    @Test("a regain while the session is confirmed reads the list once and asks nothing")
    func aRegainWhileVerified() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let session = await signedIn()
        let list = timeline(reporting: session)
        let whoamisBefore = whoamis.count
        let pagesBefore = pages.count
        var reloaded = 0
        let ordinal = routes.countLoss()

        routes.deliverRegain(closing: ordinal)
        await settle(until: { session.reachabilityRecoveries == 1 })
        await reloadsOwed(session, list, seen: &reloaded)

        #expect(whoamis.count == whoamisBefore, "a confirmed session was asked to confirm again")
        #expect(pages.count == pagesBefore + 1)

        // Invariant #1, and the store REFUSES rather than joins: a read arriving while one is out
        // is the same lineage, and the lineage gate drops it.
        let duringARead = pages.count
        let overlapping = Task { @MainActor in
            await list.refresh(using: session.activeHandle!, baseURL: Stub.baseURL)
        }
        await list.refresh(using: session.activeHandle!, baseURL: Stub.baseURL)
        await overlapping.value
        #expect(pages.count == duringARead + 1, "two overlapping reads went on the wire")
    }

    // MARK: - (c), (d) and (f): a regain that arrives after its own recovery

    @Test("a ladder check that confirms before the regain is delivered leaves it a no-op")
    func aLateRegainAfterTheLadderConfirmed() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let session = await signedIn()
        let list = timeline(reporting: session)
        let before = unconfirm(session)
        var reloaded = 0
        let ordinal = routes.countLoss()

        // The rung was issued AFTER the loss was counted, so its confirmation carries that
        // ordinal — and the regain that arrives later closes an outage already recovered from.
        await settle(until: { !self.ladder.waits.isEmpty })
        ladder.release(0)
        await settle(until: { session.verification == .verified })
        await reloadsOwed(session, list, seen: &reloaded)
        routes.deliverRegain(closing: ordinal)
        await settle(until: { session.reachabilityRecoveries > 1 }, turns: 60)
        await reloadsOwed(session, list, seen: &reloaded)

        #expect(session.reachabilityRecoveries == 1, "the same outage recovered twice")
        #expect(whoamis.count == before.whoamis + 1)
        #expect(pages.count == before.pages + 1, "the list was read twice for one outage")
    }

    @Test("a check issued after the loss and confirmed before the regain leaves it a no-op")
    func aLateRegainAfterAnAskedForCheckConfirmed() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let session = await signedIn()
        let list = timeline(reporting: session)
        let before = unconfirm(session)
        var reloaded = 0
        let ordinal = routes.countLoss()

        await session.retryNow()
        await settle(until: { session.verification == .verified })
        await reloadsOwed(session, list, seen: &reloaded)
        routes.deliverRegain(closing: ordinal)
        await settle(until: { session.reachabilityRecoveries > 1 }, turns: 60)
        await reloadsOwed(session, list, seen: &reloaded)

        #expect(session.reachabilityRecoveries == 1, "the same outage recovered twice")
        #expect(pages.count == before.pages + 1)
    }

    @Test("two outages with a confirmation between them recover once each, however late")
    func twoOutagesWithAConfirmationBetweenThem() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let session = await signedIn()
        let list = timeline(reporting: session)
        let before = unconfirm(session)
        var reloaded = 0
        let first = routes.countLoss()

        await session.retryNow()
        await settle(until: { session.verification == .verified })
        await reloadsOwed(session, list, seen: &reloaded)
        let second = routes.countLoss()

        routes.deliverRegain(closing: first)
        await settle(until: { session.reachabilityRecoveries > 1 }, turns: 60)
        #expect(
            session.reachabilityRecoveries == 1,
            "the outage that had already recovered recovered again"
        )

        routes.deliverRegain(closing: second)
        await settle(until: { session.reachabilityRecoveries == 2 })
        await reloadsOwed(session, list, seen: &reloaded)

        #expect(pages.count == before.pages + 2, "one read per outage, and no more")
    }

    // MARK: - (e): an unmatched regain

    @Test("a regain whose outage has already recovered changes nothing at all")
    func anUnmatchedRegainIsNothing() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let session = await signedIn()
        let list = timeline(reporting: session)
        let whoamisBefore = whoamis.count
        let pagesBefore = pages.count
        var reloaded = 0
        let ordinal = routes.countLoss()

        routes.deliverRegain(closing: ordinal)
        await settle(until: { session.reachabilityRecoveries == 1 })
        await reloadsOwed(session, list, seen: &reloaded)

        routes.deliverRegain(closing: ordinal)
        await settle(until: { session.reachabilityRecoveries > 1 }, turns: 60)
        await reloadsOwed(session, list, seen: &reloaded)

        #expect(session.reachabilityRecoveries == 1, "one outage, counted twice")
        #expect(pages.count == pagesBefore + 1, "one outage, read twice")
        #expect(whoamis.count == whoamisBefore)
    }

    // MARK: - (g) and (h): what a confirmation may and may not record

    /// A loss counted after the check was issued and before its confirmation is recorded belongs
    /// to the outage AFTER that check. Recording the count at the confirmation instead would
    /// silence the regain that closes it.
    @Test("a loss counted inside a check still owes its own recovery")
    func aLossCountedInsideACheckStillOwesARecovery() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        // The second whoami is the one this case asks for: the first belongs to the sign-in.
        let session = await signedIn(countingALossOnWhoami: 2)
        let list = timeline(reporting: session)
        let before = unconfirm(session)
        var reloaded = 0

        await session.retryNow()
        await settle(until: { session.verification == .verified })
        await reloadsOwed(session, list, seen: &reloaded)
        #expect(routes.lossesSeen() == 1, "precondition: the check counted a loss as it answered")

        routes.deliverRegain(closing: 1)
        await settle(until: { session.reachabilityRecoveries == 2 })
        await reloadsOwed(session, list, seen: &reloaded)

        #expect(session.reachabilityRecoveries == 2, "the regain closed nothing")
        #expect(pages.count == before.pages + 2)
    }

    /// A confirmation that incremented NOTHING requested no reload, so it cannot stand in for one:
    /// the regain is still owed its recovery.
    @Test("a check that confirms an already-confirmed session leaves the regain its recovery")
    func aConfirmationThatIncrementedNothingRecordsNothing() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let session = await signedIn()
        let list = timeline(reporting: session)
        let pagesBefore = pages.count
        var reloaded = 0
        let ordinal = routes.countLoss()

        // Confirmed already, so this asks, succeeds, and increments nothing.
        await session.retryNow()
        await settle(until: { self.whoamis.count > 1 })
        #expect(session.reachabilityRecoveries == 0, "precondition: nothing was recovered from")

        routes.deliverRegain(closing: ordinal)
        await settle(until: { session.reachabilityRecoveries == 1 })
        await reloadsOwed(session, list, seen: &reloaded)

        #expect(session.reachabilityRecoveries == 1, "the regain recovered nothing")
        #expect(pages.count == pagesBefore + 1)
    }
}
