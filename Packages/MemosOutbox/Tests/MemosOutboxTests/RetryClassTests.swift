import Foundation
import MemosOutbox
import Testing

/// The three retry classes (MEMNG-955), one test each, plus the bound that keeps every timed wait
/// short and the memo-create replay MEMNG-656 asked for.
///
/// Driven through the real engine and the real completion endpoint over a scripted server, so the
/// class a failure lands in is read back from the manifest the engine wrote, not from a helper.
@Suite("Retry classes")
struct RetryClassTests {
    /// A server that refuses the upload session with `status` (and `Retry-After`, if given).
    private static func refusingSessions(status: Int, retryAfter: String?) -> ScriptedHTTP {
        ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/uploads"):
                var headers: [String: String] = [:]
                if let retryAfter { headers["Retry-After"] = retryAfter }
                return OutboxHTTPResponse(statusCode: status, headers: headers)
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
    }

    // MARK: - transient

    @Test("transient: a 503 with Retry-After: 7 schedules the retry at 7 s, and says it retries")
    func transientHonoursRetryAfter() async throws {
        let harness = try await Harness.make(
            http: Self.refusingSessions(status: 503, retryAfter: "7"))
        defer { harness.cleanUp() }

        await harness.engine.drain()

        let saved = try #require(await harness.reload())
        #expect(saved.state == .waiting)
        #expect(saved.waitReason == .retrying)
        #expect(saved.waitReason?.retryClass == .transient)
        let delay = saved.nextAttemptAt.timeIntervalSince(harness.now)
        #expect(abs(delay - 7) <= 1, "scheduled \(delay) s out, not the 7 s the server asked for")
    }

    @Test("transient: without Retry-After the first retry is 2 s out, not minutes")
    func transientWithoutRetryAfterUsesTheCurve() async throws {
        let harness = try await Harness.make(
            http: Self.refusingSessions(status: 503, retryAfter: nil))
        defer { harness.cleanUp() }

        await harness.engine.drain()

        let saved = try #require(await harness.reload())
        #expect(saved.nextAttemptAt == harness.now.addingTimeInterval(2))
    }

    // MARK: - connectivity

    @MainActor
    @Test("connectivity: a lost path schedules nothing, and its return resumes within 1 s")
    func connectivityWaitsForThePath() async throws {
        let root = try Fixture.temporaryDirectory()
        let preferences = Fixture.preferences()
        defer {
            try? FileManager.default.removeItem(at: root)
            Fixture.forgetting(preferences.name)
        }
        let credentials = StaticCredentials(credentials: Fixture.credentials())
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { credentials.stillCurrent(epoch: $0) }
        )
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 400)
        let job = try await repository.enqueue(
            content: "offline",
            visibility: nil,
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            binding: Fixture.binding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        )
        let scheduler = ScriptedScheduler()
        let http = ScriptedHTTP.standard(chunkSize: 400)
        let network = StubNetworkPath(.offline)
        let outbox = Outbox(
            repository: repository,
            credentials: credentials,
            http: http,
            scheduler: scheduler,
            completion: ScriptedCompletion([.retry("not now")], repeating: .retry("not now")),
            network: network,
            preferences: preferences.store
        )

        await outbox.start()

        let waiting = try #require(await repository.job(job.id))
        #expect(http.requests.isEmpty, "no path: not even the probe goes out")
        #expect(scheduler.uploads.isEmpty)
        #expect(waiting.state == .waiting)
        #expect(waiting.waitReason == .noNetwork)
        #expect(waiting.waitReason?.retryClass == .connectivity)
        // No timer: nothing was counted and the next attempt is exactly where enqueue put it.
        #expect(waiting.attemptCount == 0)
        #expect(waiting.nextAttemptAt == job.nextAttemptAt)

        let returned = ContinuousClock.now
        await network.move(to: .wifi)
        let elapsed = ContinuousClock.now - returned

        #expect(scheduler.uploads.count == 1, "the path event alone resumed it")
        #expect(elapsed < .seconds(1), "resumed after \(elapsed)")
        let sending = try #require(await repository.job(job.id))
        #expect(sending.waitReason != .noNetwork)
    }

    @Test("connectivity: a video over 200 MB on mobile data waits for Wi-Fi, a photo does not")
    func aLargeVideoWaitsForWiFi() {
        let policy = UploadNetworkPolicy(allowsMobileData: true)
        let video = OutboxFile(
            relativePath: "v.mov", filename: "v.mov", mime: "video/quicktime",
            byteSize: UploadNetworkPolicy.mobileVideoLimit + 1
        )
        let small = OutboxFile(
            relativePath: "s.mov", filename: "s.mov", mime: "video/quicktime",
            byteSize: UploadNetworkPolicy.mobileVideoLimit
        )
        let large = Fixture.job(files: [video])
        #expect(policy.waitReason(on: .cellular, for: large) == .videoOverMobileLimit)
        #expect(policy.waitReason(on: .wifi, for: large) == nil)
        #expect(policy.waitReason(on: .cellular, for: Fixture.job(files: [small])) == nil)
        #expect(policy.waitReason(on: .offline, for: large) == .noNetwork)
        #expect(
            UploadNetworkPolicy(allowsMobileData: false).waitReason(on: .cellular, for: large)
                == .homeNetwork)
    }

    // MARK: - hold

    @Test("hold: a 413 holds with reason tooLarge and fixAction remove, on no timer")
    func holdOnTooLarge() async throws {
        let harness = try await Harness.make(
            http: Self.refusingSessions(status: 413, retryAfter: nil))
        defer { harness.cleanUp() }

        await harness.engine.drain()
        await harness.engine.drain()

        let held = try #require(await harness.reload())
        #expect(held.state == .held)
        #expect(held.holdReason == .tooLarge)
        #expect(held.holdReason?.fixAction == .remove)
        #expect(held.holdReason?.retryClass == .hold)
        #expect(harness.http.requests(method: "POST").count == 1, "held means no second try")
        // No timer: however far the clock runs, the planner still says hold.
        let far = harness.now.addingTimeInterval(365 * 86_400)
        #expect(
            OutboxPlanner.nextAction(for: held, credentials: Fixture.credentials(), now: far)
                == .hold(.tooLarge))
    }

    // MARK: - the bound

    /// No timed wait the planner hands out is unbounded: for every failure count, a job that just
    /// backed off is actionable again no later than `RetrySchedule.cap` after the failure. A
    /// curve that grows past the cap — the old six-hour one, or one with no cap at all — leaves a
    /// capture waiting longer than any transient failure deserves, and fails here.
    @Test("every transient wait ends within a minute of the failure, at every attempt count")
    func everyTransientWaitIsBounded() {
        let failedAt = Date(timeIntervalSince1970: 1_750_000_000)
        var job = Fixture.job(files: [Fixture.file()])
        let credentials = Fixture.credentials()
        for attempt in 1...200 {
            job = job.backingOff(at: failedAt, error: "socket dropped")
            #expect(job.attemptCount == attempt)
            let waited = job.nextAttemptAt.timeIntervalSince(failedAt)
            #expect(waited > 0 && waited <= 60, "attempt \(attempt) waits \(waited) s")
            let after = failedAt.addingTimeInterval(60)
            if case .wait = OutboxPlanner.nextAction(
                for: job, credentials: credentials, now: after)
            {
                Issue.record("attempt \(attempt) is still waiting a minute after it failed")
            }
        }
        #expect(RetrySchedule.delay(forAttempt: Int.max) <= RetrySchedule.cap)
    }

    // MARK: - MEMNG-656

    @Test("a 5xx on the memo create is retried once within 5 s, under the same idempotency key")
    func aServerErrorOnCreateRetriesWithinSeconds() async throws {
        let attempts = Counter()
        let http = ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/memos"):
                attempts.increment()
                if attempts.count == 1 { return OutboxHTTPResponse(statusCode: 502) }
                return OutboxHTTPResponse(statusCode: 201, body: Data(#"{"uid":"m1"}"#.utf8))
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
        // No `completion:` — the real endpoint, so the 5xx is classified where it is in the app.
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }

        await harness.engine.drain()

        let waiting = try #require(await harness.reload())
        #expect(waiting.waitReason == .retrying)
        let delay = waiting.nextAttemptAt.timeIntervalSince(harness.now)
        #expect(delay > 0 && delay <= 5, "the retry is \(delay) s out")

        harness.clock.advance(delay)
        await harness.engine.drain()

        let posts = harness.http.requests(method: "POST")
        #expect(posts.count == 2, "exactly one retry")
        #expect(posts.count == 2 && posts[0].httpBody == posts[1].httpBody, "same body, same key")
        let key = harness.job.idempotencyKey.uuidString
        let bodies = posts.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        #expect(bodies.allSatisfy { $0.contains(key) })
        #expect(await harness.reload() == nil, "the replay resolved the capture")
    }
}

/// The retry-class edges MEMNG-1035 closed, through the real engine over a scripted server.
@Suite("Retry classes: the edges")
struct RetryClassEdgeTests {
    private static func eventually(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// A server whose memo create answers `create` for every POST; `/health` is fine.
    private static func creating(
        _ create: @escaping @Sendable (Int) -> OutboxHTTPResponse
    ) -> (ScriptedHTTP, Counter) {
        let posts = Counter()
        let http = ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/memos"):
                posts.increment()
                return create(posts.count)
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
        return (http, posts)
    }

    private static let created = OutboxHTTPResponse(
        statusCode: 201, body: Data(#"{"uid":"m1"}"#.utf8))

    // MARK: - item 1: Retry-After 0

    @Test("a server-named delay under the floor waits the floor; one at or over it is kept")
    func retryAfterFloor() {
        let now = Date(timeIntervalSince1970: 1000)
        let floor = UploadBudget.shortestRetryAfter
        #expect(floor > 1, "a whole-second manifest can put now + 1 back on now")
        for asked in [0.0, 1.0] {
            #expect(
                RetrySchedule.nextAttempt(afterFailure: 1, from: now, retryAfter: asked)
                    == now.addingTimeInterval(floor))
            #expect(RetrySchedule.delay(forAttempt: 1, retryAfter: asked, rng: { 0 }) == floor)
        }
        for asked in [floor, 7] {
            #expect(
                RetrySchedule.nextAttempt(afterFailure: 1, from: now, retryAfter: asked)
                    == now.addingTimeInterval(asked))
            #expect(RetrySchedule.delay(forAttempt: 1, retryAfter: asked, rng: { 0 }) == asked)
        }
    }

    @Test("a create answered 503 with Retry-After: 0 is sent again by the timer, no drain asked")
    func createRetryAfterZeroIsWokenByTheTimer() async throws {
        let (http, posts) = Self.creating { count in
            count == 1
                ? OutboxHTTPResponse(statusCode: 503, headers: ["Retry-After": "0"])
                : Self.created
        }
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }

        await harness.engine.drain()

        let waiting = try #require(await harness.reload())
        #expect(waiting.waitReason == .retrying)
        let deadline = try #require(harness.sleeper.armed.first, "nothing armed: no wake")
        #expect(deadline == harness.now.addingTimeInterval(UploadBudget.shortestRetryAfter))
        #expect(posts.count == 1)

        harness.clock.advance(UploadBudget.shortestRetryAfter)
        harness.sleeper.advance(to: harness.clock.now)

        #expect(try await Self.eventually { await harness.reload() == nil })
        #expect(posts.count == 2)
    }

    // MARK: - items 5 and 7: the create's 413 and 409

    @Test("a create answered 413 under the current grant holds tooLarge, with no second POST")
    func createTooLargeHolds() async throws {
        let (http, posts) = Self.creating { _ in OutboxHTTPResponse(statusCode: 413) }
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }

        await harness.engine.drain()
        await harness.engine.drain()

        let held = try #require(await harness.reload())
        #expect(held.state == .held)
        #expect(held.holdReason == .tooLarge)
        #expect(posts.count == 1, "held means no second try")
    }

    @Test(
        "a create refused under a grant replaced in flight holds by its status, not a back-off",
        arguments: [(413, HoldReason.tooLarge), (409, HoldReason.serverRefused)]
    )
    func createRefusalUnderAReplacedGrantHolds(status: Int, reason: HoldReason) async throws {
        let switched = CredentialsBox()
        let (http, posts) = Self.creating { _ in
            switched.value?.supersede()
            return OutboxHTTPResponse(statusCode: status)
        }
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }
        switched.value = harness.credentials

        await harness.engine.drain()
        await harness.engine.drain()

        let held = try #require(await harness.reload())
        #expect(held.state == .held, "a \(status) is not the credential's to space out")
        #expect(held.holdReason == reason)
        #expect(posts.count == 1)
    }

    // MARK: - item 7: a chunk row waiting on the network

    @Test("a chunk-lane row waiting on the network arms no timer, its deadline still ahead")
    func chunkConnectivityWaitArmsNothing() async throws {
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(chunkSize: 400), network: StubNetworkPath(.cellular),
            allowsMobileData: false)
        defer { harness.cleanUp() }
        // Backing off when the phone left the wifi: its deadline is still ahead, so only the wait
        // reason keeps it off the timer.
        let ahead = harness.now.addingTimeInterval(30)
        var backingOff = harness.job
        backingOff.state = .waiting
        backingOff.waitReason = .retrying
        backingOff.nextAttemptAt = ahead
        try await harness.repository.save(backingOff)

        await harness.engine.drain()

        let saved = try #require(await harness.reload())
        #expect(saved.lane == .chunk)
        #expect(saved.waitReason == .homeNetwork)
        #expect(saved.nextAttemptAt == ahead)
        #expect(harness.sleeper.history.isEmpty, "armed \(harness.sleeper.history)")
    }

    // MARK: - item 8: a sign-in releases signInRequired

    @Test("a sign-in releases a signInRequired hold; another account's capture stays held")
    func signInReleasesTheHold() async throws {
        let (http, posts) = Self.creating { count in
            count == 1 ? OutboxHTTPResponse(statusCode: 401) : Self.created
        }
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }
        await harness.engine.drain()
        #expect(await harness.reload()?.holdReason == .signInRequired)
        let other = try await harness.repository.enqueue(
            content: "someone else's memo", visibility: "PRIVATE", capturedAt: harness.now,
            binding: Fixture.binding(owner: "someone-else"), sources: [])
        try await harness.repository.save(other.held(.signInRequired))

        // Signed in again as the same account: the session's epoch moved.
        harness.credentials.supersede()
        await harness.engine.drain()

        #expect(await harness.reload() == nil, "released and sent")
        #expect(posts.count == 2)
        #expect(await harness.repository.job(other.id)?.state == .held)
        let bodies = harness.http.requests(method: "POST").map {
            String(decoding: $0.httpBody ?? Data(), as: UTF8.self)
        }
        #expect(!bodies.contains { $0.contains("someone else") })
    }

    @Test("a plain foreground under the same grant releases nothing")
    func sameGrantReleasesNothing() async throws {
        let (http, posts) = Self.creating { count in
            count == 1 ? OutboxHTTPResponse(statusCode: 401) : Self.created
        }
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }
        await harness.engine.drain()

        await harness.engine.drain()
        await harness.engine.drain()

        #expect(await harness.reload()?.holdReason == .signInRequired)
        #expect(posts.count == 1)
    }

    @Test("a hold an earlier launch left is released once by this launch's first drain")
    func earlierLaunchHoldReleasedOnce() async throws {
        let (http, posts) = Self.creating { _ in OutboxHTTPResponse(statusCode: 401) }
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }
        try await harness.repository.save(harness.job.held(.signInRequired))

        await harness.engine.drain()
        await harness.engine.drain()

        #expect(posts.count == 1, "one release, one answer, held again")
        #expect(await harness.reload()?.holdReason == .signInRequired)
    }

    @Test("two drains racing a sign-in release each hold once; a hold earned again stays")
    func racingDrainsReleaseOnce() async throws {
        let (http, posts) = Self.creating { _ in OutboxHTTPResponse(statusCode: 401) }
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }
        await harness.engine.drain()
        harness.credentials.supersede()

        async let first: Void = harness.engine.drain()
        async let second: Void = harness.engine.drain()
        _ = await (first, second)
        await harness.engine.untilQuiescent()

        #expect(posts.count == 2)
        #expect(await harness.reload()?.holdReason == .signInRequired)
    }

    @Test("a guest capture's signInRequired is not released by an epoch move")
    func guestHoldIsNotReleased() async throws {
        let guest = OutboxCredentials(
            serverBaseURL: Fixture.server, ownerSubject: "device-1", token: "guest-token",
            kind: .guest)
        // A guest capture always carries a file: the guest door has no text-only memo.
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(), credentials: guest,
            binding: AccountBinding(
                serverBaseURL: Fixture.server, ownerSubject: "device-1", kind: .guest))
        defer { harness.cleanUp() }
        try await harness.repository.save(harness.job.held(.signInRequired))
        harness.credentials.supersede()

        await harness.engine.drain()

        let held = try #require(await harness.reload())
        #expect(held.state == .held)
        #expect(held.holdReason == .signInRequired)
    }

    @Test("a queue that could not be read leaves the sign-in release owed to the next drain")
    func unreadableQueueKeepsTheReleaseOwed() async throws {
        let (http, posts) = Self.creating { count in
            count == 1 ? OutboxHTTPResponse(statusCode: 401) : Self.created
        }
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }
        await harness.engine.drain()
        harness.credentials.supersede()

        let restore = try Fixture.permissions(
            0, on: harness.root.appending(path: "outbox").appending(path: "jobs"))
        await harness.engine.drain()
        restore()
        #expect(posts.count == 1)

        await harness.engine.drain()

        #expect(posts.count == 2, "the release was owed, not spent on a list nobody read")
        #expect(await harness.reload() == nil)
    }
}
