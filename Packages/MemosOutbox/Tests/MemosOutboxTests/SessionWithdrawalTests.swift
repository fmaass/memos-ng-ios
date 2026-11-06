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

    private static func compose(_ rig: WholeRig) async throws -> Composed {
        let box = AttemptHandlerBox()
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

    @Test("A capture with no session open yet is removed without a DELETE")
    func removeWithNoOpenSessionSendsNoDelete() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        rig.postStatus.value = 503
        let composed = try await Self.compose(rig)
        let pending = try await rig.reload()
        #expect(pending.files.allSatisfy { $0.uploadUID == nil }, "the premise: nothing is open")

        #expect(await composed.outbox.withdraw(rig.job.id))
        try await settled(composed.engine)

        #expect(Self.deletes(rig).isEmpty)
        #expect(await rig.repository.job(rig.job.id) == nil)
    }

    @Test("A Remove refused because the create may be out withdraws nothing")
    func refusedRemoveWithdrawsNothing() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        let composed = try await Self.compose(rig)
        _ = try await Self.halfway(rig, composed)
        // The create — the server's finalize of every session it names — is claimed.
        var claimed = try await rig.reload()
        claimed.state = .creating
        try await rig.repository.save(claimed)
        #expect(try await rig.reload().createMayHaveBeenSent)

        #expect(await !composed.outbox.withdraw(rig.job.id))
        try await settled(composed.engine)

        #expect(Self.deletes(rig).isEmpty, "withdrew a session the create is finalizing")
        #expect(await rig.repository.job(rig.job.id) != nil)
    }
}
