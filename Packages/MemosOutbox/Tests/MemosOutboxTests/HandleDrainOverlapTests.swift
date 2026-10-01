import Foundation
import Testing

@testable import MemosOutbox

/// A chunk answer handled while a drain pass runs over the same capture (MEMNG-302).
///
/// `handle` does not take the drain's `isDraining` guard. It moves the hand-off generation before
/// its first suspension, but takes a hand-off slot only just before its write, so a pass whose
/// reconcile starts after that first move and settles while the answer is suspended in between is
/// fenced by neither. And the bookkeeping write before a hand-off is a full-value fence: an answer
/// that wrote the next cursor and a pass that read it afterwards both write the same `.uploading`
/// row, and both writes land. Nothing in the engine itself keeps the two apart.
///
/// What keeps the pass off the row is the listing. An answer the session's delegate has not
/// finished handing over is still in `inFlight()` (MEMNG-537), so a pass in that window adopts the
/// row rather than draining it, and the answer is the one path that moves it on. This is that
/// overlap with the production listing in front of the engine: the real `BackgroundChunkScheduler`
/// over a session with no tasks, plus every chunk the scripted scheduler was handed that nobody has
/// answered yet — what the background session's own `allTasks` would hold.
@Suite("A chunk answer and a drain pass over the same capture")
struct HandleDrainOverlapTests {
    private static func eventually(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// Runs `work` and waits for it, but never forever: neither a drain nor `untilQuiescent`
    /// answers a cancellation, so the wait is a latch with a deadline. On a timeout the work is
    /// left running, and the test's own `defer` releases whatever it was held on.
    private static func bounded(
        within seconds: Double = 10, _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let done = Latch()
        Task {
            await work()
            await done.open()
        }
        return await done.wait(within: seconds)
    }

    @Test("a pass run while an answer is being handled hands over no chunk of its own")
    func aPassInsideAnAnswerHandsOverNothing() async throws {
        let harness = try await Harness.make(
            bytes: 1200,
            http: .standard(chunkSize: 400),
            persistence: { OverlapPersistence($0) }
        )
        defer { harness.cleanUp() }
        let persistence = try #require(harness.persistence as? OverlapPersistence)
        // Whatever fails below, nothing stays held once the test is over.
        defer { Task { await persistence.release() } }
        let engine = harness.engine
        let scheduler = harness.scheduler
        let delegate = OutboxSessionDelegate()
        let session = URLSession(
            configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let listing = BackgroundChunkScheduler(session: session, delegate: delegate)
        let answered = AnsweredChunks()
        let enumerations = Counter()
        scheduler.alsoListing = {
            enumerations.increment()
            let running = scheduler.uploads.map(\.identity).filter { !answered.contains($0) }
            return await listing.inFlight() + running
        }
        await delegate.attach(harness.engine)
        #expect(
            await Self.bounded { await engine.untilQuiescent() },
            "the empty adoption left a pass running")

        #expect(await Self.bounded { await engine.drain() }, "the first pass never returned")
        let first = try #require(scheduler.uploads.first?.identity)
        #expect(scheduler.uploads.count == 1, "the premise: one chunk is on its way")
        #expect(first.offset == 0)

        // The pass's read of the row is answered only once the answer it released has handed its
        // own chunk over — the order in which both hand-offs would land on one equal write.
        let handedOver = persistence.answerHandedOver
        scheduler.beforeUpload = { Task { await handedOver.open() } }
        await persistence.arm()
        answered.insert(first)
        delegate.deliver(
            ChunkResult(
                identity: first,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )
        // Held at its read of the row: past the generation it moves on entry, short of the slot
        // it takes before its write.
        #expect(
            await persistence.answerHeld.wait(within: 5), "the answer never reached the row")

        #expect(
            await Self.bounded { await engine.drain() },
            "the overlapping pass never returned")
        #expect(
            scheduler.uploads.map(\.identity) == [first],
            """
            the pass planned a row whose answer was still out and handed a chunk over beside it: \
            \(scheduler.uploads.map(\.identity.offset))
            """
        )

        let passes = enumerations.count
        await persistence.release()
        #expect(
            try await Self.eventually { scheduler.uploads.count >= 2 },
            "the answer never handed its next chunk over")
        // The pass the settled answer asks for (MEMNG-537) plans the row again, and must find the
        // chunk the answer handed over still running.
        #expect(
            try await Self.eventually { enumerations.count > passes },
            "the settled answer asked for no pass")
        #expect(
            await Self.bounded { await engine.untilQuiescent() }, "the engine never went quiet")
        // A hold that ran out changed the interleaving this test is about, whatever it then saw.
        let timeouts = await persistence.timeouts
        #expect(timeouts.isEmpty, "\(timeouts)")

        let identities = scheduler.uploads.map(\.identity)
        #expect(
            identities.count == Set(identities).count,
            "one chunk was handed over twice: \(identities.map(\.offset))")
        #expect(identities.map(\.offset) == [0, 400])
        #expect(await harness.reload()?.files[0].bytesConfirmed == 400)
    }
}

/// The chunks a test has answered, so the emulated `allTasks` stops listing them.
private final class AnsweredChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: Set<OutboxTaskIdentity> = []

    func insert(_ identity: OutboxTaskIdentity) {
        _ = lock.withLock { identities.insert(identity) }
    }

    func contains(_ identity: OutboxTaskIdentity) -> Bool {
        lock.withLock { identities.contains(identity) }
    }
}

/// The real queue, with the engine's next two reads of a row choreographed once armed.
///
/// The first read is the answer's, and it is held. The second can only be a pass's, because the
/// answer is still held inside the first; it releases the answer, and is answered itself only once
/// the answer has handed its chunk over. A pass that never reads the row leaves the answer held
/// until the test lets it go. Every hold is bounded, so a regression fails rather than parks the
/// bundle, and a hold that runs out is recorded: the test fails on it, because the interleaving it
/// then ran is not the one it set up.
private actor OverlapPersistence: OutboxPersisting {
    private let inner: OutboxRepository
    private var armed = false
    private var reads = 0
    /// Every hold that ran out instead of being released: the test asserts there were none.
    private(set) var timeouts: [String] = []
    /// Opened when the answer's read is held.
    nonisolated let answerHeld = Latch()
    /// Opened by the pass's read of the row, or by the test.
    nonisolated let answerReleased = Latch()
    /// Opened when a chunk is handed over after arming.
    nonisolated let answerHandedOver = Latch()

    init(_ inner: OutboxRepository) {
        self.inner = inner
    }

    func arm() {
        armed = true
    }

    /// Lets a held answer go and stops choreographing: every read after this one passes.
    func release() async {
        armed = false
        await answerReleased.open()
    }

    func job(_ id: UUID) async -> UploadJob? {
        if armed {
            reads += 1
            switch reads {
            case 1:
                await answerHeld.open()
                if !(await answerReleased.wait(within: 5)) {
                    timeouts.append("the answer's read was held past its bound")
                }
            case 2:
                await answerReleased.open()
                if !(await answerHandedOver.wait(within: 5)) {
                    timeouts.append("the pass's read waited past the hand-over's bound")
                }
            default:
                break
            }
        }
        return await inner.job(id)
    }

    func loadJobs() async throws -> [UploadJob] { try await inner.loadJobs() }

    func save(_ job: UploadJob) async throws { try await inner.save(job) }

    func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async throws -> UploadJob? {
        try await inner.save(job, ifStillCurrent: epoch, matching: snapshot, else: fallback)
    }

    func delete(_ job: UploadJob) async { await inner.delete(job) }

    func delete(_ job: UploadJob, ifStillCurrent snapshot: UploadJob) async -> Bool {
        await inner.delete(job, ifStillCurrent: snapshot)
    }

    func sweepOrphans() async throws -> SweepOutcome { try await inner.sweepOrphans() }

    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int, attempt: Int?
    ) async throws -> URL {
        try await inner.sliceChunk(
            job: job, file: file, offset: offset, length: length, attempt: attempt
        )
    }

    func removeChunk(at url: URL) async { await inner.removeChunk(at: url) }

    nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64, attempt: Int?) -> URL {
        inner.chunkURL(jobID: jobID, fileID: fileID, offset: offset, attempt: attempt)
    }

    nonisolated func mediaURL(job: UploadJob, file: OutboxFile) -> URL {
        inner.mediaURL(job: job, file: file)
    }

    nonisolated var tails: WholeTailStaging { inner.tails }

    func applyFileAnswer(
        jobID: UUID,
        fileID: UUID,
        attempt: Int,
        outcome: WholeFileChange,
        presented: WholeTaskProvenance,
        at instant: Date
    ) async throws -> UploadJob? {
        try await inner.applyFileAnswer(
            jobID: jobID, fileID: fileID, attempt: attempt, outcome: outcome,
            presented: presented, at: instant
        )
    }
}
