import Foundation
import MemosOutbox
import Testing

/// The engine the facade built, handed out through `attachScheduler`.
///
/// `Outbox` exposes no engine, and a delayed answer has to reach the very handler the background
/// session would have answered — a second engine over the same repository would be answering a
/// question nobody asked.
final class AttemptHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any OutboxChunkHandling)?

    var value: (any OutboxChunkHandling)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// One queue on a real directory, driven through the real facade.
@MainActor
private struct AttemptWorld {
    let root: URL
    let repository: OutboxRepository
    let http: ScriptedHTTP
    let scheduler: ScriptedScheduler
    let completion: ScriptedCompletion
    let network: StubNetworkPath
    let clock: MutableClock
    let box: AttemptHandlerBox
    let outbox: Outbox
    let preferencesName: String
    let binding: AccountBinding

    var handler: (any OutboxChunkHandling) {
        get throws { try #require(box.value, "the facade never handed its engine over") }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        Fixture.forgetting(preferencesName)
    }
}

@MainActor
private func makeWorld(
    network: StubNetworkPath = StubNetworkPath(),
    allowsMobileData: Bool = false,
    chunkSize: Int = 400
) throws -> AttemptWorld {
    let root = try Fixture.temporaryDirectory()
    let provider = SwitchableCredentials(Fixture.credentials())
    let repository = try OutboxRepository(
        root: root.appending(path: "outbox"),
        stillCurrent: { provider.stillCurrent(epoch: $0) }
    )
    let http = ScriptedHTTP.standard(chunkSize: chunkSize)
    let scheduler = ScriptedScheduler()
    let completion = ScriptedCompletion([.created(uid: "m1")], repeating: .created(uid: "m1"))
    let clock = MutableClock(Date(timeIntervalSince1970: 1_750_000_000))
    let preferences = Fixture.preferences(
        allowsMobileData: allowsMobileData,
        name: "memosng.outbox.tests.attempt.\(UUID().uuidString)"
    )
    let box = AttemptHandlerBox()
    let outbox = Outbox(
        repository: repository,
        credentials: provider,
        http: http,
        scheduler: scheduler,
        completion: completion,
        network: network,
        preferences: preferences.store,
        clock: { clock.now },
        attachScheduler: { handler in box.value = handler }
    )
    return AttemptWorld(
        root: root,
        repository: repository,
        http: http,
        scheduler: scheduler,
        completion: completion,
        network: network,
        clock: clock,
        box: box,
        outbox: outbox,
        preferencesName: preferences.name,
        binding: Fixture.binding()
    )
}

/// A capture with one original of `bytes`, straight into the queue the facade reads.
@MainActor
private func enqueue(_ world: AttemptWorld, bytes: Int = 1000) async throws -> UploadJob {
    let source = try Fixture.file(in: world.root, named: "one.heic", bytes: bytes)
    return try await world.repository.enqueue(
        content: "on the beach",
        visibility: "PRIVATE",
        capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
        binding: world.binding,
        sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
    )
}

/// One chunk confirmed, a second chunk with the background session at the confirmed offset, and the
/// queue told that task survived — the state a stalled-but-alive upload is in.
@MainActor
private struct Stalled {
    let world: AttemptWorld
    let job: UploadJob
    let fileID: UUID
    /// The task Retry has to cancel — scheduled before any attempt term existed on this file.
    let predecessor: OutboxTaskIdentity
}

@MainActor
private func stall(_ world: AttemptWorld) async throws -> Stalled {
    let job = try await enqueue(world, bytes: 1000)
    await world.outbox.adopt()
    await world.outbox.drain()

    let first = try #require(world.scheduler.uploads.first?.identity)
    #expect(first.offset == 0, "control: the first chunk went out at offset 0")
    try await world.handler.handle(
        ChunkResult(
            identity: first,
            statusCode: 200,
            body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
        )
    )

    let stalled = try #require(world.scheduler.uploads.last?.identity)
    #expect(stalled.offset == 400, "control: the next chunk went out at the confirmed offset")
    world.scheduler.pretend(inFlight: [stalled])
    return Stalled(
        world: world, job: job, fileID: try #require(job.files.first?.id), predecessor: stalled
    )
}

@Suite("Retry against a task that is stalled but alive")
@MainActor
struct AttemptRetryTests {
    @Test("Retry cancels the adopted task, schedules a fresh one, and moves new bytes")
    func retryMovesBytes() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let stalled = try await stall(world)
        let scheduledBefore = world.scheduler.uploads.count

        await world.outbox.retry(stalled.job.id)

        #expect(
            world.scheduler.cancellations == [stalled.predecessor],
            "Retry handed the job back to the task it was stalled on"
        )
        #expect(
            world.scheduler.uploads.count == scheduledBefore + 1,
            "Retry scheduled no replacement"
        )
        let successor = try #require(world.scheduler.uploads.last?.identity)
        #expect(successor.offset == 400, "the replacement did not start at the confirmed offset")
        #expect(
            successor.attempt != stalled.predecessor.attempt,
            "the replacement is indistinguishable from the task it replaces"
        )

        try await world.handler.handle(
            ChunkResult(
                identity: successor,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":800}"#.utf8)
            )
        )
        let reloaded = try #require(await world.repository.job(stalled.job.id))
        #expect(reloaded.confirmedBytes == 800, "no new bytes were confirmed")
    }

    @Test("with the network policy refusing, the same Retry moves nothing and says why")
    func retryDeniedByPolicy() async throws {
        let world = try makeWorld(allowsMobileData: false)
        defer { world.cleanUp() }
        let stalled = try await stall(world)
        let scheduledBefore = world.scheduler.uploads.count

        await world.network.move(to: .cellular)
        await world.outbox.retry(stalled.job.id)

        #expect(
            world.scheduler.uploads.count == scheduledBefore,
            "a chunk went out on a network the policy refuses"
        )
        let reloaded = try #require(await world.repository.job(stalled.job.id))
        #expect(reloaded.confirmedBytes == 400, "bytes moved under a refusing policy")
        #expect(reloaded.waitReason == .homeNetwork, "the card cannot say why nothing moved")
    }

    @Test("Retry hands back every task older than the attempt it just minted, and only those")
    func retryKeepsTheSuccessorItJustScheduled() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let stalled = try await stall(world)
        let current = try #require(await world.repository.job(stalled.job.id))
        // Named, rather than left at whatever the stall reached, so the term the retry bumps FROM
        // is the one the identities below are written against.
        var prepared = current
        prepared.files[0].uploadAttempt = 1
        let saved = try #require(
            try await world.repository.save(
                prepared, ifStillCurrent: nil, matching: current, else: prepared))
        let fileID = try #require(saved.files.first).id
        let predecessor = OutboxTaskIdentity(
            jobID: saved.id, fileID: fileID, offset: 400, attempt: 1)
        let successor = OutboxTaskIdentity(jobID: saved.id, fileID: fileID, offset: 400, attempt: 2)
        let legacy = OutboxTaskIdentity(jobID: saved.id, fileID: fileID, offset: 0, attempt: nil)
        world.scheduler.pretend(inFlight: [predecessor, successor, legacy])

        await world.outbox.retry(saved.id)

        #expect(
            world.scheduler.cancellations.contains(predecessor),
            "the task Retry replaced was left running"
        )
        #expect(
            world.scheduler.cancellations.contains(legacy),
            "a task minted before the attempt term was left running"
        )
        #expect(
            !world.scheduler.cancellations.contains(successor),
            "Retry cancelled the very task it had just scheduled"
        )
    }
}

@Suite("The predecessor's answer arrives after its replacement was scheduled")
@MainActor
struct DelayedPredecessorTests {
    /// Retry, and then everything the successor must still own when the predecessor answers.
    private struct Aftermath {
        let world: AttemptWorld
        let job: UploadJob
        let predecessor: OutboxTaskIdentity
        let successor: OutboxTaskIdentity
        let successorChunk: URL
        let predecessorChunk: URL
        let before: UploadJob
    }

    @MainActor
    private func retried() async throws -> Aftermath {
        let world = try makeWorld()
        let stalled = try await stall(world)
        await world.outbox.retry(stalled.job.id)
        let successor = try #require(world.scheduler.uploads.last?.identity)
        let before = try #require(await world.repository.job(stalled.job.id))
        return Aftermath(
            world: world,
            job: stalled.job,
            predecessor: stalled.predecessor,
            successor: successor,
            successorChunk: world.repository.chunkURL(
                jobID: stalled.job.id,
                fileID: stalled.fileID,
                offset: 400,
                attempt: successor.attempt
            ),
            predecessorChunk: world.repository.chunkURL(
                jobID: stalled.job.id,
                fileID: stalled.fileID,
                offset: 400,
                attempt: stalled.predecessor.attempt
            ),
            before: before
        )
    }

    @MainActor
    private func assertSuccessorIntact(_ after: Aftermath) async throws {
        let now = try #require(await after.world.repository.job(after.job.id))
        #expect(now.state == after.before.state, "the predecessor's answer moved the state")
        #expect(
            now.nextAttemptAt == after.before.nextAttemptAt,
            "the predecessor's answer backed the replacement off"
        )
        #expect(now.lastError == after.before.lastError, "the predecessor's answer set an error")
        #expect(
            now.confirmedBytes == after.before.confirmedBytes,
            "the predecessor's answer moved the confirmed offset"
        )
        #expect(
            FileManager.default.fileExists(
                atPath: after.successorChunk.path(percentEncoded: false)
            ),
            "the predecessor's answer deleted the replacement's chunk"
        )
        #expect(
            FileManager.default.fileExists(
                atPath: after.predecessorChunk.path(percentEncoded: false)
            ),
            "the predecessor's own chunk was deleted, so the two share one path"
        )
        after.world.scheduler.consumeEpoch(of: after.predecessor)
        #expect(
            after.world.scheduler.epoch(of: after.successor) != nil,
            "the predecessor's completion consumed the replacement's epoch"
        )
    }

    @Test("the predecessor succeeds late")
    func lateSuccess() async throws {
        let after = try await retried()
        defer { after.world.cleanUp() }
        try await after.world.handler.handle(
            ChunkResult(
                identity: after.predecessor,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":800}"#.utf8)
            )
        )
        try await assertSuccessorIntact(after)
    }

    @Test("the predecessor reports its cancellation")
    func lateCancellation() async throws {
        let after = try await retried()
        defer { after.world.cleanUp() }
        try await after.world.handler.handle(
            ChunkResult(
                identity: after.predecessor,
                statusCode: nil,
                errorDescription: "cancelled"
            )
        )
        try await assertSuccessorIntact(after)
    }

    @Test("the predecessor is refused late")
    func lateRefusal() async throws {
        let after = try await retried()
        defer { after.world.cleanUp() }
        try await after.world.handler.handle(
            ChunkResult(identity: after.predecessor, statusCode: 403)
        )
        try await assertSuccessorIntact(after)
    }
}

/// A manifest as build 22 wrote it, as BYTES.
///
/// Encoding one from today's `UploadJob` would write today's fields, which is precisely the shape
/// this cannot have: the question is whether a manifest that predates every field added since
/// still decodes, and an encoder follows the type the question is about.
private enum BuildTwentyTwo {
    static func manifest(
        jobID: UUID,
        fileID: UUID,
        idempotencyKey: UUID,
        binding: AccountBinding,
        byteSize: Int,
        chunkSize: Int
    ) -> Data {
        Data(
            """
            {
              "id" : "\(jobID.uuidString)",
              "idempotencyKey" : "\(idempotencyKey.uuidString)",
              "content" : "on the beach",
              "visibility" : "PRIVATE",
              "capturedAt" : "2025-06-15T15:06:40Z",
              "files" : [
                {
                  "id" : "\(fileID.uuidString)",
                  "relativePath" : "one.heic",
                  "filename" : "one.heic",
                  "mime" : "image\\/heic",
                  "byteSize" : \(byteSize),
                  "lastModified" : "2025-06-15T15:06:40Z",
                  "uploadUID" : "u1",
                  "bytesConfirmed" : 0,
                  "chunkSize" : \(chunkSize)
                }
              ],
              "binding" : {
                "serverBaseURL" : "\(binding.serverBaseURL.absoluteString)",
                "ownerSubject" : "\(binding.ownerSubject)"
              },
              "state" : "uploading",
              "attemptCount" : 0,
              "nextAttemptAt" : "2025-06-15T15:06:40Z"
            }
            """.utf8
        )
    }
}

/// What a legacy queue looks like on disk, and the ids the raw session would name.
@MainActor
private struct Legacy {
    let world: AttemptWorld
    let jobID: UUID
    let fileID: UUID
    let idempotencyKey: UUID
}

@MainActor
private func legacyQueue(_ world: AttemptWorld, byteSize: Int = 400) throws -> Legacy {
    let jobID = UUID()
    let fileID = UUID()
    let key = UUID()
    let queue = world.root.appending(path: "outbox")
    try BuildTwentyTwo.manifest(
        jobID: jobID,
        fileID: fileID,
        idempotencyKey: key,
        binding: world.binding,
        byteSize: byteSize,
        chunkSize: byteSize
    ).write(to: queue.appending(path: "jobs/\(jobID.uuidString).json"), options: .atomic)
    let media = queue.appending(path: "media/\(jobID.uuidString)")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    try Fixture.content(byteSize).write(to: media.appending(path: "one.heic"), options: .atomic)
    return Legacy(world: world, jobID: jobID, fileID: fileID, idempotencyKey: key)
}

@Suite("The first launch after the update")
@MainActor
struct LegacyAttemptManifestTests {
    @Test("a build-22 manifest decodes, its three-term task is adopted, and the job completes")
    func legacyManifestSurvives() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let legacy = try legacyQueue(world)

        let loaded = try #require(
            try await world.repository.loadJobs().first { $0.id == legacy.jobID },
            "the build-22 manifest did not decode"
        )
        #expect(loaded.content == "on the beach", "the text did not survive the decode")
        #expect(loaded.binding == world.binding, "the binding did not survive the decode")
        #expect(loaded.idempotencyKey == legacy.idempotencyKey, "the key did not survive")
        #expect(loaded.holdReason != .unreadableManifest, "the manifest was quarantined")
        #expect(loaded.files.first?.bytesConfirmed == 0, "the confirmed offset did not survive")

        // A description build 22 wrote names three terms, and this parses one the way the raw
        // session hands it over; the double is then told to report it as in flight, which is
        // the only way this case can hold the reconciliation to adopting it.
        let task = try #require(
            OutboxTaskIdentity(
                taskDescription: "\(legacy.jobID.uuidString)|\(legacy.fileID.uuidString)|0"
            ),
            "a build-22 task description no longer parses"
        )
        world.scheduler.pretend(inFlight: [task])

        await world.outbox.start()

        #expect(world.scheduler.cancellations.isEmpty, "the legacy task was cancelled, not adopted")
        #expect(world.scheduler.uploads.isEmpty, "the adopted task was sent a second time")

        try await world.handler.handle(
            ChunkResult(
                identity: task,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )
        let after = await world.repository.job(legacy.jobID)
        #expect(after == nil, "the adopted legacy job never completed")
        #expect(
            world.completion.idempotencyKeys == [legacy.idempotencyKey],
            "the memo was created under a different key"
        )
    }
}

@Suite("Adoption picks the attempt the manifest names")
@MainActor
struct AttemptAdoptionTests {
    @Test("the obsolete attempt is cancelled and the current one drains to completion")
    func currentAttemptAdopted() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let job = try await enqueue(world, bytes: 400)
        let fileID = try #require(job.files.first?.id)

        var prepared = job
        prepared.state = .uploading
        prepared.files[0].uploadUID = "u1"
        prepared.files[0].chunkSize = 400
        prepared.files[0].uploadAttempt = 1
        try await world.repository.save(prepared)

        // The obsolete one first: a guard that ignores the attempt adopts whatever it reaches.
        let obsolete = OutboxTaskIdentity(jobID: job.id, fileID: fileID, offset: 0)
        let current = OutboxTaskIdentity(jobID: job.id, fileID: fileID, offset: 0, attempt: 1)
        world.scheduler.pretend(inFlight: [obsolete, current])

        // Through a DRAIN, because that is the only path reconciliation is on: `adopt()` awaits
        // the scheduler attachment, and a job whose live task was adopted is not drainable, so
        // this pass cancels and does nothing else.
        await world.outbox.drain()

        #expect(world.scheduler.cancellations == [obsolete], "the obsolete attempt was adopted")
        try await world.handler.handle(
            ChunkResult(
                identity: current,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )
        let after = await world.repository.job(job.id)
        #expect(after == nil, "the job stranded instead of completing")
    }

    @Test("on a build-22 manifest the attempt-less task is the current one")
    func legacyAttemptAdopted() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let legacy = try legacyQueue(world)

        let later = OutboxTaskIdentity(
            jobID: legacy.jobID, fileID: legacy.fileID, offset: 0, attempt: 1
        )
        let named = OutboxTaskIdentity(jobID: legacy.jobID, fileID: legacy.fileID, offset: 0)
        world.scheduler.pretend(inFlight: [later, named])

        await world.outbox.drain()

        #expect(world.scheduler.cancellations == [later], "a task the manifest does not name")
        try await world.handler.handle(
            ChunkResult(
                identity: named,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )
        let after = await world.repository.job(legacy.jobID)
        #expect(after == nil, "the legacy job stranded instead of completing")
    }
}

@Suite("The orphan sweep and a live chunk at a non-zero attempt")
@MainActor
struct AttemptSweepTests {
    @Test("a live chunk survives the sweep and a genuine orphan does not")
    func sweepKeepsLiveChunks() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let job = try await enqueue(world, bytes: 400)
        let file = try #require(job.files.first)

        let live = try await world.repository.sliceChunk(
            job: job, file: file, offset: 0, length: 400, attempt: 1
        )
        let orphan = world.repository.chunkURL(jobID: UUID(), fileID: UUID(), offset: 0)
        try Fixture.content(16).write(to: orphan, options: .atomic)

        let outcome = try await world.repository.sweepOrphans()

        guard case .swept(_, let chunks) = outcome else {
            Issue.record("the sweep deferred: \(outcome)")
            return
        }
        #expect(chunks == 1, "the sweep removed \(chunks) chunks, not the orphan alone")
        #expect(
            FileManager.default.fileExists(atPath: live.path(percentEncoded: false)),
            "the sweep took a live chunk whose name carries an attempt"
        )
        #expect(
            !FileManager.default.fileExists(atPath: orphan.path(percentEncoded: false)),
            "control: a chunk belonging to no job survived, so the sweep did nothing"
        )
    }
}
