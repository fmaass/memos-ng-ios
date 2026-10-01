import Foundation
import Testing

@testable import MemosOutbox

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

@Suite("The terms a retry leaves behind, and the one retry that mints them")
@MainActor
struct SupersededTaskTests {
    @Test("the superseded set is every task older than the saved term, and nothing at or past it")
    func supersededTasksNamesOnlyThePredecessors() {
        let job = UUID()
        let file = UUID()
        let all = [nil, 1, 2, 3].map {
            OutboxTaskIdentity(jobID: job, fileID: file, offset: 0, attempt: $0)
        }

        let superseded = OutboxTaskIdentity.supersededTasks(
            inFlight: all, bumped: [file: 2], jobID: job)

        #expect(superseded.map(\.attempt) == [nil, 1])
        #expect(!superseded.contains(all[2]), "the replacement this retry scheduled")
        #expect(!superseded.contains(all[3]), "a successor a later retry minted")

        // The control: the same tasks belong to another capture, and none of them is this one's.
        #expect(
            OutboxTaskIdentity.supersededTasks(
                inFlight: all, bumped: [file: 2], jobID: UUID()
            ).isEmpty)
    }

    @Test("a second Try again landing inside the first is refused, so one term is minted")
    func aSecondTryAgainInsideTheFirstIsRefused() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let stalled = try await stall(world)
        let current = try #require(await world.repository.job(stalled.job.id))
        var prepared = current
        prepared.files[0].uploadAttempt = 1
        let saved = try #require(
            try await world.repository.save(
                prepared, ifStillCurrent: nil, matching: current, else: prepared))
        let fileID = try #require(saved.files.first).id
        let predecessor = OutboxTaskIdentity(
            jobID: saved.id, fileID: fileID, offset: 400, attempt: 1)
        world.scheduler.pretend(inFlight: [predecessor])
        let entered = Latch()
        let released = Latch()
        // Parks the first retry where it enumerates the live tasks — after it has saved its bump,
        // which is the window a second press has to be refused in.
        world.scheduler.beforeInFlight = {
            await entered.open()
            await released.wait()
        }
        let first = Task { await world.outbox.retry(saved.id) }
        #expect(
            await entered.wait(within: 2), "the first Try again never reached `inFlight()`")

        await world.outbox.retry(saved.id)

        await released.open()
        await first.value

        let after = try #require(await world.repository.job(saved.id))
        #expect(after.files[0].uploadAttempt == 2, "two overlapping retries minted two terms")
        #expect(
            world.scheduler.cancellations.allSatisfy { ($0.attempt ?? -1) < 2 },
            "a retry handed back the successor another retry had just scheduled")
    }
}

/// A protocol that answers nothing, so a task that was started stays started.
///
/// The enumeration below is the one production line no double stands in for: it reads back what a
/// real session is holding. These tasks exist only to BE read back, so the loading they begin
/// never finishes and no byte leaves the machine.
private final class SilentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {}

    override func stopLoading() {}
}

/// What the scheduler makes of the descriptions it finds on a session it did not write.
///
/// After a relaunch every description on the session was written by whatever build put it there,
/// so the reconciliation has to read a build-22 three-term one and a four-term one from this build
/// side by side. Both are written here as raw strings for that reason: composed through
/// `OutboxTaskIdentity` they would only prove the type can read its own spelling back.
@Suite("The real scheduler reads back what the session is holding")
struct BackgroundSchedulerEnumerationTests {

    @Test("a description build 22 wrote is enumerated beside one this build writes")
    func bothTermFormsAreEnumerated() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://example.invalid/api/uploads/u1"))
        let jobID = UUID()
        let legacyFileID = UUID()
        let currentFileID = UUID()
        let legacy = session.dataTask(with: url)
        legacy.taskDescription = "\(jobID.uuidString)|\(legacyFileID.uuidString)|0"
        let current = session.dataTask(with: url)
        current.taskDescription = "\(jobID.uuidString)|\(currentFileID.uuidString)|400|2"
        legacy.resume()
        current.resume()

        let inFlight = await BackgroundChunkScheduler(session: session).inFlight()

        #expect(inFlight.count == 2, "the session was holding two tasks that name a chunk")
        #expect(inFlight.allSatisfy { $0.jobID == jobID }, "the capture was not read back")
        let readLegacy = try #require(
            inFlight.first { $0.fileID == legacyFileID },
            "a three-term description was dropped by the enumeration"
        )
        #expect(readLegacy.attempt == nil, "a term that is not there was read as an attempt")
        #expect(readLegacy.offset == 0)
        let readCurrent = try #require(
            inFlight.first { $0.fileID == currentFileID },
            "a four-term description was dropped by the enumeration"
        )
        #expect(readCurrent.attempt == 2, "the term that tells the attempts apart was dropped")
        #expect(readCurrent.offset == 400)
    }
}

/// Holds each answer on the gate its body names, and records which answers have come back out and
/// every notice that a listed answer settled, in the order they reached it.
private actor GatedChunkHandler: OutboxChunkHandling {
    private let gates: [String: TestGate]
    private(set) var returned: [String] = []
    /// The answers' names and "wake" for each notice, in arrival order.
    private(set) var events: [String] = []

    init(_ gates: [String: TestGate]) { self.gates = gates }

    var wakes: Int { events.filter { $0 == "wake" }.count }

    func handle(_ result: ChunkResult) async {
        let name = String(decoding: result.body, as: UTF8.self)
        await gates[name]?.pass()
        returned.append(name)
        events.append(name)
    }

    func listedAnswerSettled() async { events.append("wake") }
}

/// A finished task leaves `session.allTasks` before its answer reaches the row: the engine's
/// `handle` suspends on the row read first. Listed by the session alone, that chunk looked idle in
/// the window, and a reschedule could mint a second task under the SAME identity while the first
/// answer was still on its way — two answers racing one row.
///
/// Each scheduler here runs over a session holding no task and shares the delegate that session
/// reports to, so anything `inFlight()` lists came from the delegate, not from the session.
@Suite("An answer on its way to the row is still in flight")
struct PendingDeliveryInFlightTests {
    private struct Rig {
        let scheduler: BackgroundChunkScheduler
        let delegate: OutboxSessionDelegate
        let session: URLSession

        init() {
            let delegate = OutboxSessionDelegate()
            let session = URLSession(
                configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            self.delegate = delegate
            self.session = session
            self.scheduler = BackgroundChunkScheduler(session: session, delegate: delegate)
        }
    }

    private static func answer(_ identity: OutboxTaskIdentity, _ name: String) -> ChunkResult {
        ChunkResult(identity: identity, statusCode: 200, body: Data(name.utf8))
    }

    /// Waits, bounded, for the bookkeeping a delivery's own task does after its handling returned.
    /// A mutation that never lets it happen turns the test red instead of parking the bundle.
    private static func eventually(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test("an answer is listed while its handling is held, and gone once it returns")
    func aHeldAnswerIsListedUntilItsHandlingReturns() async throws {
        let rig = Rig()
        defer { rig.session.invalidateAndCancel() }
        let held = TestGate()
        let handler = GatedChunkHandler(["A": held])
        await rig.delegate.attach(handler)
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 400, attempt: 1)

        rig.delegate.deliver(Self.answer(identity, "A"))
        await held.waitUntilParked()

        #expect(await rig.session.allTasks.isEmpty, "the premise: the session holds no task")
        #expect(
            await rig.scheduler.inFlight() == [identity],
            """
            an answer whose handling has not returned was not listed — a reschedule in this \
            window mints a second task under the same identity
            """
        )

        await held.open()
        #expect(try await Self.eventually { await handler.returned == ["A"] })
        #expect(
            try await Self.eventually { await rig.scheduler.inFlight().isEmpty },
            "an answer that has been handled is still listed, so its chunk never looks idle again"
        )
    }

    /// Two tasks can carry one identity: a 404 clears the upload without moving the attempt, and
    /// the handler of the first then schedules the next at the same offset and attempt. The first
    /// answer finishing must not take the second one's entry with it.
    ///
    /// The first arrives before adoption and is replayed; the second arrives once the handler is
    /// attached, so both are inside `handle` at once. The replay is what `attach` awaits, so once
    /// it has returned the first answer's bookkeeping is done — no timing involved.
    @Test("two answers for one identity keep it listed until the second has been handled")
    func overlappingAnswersKeepTheIdentityListedUntilTheSecondReturns() async throws {
        let rig = Rig()
        defer { rig.session.invalidateAndCancel() }
        let first = TestGate()
        let second = TestGate()
        let handler = GatedChunkHandler(["A": first, "B": second])
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 0, attempt: 2)

        rig.delegate.deliver(Self.answer(identity, "A"))
        #expect(
            await rig.scheduler.inFlight() == [identity],
            "an answer waiting for adoption was not listed"
        )

        let adoption = Task { await rig.delegate.attach(handler) }
        await first.waitUntilParked()
        rig.delegate.deliver(Self.answer(identity, "B"))
        await second.waitUntilParked()
        #expect(
            await rig.scheduler.inFlight() == [identity],
            "one identity with two answers outstanding is listed once"
        )

        await first.open()
        await adoption.value
        #expect(await handler.returned == ["A"], "the premise: the first answer was handled")
        #expect(
            await handler.wakes == 0,
            "a pass was asked for while a second answer for the identity was still on its way"
        )
        #expect(
            await rig.scheduler.inFlight() == [identity],
            """
            the first answer's return erased the entry of a second one for the same identity \
            that is still on its way to the row
            """
        )

        await second.open()
        #expect(try await Self.eventually { await handler.returned == ["A", "B"] })
        #expect(
            try await Self.eventually { await rig.scheduler.inFlight().isEmpty },
            "both answers were handled and the identity is still listed"
        )
        #expect(
            try await Self.eventually { await handler.wakes == 1 },
            "the last answer for a listed identity settled after the replay and asked for no pass"
        )
    }

    /// Long enough for a notice already on its way to land, so an assertion that none came is not
    /// read before one could have.
    private static func quietPeriod() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    /// The audit's stall, at the delegate: a pass that read the identity left the row to the
    /// answer, so the answer's settling is what asks for the next pass.
    @Test("a listed answer asks for one pass once its handling returns")
    func aListedAnswerAsksForOnePass() async throws {
        let rig = Rig()
        defer { rig.session.invalidateAndCancel() }
        let held = TestGate()
        let handler = GatedChunkHandler(["A": held])
        await rig.delegate.attach(handler)
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 400, attempt: 1)

        rig.delegate.deliver(Self.answer(identity, "A"))
        await held.waitUntilParked()
        #expect(await rig.scheduler.inFlight() == [identity], "the premise: a read listed it")
        #expect(await handler.wakes == 0, "a pass was asked for before the answer was handled")

        await held.open()
        #expect(try await Self.eventually { await handler.wakes == 1 })
        try await Self.quietPeriod()
        #expect(await handler.events == ["A", "wake"], "one settling, one notice")
    }

    @Test("an answer no read listed asks for nothing")
    func anUnlistedAnswerAsksForNothing() async throws {
        let rig = Rig()
        defer { rig.session.invalidateAndCancel() }
        let handler = GatedChunkHandler([:])
        await rig.delegate.attach(handler)
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 400, attempt: 1)

        rig.delegate.deliver(Self.answer(identity, "A"))
        #expect(try await Self.eventually { await handler.returned == ["A"] })
        try await Self.quietPeriod()
        #expect(await handler.wakes == 0, "no pass left this row to its answer, yet one was asked")
    }

    @Test("two live answers for a listed identity: only the last one's settling asks")
    func onlyTheLastOfTwoLiveAnswersAsks() async throws {
        let rig = Rig()
        defer { rig.session.invalidateAndCancel() }
        let first = TestGate()
        let second = TestGate()
        let handler = GatedChunkHandler(["A": first, "B": second])
        await rig.delegate.attach(handler)
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 0, attempt: 2)

        rig.delegate.deliver(Self.answer(identity, "A"))
        rig.delegate.deliver(Self.answer(identity, "B"))
        await first.waitUntilParked()
        await second.waitUntilParked()
        #expect(await rig.scheduler.inFlight() == [identity], "the premise: a read listed it")

        await first.open()
        #expect(try await Self.eventually { await handler.returned == ["A"] })
        try await Self.quietPeriod()
        #expect(await handler.wakes == 0, "a pass was asked for with a second answer still out")

        await second.open()
        #expect(try await Self.eventually { await handler.wakes == 1 })
        try await Self.quietPeriod()
        #expect(await handler.events == ["A", "B", "wake"])
    }

    /// Case A of the premise gate: whatever listed a buffered answer — a pass the engine started
    /// itself before adoption — the replay that settles it must still ask, once it is over.
    @Test("a buffered answer a read listed is asked for when the replay is over")
    func aListedBufferedAnswerIsAskedForAfterTheReplay() async throws {
        let rig = Rig()
        defer { rig.session.invalidateAndCancel() }
        let handler = GatedChunkHandler([:])
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 400, attempt: 1)

        rig.delegate.deliver(Self.answer(identity, "A"))
        #expect(await rig.scheduler.inFlight() == [identity], "the premise: a read listed it")

        await rig.delegate.attach(handler)
        #expect(
            await handler.events == ["A", "wake"],
            "the replay settled a listed answer and the pass it owed was never asked for"
        )
    }

    /// Case B of the premise gate, live first: a live answer for the identity settles while the
    /// replayed one is still held, and the replayed one settles last.
    @Test("a live answer settling first leaves the ask to the replayed one, after the replay")
    func aLiveAnswerFirstLeavesTheAskToTheReplay() async throws {
        let rig = Rig()
        defer { rig.session.invalidateAndCancel() }
        let replayed = TestGate()
        let handler = GatedChunkHandler(["R": replayed])
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 0, attempt: 2)

        rig.delegate.deliver(Self.answer(identity, "R"))
        #expect(await rig.scheduler.inFlight() == [identity], "the premise: a read listed it")
        let adoption = Task { await rig.delegate.attach(handler) }
        await replayed.waitUntilParked()
        rig.delegate.deliver(Self.answer(identity, "L"))
        #expect(try await Self.eventually { await handler.returned == ["L"] })
        try await Self.quietPeriod()
        #expect(await rig.scheduler.inFlight() == [identity], "the replayed answer is still out")
        #expect(await handler.wakes == 0, "a pass was asked for with the replayed answer still out")

        await replayed.open()
        await adoption.value
        #expect(await handler.events == ["L", "R", "wake"])
    }

    /// A pass asked for mid-replay would run beside it; the notice waits for the replay's end.
    ///
    /// The replayed identity has a second, live answer still out when the replay ends, so its own
    /// settling cannot reach zero inside the replay: the one notice the replay's end may send is
    /// the live answer's, and nothing else can stand in for it if that one is lost.
    ///
    /// Listing the live identity before the buffered answer arrives cannot be staged: no live
    /// answer exists before `attach`, and any listing marks every counted identity. Holding the
    /// buffered identity live past the replay is what keeps it from supplying the lost notice.
    @Test("a listed live answer settling mid-replay asks only once the replay is over")
    func aNoticeMidReplayWaitsForTheReplay() async throws {
        let rig = Rig()
        defer { rig.session.invalidateAndCancel() }
        let replayed = TestGate()
        let later = TestGate()
        let live = TestGate()
        let handler = GatedChunkHandler(["R": replayed, "R2": later, "L": live])
        let buffered = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 0, attempt: 1)
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 400, attempt: 1)

        rig.delegate.deliver(Self.answer(buffered, "R"))
        let adoption = Task { await rig.delegate.attach(handler) }
        await replayed.waitUntilParked()
        rig.delegate.deliver(Self.answer(buffered, "R2"))
        await later.waitUntilParked()
        rig.delegate.deliver(Self.answer(identity, "L"))
        await live.waitUntilParked()
        #expect(await rig.scheduler.inFlight().contains(identity), "the premise: a read listed it")

        await live.open()
        #expect(
            try await Self.eventually { await !rig.scheduler.inFlight().contains(identity) },
            "the premise: the live answer settled"
        )
        try await Self.quietPeriod()
        #expect(await handler.wakes == 0, "a pass was asked for while the replay was running")

        await replayed.open()
        await adoption.value
        #expect(
            await handler.events == ["L", "R", "wake"],
            "the live answer's notice, owed during the replay, was not sent at its end"
        )

        await later.open()
        #expect(try await Self.eventually { await handler.wakes == 2 })
        #expect(await handler.events == ["L", "R", "wake", "R2", "wake"])
    }

    /// Owed once the first replayed answer settles, but sent only when the whole replay is over:
    /// a notice sent between two replayed answers would start a pass beside the second.
    @Test("a notice owed by the first of two replayed answers waits for the second")
    func aNoticeOwedEarlyInTheReplayWaitsForItsEnd() async throws {
        let rig = Rig()
        defer { rig.session.invalidateAndCancel() }
        let second = TestGate()
        let handler = GatedChunkHandler(["B": second])
        let listed = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 400, attempt: 1)
        let unlisted = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 0, attempt: 1)

        rig.delegate.deliver(Self.answer(listed, "A"))
        #expect(await rig.scheduler.inFlight() == [listed], "the premise: a read listed it")
        rig.delegate.deliver(Self.answer(unlisted, "B"))

        let adoption = Task { await rig.delegate.attach(handler) }
        await second.waitUntilParked()
        #expect(await handler.returned == ["A"], "the premise: the first replayed answer returned")
        #expect(await handler.wakes == 0, "a pass was asked for between two replayed answers")

        await second.open()
        await adoption.value
        #expect(await handler.events == ["A", "B", "wake"])
    }
}

/// The stall the first version of this count was reverted for, end to end. The real session
/// delegate hands a 409 to the real engine. The handler asks the server where the upload stands,
/// finds a network it may not use and parks the capture — `OutboxEngine.handle`, the
/// `permitsNetwork()` guard of its ask-the-server branch (OutboxEngine.swift:1177-1181 on
/// c5a2254) — while a pass that listed the answer as in flight left the row to it. Nothing else
/// happens after that, and the capture must move on regardless.
/// Every list the engine's passes read from the delegate, in order.
private final class Enumerations: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[OutboxTaskIdentity]] = []

    func record(_ listed: [OutboxTaskIdentity]) { lock.withLock { lists.append(listed) } }

    var all: [[OutboxTaskIdentity]] { lock.withLock { lists } }
}

@Suite("A row a pass left to its answer is planned again")
struct ListedAnswerStallTests {
    @Test("a capture parked by an answer a pass had listed moves on with no other trigger")
    func aParkedCaptureAPassListedMovesOn() async throws {
        let write = TestGate()
        let harness = try await Harness.make(
            bytes: 1000,
            http: .standard(chunkSize: 400),
            holdingFirstSave: write,
            // The handler's read is the first and forbids the network; every read after it allows
            // it. Nothing calls `move`, so no path change asks for a pass.
            network: StubNetworkPath(.cellular, thenAfterOneRead: .wifi),
            allowsMobileData: false
        )
        defer { harness.cleanUp() }
        let delegate = OutboxSessionDelegate()
        let session = URLSession(
            configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let listing = BackgroundChunkScheduler(session: session, delegate: delegate)
        // What the engine's own passes enumerated, recorded as they read it: the test itself never
        // reads the delegate's listing, because a read is what marks an answer as left to it.
        let enumerated = Enumerations()
        harness.scheduler.alsoListing = {
            let listed = await listing.inFlight()
            enumerated.record(listed)
            return listed
        }

        var job = harness.job
        job.files[0].uploadUID = "u1"
        job.files[0].chunkSize = 400
        job.files[0].bytesConfirmed = 400
        job.files[0].uploadAttempt = 1
        job.state = .uploading
        job.nextAttemptAt = harness.now
        try await harness.repository.save(job)
        let seeded = try #require(await harness.reload())
        let identity = OutboxTaskIdentity(
            jobID: job.id, fileID: job.files[0].id, offset: 400, attempt: 1)

        // The prerequisites, asserted rather than assumed: a chunk-lane row, so no whole-lane
        // deadline can arm the engine's timer, and no pass running or asked for once the empty
        // adoption has returned.
        #expect(seeded.lane == .chunk)
        #expect(!OutboxEngine.claimsWhole(seeded))
        await delegate.attach(harness.engine)
        let waited = Counter()
        await harness.engine.untilQuiescent(parked: { waited.increment() })
        #expect(waited.count == 0, "construction or the empty adoption left a pass to come")

        delegate.deliver(ChunkResult(identity: identity, statusCode: 409))
        // The park's write, held unwritten.
        await write.waitUntilParked()

        // The one pass, standing for the trigger that started it. The held write does not stop it
        // finishing: it lists the answer, adopts it and leaves the row exactly as it found it.
        #expect(enumerated.all.isEmpty, "the premise: nothing enumerated before the pass")
        await harness.engine.drain()
        #expect(enumerated.all == [[identity]], "the pass did not see the answer out")
        #expect(harness.scheduler.uploads.isEmpty, "the pass re-sent a chunk whose answer was out")
        #expect(await harness.reload() == seeded, "the pass moved a row it had left to the answer")

        await write.open()
        // Nothing but reads from here on.
        var moved = false
        for _ in 0..<300 where !moved {
            moved = harness.scheduler.uploads.contains { $0.identity.jobID == job.id }
            if !moved { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(moved, "the capture stalled: parked by an answer a pass had left it to")
    }
}
