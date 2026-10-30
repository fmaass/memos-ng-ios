import Foundation
import Testing

@testable import MemosOutbox

/// The real completion path, parked at the FIRST create — after the claim was written and before
/// the request leaves — so a case can stand inside the one window a change can race the create in.
/// Every later create goes straight through.
private final class CreateParking: MemoCompleting, @unchecked Sendable {
    private let inner: any MemoCompleting
    private let entered: Latch
    private let released: Latch
    private let lock = NSLock()
    private var parked = false

    init(_ inner: any MemoCompleting, entered: Latch, released: Latch) {
        self.inner = inner
        self.entered = entered
        self.released = released
    }

    func create(
        job: UploadJob,
        credentials: OutboxCredentials,
        under authority: SendAuthority
    ) async -> MemoCompletionOutcome {
        let first = lock.withLock {
            defer { parked = true }
            return !parked
        }
        if first {
            await entered.open()
            _ = await released.wait(within: 5)
        }
        return await inner.create(job: job, credentials: credentials, under: authority)
    }

    func patch(
        job: UploadJob,
        request: URLRequest,
        credentials: OutboxCredentials,
        under authority: SendAuthority
    ) async -> MemoPatchOutcome {
        await inner.patch(
            job: job, request: request, credentials: credentials, under: authority)
    }
}

/// A pending memo's visibility changed from its card or the Transfers sheet (MEMNG-971).
///
/// Every case drives the real repository on a real directory and the real completion path against
/// the scripted keyed server: what the outbox SENDS is the subject, so nothing here stands in for
/// the store.
@MainActor
@Suite("A pending memo's visibility")
struct PendingVisibilityTests {
    private static let captured = Date(timeIntervalSince1970: 1_780_000_000)

    private func harness(
        server: KeyedMemoServer = KeyedMemoServer(),
        completion: (@Sendable (any MemoCompleting) -> any MemoCompleting)? = nil
    ) throws -> Patching {
        let root = try Fixture.temporaryDirectory()
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"), stillCurrent: { _ in true })
        let http = ScriptedHTTP { request in
            let path = request.url?.path() ?? ""
            switch (request.httpMethod ?? "", path) {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/memos"):
                return server.answerCreate(to: request)
            case ("PATCH", _) where path.hasPrefix("/api/memos/"):
                return server.answerPatch(
                    to: request, uid: String(path.dropFirst("/api/memos/".count)))
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
        let preferences = Fixture.preferences()
        let endpoint = MemoCompletionEndpoint(http: http)
        let outbox = Outbox(
            repository: repository,
            credentials: StaticCredentials(credentials: Fixture.credentials()),
            http: http,
            scheduler: ScriptedScheduler(),
            completion: completion?(endpoint) ?? endpoint,
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: Date.init
        )
        return Patching(
            root: root, repository: repository, http: http, server: server, outbox: outbox,
            preferencesName: preferences.name)
    }

    /// A PRIVATE capture of one picture whose bytes are all on the server: the state the create
    /// is sent from.
    private func uploadedCapture(
        _ harness: Patching, content: String = "the pier at dusk"
    ) async throws -> UploadJob {
        let url = try Fixture.file(in: harness.root, named: "\(UUID()).heic", bytes: 400)
        let job = try await harness.repository.enqueue(
            content: content, visibility: "PRIVATE", capturedAt: Self.captured,
            binding: Fixture.binding(),
            sources: [StagedSource(url: url, filename: "pier.heic", mime: "image/heic")])
        var candidate = job
        for index in candidate.files.indices {
            candidate.files[index].uploadUID = "u\(index + 1)"
            candidate.files[index].bytesConfirmed = candidate.files[index].byteSize
        }
        return try #require(
            try await harness.repository.save(
                candidate, ifStillCurrent: nil, matching: job, else: candidate))
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        let data = request.httpBody ?? Data()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    @Test("a change before the create is what the POST carries, and only on that capture")
    func aChangeBeforeTheCreateIsWhatThePostCarries() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await uploadedCapture(harness)
        let other = try await uploadedCapture(harness, content: "a second capture")
        let untouched = try #require(await harness.repository.job(other.id))

        #expect(await harness.outbox.setVisibility("PUBLIC", of: job.id) == .intoCreate)
        let written = try #require(await harness.repository.job(job.id))
        #expect(written.visibility == "PUBLIC")
        #expect(written.pendingEdit == nil)
        #expect(written.idempotencyKey == job.idempotencyKey)
        #expect(await harness.repository.job(other.id) == untouched)

        await harness.outbox.drain()

        let posts = harness.memoPosts
        #expect(posts.count == 2)
        let sent = try #require(posts.first { body($0)["content"] as? String == job.content })
        #expect(body(sent)["visibility"] as? String == "PUBLIC")
        let sibling = try #require(posts.first { body($0)["content"] as? String == other.content })
        #expect(body(sibling)["visibility"] as? String == "PRIVATE")
        #expect(harness.memoPatches.isEmpty, "a change the create carried needs no edit")
        let memos = harness.server.memoUIDs.compactMap { harness.server.memo($0) }
        #expect(memos.first { $0.content == job.content }?.visibility == "PUBLIC")
        #expect(await harness.repository.job(job.id) == nil)
    }

    @Test("a change racing the create is applied by one PATCH once the memo is named")
    func aChangeRacingTheCreateIsPatchedAfter() async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(completion: {
            CreateParking($0, entered: entered, released: released)
        })
        defer { harness.cleanUp() }
        let job = try await uploadedCapture(harness)

        let parked = Task { await harness.outbox.drain() }
        #expect(await entered.wait(within: 2), "the create never reached the completion double")
        let claimed = try #require(await harness.repository.job(job.id))
        #expect(claimed.state == .creating)

        #expect(await harness.outbox.setVisibility("PUBLIC", of: job.id) == .owedAsEdit)
        let owed = try #require(await harness.repository.job(job.id))
        // The create's own body is left as it went out: a replay under the same key answers with
        // the memo that body made, and a changed body would only hide the change.
        #expect(owed.visibility == "PRIVATE")
        #expect(owed.pendingEdit?.visibility == "PUBLIC")
        #expect(owed.pendingEdit?.content == job.content)
        #expect(owed.pendingEdit?.fileIDs == job.files.map(\.id))
        #expect(owed.editKey != nil && owed.editKey != job.idempotencyKey.uuidString)

        // No second drain is asked for here: the change's own write asked for the pass that
        // replays the create and sends the edit.
        await released.open()
        await parked.value

        #expect(harness.server.memoCount == 1, "the race made a second memo")
        #expect(body(try #require(harness.memoPosts.first))["visibility"] as? String == "PRIVATE")
        #expect(harness.memoPatches.count == 1)
        let patch = try #require(harness.memoPatches.first)
        #expect(body(patch)["visibility"] as? String == "PUBLIC")
        let memo = try #require(harness.server.memo("m1"))
        #expect(memo.visibility == "PUBLIC", "the change that raced the create was lost")
        #expect(memo.attachmentUIDs == ["att-u1"], "the edit dropped the memo's picture")
        #expect(memo.content == job.content)
        #expect(await harness.repository.job(job.id) == nil)
    }

    @Test("two changes racing the create are one PATCH, carrying the last")
    func twoChangesRacingTheCreateAreOnePatchOfTheLast() async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(completion: {
            CreateParking($0, entered: entered, released: released)
        })
        defer { harness.cleanUp() }
        let job = try await uploadedCapture(harness)

        let parked = Task { await harness.outbox.drain() }
        #expect(await entered.wait(within: 2), "the create never reached the completion double")
        #expect(await harness.outbox.setVisibility("PUBLIC", of: job.id) == .owedAsEdit)
        let firstKey = try #require(await harness.repository.job(job.id)?.editKey)
        #expect(await harness.outbox.setVisibility("PUBLIC", of: job.id) == .unchanged)
        #expect(await harness.outbox.setVisibility("PROTECTED", of: job.id) == .owedAsEdit)
        let secondKey = try #require(await harness.repository.job(job.id)?.editKey)
        #expect(firstKey != secondKey, "a different edit reused the key of the one before")

        // No second drain is asked for here: the change's own write asked for the pass that
        // replays the create and sends the edit.
        await released.open()
        await parked.value

        #expect(harness.server.memoCount == 1)
        #expect(harness.memoPatches.count == 1)
        #expect(harness.server.editApplications == 1)
        #expect(harness.server.memo("m1")?.visibility == "PROTECTED")
    }

    @Test("gone, taken back or with a change on the wire refuses; the same value writes nothing")
    func refusalsAndNoOpsWriteNothing() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await uploadedCapture(harness)

        #expect(try await harness.repository.setVisibility("PUBLIC", of: UUID()) == .refused)
        #expect(try await harness.repository.setVisibility("PRIVATE", of: job.id) == .unchanged)
        #expect(await harness.repository.job(job.id) == job)

        let frozen = try #require(
            try await harness.repository.save(
                job.with { $0.editUnansweredSince = Self.captured }, ifStillCurrent: nil,
                matching: job, else: job))
        #expect(try await harness.repository.setVisibility("PUBLIC", of: job.id) == .refused)
        #expect(await harness.repository.job(job.id) == frozen)

        let taken = try #require(
            try await harness.repository.save(
                frozen.with { $0.editUnansweredSince = nil }.cancelled(at: Self.captured),
                ifStillCurrent: nil, matching: frozen, else: frozen))
        #expect(try await harness.repository.setVisibility("PUBLIC", of: job.id) == .refused)
        #expect(await harness.repository.job(job.id) == taken)
    }

    @Test("a change the lock refuses throws and leaves the manifest as it was")
    func aRefusedLeaseWritesNothing() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await uploadedCapture(harness)
        let unavailable: @Sendable (Int32, Int32) -> Int32 = { _, _ in
            errno = ENOLCK
            return -1
        }
        let locked = try OutboxRepository(
            root: harness.root.appending(path: "outbox"), flock: unavailable)
        await #expect(throws: OutboxStorageError.self) {
            _ = try await locked.setVisibility("PUBLIC", of: job.id)
        }
        #expect(await harness.repository.job(job.id) == job)
    }
}
