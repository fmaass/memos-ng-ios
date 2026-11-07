import Foundation
@testable import MemosOutbox
import Testing

/// The share extension's per-capture sessions: the registry the two processes write, the app's
/// attach-once and reconciliation, and the extension's start lane.
@Suite("Share sessions")
struct ShareSessionTests {
    private static func repository(_ root: URL) throws -> OutboxRepository {
        try OutboxRepository(root: root.appending(path: "outbox"))
    }

    private static func enqueue(_ repository: OutboxRepository, in root: URL, files: Int)
        async throws -> UploadJob
    {
        let sources = try (0..<files).map { index in
            StagedSource(
                url: try Fixture.file(in: root, named: "p\(index).jpg", bytes: 64),
                filename: "p\(index).jpg", mime: "image/jpeg")
        }
        return try await repository.enqueue(
            content: "shared", visibility: "PRIVATE", capturedAt: Date(),
            binding: Fixture.binding(), sources: sources)
    }

    // MARK: - registry

    @Test("a registry write waits for the lease: refused while another holder has it")
    func registryWriteTakesTheLease() throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = SessionRegistry(root: root)
        let entry = SessionRegistryEntry(jobID: UUID())
        let other = OutboxLock(url: root.appending(path: "sessions.lock"))
        guard case .leased(let lease) = other.acquire(.exclusive) else {
            Issue.record("the stand-in holder could not take the lease")
            return
        }
        #expect(throws: SessionRegistryFailure.locked(.contended)) {
            try registry.register(entry)
        }
        #expect(registry.entries().isEmpty)
        lease.release()
        try registry.register(entry)
        #expect(registry.entries() == [entry])
    }

    @Test("concurrent registrations in one process are serialized and none is lost")
    func concurrentRegistrationsAllLand() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = SessionRegistry(root: root)
        let entries = (0..<24).map { _ in SessionRegistryEntry(jobID: UUID()) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { try registry.register(entry) }
            }
            try await group.waitForAll()
        }
        #expect(Set(registry.entries()) == Set(entries))
    }

    // MARK: - the app's wake

    @Test("an entry whose job manifest is withdrawn is retired without a request")
    func withdrawnEntryRetiredWithoutRequest() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        let registry = SessionRegistry(root: root)
        let jobID = UUID()
        let entry = SessionRegistryEntry(jobID: jobID)
        try registry.register(entry)
        let identity = WholeTaskIdentity(
            jobID: jobID, fileID: UUID(), attempt: 0, launch: UUID(), epoch: 0)
        let session = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(taskIdentifier: 7, taskDescription: identity.taskDescription)
        ])
        let http = ScriptedHTTP { _ in OutboxHTTPResponse(statusCode: 500) }
        let sessions = ShareSessions(registry: registry) { _ in session }
        let verdicts = await sessions.wake(repository: repository)
        #expect(verdicts == [entry.identifier: .retired])
        #expect(registry.entries().isEmpty)
        #expect(session.createdTasks.isEmpty)
        #expect(session.cancelledIdentifiers == [7])
        #expect(http.requests.isEmpty)
    }

    @Test("a live task keeps its session registered; once it ended the session is retired")
    func liveTaskKeepsEntryEndedTaskRetires() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        let queued = try await Self.enqueue(repository, in: root, files: 1)
        let file = try #require(queued.files.first)
        let sent = queued.with { $0.transport = .whole }
            .startingUpload(
                fileID: file.id,
                session: try #require(
                    OutboxWire.decodeSession(
                        ScriptedHTTP.session(uid: "u1", chunkSize: 64, received: 0).body)))
        try await repository.save(sent)
        let registry = SessionRegistry(root: root)
        let entry = SessionRegistryEntry(jobID: queued.id)
        try registry.register(entry)
        let description = WholeTaskIdentity(
            jobID: queued.id, fileID: file.id, attempt: 0, launch: UUID(), epoch: 0
        ).taskDescription
        let running = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(taskIdentifier: 3, taskDescription: description)
        ])
        let kept = await ShareSessions(registry: registry) { _ in running }
            .wake(repository: repository)
        #expect(kept == [entry.identifier: .kept])
        #expect(registry.contains(identifier: entry.identifier))
        let ended = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(taskIdentifier: 3, taskDescription: description, state: .completed)
        ])
        let retired = await ShareSessions(registry: registry) { _ in ended }
            .wake(repository: repository)
        #expect(retired == [entry.identifier: .retired])
        #expect(!registry.carries(jobID: queued.id))
    }

    @Test("two overlapping wakes attach once per identifier: one URLSession per identifier")
    func overlappingWakesAttachOnce() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        let registry = SessionRegistry(root: root)
        let entries = [SessionRegistryEntry(jobID: UUID()), SessionRegistryEntry(jobID: UUID())]
        for entry in entries { try registry.register(entry) }
        let created = Tally()
        let sessions = ShareSessions(registry: registry) { identifier in
            // Slow on purpose: a second wake arrives while the first is still creating.
            Thread.sleep(forTimeInterval: 0.1)
            created.add(identifier)
            return ScriptedUploadTaskSession()
        }
        async let first = sessions.wake(repository: repository)
        async let second = sessions.wake(repository: repository)
        sessions.attach(entries[0].identifier)
        _ = await (first, second)
        #expect(
            created.counts == [entries[0].identifier: 1, entries[1].identifier: 1])
    }

    // MARK: - the extension's start

    private static let credential = ShareUploadCredential(
        token: "grant", epoch: 7, binding: Fixture.binding())

    private static func serving(status: Int) -> ScriptedHTTP {
        let count = Tally()
        return ScriptedHTTP { _ in
            guard status == 201 else { return OutboxHTTPResponse(statusCode: status) }
            let uid = "u\(count.add("POST"))"
            return ScriptedHTTP.session(uid: uid, chunkSize: 64, received: 0)
        }
    }

    @Test("the extension opens each upload session and hands every body to the capture's session")
    func startHandsBodiesToTheCapturesSession() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        let job = try await Self.enqueue(repository, in: root, files: 2)
        let registry = SessionRegistry(root: root)
        let http = Self.serving(status: 201)
        let session = ScriptedUploadTaskSession()
        let asked = Tally()
        let outcome = await ShareTransfer.start(
            jobID: job.id, credential: Self.credential, registry: registry,
            repository: repository, http: http, allowsMobileData: false,
            stillCurrent: { _ in true },
            session: { identifier in
                asked.add(identifier)
                return session
            })
        let identifier = ShareSession.identifier(jobID: job.id)
        #expect(identifier == "live.discomarder.memosng.uploads.share.\(job.id.uuidString)")
        #expect(outcome == .started(identifier: identifier, tasks: 2))
        #expect(asked.counts == [identifier: 1])
        #expect(registry.contains(identifier: identifier))
        #expect(http.requests(method: "POST").count == 2)
        let saved = try #require(await repository.job(job.id))
        #expect(saved.lane == .whole)
        #expect(saved.files.compactMap(\.uploadUID).sorted() == ["u1", "u2"])
        let identities = session.createdTasks.compactMap {
            WholeTaskIdentity(taskDescription: $0.description)
        }
        #expect(Set(identities.map(\.fileID)) == Set(job.files.map(\.id)))
        #expect(identities.allSatisfy { $0.epoch == 7 && $0.attempt == 0 })
    }

    @Test("the extension's requests present the capture grant and never the session token")
    func extensionPresentsTheGrantOnTheWire() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        // What the app left in the app group: the licence, and the grant stamped with its issue.
        let account = OutboxAccountStore(root: root)
        account.publish(Fixture.binding())
        let licence = try #require(account.currentLicence())
        let grants = CaptureGrantStore(root: root)
        try grants.write(
            PublishedCaptureGrant(
                id: 12, token: "memos_cap_wire", expiresAt: Date().addingTimeInterval(86_400),
                binding: licence.binding, incarnation: try #require(licence.incarnation)))
        let job = try await Self.enqueue(repository, in: root, files: 2)
        let credential = try #require(grants.uploadCredential(enqueuedUnder: licence))
        let http = Self.serving(status: 201)
        let session = ScriptedUploadTaskSession()
        let outcome = await ShareTransfer.start(
            jobID: job.id, credential: credential, registry: SessionRegistry(root: root),
            repository: repository, http: http, allowsMobileData: false,
            stillCurrent: { epoch in
                grants.stillStands(
                    epoch: epoch, enqueuedUnder: licence, standing: account.currentLicence())
            },
            session: { _ in session })
        #expect(outcome == .started(identifier: ShareSession.identifier(jobID: job.id), tasks: 2))
        let presented =
            http.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
            + session.createdTasks.map { $0.request.value(forHTTPHeaderField: "Authorization") }
        #expect(presented.count == 4)
        #expect(presented.allSatisfy { $0 == "Bearer memos_cap_wire" })
        #expect(!presented.contains { $0?.contains("pat") ?? true })
    }

    @Test("a refused upload session is a typed value carrying the presented epoch; nothing stays")
    func refusedStartCarriesPresentedEpoch() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        let job = try await Self.enqueue(repository, in: root, files: 1)
        let registry = SessionRegistry(root: root)
        let session = ScriptedUploadTaskSession()
        let outcome = await ShareTransfer.start(
            jobID: job.id, credential: Self.credential, registry: registry,
            repository: repository, http: Self.serving(status: 401), allowsMobileData: false,
            stillCurrent: { _ in true }, session: { _ in session })
        guard case .refused(let refusal) = outcome else {
            Issue.record("expected a typed refusal, got \(outcome)")
            return
        }
        #expect(refusal.issuedUnder == 7)
        #expect(refusal.concernsCredential)
        #expect(registry.entries().isEmpty)
        #expect(session.createdTasks.isEmpty)
        #expect(try #require(await repository.job(job.id)).files.allSatisfy { $0.uploadUID == nil })
    }

    @Test("two overlapping starts for one capture are one request per file: the second is refused")
    func overlappingStartsSendOnce() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        let job = try await Self.enqueue(repository, in: root, files: 1)
        let registry = SessionRegistry(root: root)
        let gate = TestGate()
        let http = Self.serving(status: 201)
        let parked = ParkingHTTP(http, gate: gate)
        let session = ScriptedUploadTaskSession()
        let first = Task {
            await ShareTransfer.start(
                jobID: job.id, credential: Self.credential, registry: registry,
                repository: repository, http: parked, allowsMobileData: false,
                stillCurrent: { _ in true }, session: { _ in session })
        }
        await gate.waitUntilParked()
        let second = await ShareTransfer.start(
            jobID: job.id, credential: Self.credential, registry: registry,
            repository: repository, http: parked, allowsMobileData: false,
            stillCurrent: { _ in true }, session: { _ in session })
        await gate.open()
        let outcome = await first.value
        #expect(second == .notStarted("a start for this capture is already under way"))
        #expect(outcome == .started(identifier: ShareSession.identifier(jobID: job.id), tasks: 1))
        #expect(http.requests(method: "POST").count == 1)
        #expect(session.createdTasks.count == 1)
    }

    @Test("an upload session answered after its credential ended records nothing")
    func staleAnswerRecordsNothing() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        let job = try await Self.enqueue(repository, in: root, files: 1)
        let registry = SessionRegistry(root: root)
        let gate = TestGate()
        let ended = Tally()
        let session = ScriptedUploadTaskSession()
        let start = Task {
            await ShareTransfer.start(
                jobID: job.id, credential: Self.credential, registry: registry,
                repository: repository,
                http: ParkingHTTP(Self.serving(status: 201), gate: gate),
                allowsMobileData: false,
                stillCurrent: { epoch in epoch == 7 && ended.counts.isEmpty },
                session: { _ in session })
        }
        await gate.waitUntilParked()
        ended.add("signed out")
        await gate.open()
        let outcome = await start.value
        #expect(outcome == .notStarted("the capture or its credential moved"))
        let saved = try #require(await repository.job(job.id))
        #expect(saved.files.allSatisfy { $0.uploadUID == nil })
        #expect(saved.transport == nil)
        #expect(session.createdTasks.isEmpty)
        #expect(registry.entries().isEmpty)
    }

    @Test("a credential that ends after the save hands no file to the background session")
    func endedCredentialHandsNothingOver() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        let job = try await Self.enqueue(repository, in: root, files: 2)
        let registry = SessionRegistry(root: root)
        let ended = Tally()
        let session = ScriptedUploadTaskSession()
        let outcome = await ShareTransfer.start(
            jobID: job.id, credential: Self.credential, registry: registry,
            repository: repository, http: Self.serving(status: 201), allowsMobileData: false,
            stillCurrent: { epoch in epoch == 7 && ended.counts.isEmpty },
            session: { _ in
                // The save is behind us: the credential ends before any task is created.
                ended.add("signed out")
                return session
            })
        #expect(outcome == .notStarted("the credential ended before the files were handed over"))
        #expect(session.createdTasks.isEmpty)
        #expect(registry.entries().isEmpty)
    }

    @Test("a late fallback from an earlier wake never answers a later wake for the same session")
    func wakeAnswersAreBoundToTheirTicket() {
        let wakes = ShareWakeTickets()
        let identifier = ShareSession.identifier(jobID: UUID())
        let first = wakes.arm(identifier)
        // A's events finish: A is answered, and its fallback is still pending.
        #expect(wakes.claimFinished(identifier) == [first])
        let second = wakes.arm(identifier)
        // A's fallback fires now. It may not answer B, whose events are not over.
        #expect(!wakes.claim(first))
        // B is answered exactly once, when its events finish — and its own fallback finds nothing.
        #expect(wakes.claimFinished(identifier) == [second])
        #expect(!wakes.claim(second))
        #expect(wakes.claimFinished(identifier).isEmpty)
    }

    @Test("without an upload credential nothing is registered and nothing is sent")
    func noCredentialStartsNothing() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Self.repository(root)
        let job = try await Self.enqueue(repository, in: root, files: 1)
        let registry = SessionRegistry(root: root)
        let http = Self.serving(status: 201)
        let outcome = await ShareTransfer.start(
            jobID: job.id, credential: nil, registry: registry, repository: repository,
            http: http, allowsMobileData: false, stillCurrent: { _ in true },
            session: { _ in ScriptedUploadTaskSession() })
        #expect(outcome == .notStarted("no upload credential"))
        #expect(http.requests.isEmpty)
        #expect(registry.entries().isEmpty)
    }

    /// MEMNG-1083 item 2: the app is alive in the background — it was in front, then left, so its
    /// scheduling gate is CLOSED — when the extension's transfers finish, and the background
    /// refresh runs in THIS process: `wake(holding:)` around adopt, reattach and start, exactly as
    /// the app's `BGAppRefreshTask` handler. Whatever it does, it starts no new upload.
    ///
    /// The capture is NOT finalized there, by decision (MEMNG-1185): the reattached files need the
    /// offset HEAD (`OutboxPlanner.nextWholeAction`'s `.resume`), and a closed gate turns that
    /// into a wait for the foreground. The gate keeps its meaning — no new server question from a
    /// backgrounded pass — so the capture finishes at the next foreground, which opens the gate.
    @MainActor
    @Test("a live backgrounded process leaves a landed share capture to the next foreground")
    func liveBackgroundedRefreshAndAFinishedShareCapture() async throws {
        let rig = try await WholeRig.make(
            withUploads: false, attached: false,
            answerHead: { request in
                let size = request.url?.lastPathComponent == "u1" ? "1000" : "3000"
                return OutboxHTTPResponse(statusCode: 200, headers: ["Upload-Offset": size])
            }
        )
        defer { rig.cleanUp() }
        let sessions = SessionRegistry(root: rig.root)
        let extensionPosts = Counter()
        let extensionHTTP = ScriptedHTTP { _ in
            extensionPosts.increment()
            return ScriptedHTTP.session(
                uid: "u\(extensionPosts.count)", chunkSize: 5 * 1024 * 1024, received: 0)
        }
        let shareSession = ScriptedUploadTaskSession()
        let started = await ShareTransfer.start(
            jobID: rig.job.id,
            credential: ShareUploadCredential(token: "grant", epoch: 3, binding: Fixture.binding()),
            registry: sessions, repository: rig.repository, http: extensionHTTP,
            allowsMobileData: false, stillCurrent: { _ in true },
            session: { @Sendable _ in shareSession })
        let identifier = ShareSession.identifier(jobID: rig.job.id)
        #expect(started == .started(identifier: identifier, tasks: 2))
        let listing = shareSession.createdTasks.map {
            WholeTaskListing(
                taskIdentifier: $0.taskIdentifier, taskDescription: $0.description,
                state: .completed)
        }
        let clock = MutableClock(Date(timeIntervalSince1970: 1_750_000_000))
        let outbox = Outbox(
            repository: rig.repository, credentials: rig.credentials, http: rig.http,
            scheduler: ScriptedScheduler(), completion: rig.completion, network: rig.network,
            preferences: rig.preferences,
            uploads: BackgroundUploadScheduler(
                session: ScriptedUploadTaskSession(), now: { clock.now },
                pause: { clock.advance(11) }),
            shareSessions: ShareSessions(registry: sessions) { _ in
                ScriptedUploadTaskSession(listing: listing)
            }
        )
        // The app left the front while the extension's transfers were still out.
        outbox.appEnteredBackground()

        let wake = OutboxBackgroundCompletion().enterWake()
        await outbox.wake(holding: wake) {
            await outbox.adopt()
            await outbox.reattachShareSessions()
            await outbox.start()
        }

        #expect(!sessions.contains(identifier: identifier), "the share session was retired")
        #expect(rig.attemptedUploadPosts == 0, "a closed gate started a new upload")
        #expect(rig.http.requests(method: "HEAD").isEmpty, "a closed gate asked for the offset")
        #expect(rig.completion.idempotencyKeys.isEmpty, "a closed gate finished the capture")
        #expect(await rig.repository.job(rig.job.id) != nil, "the capture is still queued")

        // The person opens the app: the gate opens, and the capture finishes from the offset.
        await outbox.appBecameActive().value

        #expect(!rig.http.requests(method: "HEAD").isEmpty, "resumed from the server's offset")
        #expect(rig.completion.idempotencyKeys == [rig.job.idempotencyKey])
        #expect(rig.attemptedUploadPosts == 0, "a landed capture was uploaded again")
    }
}

/// Counts by key, from any thread.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Int] = [:]

    @discardableResult
    func add(_ key: String) -> Int {
        lock.withLock {
            stored[key, default: 0] += 1
            return stored[key] ?? 0
        }
    }

    var counts: [String: Int] { lock.withLock { stored } }
}

/// Delivers the first answer only once the test opens the gate: the request has left, and its
/// answer is held — the window an overlapping start or an ended credential lands in.
private final class ParkingHTTP: OutboxHTTPPerforming, @unchecked Sendable {
    private let inner: ScriptedHTTP
    private let gate: TestGate
    private let calls = Tally()

    init(_ inner: ScriptedHTTP, gate: TestGate) {
        self.inner = inner
        self.gate = gate
    }

    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        let response = try await inner.perform(request, under: authority)
        if calls.add("perform") == 1 { await gate.pass() }
        return response
    }
}
