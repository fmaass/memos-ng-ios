import Foundation
@testable import MemosOutbox
import Testing

/// Remove on a pending card withdraws the capture's open upload sessions (MEMNG-953).
///
/// Every row runs the real facade over the real engine on `WholeRig`, composed as the torture
/// suite's T9 composes it, and reads the result back from the wire (what the scripted server was
/// asked) and from the disk.
@Suite("Remove withdraws every open upload session")
@MainActor
struct SessionWithdrawalTests {
    private struct Composed {
        let outbox: Outbox
        let engine: OutboxEngine
    }

    /// An entry of the withdraw queue as it is written on disk, read and written here by path so
    /// that what a test asserts about the queue is the file, not an API of the code under test.
    private struct OwedEntry: Codable, Equatable {
        var uploadUID: String
        var binding: AccountBinding
    }

    private static func queueFile(_ rig: WholeRig) -> URL {
        rig.root.appending(path: "outbox/session-withdrawals.json")
    }

    private static func queued(_ rig: WholeRig) throws -> [OwedEntry] {
        guard let data = try? Data(contentsOf: queueFile(rig)) else { return [] }
        return try JSONDecoder().decode([OwedEntry].self, from: data)
    }

    /// A withdraw an earlier Remove queued and the server never answered.
    private static func owe(_ uid: String, in rig: WholeRig) throws {
        let entry = OwedEntry(uploadUID: uid, binding: rig.job.binding)
        try JSONEncoder().encode([entry]).write(to: queueFile(rig), options: .atomic)
    }

    /// Holds every DELETE in the transport until the test opens the gate.
    private struct DeleteGate: OutboxHTTPPerforming {
        let inner: ScriptedHTTP
        let gate: TestGate

        func perform(_ request: URLRequest, under authority: SendAuthority) async throws
            -> OutboxHTTPResponse
        {
            if request.httpMethod == "DELETE" { await gate.pass() }
            return try await inner.perform(request, under: authority)
        }
    }

    private static func compose(
        _ rig: WholeRig,
        repository: OutboxRepository? = nil,
        http: (any OutboxHTTPPerforming)? = nil
    ) async throws -> Composed {
        let box = AttemptHandlerBox()
        let outbox = Outbox(
            repository: repository ?? rig.repository,
            credentials: rig.credentials,
            http: http ?? rig.http,
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
        return Composed(outbox: outbox, engine: engine)
    }

    /// The capture at 50 %: the picture is on the server, the video's task is still out. Returns
    /// the paths of the two sessions it opened.
    private static func halfway(_ rig: WholeRig, _ composed: Composed) async throws -> Set<String> {
        let picture = try rig.task(for: rig.picture.id)
        rig.session.forget(picture.taskIdentifier)
        await composed.engine.handle(try rig.answer(picture, status: 200, received: 1000))
        try await settled(composed.engine)
        let pending = try await rig.reload()
        #expect(pending.file(rig.picture.id)?.isComplete == true, "the premise: one file is up")
        let opened = Set(pending.files.compactMap(\.uploadUID).map { "/api/uploads/\($0)" })
        #expect(opened.count == 2, "the premise: two sessions are open")
        return opened
    }

    private static func deletes(_ rig: WholeRig) -> [URLRequest] {
        rig.http.requests(method: "DELETE")
    }

    private static func paths(_ requests: [URLRequest]) -> [String] {
        requests.compactMap { $0.url?.path() }
    }

    @Test("Remove sends exactly one DELETE per open session, under the capture's own account")
    func removeSendsOneDeletePerOpenSession() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        let composed = try await Self.compose(rig)
        let opened = try await Self.halfway(rig, composed)

        #expect(await composed.outbox.withdraw(rig.job.id))
        try await settled(composed.engine)

        let sent = Self.deletes(rig)
        #expect(sent.count == opened.count, "one DELETE per open session, no more")
        #expect(Set(Self.paths(sent)) == opened)
        #expect(
            sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer pat-token" }
        )
        #expect(await rig.repository.job(rig.job.id) == nil)

        // A later pass finds nothing to finish and nothing more to withdraw.
        await composed.outbox.drain()
        try await settled(composed.engine)
        #expect(Self.deletes(rig).count == opened.count)
        #expect(rig.completion.idempotencyKeys.isEmpty, "a removed capture became a memo")
    }

    /// The body is the server's own: its PATCH answers a withdrawn session with
    /// `HTTPException(409, detail="upload_withdrawn")` (memos-ng v2.14.0 `app/routers/uploads.py`).
    /// The `UploadWithdrawnError` object body belongs to the finalize route, which this client
    /// never calls: its finalize is the memo create, and a create naming a withdrawn session
    /// answers with it as missing, never 409. That create cannot follow a Remove — see
    /// `refusedRemoveWithdrawsNothing`.
    @Test("A transfer answering 409 upload_withdrawn for a removed capture is terminal")
    func withdrawnAnswerForRemovedCaptureIsTerminal() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        let composed = try await Self.compose(rig)
        let opened = try await Self.halfway(rig, composed)
        let video = try rig.task(for: rig.video.id)

        #expect(await composed.outbox.withdraw(rig.job.id))
        try await settled(composed.engine)
        #expect(Set(Self.paths(Self.deletes(rig))) == opened)
        let heads = rig.http.requests(method: "HEAD").count
        let tasks = rig.session.createdTasks.count

        // The video's bytes reached the server after the withdraw: the server refuses them.
        let identity = try #require(WholeTaskIdentity(taskDescription: video.description))
        let body = try JSONSerialization.data(withJSONObject: ["detail": "upload_withdrawn"])
        rig.session.forget(video.taskIdentifier)
        await composed.engine.handle(
            WholeAnswer(
                taskIdentifier: video.taskIdentifier, identity: identity, statusCode: 409,
                body: body
            )
        )
        try await settled(composed.engine)
        await composed.outbox.drain()
        try await settled(composed.engine)

        #expect(rig.http.requests(method: "HEAD").count == heads, "re-synced a withdrawn session")
        #expect(rig.uploadPosts == 2, "opened a fresh session for a removed capture")
        #expect(rig.session.createdTasks.count == tasks, "re-sent a withdrawn file")
        #expect(Self.deletes(rig).count == opened.count, "withdrew a session twice")
        #expect(rig.completion.idempotencyKeys.isEmpty, "a removed capture was finalized")
        #expect(await rig.repository.job(rig.job.id) == nil, "the removed capture came back")
    }

    @Test("A DELETE that fails is remembered and retried; Remove neither waits nor resurrects")
    func failedDeleteIsRememberedAndRetried() async throws {
        let online = WholeBox(false)
        let rig = try await WholeRig.make(
            attached: false,
            answerDelete: { request in
                guard online.value else {
                    // One session off the network, the other refused by a busy database.
                    if request.url?.path() == "/api/uploads/u1" {
                        throw URLError(.notConnectedToInternet)
                    }
                    return OutboxHTTPResponse(statusCode: 503)
                }
                return OutboxHTTPResponse(statusCode: 204)
            }
        )
        defer { rig.cleanUp() }
        let composed = try await Self.compose(rig)
        let opened = try await Self.halfway(rig, composed)

        #expect(await composed.outbox.withdraw(rig.job.id), "Remove waited on the server")
        try await settled(composed.engine)
        #expect(Set(Self.paths(Self.deletes(rig))) == opened)
        #expect(await rig.repository.job(rig.job.id) == nil)
        #expect(!composed.outbox.jobs.contains { $0.id == rig.job.id })

        online.value = true
        await composed.outbox.appBecameActive().value
        try await settled(composed.engine)
        let sent = Self.paths(Self.deletes(rig))
        #expect(sent.count == 2 * opened.count, "a failed DELETE was not retried")
        #expect(Set(sent) == opened)
        #expect(await rig.repository.job(rig.job.id) == nil, "the retry resurrected the capture")
        #expect(!composed.outbox.jobs.contains { $0.id == rig.job.id })

        // Answered: nothing is owed any more.
        await composed.outbox.appBecameActive().value
        try await settled(composed.engine)
        #expect(Self.deletes(rig).count == 2 * opened.count, "a withdrawn session was asked again")
    }

    @Test("A withdraw owed by one account is never sent under another")
    func deleteGoesOnlyUnderTheCapturesAccount() async throws {
        let online = WholeBox(false)
        let rig = try await WholeRig.make(
            attached: false,
            answerDelete: { _ in
                guard online.value else { throw URLError(.notConnectedToInternet) }
                return OutboxHTTPResponse(statusCode: 204)
            }
        )
        defer { rig.cleanUp() }
        let composed = try await Self.compose(rig)
        let opened = try await Self.halfway(rig, composed)
        #expect(await composed.outbox.withdraw(rig.job.id))
        try await settled(composed.engine)
        let offline = Self.deletes(rig).count
        #expect(offline == opened.count)

        // Another account signs in. Its server would answer 204 for a uid it does not own, and
        // nothing would be withdrawn.
        online.value = true
        rig.credentials.set(Fixture.credentials(owner: "someone-else", token: "other-token"))
        await composed.outbox.appBecameActive().value
        try await settled(composed.engine)
        #expect(Self.deletes(rig).count == offline, "sent under another account")

        rig.credentials.set(Fixture.credentials())
        await composed.outbox.appBecameActive().value
        try await settled(composed.engine)
        let retried = Self.deletes(rig).dropFirst(offline)
        #expect(Set(Self.paths(Array(retried))) == opened, "the owner's return did not retry it")
        #expect(
            Self.deletes(rig).allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer pat-token"
            }
        )
    }

    @Test("Two overlapping Removes, and a foreground beside them, put one DELETE per session")
    func overlappingRemovesWithdrawEachSessionOnce() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        let composed = try await Self.compose(rig)
        let opened = try await Self.halfway(rig, composed)
        let outbox = composed.outbox
        let id = rig.job.id

        async let first = outbox.withdraw(id)
        async let second = outbox.withdraw(id)
        async let foreground: Void = outbox.appBecameActive().value
        let answers = await [first, second]
        await foreground
        try await settled(composed.engine)

        #expect(answers.filter { $0 }.count == 1, "one Remove wins, the other is refused")
        let sent = Self.paths(Self.deletes(rig))
        #expect(sent.count == opened.count, "a session was withdrawn twice")
        #expect(Set(sent) == opened)
        #expect(await rig.repository.job(id) == nil)
    }

    @Test("A capture with no session open queues nothing, and its Remove sends what is owed")
    func removeWithNoOpenSessionSendsNoDelete() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        rig.postStatus.value = 503
        let composed = try await Self.compose(rig)
        let pending = try await rig.reload()
        #expect(pending.files.allSatisfy { $0.uploadUID == nil }, "the premise: nothing is open")
        try Self.owe("u-earlier", in: rig)

        #expect(await composed.outbox.withdraw(rig.job.id))
        try await settled(composed.engine)

        // Exactly the earlier capture's withdraw: none for a session this one never opened.
        #expect(Self.paths(Self.deletes(rig)) == ["/api/uploads/u-earlier"])
        #expect(try Self.queued(rig).isEmpty, "an answered withdraw stayed queued")
        #expect(await rig.repository.job(rig.job.id) == nil)
    }

    /// Stands in for the acceptance criterion "a finalize refused as withdrawn is terminal": the
    /// client's finalize is the memo create, and this proves a create that may be out and a
    /// withdraw never meet. Remove is refused, and nothing of the capture is queued or sent — not
    /// then, and not by the next pass, which still sends what an earlier Remove owes.
    @Test("A Remove refused because the create may be out withdraws nothing")
    func refusedRemoveWithdrawsNothing() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        let composed = try await Self.compose(rig)
        _ = try await Self.halfway(rig, composed)
        try Self.owe("u-earlier", in: rig)
        // The create — the server's finalize of every session it names — is claimed.
        var claimed = try await rig.reload()
        claimed.state = .creating
        try await rig.repository.save(claimed)
        #expect(try await rig.reload().createMayHaveBeenSent)

        #expect(await !composed.outbox.withdraw(rig.job.id))
        try await settled(composed.engine)

        #expect(Self.deletes(rig).isEmpty, "withdrew a session the create is finalizing")
        #expect(try Self.queued(rig).map(\.uploadUID) == ["u-earlier"], "queued the claimed one")
        #expect(await rig.repository.job(rig.job.id) != nil)

        await composed.outbox.appBecameActive().value
        try await settled(composed.engine)
        #expect(Self.paths(Self.deletes(rig)) == ["/api/uploads/u-earlier"])
        #expect(try Self.queued(rig).isEmpty)
    }

    @Test("Remove returns while the DELETE is still suspended in the transport")
    func removeDoesNotWaitForTheDelete() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        let gate = TestGate()
        let composed = try await Self.compose(rig, http: DeleteGate(inner: rig.http, gate: gate))
        let opened = try await Self.halfway(rig, composed)

        #expect(await composed.outbox.withdraw(rig.job.id))
        // Remove has answered; the first DELETE is only now held in the transport.
        try await bounded("a DELETE reaching the transport") { await gate.waitUntilParked() }
        #expect(Self.deletes(rig).isEmpty, "the DELETE was answered before Remove returned")
        #expect(!composed.outbox.jobs.contains { $0.id == rig.job.id })
        #expect(await rig.repository.job(rig.job.id) == nil)

        await gate.open()
        try await settled(composed.engine)
        #expect(Set(Self.paths(Self.deletes(rig))) == opened)
        #expect(try Self.queued(rig).isEmpty)
    }

    @Test("A withdraw left unanswered survives a relaunch and is sent by the next process")
    func queuedWithdrawSurvivesARelaunch() async throws {
        let online = WholeBox(false)
        let rig = try await WholeRig.make(
            attached: false,
            answerDelete: { _ in
                guard online.value else { throw URLError(.notConnectedToInternet) }
                return OutboxHTTPResponse(statusCode: 204)
            }
        )
        defer { rig.cleanUp() }
        let composed = try await Self.compose(rig)
        let opened = try await Self.halfway(rig, composed)
        #expect(await composed.outbox.withdraw(rig.job.id))
        try await settled(composed.engine)
        let offline = Self.deletes(rig).count
        #expect(Set(try Self.queued(rig).map { "/api/uploads/\($0.uploadUID)" }) == opened)

        // A new process: a repository and a facade read back from the same directory.
        online.value = true
        let reopened = try OutboxRepository(
            root: rig.root.appending(path: "outbox"),
            stillCurrent: { rig.credentials.stillCurrent(epoch: $0) }
        )
        let relaunched = try await Self.compose(rig, repository: reopened)
        try await settled(relaunched.engine)

        let retried = Self.paths(Array(Self.deletes(rig).dropFirst(offline)))
        #expect(Set(retried) == opened, "the queued withdraw did not survive the relaunch")
        #expect(retried.count == opened.count)
        #expect(try Self.queued(rig).isEmpty)
        #expect(await reopened.job(rig.job.id) == nil, "the relaunch resurrected the capture")
    }
}
