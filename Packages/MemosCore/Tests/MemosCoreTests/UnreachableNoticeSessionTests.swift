import Foundation
import MemosAPI
import Testing

@testable import MemosCore

private let whoamiOperation = "whoami_api_auth_user_get"
private let noticeToken = "memos_pat_notice_secret"
private let noticeAddress = "https://memos.example.invalid"
private let noticeHost = "memos.example.invalid"
/// SHA-256 of the token above, computed OUTSIDE this app (`printf '%s' <token> | sha256sum`), so
/// a launch that admits proves the store's own hasher produced THAT value rather than agreeing
/// with itself.
private let noticeTokenDigest =
    "d2ca82b57c8f95f9079575671be331eb7f4922de9bb3e94be122117b72cd363b"

/// A sleeper that parks every call until the test lets it go.
///
/// Neither existing recorder can hold a wake open: both answer the instant they are called, so a
/// suite built on them can only ever see the state after a delay has run, never during it — and
/// the notice is entirely about what is true DURING one. It also, deliberately, does not observe
/// cancellation: a wake the store has cancelled can then be resumed on purpose, which is the only
/// way to put an obsolete wake in front of the guards that exist to stop it.
final class ParkingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var recorded: [Duration] = []

    /// Every wait asked for, in the order it was asked for. The index into it is what `release`
    /// takes.
    var waits: [Duration] { lock.withLock { recorded } }

    func sleep(_ wait: Duration) async {
        let index: Int = lock.withLock {
            recorded.append(wait)
            return recorded.count - 1
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // A release that arrived while this call was between recording and parking must not be
            // lost: the caller's task and the test run on different turns of the main actor.
            let alreadyReleased: Bool = lock.withLock {
                if released.contains(index) { return true }
                parked[index] = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
    }

    func release(_ index: Int) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            released.insert(index)
            return parked.removeValue(forKey: index)
        }
        continuation?.resume()
    }

    /// Lets go of everything still parked, so a finished test leaves no continuation behind.
    func releaseAll() {
        let all: [CheckedContinuation<Void, Never>] = lock.withLock {
            let waiting = Array(parked.values)
            released.formUnion(parked.keys)
            parked.removeAll()
            return waiting
        }
        for continuation in all { continuation.resume() }
    }
}

/// A clock the test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { instant = start }

    var now: Date { lock.withLock { instant } }

    func advance(_ interval: TimeInterval) { lock.withLock { instant += interval } }
}

/// The "can't reach the server" notice, over the session that decides it.
///
/// Nothing here constructs a store of memos: the notice is raised and lowered by the whoami
/// lifecycle alone, which is the property that makes an offline launch say something without a
/// single list having been asked for.
@MainActor
@Suite("The unreachable notice, over a real session")
struct UnreachableNoticeSessionTests {
    private let clock = ManualClock()

    private func credentials() -> InMemoryCredentials {
        let store = InMemoryCredentials()
        try? store.set(noticeToken, for: SessionStore.tokenAccount)
        try? store.set(noticeAddress, for: SessionStore.serverAccount)
        return store
    }

    private func boundFile() -> StubLastKnownUser {
        StubLastKnownUser(
            LastKnownUser(
                subject: "fabian",
                displayName: "Fabian",
                email: "f@example.invalid",
                role: "admin",
                authKind: "oidc",
                serverBaseURL: noticeAddress,
                credentialFingerprint: noticeTokenDigest
            )
        )
    }

    private func makeSession(
        sleeper: ParkingSleeper,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            sleeper: { await sleeper.sleep($0) },
            // Both seams park in the same recorder, so these witnesses read one ordered script of
            // everything the session waited for, ladder waits and notice wakes alike.
            noticeSleeper: { await sleeper.sleep($0) },
            now: { [clock] in clock.now },
            lastKnownUser: boundFile()
        )
    }

    /// Pumps the main actor until a scheduled task has had its turn, or gives up — the bound is
    /// there so that a condition which never comes true is a failure rather than a hung suite.
    private func settle(until condition: () -> Bool, turns: Int = 400) async {
        for _ in 0..<turns where !condition() { await Task.yield() }
    }

    /// Which of the recorded waits are the notice's own.
    ///
    /// By duration, because that is what tells them apart honestly: the notice waits out at most
    /// `bannerDelay`, and the retry ladder's first wait is 3 s jittered by ±20 %, so nothing it
    /// asks for is ever this short.
    private func noticeWaits(_ sleeper: ParkingSleeper) -> [Int] {
        let waits = sleeper.waits
        return waits.indices.filter { waits[$0] <= SessionStore.bannerDelay }
    }

    // MARK: - the notice goes up, with no store involved

    /// The launch this whole thing is for: a stored credential opens the app, whoami never gets an
    /// answer, and the app waits out the delay before it says so.
    @Test("a launch whose check never arrives says so, but not straight away")
    func aFailedLaunchRaisesTheNoticeAfterTheDelay() async {
        let sleeper = ParkingSleeper()
        defer { sleeper.releaseAll() }
        let session = makeSession(sleeper: sleeper) { _, _, _ in throw URLError(.timedOut) }

        await session.restore()

        guard case .unverified(let sentence) = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
        #expect(sentence.contains(noticeHost), "the sentence names the server it could not reach")
        #expect(session.showsUnreachableNotice == false, "nothing is said inside the window")
        #expect(session.unverifiedSince == clock.now)

        await settle(until: { !self.noticeWaits(sleeper).isEmpty })
        guard let wake = noticeWaits(sleeper).first else {
            Issue.record("no wake was armed for the outage, got \(sleeper.waits)")
            return
        }
        #expect(sleeper.waits[wake] == SessionStore.bannerDelay, "the whole delay was still to run")

        clock.advance(2)
        sleeper.release(wake)
        await settle(until: { session.showsUnreachableNotice })

        #expect(session.showsUnreachableNotice, "the outage outlasted the window")
    }

    // MARK: - the notice does not flash

    /// The drop-out nobody should have to read about: the check fails, the ladder's next attempt
    /// succeeds inside the window, and the wake that was already asleep says nothing when it wakes.
    @Test("a failure answered inside the window is never shown at all")
    func aRecoveryInsideTheWindowShowsNothing() async {
        let sleeper = ParkingSleeper()
        defer { sleeper.releaseAll() }
        let attempts = Counter()
        let session = makeSession(sleeper: sleeper) { _, _, operation in
            guard operation == whoamiOperation else { return Stub.json(Stub.user) }
            attempts.increment()
            if attempts.count == 1 { throw URLError(.timedOut) }
            return Stub.json(Stub.user)
        }
        await session.enteredForeground()

        await session.restore()
        await settle(until: { sleeper.waits.count >= 2 })
        let wake = noticeWaits(sleeper).first
        let ladder = sleeper.waits.indices.first { !self.noticeWaits(sleeper).contains($0) }
        guard let wake, let ladder else {
            Issue.record("expected a notice wake and a ladder wait, got \(sleeper.waits)")
            return
        }

        // Inside the window, the ladder's second attempt lands and the session is confirmed.
        clock.advance(1)
        sleeper.release(ladder)
        await settle(until: { session.verification == .verified })

        #expect(session.verification == .verified)
        #expect(session.showsUnreachableNotice == false)
        #expect(session.unverifiedSince == nil, "the outage is over, so nothing dates it")

        // And the wake that was asleep through all of it publishes nothing on its own account.
        clock.advance(60)
        sleeper.release(wake)
        await settle(until: { session.showsUnreachableNotice }, turns: 40)

        #expect(session.showsUnreachableNotice == false, "a wake outlived the outage it was for")
    }

    // MARK: - recovery through the ladder that already exists

    /// No recovery path of its own: the notice comes down because whoami finally answered, through
    /// the same schedule that was already asking.
    @Test("the notice comes down when the check that raised it finally answers")
    func theLadderTakesTheNoticeDown() async {
        let sleeper = ParkingSleeper()
        defer { sleeper.releaseAll() }
        let attempts = Counter()
        let session = makeSession(sleeper: sleeper) { _, _, operation in
            guard operation == whoamiOperation else { return Stub.json(Stub.user) }
            attempts.increment()
            if attempts.count == 1 { throw URLError(.timedOut) }
            return Stub.json(Stub.user)
        }
        await session.enteredForeground()

        await session.restore()
        await settle(until: { sleeper.waits.count >= 2 })
        let wake = noticeWaits(sleeper).first
        let ladder = sleeper.waits.indices.first { !self.noticeWaits(sleeper).contains($0) }
        guard let wake, let ladder else {
            Issue.record("expected a notice wake and a ladder wait, got \(sleeper.waits)")
            return
        }

        clock.advance(3)
        sleeper.release(wake)
        await settle(until: { session.showsUnreachableNotice })
        #expect(session.showsUnreachableNotice, "the notice is up before the recovery")

        sleeper.release(ladder)
        await settle(until: { session.verification == .verified })

        #expect(session.verification == .verified)
        #expect(session.showsUnreachableNotice == false, "the answer took it down")
        #expect(session.unverifiedSince == nil)
        #expect(session.reachabilityRecoveries == 1, "one recovery, counted for the screens")
    }

    // MARK: - a wake that outlived its outage

    /// Two outages with a confirmation between them. The first outage's wake is released late, on
    /// purpose, while the second one is still inside its window — and it has nothing to say,
    /// because what it was armed for is over and it re-reads the present rather than asserting the
    /// past. The second assignment inside outage two arms nothing new: one outage, one wake.
    @Test("a wake from an earlier outage cannot raise the notice for a later one")
    func aStaleWakeSaysNothing() async {
        let sleeper = ParkingSleeper()
        defer { sleeper.releaseAll() }
        let attempts = Counter()
        let session = makeSession(sleeper: sleeper) { _, _, operation in
            guard operation == whoamiOperation else { return Stub.json(Stub.user) }
            attempts.increment()
            // The first check fails (outage one) and the second confirms; everything from the
            // third on fails again, which is the second assignment inside outage two.
            if attempts.count == 1 || attempts.count >= 3 { throw URLError(.timedOut) }
            return Stub.json(Stub.user)
        }
        await session.enteredForeground()

        await session.restore()
        await settle(until: { sleeper.waits.count >= 2 })
        let first = noticeWaits(sleeper).first
        let ladder = sleeper.waits.indices.first { !self.noticeWaits(sleeper).contains($0) }
        guard let first, let ladder else {
            Issue.record("expected a notice wake and a ladder wait, got \(sleeper.waits)")
            return
        }

        // Outage one ends inside its window, with W1 still parked.
        clock.advance(1)
        sleeper.release(ladder)
        await settle(until: { session.verification == .verified })
        #expect(session.verification == .verified)

        // Outage two begins, reported the way a store reports one.
        let generation = session.activeHandle?.generation
        guard let generation else {
            Issue.record("a confirmed session has no handle")
            return
        }
        session.noteTransportFailure(.timedOut, issuedUnder: generation)
        await settle(until: { self.noticeWaits(sleeper).count >= 2 })
        let second = noticeWaits(sleeper).last
        guard let second, second != first else {
            Issue.record("outage two armed no wake of its own, got \(sleeper.waits)")
            return
        }

        // W1 is let go while outage two is still inside its window. It has nothing to say.
        sleeper.release(first)
        await settle(until: { session.showsUnreachableNotice }, turns: 40)
        #expect(session.showsUnreachableNotice == false, "an old outage's wake spoke for a new one")

        // A further failed check inside outage two assigns `.unverified` again and arms nothing:
        // the wake already asleep owns the outage.
        let ladderTwo = sleeper.waits.indices.last { !self.noticeWaits(sleeper).contains($0) }
        guard let ladderTwo, ladderTwo != ladder else {
            Issue.record("outage two scheduled no retry, got \(sleeper.waits)")
            return
        }
        sleeper.release(ladderTwo)
        await settle(until: { self.noticeWaits(sleeper).count > 2 }, turns: 60)
        #expect(noticeWaits(sleeper).count == 2, "one outage, one wake")

        // And the wake that does own it arrives, once.
        clock.advance(60)
        sleeper.release(second)
        await settle(until: { session.showsUnreachableNotice })
        #expect(session.showsUnreachableNotice)
    }

    // MARK: - signing out is not a recovery

    /// The notice goes away because nobody is signed in any more, and that is a different sentence
    /// from "the server came back". Nothing behind the screen may reload for it: there is no
    /// session left to read anything with.
    @Test("a sign-out takes the notice down without counting a recovery")
    func aSignOutIsNotARecovery() async {
        let sleeper = ParkingSleeper()
        defer { sleeper.releaseAll() }
        let session = makeSession(sleeper: sleeper) { _, _, operation in
            guard operation == whoamiOperation else { return Stub.json(Stub.user) }
            throw URLError(.timedOut)
        }
        await session.enteredForeground()

        await session.restore()
        await settle(until: { sleeper.waits.count >= 2 })
        guard let wake = noticeWaits(sleeper).first else {
            Issue.record("expected a notice wake, got \(sleeper.waits)")
            return
        }
        clock.advance(3)
        sleeper.release(wake)
        await settle(until: { session.showsUnreachableNotice })
        #expect(session.showsUnreachableNotice, "the notice is up before the sign-out")

        await session.signOutWithoutRevoking()

        #expect(session.verification == .verified, "nothing is owed an answer any more")
        #expect(session.showsUnreachableNotice == false, "and nothing says otherwise on screen")
        #expect(session.reachabilityRecoveries == 0, "a sign-out reloads nothing behind it")
    }

    // MARK: - the reader asks again

    /// Two taps on Retry over a check that is already in the air.
    ///
    /// The wire is what is read: a tap is a request for an answer, not for a request. Both taps
    /// are told what the one check said.
    @Test("overlapping retries are one question on the wire, and every caller is told")
    func retriesOverAnInFlightCheckAreOneRequest() async {
        let sleeper = ParkingSleeper()
        /// The whoami itself, held open, so the two later taps arrive while one is unanswered.
        let wire = ParkingSleeper()
        defer {
            sleeper.releaseAll()
            wire.releaseAll()
        }
        let whoamis = Counter()
        let session = makeSession(sleeper: sleeper) { _, _, operation in
            guard operation == whoamiOperation else { return Stub.json(Stub.user) }
            whoamis.increment()
            guard whoamis.count > 1 else { throw URLError(.timedOut) }
            await wire.sleep(.seconds(1))
            return Stub.json(Stub.user)
        }
        await session.enteredForeground()

        await session.restore()
        await settle(until: { sleeper.waits.count >= 2 })

        let first = Task { await session.retryNow() }
        await settle(until: { !wire.waits.isEmpty })
        guard whoamis.count == 2 else {
            Issue.record("the retry sent no check of its own, whoamis: \(whoamis.count)")
            return
        }
        let second = Task { await session.retryNow() }
        let third = Task { await session.retryNow() }
        // Both taps get their turn on the main actor while the first check is still unanswered:
        // whatever they do, they do it against a flight in progress.
        await settle(until: { whoamis.count > 2 }, turns: 60)
        #expect(whoamis.count == 2, "a second tap sent its own question")

        wire.releaseAll()
        await first.value
        await second.value
        await third.value

        #expect(whoamis.count == 2, "three taps, one question")
        #expect(session.verification == .verified, "and every caller waited for its answer")
    }

    /// A tap while the ladder is asleep between rungs. The ladder starts again from its first
    /// rung: somebody is looking at the screen, which is the opposite of the situation the long
    /// waits exist for.
    @Test("a retry over a sleeping ladder puts the next wait back on the first rung")
    func aRetryOverASleepingLadderRestartsIt() async {
        let sleeper = ParkingSleeper()
        defer { sleeper.releaseAll() }
        let whoamis = Counter()
        let session = makeSession(sleeper: sleeper) { _, _, operation in
            guard operation == whoamiOperation else { return Stub.json(Stub.user) }
            whoamis.increment()
            throw URLError(.timedOut)
        }
        await session.enteredForeground()

        await session.restore()
        await settle(until: { sleeper.waits.count >= 2 })
        let notices = noticeWaits(sleeper)
        guard let rungOne = sleeper.waits.indices.first(where: { !notices.contains($0) }) else {
            Issue.record("expected a ladder wait, got \(sleeper.waits)")
            return
        }
        // One rung climbed and failed, so the ladder is asleep on its second wait, 10 s.
        sleeper.release(rungOne)
        await settle(until: { self.ladderWaits(sleeper).count >= 2 })
        let rungs = sleeper.waits.count
        guard ladderWaits(sleeper).count == 2 else {
            Issue.record("expected two rungs, got \(sleeper.waits)")
            return
        }

        await session.retryNow()
        await settle(until: { sleeper.waits.count > rungs })

        guard sleeper.waits.count == rungs + 1, let next = ladderWaits(sleeper).last else {
            Issue.record("expected one further rung, got \(sleeper.waits)")
            return
        }
        // The tap's own check failed, and what it schedules is the FIRST rung, 3 s before jitter —
        // not the 30 s the ladder had climbed to.
        let seconds = Double(next.components.seconds)
            + Double(next.components.attoseconds) / 1e18
        #expect(
            seconds >= 3 * 0.8 && seconds <= 3 * 1.2,
            "the retry carried the ladder's rung: next wait was \(seconds) s, not the first"
        )
    }

    /// The recorded waits that are the ladder's, in order.
    private func ladderWaits(_ sleeper: ParkingSleeper) -> [Duration] {
        let notices = noticeWaits(sleeper)
        return sleeper.waits.indices.filter { !notices.contains($0) }.map { sleeper.waits[$0] }
    }
}
