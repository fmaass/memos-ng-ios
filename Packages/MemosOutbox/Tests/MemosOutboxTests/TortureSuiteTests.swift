import Foundation
@testable import MemosOutbox
import Testing

/// The torture suite's simulator rows (Appendix C of the upload moonshot, T7 to T12): each row is
/// one test with a stable id, so a nightly run can name it with `--only-testing`, e.g.
/// `MemosOutboxTests/TortureSuiteTests/t7SignOutMidTransfer()`.
///
/// Every row runs the real engine on `WholeRig`, the whole lane's scripted session and server,
/// and the real facade composed over it where the row is something a person does to the queue.
/// "Pass" is read back twice: from the wire (what the scripted server and session were asked) and
/// from the manifest on disk.
@Suite("Torture suite: the simulator rows T7 to T12")
struct TortureSuiteTests {
    /// What the scripted server was asked, one list per method, and the tasks the session was
    /// handed, last: a mark a later read can count from.
    private static func sent(_ rig: WholeRig) -> [[URLRequest]] {
        ["GET", "HEAD", "POST", "PATCH", "DELETE"].map { rig.http.requests(method: $0) }
            + [rig.session.createdTasks.map(\.request)]
    }

    /// Every Authorization header sent since `mark` — all of them, without one.
    private static func bearers(_ rig: WholeRig, since mark: [[URLRequest]] = []) -> [String] {
        sent(rig).enumerated()
            .flatMap { index, requests in
                requests.dropFirst(index < mark.count ? mark[index].count : 0)
            }
            .compactMap { $0.value(forHTTPHeaderField: "Authorization") }
    }

    /// The task the session ends for good: it leaves the listing and answers, as a cancelled or
    /// finished task does.
    private static func end(
        _ task: ScriptedUploadTaskSession.Created, of rig: WholeRig, status: Int?,
        received: Int? = nil
    ) async throws {
        rig.session.forget(task.taskIdentifier)
        await rig.engine.handle(try rig.answer(task, status: status, received: received))
    }

    @Test("T7: sign out mid-transfer: nothing is sent signed out; the same account resumes it")
    func t7SignOutMidTransfer() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        try await Self.end(picture, of: rig, status: 200, received: 1000)
        try await settled(rig.engine)

        // The sign-out: the grant's epoch moves, nobody is signed in, the withdrawal is issued.
        rig.credentials.set(nil)
        rig.credentials.supersede()
        await rig.engine.abandonAllTasks(withdrawnAt: 1)
        #expect(rig.session.cancelledIdentifiers.contains(video.taskIdentifier))
        try await Self.end(video, of: rig, status: nil)
        let sentBefore = rig.attempted.value.count
        await rig.engine.drain()
        try await settled(rig.engine)

        #expect(rig.attempted.value.count == sentBefore, "a request went out signed out")
        #expect(rig.session.createdTasks.count == 2, "a task was created signed out")
        let parked = try await rig.reload()
        #expect(parked.binding == Fixture.binding())
        #expect(parked.cancelledAt == nil)
        #expect(parked.file(rig.picture.id)?.isComplete == true, "the landed file was forgotten")
        #expect(parked.file(rig.video.id)?.isComplete == false)
        #expect(rig.completion.idempotencyKeys.isEmpty)

        // The same account signs back in, with a new token: the capture goes on, under it alone.
        rig.credentials.set(Fixture.credentials(token: "pat-token-2"))
        rig.clock.advance(120)
        let mark = Self.sent(rig)
        await rig.engine.drain()
        try await settled(rig.engine)

        let resent = Array(rig.session.createdTasks.dropFirst(2))
        #expect(resent.count == 1)
        let successor = try #require(resent.first)
        let identity = try #require(WholeTaskIdentity(taskDescription: successor.description))
        #expect(identity.fileID == rig.video.id)
        #expect(identity.epoch == 1)
        let renewed = Self.bearers(rig, since: mark)
        #expect(!renewed.isEmpty)
        #expect(renewed.allSatisfy { $0 == "Bearer pat-token-2" }, "\(renewed)")
        try await Self.end(successor, of: rig, status: 200, received: 3000)
        try await settled(rig.engine)
        #expect(rig.completion.idempotencyKeys.count == 1)
        #expect(await rig.repository.job(rig.job.id) == nil)
    }

    @Test("T8: switch accounts mid-transfer: the old account's job is held, never re-bound")
    func t8AccountSwitchMidTransfer() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)

        // Another account signs in over this one while both files are out.
        rig.credentials.set(Fixture.credentials(owner: "someone-else", token: "other-token"))
        rig.credentials.supersede()
        await rig.engine.abandonAllTasks(withdrawnAt: 1)
        let cancelled = Set(rig.session.cancelledIdentifiers)
        #expect(cancelled.isSuperset(of: [picture.taskIdentifier, video.taskIdentifier]))
        // The old grant's answers arrive late: one transfer had finished, one is refused.
        try await Self.end(picture, of: rig, status: 200, received: 1000)
        try await Self.end(video, of: rig, status: 401)
        await rig.engine.drain()
        try await settled(rig.engine)

        let held = try await rig.reload()
        #expect(held.state == .held)
        #expect(held.holdReason == .accountMismatch)
        #expect(held.binding == Fixture.binding(), "the capture was re-bound")
        #expect(!Self.bearers(rig).contains("Bearer other-token"), "sent as the other account")
        #expect(rig.session.createdTasks.count == 2)
        #expect(rig.completion.idempotencyKeys.isEmpty)

        // A Try again under the other account frees nothing either.
        await rig.engine.release(jobID: rig.job.id)
        await rig.engine.drain()
        try await settled(rig.engine)
        let again = try await rig.reload()
        #expect(again.holdReason == .accountMismatch)
        #expect(again.binding == Fixture.binding())
        #expect(!Self.bearers(rig).contains("Bearer other-token"))
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test(
        "T9: Remove with the first file on the server withdraws every upload session",
        .disabled("MEMNG-973 T9: Remove sends no DELETE /api/uploads/{uid}; the contract has none")
    )
    @MainActor
    func t9RemoveWithFirstFileOnServer() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        let box = AttemptHandlerBox()
        // What `composed` builds, with the engine handed out at adoption: the member composition
        // has no chunk scheduler to attach one through (MEMNG-546).
        let outbox = Outbox(
            repository: rig.repository,
            credentials: rig.credentials,
            http: rig.http,
            scheduler: rig.chunks,
            completion: MemoCompletionEndpoint(http: rig.http),
            network: rig.network,
            preferences: rig.preferences,
            attachScheduler: { box.value = $0 },
            schedulingGate: SchedulingGate(isOpen: false),
            uploads: BackgroundUploadScheduler(
                session: rig.session, delegate: rig.delegate, launch: rig.launch,
                pause: {}
            )
        )
        await outbox.appBecameActive().value
        let engine = try #require(box.value as? OutboxEngine)
        try await settled(engine)
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        rig.session.forget(picture.taskIdentifier)
        await engine.handle(try rig.answer(picture, status: 200, received: 1000))
        try await settled(engine)
        let pending = try await rig.reload()
        #expect(pending.file(rig.picture.id)?.isComplete == true, "the premise: one file is up")
        let opened = Set(pending.files.compactMap(\.uploadUID).map { "/api/uploads/\($0)" })
        #expect(opened.count == 2)

        #expect(await outbox.withdraw(rig.job.id))

        #expect(rig.session.cancelledIdentifiers.contains(video.taskIdentifier))
        let withdrawn = Set(rig.http.requests(method: "DELETE").compactMap { $0.url?.path() })
        #expect(withdrawn == opened, "an upload session was left on the server")
        #expect(await rig.repository.job(rig.job.id) == nil)
        #expect(rig.completion.idempotencyKeys.isEmpty)
        #expect(try await rig.repository.sweepOrphans() == .swept(media: 0, chunks: 0))
    }

    @Test("T10: two overlapping retries of one file put exactly one PATCH on the wire")
    func t10OverlappingRetriesAreOnePatch() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        try await Self.end(picture, of: rig, status: 200, received: 1000)
        try await settled(rig.engine)

        // The video stalls; Try again is pressed twice, the second inside the hop the first one
        // suspends on once its new term is written (the enumeration of the live tasks).
        let engine = rig.engine
        let jobID = rig.job.id
        rig.chunks.beforeInFlight = { await engine.release(jobID: jobID) }
        await engine.release(jobID: jobID)
        #expect(rig.chunks.beforeInFlight == nil, "the second press never landed inside the first")
        let pressed = try await rig.reload()
        #expect(pressed.file(rig.video.id)?.uploadAttempt == 1, "two presses minted two terms")
        #expect(rig.session.cancelledIdentifiers == [video.taskIdentifier])

        // The cancelled task ends, and each press's drain runs.
        try await Self.end(video, of: rig, status: nil)
        await engine.drain()
        await engine.drain()
        try await settled(engine)

        #expect(rig.attempts(of: rig.video.id).count == 2, "not exactly one PATCH for the retry")
        #expect(rig.attempts(of: rig.picture.id) == [0])
        #expect(rig.session.createdTasks.count == 3)
        let successor = try #require(rig.session.createdTasks.last)
        let identity = try #require(WholeTaskIdentity(taskDescription: successor.description))
        let current = try await rig.reload().file(rig.video.id)?.uploadAttempt
        #expect(identity.fileID == rig.video.id)
        #expect(identity.attempt == current, "the PATCH on the wire is not the current term")
    }

    @Test("T11: a stale 401 after a successful re-sign-in neither holds nor ends; the job resumes")
    func t11StaleRefusalAfterReSignIn() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)

        // The same account signs in again; the old token's refusal arrives after that.
        rig.credentials.set(Fixture.credentials(token: "pat-token-2"))
        rig.credentials.supersede()
        let mark = Self.sent(rig)
        try await Self.end(picture, of: rig, status: 401)
        try await settled(rig.engine)

        let after = try await rig.reload()
        #expect(after.state != .held, "a stale refusal held the capture")
        #expect(after.holdReason == nil)
        #expect(after.binding == Fixture.binding())

        try await Self.end(video, of: rig, status: 200, received: 3000)
        rig.clock.advance(120)
        await rig.engine.drain()
        try await settled(rig.engine)
        let resent = Array(rig.session.createdTasks.dropFirst(2))
        #expect(resent.count == 1)
        let successor = try #require(resent.first)
        let identity = try #require(WholeTaskIdentity(taskDescription: successor.description))
        #expect(identity.fileID == rig.picture.id)
        #expect(identity.epoch == 1)
        let renewed = Self.bearers(rig, since: mark)
        #expect(!renewed.isEmpty)
        #expect(renewed.allSatisfy { $0 == "Bearer pat-token-2" }, "\(renewed)")
        try await Self.end(successor, of: rig, status: 200, received: 1000)
        try await settled(rig.engine)
        #expect(rig.completion.idempotencyKeys.count == 1)
        #expect(await rig.repository.job(rig.job.id) == nil)
    }

    @Test("T12: 48 hours waiting for Wi-Fi leave the manifest intact; the first Wi-Fi lands it")
    func t12ManifestIntactAfterTwoDaysWaiting() async throws {
        let rig = try await WholeRig.make(network: StubNetworkPath(.cellular))
        defer { rig.cleanUp() }
        let queued = try await rig.reload()
        await rig.engine.drain()
        try await settled(rig.engine)
        #expect(try await rig.reload().waitReason == .homeNetwork)

        // Two days in the background: a wake every hour, and a relaunch's sweep on day 3.
        for _ in 0..<48 {
            rig.clock.advance(3600)
            await rig.engine.drain()
        }
        try await settled(rig.engine)
        _ = try await rig.repository.sweepOrphans()

        #expect(rig.attempted.value.isEmpty, "a request went out over mobile data")
        #expect(rig.session.createdTasks.isEmpty)
        let day3 = try await rig.reload()
        #expect(day3.state == .waiting)
        #expect(day3.waitReason == .homeNetwork)
        #expect(day3.idempotencyKey == queued.idempotencyKey)
        #expect(day3.binding == queued.binding)
        #expect(day3.content == queued.content)
        #expect(day3.capturedAt == queued.capturedAt)
        #expect(day3.cancelledAt == nil)
        #expect(day3.files.map(\.id) == queued.files.map(\.id))
        #expect(day3.files.map(\.byteSize) == queued.files.map(\.byteSize))
        #expect(day3.files.allSatisfy { $0.bytesConfirmed == 0 && $0.uploadUID == nil })
        for file in day3.files {
            let original = try Data(contentsOf: rig.repository.mediaURL(job: day3, file: file))
            #expect(original == Fixture.content(Int(file.byteSize)), "an original changed")
        }

        // The first Wi-Fi: both files go, once, and the memo is made.
        await rig.network.move(to: .wifi)
        await rig.engine.drain()
        try await settled(rig.engine)
        #expect(rig.session.createdTasks.count == 2)
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        try await Self.end(picture, of: rig, status: 200, received: 1000)
        try await Self.end(video, of: rig, status: 200, received: 3000)
        try await settled(rig.engine)
        #expect(rig.session.createdTasks.count == 2)
        #expect(rig.completion.idempotencyKeys.count == 1)
        #expect(await rig.repository.job(rig.job.id) == nil)
    }
}
