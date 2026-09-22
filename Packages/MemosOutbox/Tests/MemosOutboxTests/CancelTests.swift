import CryptoKit
import Foundation
import MemosOutbox
import Testing

/// A server that answers a keyed create the way the real one does.
///
/// A key it has already committed answers with the memo it committed then, so a replay cannot
/// make a second one — which is the whole reason a cancelled capture keeps its key. It can also
/// commit a memo and then lose the answer, which a client cannot tell from "nothing happened".
private final class MemoServer: @unchecked Sendable {
    private let lock = NSLock()
    private var committed: [String: String] = [:]
    private var order: [String] = []
    private var lostResponses: Int

    init(losingResponses: Int = 0) { lostResponses = losingResponses }

    var memoCount: Int { lock.withLock { order.count } }

    func uid(forKey key: UUID) -> String? { lock.withLock { committed[key.uuidString] } }

    func answer(to request: URLRequest) -> OutboxHTTPResponse {
        let body = request.httpBody ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let key = object?["idempotency_key"] as? String ?? ""
        return lock.withLock {
            let uid: String
            if let existing = committed[key] {
                uid = existing
            } else {
                uid = "m\(order.count + 1)"
                committed[key] = uid
                order.append(uid)
            }
            guard lostResponses == 0 else {
                lostResponses -= 1
                return OutboxHTTPResponse(statusCode: 503)
            }
            return ScriptedHTTP.json(["uid": uid], status: 201)
        }
    }
}

/// A latch a test can wait on from one side and open from the other.
private actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// The real completion path, parked where the request has gone out and its answer has not come
/// back — the only instant a cancel can land in that this queue cannot otherwise be put into.
private final class ParkedCompletion: MemoCompleting, @unchecked Sendable {
    private let inner: any MemoCompleting
    private let entered: Latch
    private let released: Latch

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
        await entered.open()
        await released.wait()
        return await inner.create(job: job, credentials: credentials, under: authority)
    }
}

@MainActor
private struct Cancelling {
    let root: URL
    let repository: OutboxRepository
    let http: ScriptedHTTP
    let provider: SwitchableCredentials
    let server: MemoServer
    let outbox: Outbox
    let preferencesName: String

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        Fixture.forgetting(preferencesName)
    }

    /// Creates only: the upload sessions are POSTs too, and this is about how many memos were asked
    /// for.
    var memoPosts: [URLRequest] {
        http.requests(method: "POST").filter { $0.url?.path() == "/api/memos" }
    }
}

/// Taking a capture back out of the queue.
///
/// Every case here drives the real repository on a real directory: the fence a cancel has to lose
/// is a synchronous read and write inside that actor, so a double would be asserting the test's own
/// idea of it. The transport is scripted, the queue is not.
@MainActor
@Suite("A capture taken back to the editor")
struct CancelTests {
    private func harness(
        root existing: URL? = nil,
        server: MemoServer = MemoServer(),
        completion: (@Sendable (ScriptedHTTP) -> any MemoCompleting)? = nil
    ) throws -> Cancelling {
        let root = try existing ?? Fixture.temporaryDirectory()
        let provider = SwitchableCredentials(Fixture.credentials())
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        let http = ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/memos"):
                return server.answer(to: request)
            case ("POST", "/api/uploads"):
                return ScriptedHTTP.session(uid: "u1", chunkSize: 5 * 1024 * 1024, received: 0)
            case ("HEAD", _):
                return OutboxHTTPResponse(statusCode: 200, headers: ["Upload-Offset": "0"])
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
        let preferences = Fixture.preferences()
        let outbox = Outbox(
            repository: repository,
            credentials: provider,
            http: http,
            scheduler: ScriptedScheduler(),
            completion: completion?(http) ?? MemoCompletionEndpoint(http: http),
            network: StubNetworkPath(),
            preferences: preferences.store
        )
        return Cancelling(
            root: root,
            repository: repository,
            http: http,
            provider: provider,
            server: server,
            outbox: outbox,
            preferencesName: preferences.name
        )
    }

    private func capture(
        _ harness: Cancelling,
        content: String = "on the beach",
        files: [(name: String, bytes: Int)] = []
    ) async throws -> UploadJob {
        var sources: [StagedSource] = []
        for file in files {
            let url = try Fixture.file(in: harness.root, named: file.name, bytes: file.bytes)
            sources.append(StagedSource(url: url, filename: file.name, mime: "image/heic"))
        }
        return try await harness.repository.enqueue(
            content: content,
            visibility: "PRIVATE",
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            binding: Fixture.binding(),
            sources: sources
        )
    }

    /// Puts the queue into a state a drain would have reached, so a cancel can be asked about a
    /// point in the upload rather than only about a fresh capture.
    private func standing(
        _ harness: Cancelling,
        _ job: UploadJob,
        _ change: (inout UploadJob) -> Void
    ) async throws -> UploadJob {
        var candidate = job
        change(&candidate)
        let written = try await harness.repository.save(
            candidate, ifStillCurrent: nil, matching: job, else: candidate
        )
        return try #require(written)
    }

    private func digest(_ url: URL) throws -> SHA256Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    @Test("the editor gets the text back and every original, byte for byte")
    func cancelRestoresTextAndEveryOriginal() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, content: "two pictures", files: [("one.heic", 2048), ("two.heic", 3072)])
        let midway = try await standing(harness, job) {
            $0.state = .uploading
            $0.files[0].uploadUID = "u1"
            $0.files[0].bytesConfirmed = 1024
        }
        let draft = try #require(await harness.outbox.cancel(job.id))
        #expect(draft.content == "two pictures")
        #expect(draft.pictures.map(\.filename) == ["one.heic", "two.heic"])
        for (picture, file) in zip(draft.pictures, midway.files) {
            let held = harness.repository.mediaURL(job: midway, file: file)
            #expect(try digest(picture.url) == digest(held))
            #expect(try digest(picture.url) == digest(harness.root.appending(path: file.filename)))
        }
        let standing = await harness.repository.job(job.id)
        #expect(standing != nil)
    }

    @Test("cancel before the first byte keeps the capture and sends nothing")
    func cancelBeforeTheFirstByte() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [("one.heic", 2048)])
        let draft = try #require(await harness.outbox.cancel(job.id))
        #expect(draft.pictures.count == 1)
        await harness.outbox.drain()
        #expect(harness.server.memoCount == 0)
        #expect(harness.memoPosts.isEmpty)
        let standing = await harness.repository.job(job.id)
        #expect(standing?.cancelledAt != nil)
    }

    @Test("cancel mid-chunk keeps the whole original, not the part that went up")
    func cancelMidChunk() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [("one.heic", 4096)])
        let midway = try await standing(harness, job) {
            $0.state = .uploading
            $0.files[0].uploadUID = "u1"
            $0.files[0].bytesConfirmed = 2048
        }
        let draft = try #require(await harness.outbox.cancel(job.id))
        let held = harness.repository.mediaURL(job: midway, file: midway.files[0])
        #expect(try digest(draft.pictures[0].url) == digest(held))
        #expect(try Data(contentsOf: draft.pictures[0].url).count == 4096)
        await harness.outbox.drain()
        #expect(harness.server.memoCount == 0)
    }

    @Test("cancel after the last byte, before the memo exists, makes no memo")
    func cancelAfterTheBytesBeforeTheMemo() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [("one.heic", 2048)])
        _ = try await standing(harness, job) {
            $0.state = .creating
            $0.files[0].uploadUID = "u1"
            $0.files[0].bytesConfirmed = 2048
        }
        let draft = try #require(await harness.outbox.cancel(job.id))
        #expect(draft.pictures.count == 1)
        await harness.outbox.drain()
        #expect(harness.server.memoCount == 0)
        let standing = await harness.repository.job(job.id)
        #expect(standing != nil)
    }

    @Test("a manifest that outlived the app is enough to hand the capture back")
    func cancelAfterAnAppKill() async throws {
        let first = try harness()
        defer { first.cleanUp() }
        let job = try await capture(first, content: "kept overnight", files: [("one.heic", 2048)])
        // A second queue over the same directory, holding nothing the first one knew.
        let relaunched = try harness(root: first.root, server: first.server)
        defer { Fixture.forgetting(relaunched.preferencesName) }
        let draft = try #require(await relaunched.outbox.cancel(job.id))
        #expect(draft.content == "kept overnight")
        #expect(try digest(draft.pictures[0].url) == digest(first.root.appending(path: "one.heic")))
        let standing = await relaunched.repository.job(job.id)
        #expect(standing?.idempotencyKey == job.idempotencyKey)
    }

    @Test("a create that committed but was never acknowledged still makes exactly one memo")
    func aCommittedCreateIsNotMadeTwice() async throws {
        let harness = try harness(server: MemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(harness, content: "committed once")
        await harness.outbox.drain()
        #expect(harness.server.memoCount == 1)
        let firstBody = try #require(harness.memoPosts.first?.httpBody)
        let draft = try #require(await harness.outbox.cancel(job.id))
        let carried = try #require(await harness.repository.job(job.id))
        #expect(carried.idempotencyKey == job.idempotencyKey)
        let resubmitted = await harness.outbox.resubmit(job.id, draft: draft)
        #expect(resubmitted)
        #expect(harness.server.memoCount == 1)
        #expect(harness.memoPosts.count == 2)
        // As FIRST SENT, byte for byte: the replay is the same request, which is what the server
        // answers with the memo it already made rather than with a second one.
        #expect(harness.memoPosts[1].httpBody == firstBody)
    }

    @Test("a re-submitted draft keeps the cancelled job's key; a new capture gets its own")
    func resubmitCarriesTheOriginalKey() async throws {
        let harness = try harness(
            completion: { _ in
                ScriptedCompletion([.retry("not now")], repeating: .retry("not now"))
            }
        )
        defer { harness.cleanUp() }
        let job = try await capture(harness, content: "keep the key")
        let before = try await harness.repository.loadJobs().count
        let draft = try #require(await harness.outbox.cancel(job.id))
        let resubmitted = await harness.outbox.resubmit(job.id, draft: draft)
        #expect(resubmitted)
        let carried = try #require(await harness.repository.job(job.id))
        #expect(carried.idempotencyKey == job.idempotencyKey)
        let after = try await harness.repository.loadJobs().count
        #expect(after == before)
        _ = await harness.outbox.enqueue(
            content: "a second capture", visibility: "PRIVATE", sources: [])
        let jobs = try await harness.repository.loadJobs()
        let fresh = try #require(jobs.first { $0.id != job.id })
        #expect(fresh.idempotencyKey != job.idempotencyKey)
    }

    @Test("a create acknowledged after the cancel leaves the capture on this device")
    func aLateAcknowledgementLeavesTheCaptureAlone() async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(
            completion: {
                ParkedCompletion(
                    MemoCompletionEndpoint(http: $0), entered: entered, released: released)
            }
        )
        defer { harness.cleanUp() }
        let job = try await capture(harness, content: "taken back mid-create")
        let draining = Task { await harness.outbox.drain() }
        await entered.wait()
        let draft = try #require(await harness.outbox.cancel(job.id))
        await released.open()
        await draining.value
        let standing = try #require(await harness.repository.job(job.id))
        #expect(standing.idempotencyKey == job.idempotencyKey)
        #expect(standing.cancelledAt != nil)
        #expect(harness.server.memoCount == 1)
        let resubmitted = await harness.outbox.resubmit(job.id, draft: draft)
        #expect(resubmitted)
        #expect(harness.server.memoCount == 1)
    }

    @Test("a re-submitted draft keeps its account, and only a person's retry moves it")
    func resubmitDoesNotRestampTheBinding() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await capture(harness, content: "under one account")
        let draft = try #require(await harness.outbox.cancel(job.id))
        harness.provider.set(Fixture.credentials(owner: "someone-else"))
        let resubmitted = await harness.outbox.resubmit(job.id, draft: draft)
        #expect(resubmitted)
        let held = try #require(await harness.repository.job(job.id))
        #expect(held.binding == Fixture.binding())
        #expect(held.state == .held)
        #expect(held.holdReason == .accountMismatch)
        #expect(harness.memoPosts.isEmpty)
        harness.provider.set(Fixture.credentials())
        await harness.outbox.drain()
        #expect(harness.memoPosts.isEmpty)
        await harness.outbox.retry(job.id)
        #expect(harness.memoPosts.count == 1)
        #expect(harness.server.memoCount == 1)
    }

    @Test("cancel and a finishing create resolve to exactly one owner", arguments: [true, false])
    func exactlyOneOwner(cancelFirst: Bool) async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(
            completion: {
                ParkedCompletion(
                    MemoCompletionEndpoint(http: $0), entered: entered, released: released)
            }
        )
        defer { harness.cleanUp() }
        let job = try await capture(harness, content: "one owner")
        let cancelWon: Bool
        let createWon: Bool
        if cancelFirst {
            let draining = Task { await harness.outbox.drain() }
            await entered.wait()
            cancelWon = await harness.outbox.cancel(job.id) != nil
            await released.open()
            await draining.value
            createWon = await harness.repository.job(job.id) == nil
        } else {
            await released.open()
            await harness.outbox.drain()
            createWon = await harness.repository.job(job.id) == nil
            cancelWon = await harness.outbox.cancel(job.id) != nil
        }
        #expect([cancelWon, createWon].filter { $0 }.count == 1)
    }

    /// Where the cancel lands relative to the create it is racing.
    private enum Interleaving: Sendable, CaseIterable {
        case beforeTheCreate
        case insideTheCreate
        case afterTheCreate
    }

    @Test(
        "however cancel and a finishing create interleave, one memo at most and one owner",
        arguments: Interleaving.allCases
    )
    private func theResolvedEndState(_ point: Interleaving) async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(
            completion: {
                ParkedCompletion(
                    MemoCompletionEndpoint(http: $0), entered: entered, released: released)
            }
        )
        defer { harness.cleanUp() }
        let job = try await capture(harness, content: "one memo at most")
        var draft: RestoredDraft?
        switch point {
        case .beforeTheCreate:
            draft = await harness.outbox.cancel(job.id)
            await released.open()
            await harness.outbox.drain()
        case .insideTheCreate:
            let draining = Task { await harness.outbox.drain() }
            await entered.wait()
            draft = await harness.outbox.cancel(job.id)
            await released.open()
            await draining.value
        case .afterTheCreate:
            await released.open()
            await harness.outbox.drain()
            draft = await harness.outbox.cancel(job.id)
        }
        #expect(harness.server.memoCount <= 1)
        let standing = await harness.repository.job(job.id)
        guard let standing else {
            // The job is done, which it can only be because the server took the memo.
            #expect(harness.server.memoCount == 1)
            #expect(draft == nil)
            return
        }
        #expect(standing.cancelledAt != nil)
        let resolvedBefore = harness.server.uid(forKey: job.idempotencyKey)
        let resubmitted = await harness.outbox.resubmit(job.id, draft: try #require(draft))
        #expect(resubmitted)
        #expect(harness.server.memoCount == 1)
        let resolved = harness.server.uid(forKey: job.idempotencyKey)
        #expect(resolved != nil)
        if let resolvedBefore { #expect(resolved == resolvedBefore) }
        let finished = await harness.repository.job(job.id)
        #expect(finished == nil)
    }
}
