import Foundation
import MemosOutbox
import Testing

/// One witness per ORDINARY write the drain makes (MEMNG-289).
///
/// The refusal writes were fenced by MEMNG-270; every other write still landed unconditionally
/// after its awaits, so a response that outlived the capture could resurrect a state the operation
/// had left — the person released it, removed it, another pass advanced or finished it. Each test
/// below drives the real engine to ONE such write, lands another pass inside that write's hop into
/// the repository, and asserts the manifest is what the interleaving left rather than what the
/// overtaken pass was holding.
///
/// The shape is the same every time, which is the point: the site is named by the CANDIDATE it
/// offers (`InterferingPersistence`), the other pass is one of `Overtake`'s two, and the assertion
/// is on the row on disk. A witness that cannot fail is not a witness — every one of these was run
/// with its own site's fence replaced by an unconditional `repository.save(candidate)` and had to
/// go red.
@Suite("Every ordinary write is fenced on the job it was decided from")
struct OrdinaryWriteFenceTests {

    // MARK: - drainOnce

    /// :134 — the account-mismatch hold, written before any network is touched.
    @Test("a capture that left the outbox is not put back by an account-mismatch hold")
    func accountMismatchHold() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            binding: Fixture.binding(owner: "someone-else"),
            overtakenBy: .finished,
            whenWriting: { $0.holdReason == .accountMismatch }
        )
        defer { world.harness.cleanUp() }

        await world.harness.engine.drain()

        await world.expectOvertaken()
        #expect(
            await world.harness.reload() == nil,
            "a hold put back a capture that had already left the outbox"
        )
    }

    /// :169 — "Try again" on a pending row.
    @Test("a capture that left the outbox is not put back by a release")
    func release() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            overtakenBy: .finished,
            whenWriting: { $0.state == .waiting && $0.holdReason == nil }
        )
        defer { world.harness.cleanUp() }
        try await world.harness.repository.save(
            world.harness.job.held(.serverRefused, error: "The server refused this memo.")
        )

        await world.harness.engine.release(jobID: world.harness.job.id)

        await world.expectOvertaken()
        #expect(
            await world.harness.reload() == nil,
            "a release put back a capture that had already left the outbox"
        )
    }

    // MARK: - advance

    /// :184 — the planner's hold, reached from a chunk answer that re-enters `advance`.
    @Test("a hold the planner asked for does not overwrite a newer answer")
    func plannerHold() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            binding: Fixture.binding(owner: "someone-else"),
            overtakenBy: .advanced(123),
            whenWriting: { $0.holdReason == .accountMismatch }
        )
        defer { world.harness.cleanUp() }
        let started = try await world.resumed(state: .uploading)

        await world.harness.engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(
                    jobID: started.id, fileID: started.files[0].id, offset: 0
                ),
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        await world.expectOvertaken()
        let saved = try #require(await world.harness.reload())
        #expect(saved.files[0].bytesConfirmed == 123, "the hold wrote over a newer count")
        #expect(saved.holdReason == nil, "and held a capture another pass owns")
    }

    /// :219 — out of steps in one pass, spaced out rather than spun.
    @Test("a capture that left the outbox is not put back by the step budget's back-off")
    func stepBudgetBackOff() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400, headOffset: 400),
            completion: ScriptedCompletion(
                [],
                repeating: .unlinkable(
                    UploadsUnlinkableFailure(
                        missingUploadUIDs: [], incompleteUploadUIDs: ["u1"]
                    )
                )
            ),
            overtakenBy: .finished,
            whenWriting: { $0.lastError == "The server kept asking to start over." }
        )
        defer { world.harness.cleanUp() }
        _ = try await world.resumed(state: .waiting, bytesConfirmed: 400)

        await world.harness.engine.drain()

        await world.expectOvertaken()
        #expect(
            await world.harness.reload() == nil,
            "the step budget put back a capture that had already left the outbox"
        )
    }

    /// :263 — the capture parks for a network it may use.
    @Test("a capture that left the outbox is not put back by a network park")
    func waitForNetwork() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            network: StubNetworkPath(.cellular),
            overtakenBy: .finished,
            whenWriting: { $0.waitReason == .homeNetwork }
        )
        defer { world.harness.cleanUp() }

        await world.harness.engine.drain()

        await world.expectOvertaken()
        #expect(world.harness.http.requests.isEmpty, "the premise: nothing was sent")
        #expect(
            await world.harness.reload() == nil,
            "a network park put back a capture that had already left the outbox"
        )
    }

    // MARK: - startUpload

    /// :292 — the upload session could not be asked for.
    @Test("a capture that left the outbox is not put back by an unreachable server")
    func startUploadTransportFailure() async throws {
        let world = try await fenced(
            bytes: 400,
            http: ScriptedHTTP { request in
                guard request.httpMethod == "GET" else { throw Unreachable() }
                return OutboxHTTPResponse(statusCode: 200)
            },
            overtakenBy: .finished,
            whenWriting: { $0.lastError == "The server could not be reached." }
        )
        defer { world.harness.cleanUp() }

        await world.harness.engine.drain()

        await world.expectOvertaken()
        #expect(
            await world.harness.reload() == nil,
            "a back-off put back a capture that had already left the outbox"
        )
    }

    /// :323 — the session the server just handed out. The one write that must land before a chunk
    /// may be sent against the uid it names.
    @Test("an upload session is not written onto a capture that has left the outbox")
    func startUploadSession() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            overtakenBy: .finished,
            whenWriting: { $0.files.first?.uploadUID != nil }
        )
        defer { world.harness.cleanUp() }

        await world.harness.engine.drain()

        await world.expectOvertaken()
        #expect(
            await world.harness.reload() == nil,
            "an upload session put back a capture that had already left the outbox"
        )
        #expect(
            world.harness.scheduler.uploads.isEmpty,
            "and nothing was sent against a uid nobody wrote down"
        )
    }

    // MARK: - schedule

    /// :341 — the chunk could not be sliced out of the original.
    @Test("a capture that left the outbox is not put back by a failed slice")
    func sliceFailure() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            overtakenBy: .finished,
            whenWriting: { $0.attemptCount == 1 }
        )
        defer { world.harness.cleanUp() }
        let started = try await world.resumed(state: .waiting)
        // The original is gone, which is the one thing a slice cannot recover from.
        try FileManager.default.removeItem(
            at: world.harness.repository.mediaURL(job: started, file: started.files[0])
        )

        await world.harness.engine.drain()

        await world.expectOvertaken()
        #expect(
            await world.harness.reload() == nil,
            "a back-off put back a capture that had already left the outbox"
        )
        #expect(world.harness.scheduler.uploads.isEmpty)
    }

    /// :361 — the bookkeeping write, which since MEMNG-289 lands BEFORE the hand-off. A chunk is
    /// not put on the background session for a capture whose row has moved on.
    @Test("no chunk is handed over when the write that records it is refused")
    func uploadingBookkeeping() async throws {
        let world = try await fenced(
            bytes: 1000,
            http: .standard(chunkSize: 400),
            overtakenBy: .advanced(123),
            whenWriting: { $0.state == .uploading }
        )
        defer { world.harness.cleanUp() }
        _ = try await world.resumed(state: .waiting)

        await world.harness.engine.drain()

        await world.expectOvertaken()
        let saved = try #require(await world.harness.reload())
        #expect(saved.files[0].bytesConfirmed == 123, "the bookkeeping wrote over a newer count")
        #expect(
            world.harness.scheduler.uploads.isEmpty,
            "a chunk went out for a state nobody wrote"
        )
    }

    // MARK: - complete

    /// :409 — the memo is about to be created, and the row says so first.
    @Test("a create is not started against a capture another pass has moved on")
    func creatingMemo() async throws {
        let completion = ScriptedCompletion([.created(uid: "m1")])
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            completion: completion,
            overtakenBy: .advanced(123),
            whenWriting: { $0.state == .creating }
        )
        defer { world.harness.cleanUp() }
        _ = try await world.resumed(state: .waiting, bytesConfirmed: 400)

        await world.harness.engine.drain()

        await world.expectOvertaken()
        #expect(completion.idempotencyKeys.isEmpty, "a memo was created for a row that had moved")
        let saved = try #require(await world.harness.reload())
        #expect(saved.files[0].bytesConfirmed == 123)
        #expect(saved.state != JobState.creating)
    }

    /// :423 — the server refused to link the files and named none this job carries.
    @Test("a capture that left the outbox is not put back by an unlinkable refusal")
    func unlinkableWithNothingToRecover() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            completion: ScriptedCompletion(
                [
                    .unlinkable(
                        UploadsUnlinkableFailure(
                            missingUploadUIDs: ["not-this-job"], incompleteUploadUIDs: []
                        )
                    )
                ],
                repeating: .retry("not again")
            ),
            overtakenBy: .finished,
            whenWriting: { $0.lastError == "The server could not link this memo's files." }
        )
        defer { world.harness.cleanUp() }
        _ = try await world.resumed(state: .waiting, bytesConfirmed: 400)

        await world.harness.engine.drain()

        await world.expectOvertaken()
        #expect(
            await world.harness.reload() == nil,
            "a hold put back a capture that had already left the outbox"
        )
    }

    /// :437 — what the recovery and the offset HEAD worked out, written back.
    @Test("a recovered upload session does not overwrite a newer answer")
    func unlinkableRecovery() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400, headOffset: 400),
            completion: ScriptedCompletion(
                [
                    .unlinkable(
                        UploadsUnlinkableFailure(
                            missingUploadUIDs: [], incompleteUploadUIDs: ["u1"]
                        )
                    )
                ],
                repeating: .retry("not again")
            ),
            overtakenBy: .advanced(123),
            whenWriting: { $0.state == .uploading }
        )
        defer { world.harness.cleanUp() }
        _ = try await world.resumed(state: .waiting, bytesConfirmed: 400)

        await world.harness.engine.drain()

        await world.expectOvertaken()
        let saved = try #require(await world.harness.reload())
        #expect(saved.files[0].bytesConfirmed == 123, "the recovery wrote over a newer count")
        #expect(saved.state != JobState.creating)
    }

    /// :440 — the server could not take the memo this time.
    @Test("a capture that left the outbox is not put back by a create's back-off")
    func createRetry() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            completion: ScriptedCompletion([.retry("500")], repeating: .retry("500")),
            overtakenBy: .finished,
            whenWriting: { $0.lastError == "500" }
        )
        defer { world.harness.cleanUp() }
        _ = try await world.resumed(state: .waiting, bytesConfirmed: 400)

        await world.harness.engine.drain()

        await world.expectOvertaken()
        #expect(
            await world.harness.reload() == nil,
            "a back-off put back a capture that had already left the outbox"
        )
    }

    /// :453 — a refusal that is this device's own, so no grant earned it and no epoch travels.
    @Test("a refusal with no grant behind it does not overwrite a newer answer")
    func createRefusedWithoutAGrant() async throws {
        let world = try await fenced(
            bytes: 400,
            http: .standard(chunkSize: 400),
            completion: ScriptedCompletion(
                [.refused("The memo was rejected (422).", nil)],
                repeating: .retry("not again")
            ),
            overtakenBy: .advanced(123),
            whenWriting: { $0.holdReason == .serverRefused }
        )
        defer { world.harness.cleanUp() }
        _ = try await world.resumed(state: .waiting, bytesConfirmed: 400)

        await world.harness.engine.drain()

        await world.expectOvertaken()
        let saved = try #require(await world.harness.reload())
        #expect(saved.files[0].bytesConfirmed == 123, "the hold wrote over a newer count")
        #expect(saved.holdReason == nil, "and held a capture another pass owns")
    }

    // MARK: - handle

    /// :533 — the answer says to ask the server, and the phone is on a network that may not.
    @Test("a capture that left the outbox is not put back by a park in the chunk answer")
    func handleParksForTheNetwork() async throws {
        let world = try await fenced(
            bytes: 1000,
            http: .standard(chunkSize: 400, headOffset: 250),
            network: StubNetworkPath(.cellular),
            overtakenBy: .finished,
            whenWriting: { $0.waitReason == .homeNetwork }
        )
        defer { world.harness.cleanUp() }
        let started = try await world.resumed(state: .uploading)

        await world.harness.engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(
                    jobID: started.id, fileID: started.files[0].id, offset: 0
                ),
                statusCode: 409
            )
        )

        await world.expectOvertaken()
        #expect(
            world.harness.http.requests(method: "HEAD").isEmpty,
            "the premise: no HEAD went out"
        )
        #expect(
            await world.harness.reload() == nil,
            "a park put back a capture that had already left the outbox"
        )
    }

    /// :565 — the cursor itself: the server's own count, and the write MEMNG-289 was raised for.
    @Test("a capture that left the outbox is not put back by the cursor")
    func handleAdvancesTheCursor() async throws {
        let world = try await fenced(
            bytes: 1000,
            http: .standard(chunkSize: 400),
            overtakenBy: .finished,
            whenWriting: { $0.files.first?.bytesConfirmed == 400 }
        )
        defer { world.harness.cleanUp() }
        let started = try await world.resumed(state: .uploading)

        await world.harness.engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(
                    jobID: started.id, fileID: started.files[0].id, offset: 0
                ),
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        await world.expectOvertaken()
        #expect(
            await world.harness.reload() == nil,
            "a chunk answer put back a capture that had already left the outbox"
        )
        #expect(
            world.harness.scheduler.uploads.isEmpty,
            "and nothing carried on from a count nobody wrote"
        )
    }
}

/// The three the plan asks for beside the per-site witnesses: that the reordered bookkeeping write
/// cannot lose a resumed job's progress, that a release owns the capture it took, and that a pass
/// whose write and whose recovery both fail stops without repeating itself.
@Suite("What the fence must not cost")
struct OrdinaryWriteFenceLivenessTests {

    /// The reorder of MEMNG-289 decision 2, from the other side: the write goes first, so no answer
    /// can arrive before it — and the chunk still goes out, and its answer still moves the cursor.
    @Test("a resumed job's chunk waits for its own bookkeeping and then advances")
    func resumedProgressSurvivesItsOwnBookkeeping() async throws {
        let gate = TestGate()
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(chunkSize: 400), holdingFirstSave: gate
        )
        defer { harness.cleanUp() }
        var resumed = harness.job
        resumed.files[0].uploadUID = "u1"
        resumed.files[0].chunkSize = 400
        try await harness.repository.save(resumed)

        let engine = harness.engine
        let draining = Task { await engine.drain() }
        await gate.waitUntilParked()

        #expect(
            harness.scheduler.uploads.isEmpty,
            "the chunk was handed over before the write that records it had landed"
        )
        #expect(
            try #require(await harness.reload()).state == JobState.waiting,
            "the premise: the parked write is the one that records the upload"
        )

        await gate.open()
        await draining.value

        let sent = try #require(harness.scheduler.uploads.first)
        #expect(sent.identity.offset == 0)
        #expect(try #require(await harness.reload()).state == JobState.uploading)

        await harness.engine.handle(
            ChunkResult(
                identity: sent.identity,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        #expect(
            try #require(await harness.reload()).files[0].bytesConfirmed == 400,
            "the answer to a chunk whose own bookkeeping preceded it was dropped"
        )
        #expect(harness.scheduler.uploads.count == 2, "and the next chunk did not follow")
    }

    /// A release lands while an old chunk answer is inside the credential hop. The release's own
    /// drain — production's, through the facade, not one this test issued — owns the capture from
    /// there, and the old answer's count is not written over it.
    @MainActor
    @Test("a capture released under an old answer is left as the release's own drain left it")
    func aReleaseOwnsTheCaptureItTook() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        // A `let`, because the closure below captures it: the capture is what a person's tap has
        // to be able to reach, and a `var` cannot cross into concurrently-executing code.
        let held: UploadJob = {
            var job = harness.job
            job.files[0].uploadUID = "u1"
            job.files[0].chunkSize = 400
            job.state = .held
            job.holdReason = .serverRefused
            job.lastError = "The server refused this memo."
            return job
        }()
        try await harness.repository.save(held)

        let preferences = Fixture.preferences(name: "memosng.outbox.tests.release-overtake")
        defer { Fixture.forgetting(preferences.name) }
        let released = LockedFlag()
        let facade = OutboxBox()
        let engines = HandlerBox()
        // The person taps "Try again" in the instant the answer's handler is acquiring a
        // credential — the suspension it cannot close, and the one this fence is about.
        let provider = InterferingCredentials(Fixture.credentials()) {
            await facade.retryOnce(held.id, released)
        }
        let outbox = Outbox(
            repository: harness.repository,
            credentials: provider,
            http: harness.http,
            scheduler: harness.scheduler,
            completion: harness.completion,
            network: harness.network,
            preferences: preferences.store,
            clock: { harness.clock.now },
            attachScheduler: { handler in await engines.attach(handler) }
        )
        facade.attach(outbox)
        await outbox.adopt()
        let engine = try #require(await engines.handler)

        await engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(
                    jobID: held.id, fileID: held.files[0].id, offset: 0
                ),
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        #expect(released.get(), "the premise: the release landed inside the acquisition")
        let saved = try #require(await harness.repository.job(held.id))
        #expect(
            saved.files[0].bytesConfirmed == 0,
            "the old answer's count landed on a capture the release owns"
        )
        #expect(saved.holdReason == nil, "and put the hold the release had cleared back")
        #expect(saved.state == JobState.uploading, "the release's own drain did not carry it on")
        #expect(
            harness.scheduler.uploads.map(\.identity.offset) == [0],
            "exactly one chunk, and it is the release's drain that sent it"
        )
    }

    /// A value that was SAVED is not automatically a value that can be fenced on: the fence is a
    /// full-value compare and the manifest keeps dates to whole seconds, so a candidate carrying a
    /// fraction of a second describes a row this device never held. The shortest path through both
    /// is one pass that backs a chunk off and then holds the capture — the planner answers the
    /// account before it looks at any retry deadline — with nothing else competing for the row.
    @Test("a hold decided from a back-off the same pass just saved still lands")
    func aHoldAfterItsOwnBackOffLands() async throws {
        let harness = try await Harness.make(
            bytes: 400,
            http: .standard(chunkSize: 400),
            binding: Fixture.binding(owner: "someone-else"),
            clockStart: Date(timeIntervalSince1970: 1_750_000_000.75)
        )
        defer { harness.cleanUp() }
        var started = harness.job
        started.files[0].uploadUID = "u1"
        started.files[0].chunkSize = 400
        started.state = .uploading
        try await harness.repository.save(started)

        await harness.engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(
                    jobID: started.id, fileID: started.files[0].id, offset: 0
                ),
                statusCode: 500
            )
        )

        let saved = try #require(await harness.reload())
        #expect(saved.attemptCount == 1, "the premise: the back-off itself landed")
        #expect(
            saved.state == JobState.held,
            """
            a hold nothing was competing for was dropped: it was fenced on a value carrying a \
            fraction of a second the manifest cannot hold
            """
        )
        #expect(saved.holdReason == .accountMismatch)
    }

    /// The write fails, and so does the hold that says so. Nothing is written, nothing is asked of
    /// the server a second time, and the pass ends.
    @Test("a pass whose write and whose recovery both fail stops, having asked once")
    func bothWritesFailing() async throws {
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(chunkSize: 400), refusedSaves: .max
        )
        defer { harness.cleanUp() }
        let before = try #require(await harness.reload())

        await harness.engine.drain()

        let disk = try #require(harness.persistence as? FaultyPersistence)
        #expect(
            await disk.refusedSaves == 2,
            "the fenced write and the hold that reports it, and nothing else"
        )
        #expect(harness.http.requests(method: "POST").count == 1, "one upload start, not a loop")
        #expect(harness.scheduler.uploads.isEmpty)
        #expect(
            try #require(await harness.reload()) == before,
            "the manifest is not, whole, what it was before the pass that could not write"
        )
        #expect(await harness.engine.lastPersistenceFailure != nil, "and it is said out loud")
    }
}

// MARK: - the world these witnesses run in

/// What the OTHER pass did to the row while the write under test was in its hop.
enum Overtake: Sendable {
    /// A pass ahead of this one created the memo, and a capture leaves the outbox whole — so this
    /// is the interference a resurrection is worst for: the row would come back naming originals
    /// that are gone.
    case finished
    /// A newer chunk answer banked the server's own count. The row is still there and still this
    /// capture's; it is simply no longer the one the overtaken pass decided about.
    case advanced(Int64)

    func apply(in repository: OutboxRepository) async {
        guard let job = (try? await repository.loadJobs())?.first else { return }
        switch self {
        case .finished:
            await repository.delete(job)
        case .advanced(let bytes):
            guard let file = job.files.first else { return }
            try? await repository.save(job.advancing(fileID: file.id, bytesConfirmed: bytes))
        }
    }
}

/// One capture, one scripted server, and the other pass waiting inside one chosen write.
private struct FencedWorld {
    let harness: Harness
    let other: InterferingPersistence

    /// The premise every witness rests on, asserted rather than assumed: the write under test was
    /// actually reached, and the pass wrote nothing more for that capture afterwards.
    func expectOvertaken() async {
        #expect(
            await other.didInterfere,
            "the write under test was never reached, so nothing was fenced"
        )
        #expect(
            await other.attemptsAfter == 0,
            "the pass carried on writing after a write the fence had refused"
        )
    }

    /// The capture as a relaunch or an earlier pass left it: an upload session the server issued,
    /// and whatever the server has confirmed of it.
    @discardableResult
    func resumed(state: JobState, bytesConfirmed: Int64 = 0) async throws -> UploadJob {
        var job = harness.job
        job.files[0].uploadUID = "u1"
        job.files[0].chunkSize = 400
        job.files[0].bytesConfirmed = bytesConfirmed
        job.state = state
        try await harness.repository.save(job)
        return job
    }
}

private enum FenceHarnessFailure: Error {
    case persistenceNotInterfering
}

private func fenced(
    bytes: Int,
    http: ScriptedHTTP,
    completion: (any MemoCompleting)? = nil,
    binding: AccountBinding = Fixture.binding(),
    network: StubNetworkPath = StubNetworkPath(),
    overtakenBy overtake: Overtake,
    whenWriting matches: @escaping @Sendable (UploadJob) -> Bool
) async throws -> FencedWorld {
    let harness = try await Harness.make(
        bytes: bytes,
        http: http,
        completion: completion,
        binding: binding,
        persistence: { repository in
            InterferingPersistence(repository, when: matches) {
                await overtake.apply(in: repository)
            }
        },
        network: network
    )
    guard let other = harness.persistence as? InterferingPersistence else {
        throw FenceHarnessFailure.persistenceNotInterfering
    }
    return FencedWorld(harness: harness, other: other)
}

/// A server that cannot be reached at all, which is a different answer from a refusal.
private struct Unreachable: Error {}

/// The facade, held for a closure that is built before it exists.
@MainActor
final class OutboxBox {
    private var outbox: Outbox?
    private var fired = false

    func attach(_ outbox: Outbox) { self.outbox = outbox }

    /// "Try again", through production's own wiring: `Outbox.retry` releases AND drains, which is
    /// the whole point — a drain this test issued would prove the fence and not the liveness.
    func retryOnce(_ id: UUID, _ flag: LockedFlag) async {
        guard let outbox, !fired else { return }
        fired = true
        await outbox.retry(id)
        flag.set()
    }
}

/// The engine, as the facade hands it to whatever adopts the background session.
actor HandlerBox {
    private(set) var handler: (any OutboxChunkHandling)?

    func attach(_ handler: any OutboxChunkHandling) { self.handler = handler }
}
