import Foundation
@testable import MemosOutbox
import Testing

/// MEMNG-546: the member queue runs on the whole lane only. A row an older build began in chunks is
/// moved onto it where it is first read, the old chunk session's leftovers are cancelled once at
/// adoption, and a chunk answer that outlived the move is dropped.
@Suite("The member chunk lane is retired")
struct ChunkLaneRetirementTests {
    private static func legacyRow(
        transport: UploadTransport?
    ) -> (UploadJob, done: UUID, part: UUID) {
        let done = Fixture.file(uploadUID: "u1", byteSize: 1024, bytesConfirmed: 1024)
        var part = Fixture.file(uploadUID: "u2", byteSize: 1024, bytesConfirmed: 100)
        part.uploadAttempt = 2
        part.conflictResync = true
        var job = Fixture.job(files: [done, part], state: .uploading)
        job.transport = transport
        return (job, done.id, part.id)
    }

    private static func repositories() throws -> (
        URL, plain: OutboxRepository, retiring: OutboxRepository
    ) {
        let root = try Fixture.temporaryDirectory()
        return (
            root, try OutboxRepository(root: root),
            try OutboxRepository(root: root, retiresChunkLane: true)
        )
    }

    @Test("a manifest with no lane and a started file is moved onto the whole lane and written")
    func legacyNoTransportManifestMoves() async throws {
        let (root, plain, retiring) = try Self.repositories()
        defer { try? FileManager.default.removeItem(at: root) }
        let (job, done, part) = Self.legacyRow(transport: nil)
        try await plain.save(job)

        let moved = try #require(try await retiring.loadJobs().first)
        #expect(moved.transport == .whole)
        #expect(moved.file(done) == job.file(done), "a file the server holds whole was touched")
        let restarted = try #require(moved.file(part))
        #expect(restarted.uploadUID == nil, "the chunk session was kept")
        #expect(restarted.bytesConfirmed == 0, "a chunk's count was carried onto the whole lane")
        #expect(restarted.conflictResync == nil)
        #expect(restarted.uploadAttempt == 2, "the attempt term moved")
        // Read back through a repository that moves nothing: the move is on the disk.
        #expect(await plain.job(job.id) == moved, "the move was not written down")
    }

    @Test("an explicit chunk manifest is moved by the one-row lookup too, and written")
    func explicitChunkManifestMoves() async throws {
        let (root, plain, retiring) = try Self.repositories()
        defer { try? FileManager.default.removeItem(at: root) }
        let (job, done, part) = Self.legacyRow(transport: .chunk)
        try await plain.save(job)

        let moved = try #require(await retiring.job(job.id))
        #expect(moved.lane == .whole)
        #expect(moved.file(done)?.isComplete == true)
        #expect(moved.file(part)?.bytesConfirmed == 0)
        #expect(await plain.job(job.id)?.transport == .whole, "the move was not written down")
    }

    @Test("a fresh row, a guest row and a repository that was not asked are left as they are")
    func onlyStartedMemberRowsMove() async throws {
        let (root, plain, retiring) = try Self.repositories()
        defer { try? FileManager.default.removeItem(at: root) }
        // No session yet: its first hand-off claims it, and the share extension reads the missing
        // field as unclaimed.
        let fresh = Fixture.job(files: [Fixture.file()])
        var guest = Self.legacyRow(transport: nil).0
        guest.binding = AccountBinding(
            serverBaseURL: Fixture.server, ownerSubject: "device-1", kind: .guest)
        let chunk = Self.legacyRow(transport: .chunk).0
        for row in [fresh, guest, chunk] { try await plain.save(row) }

        #expect(try await plain.loadJobs().allSatisfy { $0.transport != .whole })
        #expect(await retiring.job(fresh.id)?.transport == nil)
        #expect(await plain.job(fresh.id)?.transport == nil, "a fresh row was claimed by a read")
        #expect(await retiring.job(guest.id)?.transport == nil, "a guest row left the chunk lane")
        #expect(await retiring.job(guest.id)?.files == guest.files)
        #expect(await plain.job(chunk.id)?.transport == .chunk, "an unasked repository moved it")
        #expect(await plain.job(chunk.id)?.files == chunk.files)
    }

    @Test("a moved row drains on the whole lane: no chunk, no resume of the old session")
    func movedRowDrainsWhole() async throws {
        let rig = try await WholeRig.make(prepare: { job in
            var legacy = job
            legacy.transport = .chunk
            legacy.files[1].uploadUID = "old"
            legacy.files[1].bytesConfirmed = 100
            return legacy
        })
        defer { rig.cleanUp() }
        let retiring = try OutboxRepository(
            root: rig.root.appending(path: "outbox"), retiresChunkLane: true)
        _ = try await retiring.loadJobs()

        await rig.engine.drain()
        try await settled(rig.engine)

        #expect(rig.chunks.uploads.isEmpty, "a chunk went out for a member row")
        #expect(rig.session.createdTasks.count == 2, "both files were not sent whole")
        #expect(!rig.attempted.value.contains { $0.hasPrefix("HEAD") }, "the old session resumed")
        #expect(try await rig.reload().transport == .whole)
    }

    @Test("an engine with the whole lane sends a chunk-lane row whole, moved or not")
    func wholeEngineNeverPlansAChunk() async throws {
        let rig = try await WholeRig.make(prepare: { job in
            var legacy = job
            legacy.transport = .chunk
            return legacy
        })
        defer { rig.cleanUp() }

        await rig.engine.drain()
        try await settled(rig.engine)

        #expect(rig.chunks.uploads.isEmpty, "the planner's chunk step ran for a member row")
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("a row begun in chunks that no repository moved is moved by the engine, not spun on")
    func engineMovesAnUnmovedRow() async throws {
        let rig = try await WholeRig.make(prepare: { job in
            var started = job
            started.files[0].uploadUID = "c1"
            return started
        })
        defer { rig.cleanUp() }

        await rig.engine.drain()
        try await settled(rig.engine)

        #expect(rig.chunks.uploads.isEmpty, "a chunk went out for a member row")
        #expect(rig.session.createdTasks.count == 2, "the row was not sent whole")
        let saved = try await rig.reload()
        #expect(saved.transport == .whole)
        #expect(saved.files[0].uploadUID != "c1", "the chunk session was resumed")
    }

    @Test("a late chunk answer for a moved row is dropped, even at the offset and term it names")
    func lateChunkAnswerIsDropped() async throws {
        let rig = try await WholeRig.make(prepare: { job in
            var moved = job
            moved.transport = .whole
            moved.files[0].uploadUID = "w1"
            return moved
        })
        defer { rig.cleanUp() }
        rig.gate.close()
        let before = try await rig.reload()
        let file = before.files[0]
        let late = ChunkResult(
            identity: OutboxTaskIdentity(
                jobID: before.id, fileID: file.id, offset: 0, attempt: file.uploadAttempt),
            statusCode: 200,
            body: ScriptedHTTP.session(uid: "w1", chunkSize: 1024, received: Int(file.byteSize))
                .body
        )

        await rig.engine.handle(late)
        try await settled(rig.engine)

        let after = try #require(try await rig.reload().file(file.id))
        #expect(after.bytesConfirmed == 0, "a chunk's count was banked on the whole lane")
        #expect(after.uploadUID == "w1")
    }

    @Test("the retired session cancels what it holds once, lists nothing, and sends nothing")
    func retiredSessionCancelsOnce() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverAnswering.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://example.invalid/api/uploads/u1"))
        let left = session.dataTask(with: url)
        left.taskDescription = "\(UUID().uuidString)|\(UUID().uuidString)|0|1"
        left.resume()
        let retired = RetiredChunkSession(session: session)

        #expect(await retired.inFlight().isEmpty, "a retired task was listed for adoption")
        await retired.retire()
        #expect(left.state != .running, "a leftover chunk task was not cancelled")

        let later = session.dataTask(with: url)
        later.resume()
        await retired.retire()
        #expect(later.state == .running, "the launch's cancel ran twice")
        await retired.cancelEveryTask()
        #expect(later.state != .running, "a withdrawal left a task on the retired session")
    }

    @Test("the composed member outbox retires the old chunk session at adoption")
    @MainActor
    func composedRetiresAtAdoption() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverAnswering.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let left = session.dataTask(with: try #require(URL(string: "https://example.invalid/x")))
        left.resume()
        let outbox = Outbox.composed(
            repository: rig.repository,
            credentials: rig.credentials,
            http: rig.http,
            uploads: BackgroundUploadScheduler(
                session: rig.session, delegate: rig.delegate, launch: rig.launch, pause: {}),
            network: rig.network,
            preferences: rig.preferences,
            retiredChunks: RetiredChunkSession(session: session)
        )

        await outbox.adopt()

        #expect(left.state != .running, "adoption left the old chunk session's task running")
    }
}

/// A loading that never finishes, so a task stays running until something cancels it.
private final class NeverAnswering: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {}

    override func stopLoading() {}
}
