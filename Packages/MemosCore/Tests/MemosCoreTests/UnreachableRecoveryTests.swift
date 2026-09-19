import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let whoamiOperation = "whoami_api_auth_user_get"
private let recoveryAddress = "memos.example.invalid"
private let recoveryToken = "memos_pat_recovery_secret"

/// The seconds a `Duration` stands for, so a jittered wait can be measured against its band.
private func waitSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// What a store's SUCCESS is allowed to mean.
///
/// It is a request for a check and never a verdict: the only thing that confirms a session is a
/// whoami that answered. A page that arrived proves the server was reachable for the credential
/// that asked, at the instant it asked — which is not the same sentence as "this session is good
/// now", and the difference is a whole outage's worth of wrong state when the two are conflated.
///
/// Every witness here reads the wire: the number of `whoami` requests the stub transport was
/// given. That is the only honest measure of "asked once" — the store's own state cannot
/// distinguish a question from an assumption.
@MainActor
@Suite("A store's success asks the session to check, and never decides for it")
struct UnreachableRecoveryTests {
    private let clock = ManualClock()
    /// The retry ladder's waits, and nothing else.
    private let ladder = ParkingSleeper()
    /// The notice's debounce wake, on the seam of its own that exists so `ladder.waits` is purely
    /// the ladder's rungs.
    private let notice = ParkingSleeper()

    private func makeSession(handler: @escaping StubTransport.Handler) -> SessionStore {
        SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            sleeper: { [ladder] in await ladder.sleep($0) },
            noticeSleeper: { [notice] in await notice.sleep($0) },
            now: { [clock] in clock.now }
        )
    }

    /// Answers whoami as the test scripts it and every list read with an empty page.
    ///
    /// The page is empty on purpose: a success is a success whatever it carried, and rows would
    /// only add a second reason for the apply point to be reached.
    private func handler(
        whoami: @escaping @Sendable () async throws -> (HTTPResponse, HTTPBody?)
    ) -> StubTransport.Handler {
        { _, _, operation in
            guard operation == whoamiOperation else {
                return Stub.json(Stub.memoList([], nextCursor: nil))
            }
            return try await whoami()
        }
    }

    /// Pumps the main actor until a scheduled task has had its turn, or gives up — the bound is
    /// there so that a condition which never comes true is a failure rather than a hung suite.
    private func settle(until condition: () -> Bool, turns: Int = 400) async {
        for _ in 0..<turns where !condition() { await Task.yield() }
    }

    /// Lets the notice's wake run out and waits for the banner it publishes.
    private func raiseTheNotice(on session: SessionStore) async {
        clock.advance(waitSeconds(SessionStore.bannerDelay) + 1)
        await settle(until: { !self.notice.waits.isEmpty })
        notice.releaseAll()
        await settle(until: { session.showsUnreachableNotice })
    }

    // MARK: - the route a success actually takes

    /// The recovery this whole thing is for: the network came back, a list read landed, and the
    /// session is confirmed by the CHECK that read asked for rather than by the read itself.
    @Test("a page that arrived asks the session to check, and the check is what confirms it")
    func aSuccessfulPageAsksForOneCheck() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let whoamis = Counter()
        let session = makeSession(
            handler: handler(whoami: {
                whoamis.increment()
                return Stub.json(Stub.user)
            })
        )
        await session.signIn(serverAddress: recoveryAddress, token: recoveryToken)
        let generation = session.activeHandle!.generation
        session.noteTransportFailure(.offline, issuedUnder: generation)
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
        let beforeThePage = whoamis.count

        let timeline = TimelineStore()
        timeline.reports(to: session)
        await timeline.refresh(using: session.activeHandle!, baseURL: Stub.baseURL)
        await settle(until: { session.verification == .verified })

        #expect(whoamis.count == beforeThePage + 1, "the page asked exactly once")
        #expect(session.verification == .verified, "and the answer, not the page, confirmed it")
        #expect(session.showsUnreachableNotice == false)
        #expect(session.unverifiedSince == nil, "the outage is over, so nothing dates it")
        #expect(timeline.lastError == nil)
        #expect(session.reachabilityRecoveries == 1, "the screens are told the server came back")

        // A second page over a session that is already confirmed is not a recovery: nothing
        // changed, so nothing reloads behind it.
        await timeline.refresh(using: session.activeHandle!, baseURL: Stub.baseURL)
        await settle(until: { session.reachabilityRecoveries > 1 }, turns: 60)
        #expect(session.reachabilityRecoveries == 1, "a confirmed session recovers from nothing")
    }

    // MARK: - a success that is older than the failure after it

    /// A page issued before the network went away lands after it did. It may ask; it may not
    /// answer — and it may not reset the ladder that is already climbing, or a flapping
    /// connection would hold the app at a three-second retry for as long as it flapped.
    @Test("a success older than the failure that followed it asks once and decides nothing")
    func anOlderSuccessAsksOnceAndLeavesTheLadderClimbing() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let whoamis = Counter()
        let session = makeSession(
            handler: handler(whoami: {
                whoamis.increment()
                guard whoamis.count > 1 else { return Stub.json(Stub.user) }
                throw URLError(.timedOut)
            })
        )
        await session.enteredForeground()
        await session.signIn(serverAddress: recoveryAddress, token: recoveryToken)
        let generation = session.activeHandle!.generation
        session.noteTransportFailure(.offline, issuedUnder: generation)
        await raiseTheNotice(on: session)

        // Two rungs of the ladder, each failing: the schedule is at attempt 3 when the stale
        // success arrives. Releasing rung i is what schedules attempt i + 2.
        await settle(until: { self.ladder.waits.count >= 1 })
        ladder.release(0)
        await settle(until: { self.ladder.waits.count >= 2 })
        ladder.release(1)
        await settle(until: { self.ladder.waits.count >= 3 })
        let beforeTheSuccess = whoamis.count
        let rungs = ladder.waits.count

        session.noteTransportSuccess(issuedUnder: generation)
        await settle(until: { self.ladder.waits.count > rungs })

        #expect(whoamis.count == beforeTheSuccess + 1, "one ask for the success, and one only")
        #expect(session.showsUnreachableNotice, "the ask failed, so the sentence stands")
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
        #expect(session.unverifiedSince != nil, "and the outage is still the one it always was")
        guard ladder.waits.count == rungs + 1 else {
            Issue.record("expected one further rung, got \(ladder.waits)")
            return
        }
        // Attempt 3 asked and failed, so the next wait is attempt 4's — the cap, not the first
        // rung. A probe that reset the ladder would record 3 s here.
        let next = waitSeconds(ladder.waits[rungs])
        #expect(
            next >= 45 * 0.8 && next <= 45 * 1.2,
            "the ladder was reset: next wait was \(next) s, not the capped one"
        )
    }

    // MARK: - a success that crosses a replacement

    /// The session that earned the success is gone by the time its task runs, and the one standing
    /// in its place is somebody else's. Nothing of the first one's may be asked on the second's
    /// behalf.
    @Test("a success earned by a replaced session never puts a question on its successor's wire")
    func aSuccessThatCrossesAReplacementAsksNothing() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let whoamis = Counter()
        let session = makeSession(
            handler: handler(whoami: {
                whoamis.increment()
                return Stub.json(Stub.user)
            })
        )
        await session.signIn(serverAddress: recoveryAddress, token: recoveryToken)
        let replaced = session.activeHandle!.generation
        session.noteTransportFailure(.offline, issuedUnder: replaced)

        // Reported while that session is still the live one, so it passes the entry guard — and
        // then a sign-in replaces the session underneath the task it started.
        session.noteTransportSuccess(issuedUnder: replaced)
        await session.signIn(serverAddress: recoveryAddress, token: recoveryToken)
        await settle(until: { whoamis.count > 2 }, turns: 60)

        #expect(session.verification == .verified, "the replacement stands on its own answer")
        #expect(
            session.activeHandle!.generation != replaced,
            "the sign-in minted a new incarnation, which is the whole premise"
        )
        #expect(whoamis.count == 2, "only the two sign-ins asked; the stale success asked nothing")
    }

    /// The same replacement, reported the other way round: the success arrives carrying a
    /// generation that ended while it was in the air. It is refused at the door.
    @Test("a success stamped with an ended generation leaves the live session exactly as it was")
    func aStaleGenerationSuccessIsRefused() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let whoamis = Counter()
        let session = makeSession(
            handler: handler(whoami: {
                whoamis.increment()
                return Stub.json(Stub.user)
            })
        )
        await session.signIn(serverAddress: recoveryAddress, token: recoveryToken)
        let ended = session.activeHandle!.generation
        await session.signIn(serverAddress: recoveryAddress, token: recoveryToken)
        let live = session.activeHandle!.generation
        #expect(live != ended, "the second sign-in is a different incarnation")
        session.noteTransportFailure(.offline, issuedUnder: live)
        await raiseTheNotice(on: session)
        let beforeTheStaleSuccess = whoamis.count

        session.noteTransportSuccess(issuedUnder: ended)
        await settle(until: { whoamis.count > beforeTheStaleSuccess }, turns: 60)

        #expect(whoamis.count == beforeTheStaleSuccess, "an ended session's success asks nothing")
        #expect(session.showsUnreachableNotice, "and the live session's sentence still stands")
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
    }

    /// The same replacement with no gap in it at all: the session is put back under a fresh
    /// incarnation in the very turn the success was reported in, before the check it asked for has
    /// had one.
    ///
    /// A second sign-in over one already running is refused, and the refusal restores the session
    /// it interrupted — the same client, the same credential, the same person — under a NEW
    /// number. So every guard downstream of the report still passes on what it reads: only the
    /// number says the session that earned the success is over. That number is the whole of the
    /// fence here, and without it the outgoing session's page puts a question on the incoming
    /// one's wire.
    ///
    /// Nothing between the report and the replacement leaves the main actor — the presenter
    /// refuses without ever suspending — so the queued check cannot have run before the premise
    /// is asserted below; the order is the language's, not the scheduler's. The only waiting is
    /// after the crossing, and a wait too short to see a question could only hide one: the same
    /// wait, with the fence taken out, sees it.
    @Test("a success whose session is replaced before its check runs asks the successor nothing")
    func aSuccessReplacedInTheSameTurnAsksNothing() async {
        defer {
            ladder.releaseAll()
            notice.releaseAll()
        }
        let whoamis = Counter()
        let session = makeSession(
            handler: handler(whoami: {
                whoamis.increment()
                // Only the sign-in's own question is answered. Anything asked after it fails the
                // way an unreachable server fails, so a question that should not have been asked
                // at all is countable and settles nothing behind the count.
                guard whoamis.count > 1 else { return Stub.json(Stub.user) }
                throw URLError(.timedOut)
            })
        )
        await session.signIn(serverAddress: recoveryAddress, token: recoveryToken)
        let earned = session.activeHandle!.generation
        session.noteTransportFailure(.offline, issuedUnder: earned)
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
        let beforeTheSuccess = whoamis.count

        // One turn of the main actor, and no suspension inside it: the report queues the check,
        // and the refused attempt ends the incarnation it was queued for before it can run.
        session.noteTransportSuccess(issuedUnder: earned)
        await session.signInNatively(
            serverAddress: recoveryAddress,
            deviceName: "iPhone",
            presenter: StubPresenter(behaviour: .failure(.alreadySigningIn))
        )

        // The premise, read before anything queued has had its turn: the crossing happened, and
        // everything the check would go on to read came through it alive.
        guard let live = session.activeHandle else {
            Issue.record("the restored session holds no client, so nothing could be asked of it")
            return
        }
        guard live.generation != earned else {
            Issue.record("no replacement to cross: still generation \(earned)")
            return
        }
        guard whoamis.count == beforeTheSuccess else {
            Issue.record("the check ran before the replacement: \(whoamis.count) asks")
            return
        }
        #expect(session.state.user != nil, "and the restored session still has a person in it")

        await settle(until: { whoamis.count > beforeTheSuccess })

        #expect(
            whoamis.count == beforeTheSuccess,
            "the replaced session's check asked on the incarnation that stood in its place"
        )
        #expect(session.activeHandle?.generation == live.generation, "and left it where it was")
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
    }
}
