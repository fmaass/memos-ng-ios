import CryptoKit
import Foundation
import MemosOutbox
import Testing

/// A server that answers a keyed create and a keyed edit the way the real one does.
///
/// A create key it has already committed answers with the memo it committed then — including the
/// attachment uids that memo got — because those uids are the only legal way a later edit can name
/// a picture the memo already holds. An edit key it has already applied answers with the memo's
/// current state and applies nothing, which is what makes a second transmission of the same edit
/// harmless rather than a second edit.
final class KeyedMemoServer: @unchecked Sendable {
    struct Memo {
        var uid: String
        var attachmentUIDs: [String]
        var content: String?
        var createdAt: String?
        var visibility: String?
    }

    private let lock = NSLock()
    private var committed: [String: String] = [:]
    private var memos: [String: Memo] = [:]
    private var order: [String] = []
    private var appliedEdits: Set<String> = []
    private var lostCreateResponses: Int
    private var lostPatchResponses: Int
    private let replayStatus: Int
    private var patchRefusals: [Int]

    init(
        losingResponses: Int = 0,
        losingPatchResponses: Int = 0,
        replayStatus: Int = 201,
        refusingPatchesWith patchRefusals: [Int] = []
    ) {
        lostCreateResponses = losingResponses
        lostPatchResponses = losingPatchResponses
        self.replayStatus = replayStatus
        self.patchRefusals = patchRefusals
    }

    var memoCount: Int { lock.withLock { order.count } }
    var memoUIDs: [String] { lock.withLock { order } }
    /// How many times an edit was actually APPLIED, which a transmission count cannot see.
    var editApplications: Int { lock.withLock { appliedEdits.count } }
    func memo(_ uid: String) -> Memo? { lock.withLock { memos[uid] } }

    func answerCreate(to request: URLRequest) -> OutboxHTTPResponse {
        let object = Self.object(request)
        let key = object["idempotency_key"] as? String ?? ""
        let uploads = object["upload_uids"] as? [String] ?? []
        return lock.withLock {
            let uid: String
            var isReplay = true
            if let existing = committed[key] {
                uid = existing
            } else {
                isReplay = false
                uid = "m\(order.count + 1)"
                committed[key] = uid
                order.append(uid)
                memos[uid] = Memo(
                    uid: uid,
                    attachmentUIDs: uploads.map { "att-\($0)" },
                    content: object["content"] as? String,
                    createdAt: object["created_at"] as? String,
                    visibility: object["visibility"] as? String
                )
            }
            guard lostCreateResponses == 0 else {
                lostCreateResponses -= 1
                return OutboxHTTPResponse(statusCode: 503)
            }
            return ScriptedHTTP.json(
                Self.body(memos[uid]!), status: isReplay ? replayStatus : 201)
        }
    }

    func answerPatch(to request: URLRequest, uid: String) -> OutboxHTTPResponse {
        let object = Self.object(request)
        let editKey = object["edit_key"] as? String ?? ""
        return lock.withLock {
            // Scripted refusals are answered before the memo is touched, so a case can say what
            // the server answered without also saying that the edit was applied.
            if !patchRefusals.isEmpty {
                return OutboxHTTPResponse(statusCode: patchRefusals.removeFirst())
            }
            guard var memo = memos[uid] else { return OutboxHTTPResponse(statusCode: 404) }
            if !appliedEdits.contains(editKey) {
                appliedEdits.insert(editKey)
                if let content = object["content"] as? String { memo.content = content }
                if let created = object["created_at"] as? String { memo.createdAt = created }
                if let visibility = object["visibility"] as? String { memo.visibility = visibility }
                if let listed = object["attachment_uids"] as? [String] {
                    let supplied = Set(object["upload_uids"] as? [String] ?? [])
                    memo.attachmentUIDs = listed.map { supplied.contains($0) ? "att-\($0)" : $0 }
                }
                memos[uid] = memo
            }
            guard lostPatchResponses == 0 else {
                lostPatchResponses -= 1
                return OutboxHTTPResponse(statusCode: 503)
            }
            return ScriptedHTTP.json(Self.body(memo), status: 200)
        }
    }

    private static func body(_ memo: Memo) -> [String: Any] {
        let attachments: [[String: Any]] = memo.attachmentUIDs.enumerated().map {
            ["uid": $1, "position": $0]
        }
        var object: [String: Any] = ["uid": memo.uid, "attachments": attachments]
        if let content = memo.content { object["content"] = content }
        if let created = memo.createdAt { object["created_at"] = created }
        if let visibility = memo.visibility { object["visibility"] = visibility }
        return object
    }

    private static func object(_ request: URLRequest) -> [String: Any] {
        let body = request.httpBody ?? Data()
        return ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
    }
}

/// The real completion path, parked at the instant the edit is about to go out and has not.
///
/// It is how a test stands in the one place a relaunch has to be able to happen: the create is
/// resolved and written down, and nothing of the edit has reached the wire yet.
private final class PatchParking: MemoCompleting, @unchecked Sendable {
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
        await inner.create(job: job, credentials: credentials, under: authority)
    }

    func patch(
        job: UploadJob,
        request: URLRequest,
        credentials: OutboxCredentials,
        under authority: SendAuthority
    ) async -> MemoPatchOutcome {
        await entered.open()
        await released.wait()
        return await inner.patch(
            job: job, request: request, credentials: credentials, under: authority)
    }
}

@MainActor
struct Patching {
    let root: URL
    let repository: OutboxRepository
    let http: ScriptedHTTP
    let server: KeyedMemoServer
    let outbox: Outbox
    let preferencesName: String

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        Fixture.forgetting(preferencesName)
    }

    /// Creates only: the upload sessions are POSTs too, and this is about how many memos were
    /// asked for.
    var memoPosts: [URLRequest] {
        http.requests(method: "POST").filter { $0.url?.path() == "/api/memos" }
    }

    /// The upload sessions a pass opened, which is how a picture staged into a restored draft
    /// shows that it reached the wire before the edit did.
    var uploadPosts: [URLRequest] {
        http.requests(method: "POST").filter { $0.url?.path() == "/api/uploads" }
    }

    /// Edits only: a chunk is a PATCH as well, and it goes to the upload session, not to the memo.
    var memoPatches: [URLRequest] {
        http.requests(method: "PATCH").filter {
            ($0.url?.path() ?? "").hasPrefix("/api/memos/")
        }
    }
}

/// Applying a restored draft's edits to the memo its uncertain create already made.
///
/// Every case drives the real repository on a real directory and the real completion path against
/// a scripted transport: what the outbox SENDS is the whole subject here, so a stand-in for the
/// store would be asserting the test's own idea of the wire.
@MainActor
@Suite("A restored draft that was edited")
struct PatchCompletionTests {
    private func harness(
        root existing: URL? = nil,
        server: KeyedMemoServer = KeyedMemoServer(),
        clock: MutableClock? = nil,
        completion: (@Sendable (any MemoCompleting) -> any MemoCompleting)? = nil,
        uploads: (any OutboxUploadScheduling)? = nil,
        sessionUID: (@Sendable (URLRequest) -> String)? = nil,
        performer wrap: ((ScriptedHTTP) -> any OutboxHTTPPerforming)? = nil
    ) throws -> Patching {
        let root = try existing ?? Fixture.temporaryDirectory()
        let provider = StaticCredentials(credentials: Fixture.credentials())
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { _ in true }
        )
        let http = ScriptedHTTP { request in
            let path = request.url?.path() ?? ""
            switch (request.httpMethod ?? "", path) {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/memos"):
                return server.answerCreate(to: request)
            case ("POST", "/api/uploads"):
                return ScriptedHTTP.session(
                    uid: sessionUID?(request) ?? "uC", chunkSize: 5 * 1024 * 1024, received: 0
                )
            case ("PATCH", _) where path.hasPrefix("/api/memos/"):
                return server.answerPatch(
                    to: request, uid: String(path.dropFirst("/api/memos/".count)))
            case ("HEAD", _):
                return OutboxHTTPResponse(statusCode: 200, headers: ["Upload-Offset": "0"])
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
        let preferences = Fixture.preferences()
        // What the outbox sends through: the scripted server itself, or a wrapper a case hands
        // over around it — the requests are recorded by the scripted server either way.
        let performer = wrap?(http) ?? http
        let endpoint = MemoCompletionEndpoint(http: performer)
        // Only when a case hands one over: the facade's own stamps come from the real clock, so a
        // default of anything but `Date.init` would put the queue behind itself.
        let tick: @Sendable () -> Date
        if let clock {
            tick = { clock.now }
        } else {
            tick = Date.init
        }
        let outbox = Outbox(
            repository: repository,
            credentials: provider,
            http: performer,
            scheduler: ScriptedScheduler(),
            completion: completion?(endpoint) ?? endpoint,
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: tick,
            uploads: uploads
        )
        return Patching(
            root: root,
            repository: repository,
            http: http,
            server: server,
            outbox: outbox,
            preferencesName: preferences.name
        )
    }

    private func capture(
        _ harness: Patching,
        content: String = "two pictures from the pier",
        files: [(name: String, bytes: Int)]
    ) async throws -> UploadJob {
        var sources: [StagedSource] = []
        for file in files {
            let url = try Fixture.file(in: harness.root, named: file.name, bytes: file.bytes)
            sources.append(StagedSource(url: url, filename: file.name, mime: "image/heic"))
        }
        return try await harness.repository.enqueue(
            content: content,
            visibility: "PRIVATE",
            capturedAt: Self.captured,
            binding: Fixture.binding(),
            sources: sources
        )
    }

    /// Puts the queue into a state a drain would have reached, so a case can be about the edit
    /// rather than about the chunk pipeline that the scheduler double deliberately swallows.
    @discardableResult
    private func standing(
        _ harness: Patching,
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

    /// Marks the captured pictures uploaded, which is the state the create is sent from.
    private func uploaded(_ harness: Patching, _ job: UploadJob) async throws -> UploadJob {
        try await standing(harness, job) { candidate in
            for index in candidate.files.indices {
                candidate.files[index].uploadUID = "u\(index + 1)"
                candidate.files[index].bytesConfirmed = candidate.files[index].byteSize
            }
        }
    }

    @Test("a whole-lane capture taken back, edited and sent again: one create, then the edit")
    func wholeLaneResubmitAppliesTheEdit() async throws {
        let session = ScriptedUploadTaskSession(onCancel: .leavesListing(after: 1))
        let delegate = UploadSessionDelegate()
        let harness = try harness(
            uploads: BackgroundUploadScheduler(session: session, delegate: delegate)
        )
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [(name: "pier.heic", bytes: 1000)])
        await harness.outbox.drain()
        #expect(session.createdTasks.count == 1)

        var edited = try #require(await harness.outbox.cancel(job.id))
        edited.content = "the pier, the day after"
        #expect(await harness.outbox.resubmit(job.id, draft: edited) == .accepted)
        #expect(session.createdTasks.count == 2)
        let sent = try #require(session.createdTasks.last)
        let identity = try #require(WholeTaskIdentity(taskDescription: sent.description))

        delegate.deliver(
            WholeAnswer(
                taskIdentifier: sent.taskIdentifier, identity: identity, statusCode: 200,
                body: ScriptedHTTP.session(uid: "uC", chunkSize: 1, received: 1000).body
            )
        )
        var waited = 0
        while await harness.repository.job(job.id) != nil, waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }

        #expect(harness.memoPosts.count == 1)
        #expect(harness.memoPatches.count == 1)
        #expect(harness.server.editApplications == 1)
        let uid = try #require(harness.server.memoUIDs.first)
        #expect(harness.server.memo(uid)?.content == "the pier, the day after")
        #expect(await harness.repository.job(job.id) == nil)
    }

    /// Pilot checklist (page 4065) line 7: the whole capture is taken back, and the draft comes
    /// back with a new visibility and one more picture. One memo carries all of it: the original
    /// picture and the added one, each exactly once, under the uploads the server issued for them.
    @Test("line 7: a whole capture sent again with a new visibility and an added picture")
    func wholeLaneResubmitCarriesVisibilityAndPicture() async throws {
        let session = ScriptedUploadTaskSession(onCancel: .leavesListing(after: 1))
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        let delegate = UploadSessionDelegate(completion: box)
        let issued = IssuedUploads()
        let harness = try harness(
            uploads: BackgroundUploadScheduler(session: session, delegate: delegate),
            sessionUID: { issued.issue(for: $0) }
        )
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [(name: "pier.heic", bytes: 1000)])
        await harness.outbox.drain()
        #expect(session.createdTasks.count == 1)

        var edited = try #require(await harness.outbox.cancel(job.id))
        edited.content = "the pier, the day after"
        edited.visibility = "PUBLIC"
        edited.pictures.append(try newPicture(harness))
        #expect(await harness.outbox.resubmit(job.id, draft: edited) == .accepted)
        try await outboxQuiet(harness.outbox)

        // Every live task's whole file arrives, once, under the upload its request names, until
        // the capture has left the outbox. A round ends on the engine's own handshakes.
        var answered: Set<Int> = []
        for _ in 0..<4 {
            guard await harness.repository.job(job.id) != nil else { break }
            let live = session.createdTasks.filter {
                !answered.contains($0.taskIdentifier)
                    && !session.cancelledIdentifiers.contains($0.taskIdentifier)
            }
            try await answersSettled(harness.outbox, box: box, delegate: delegate) {
                for created in live {
                    answered.insert(created.taskIdentifier)
                    delegate.deliver(try wholeArrival(of: created))
                }
            }
        }

        #expect(await harness.repository.job(job.id) == nil)
        #expect(harness.memoPosts.count == 1)
        let uid = try #require(harness.server.memoUIDs.first)
        let memo = try #require(harness.server.memo(uid))
        #expect(memo.content == "the pier, the day after")
        #expect(memo.visibility == "PUBLIC")
        let carried = memo.attachmentUIDs.map { issued.filename(of: $0) ?? "unissued \($0)" }
        #expect(
            carried.sorted() == ["picked.heic", "pier.heic"],
            "the memo does not carry the original and the added picture once each"
        )
    }

    /// The whole file the task carries has arrived: the server's answer for its own upload.
    private func wholeArrival(of created: ScriptedUploadTaskSession.Created) throws -> WholeAnswer {
        let identity = try #require(WholeTaskIdentity(taskDescription: created.description))
        let upload = try #require(created.request.url?.lastPathComponent)
        let attributes = try FileManager.default.attributesOfItem(atPath: created.file.path)
        let size = (attributes[.size] as? Int) ?? 0
        return WholeAnswer(
            taskIdentifier: created.taskIdentifier, identity: identity, statusCode: 200,
            body: ScriptedHTTP.session(uid: upload, chunkSize: 1, received: size).body
        )
    }

    /// Drains until the job is gone or the passes run out: the create's resolution and the edit
    /// are separate advances by construction, and a witness that pinned their exact number would
    /// be asserting the engine's loop shape rather than what reached the wire.
    private func settle(_ harness: Patching, _ jobID: UUID, passes: Int = 4) async {
        for _ in 0..<passes {
            if await harness.repository.job(jobID) == nil { return }
            await harness.outbox.drain()
        }
    }

    private func digest(_ url: URL) throws -> SHA256Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    private func sent(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static let captured = Date(timeIntervalSince1970: 1_750_000_000)
    private static let edited = Date(timeIntervalSince1970: 1_751_111_111)

    /// What a restored draft looks like after the editor changed every field a compose screen
    /// lets a create change — including a picture picked while it was back in the editor.
    private func editedDraft(
        _ draft: RestoredDraft,
        picking newest: RestoredDraft.Picture
    ) -> RestoredDraft {
        var edited = draft
        edited.content = "the pier, the day after"
        edited.visibility = "PUBLIC"
        edited.capturedAt = Self.edited
        edited.pictures = [draft.pictures[0], newest, draft.pictures[1]]
        return edited
    }

    private func newPicture(_ harness: Patching) throws -> RestoredDraft.Picture {
        let url = try Fixture.file(in: harness.root, named: "picked.heic", bytes: 300)
        return RestoredDraft.Picture(
            id: UUID(), url: url, filename: "picked.heic", mime: "image/heic")
    }

    /// The uid the newly picked picture uploads under once it has been staged into the job.
    private func stagedUpload(
        _ harness: Patching,
        _ jobID: UUID,
        uid: String = "uC"
    ) async throws -> UploadJob {
        let job = try #require(await harness.repository.job(jobID))
        let index = try #require(job.files.firstIndex { !$0.isComplete })
        return try await standing(harness, job) { candidate in
            candidate.files[index].uploadUID = uid
            candidate.files[index].bytesConfirmed = candidate.files[index].byteSize
        }
    }

    // MARK: - An edited restored draft, applied as one edit

    @Test("an edited restored draft becomes one memo carrying every edit")
    func theEditedDraftIsAppliedAsOneEdit() async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        #expect(harness.server.memoCount == 1)
        let firstBody = try #require(harness.memoPosts.first?.httpBody)

        let draft = try #require(await harness.outbox.cancel(job.id))
        #expect(draft.pictures.count == 2)
        let edited = editedDraft(draft, picking: try newPicture(harness))
        let resubmitted = await harness.outbox.resubmit(job.id, draft: edited)
        #expect(resubmitted == .accepted)
        let minted = try #require(await harness.repository.job(job.id)?.editKey)
        _ = try await stagedUpload(harness, job.id)
        await settle(harness, job.id)

        // One memo, and the create that resolved it was the FIRST-SENT body byte for byte: that is
        // the only replay the original key authorises, and it is what makes the second request an
        // edit rather than a second memo.
        #expect(harness.server.memoCount == 1)
        #expect(harness.memoPosts.count == 2)
        #expect(harness.memoPosts[1].httpBody == firstBody)
        // The control the byte equality needs: the edited payload is a DIFFERENT create body, so
        // the equality above is a statement about this request and not about any two creates.
        var asEdited = job
        asEdited.content = edited.content
        asEdited.visibility = edited.visibility
        asEdited.capturedAt = edited.capturedAt
        let asEditedBody = try OutboxRequests.createMemo(
            baseURL: Fixture.server, token: "t", job: asEdited
        ).httpBody
        #expect(harness.memoPosts[1].httpBody != asEditedBody)

        #expect(harness.memoPatches.count == 1)
        let patch = try #require(harness.memoPatches.first)
        #expect(patch.url?.path() == "/api/memos/m1")
        let body = try sent(patch)
        // Four sub-assertions, one per field: an edit that carried only the text would pass a
        // single-field test while silently dropping the date, the visibility and the pictures.
        #expect(body["content"] as? String == "the pier, the day after")
        #expect(body["created_at"] as? String == OutboxEncoding.iso8601(Self.edited))
        #expect(body["visibility"] as? String == "PUBLIC")
        #expect(body["attachment_uids"] as? [String] == ["att-u1", "uC", "att-u2"])
        // The newly picked picture is named as an upload in the same request that places it, which
        // is the only form the contract accepts an upload uid in a picture list under.
        #expect(body["upload_uids"] as? [String] == ["uC"])
        // The edit key is a value of its own, minted for this edit and written down before the
        // pass that sends it — never the create's idempotency key, which answers a different
        // question and would make a second edit indistinguishable from the first.
        #expect(body["edit_key"] as? String == minted)
        #expect(minted != job.idempotencyKey.uuidString)

        let memo = try #require(harness.server.memo("m1"))
        #expect(memo.content == "the pier, the day after")
        #expect(memo.visibility == "PUBLIC")
        #expect(memo.createdAt == OutboxEncoding.iso8601(Self.edited))
        #expect(memo.attachmentUIDs == ["att-u1", "att-uC", "att-u2"])
        let remaining = await harness.repository.job(job.id)
        #expect(remaining == nil)
    }

    // MARK: - A replayed create is one memo

    @Test("a replay answered 201 with the same uid makes no second memo", arguments: [201, 200])
    func aReplayedCreateIsOneMemo(status: Int) async throws {
        let harness = try harness(
            server: KeyedMemoServer(losingResponses: 1, replayStatus: status))
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [(name: "a.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        let resubmitted = await harness.outbox.resubmit(job.id, draft: draft)
        #expect(resubmitted == .accepted)
        await settle(harness, job.id)

        #expect(harness.server.memoCount == 1)
        #expect(harness.memoPosts.count == 2)
        #expect(harness.memoPosts[1].httpBody == harness.memoPosts[0].httpBody)
        // Unedited: the create IS the whole answer, so no edit is sent at all.
        #expect(harness.memoPatches.count == 0)
        let remaining = await harness.repository.job(job.id)
        #expect(remaining == nil)
    }

    // MARK: - A create and an edit, never both, never neither

    @Test("a resubmit sends an edit exactly when there is one", arguments: [true, false])
    func createAndEditAreExclusive(editing: Bool) async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        let wanted = editing ? editedDraft(draft, picking: try newPicture(harness)) : draft
        let resubmitted = await harness.outbox.resubmit(job.id, draft: wanted)
        #expect(resubmitted == .accepted)
        if editing { _ = try await stagedUpload(harness, job.id) }
        await settle(harness, job.id)

        // The create replay happens either way — it is what resolves the uncertain create — and
        // the edit happens if and only if there was one. Never both on an unchanged draft, never
        // neither on a changed one: an edited draft that sent no edit is the silent loss this
        // whole path exists to prevent.
        #expect(harness.memoPosts.count == 2)
        #expect(harness.memoPatches.count == (editing ? 1 : 0))
        #expect(harness.server.memoCount == 1)
        if editing {
            let body = try sent(try #require(harness.memoPatches.first))
            for key in ["content", "created_at", "visibility", "attachment_uids", "edit_key"] {
                #expect(body[key] != nil, "the edit sent no '\(key)'")
            }
        }
        let remaining = await harness.repository.job(job.id)
        #expect(remaining == nil)
    }

    // MARK: - The job survives the replay, and a relaunch drives the edit home

    @Test("a relaunch before the edit was sent drives it home")
    func aRelaunchBeforeTheEditFinishesIt() async throws {
        let server = KeyedMemoServer(losingResponses: 1)
        let entered = Latch()
        let released = Latch()
        let first = try harness(
            server: server,
            completion: { PatchParking($0, entered: entered, released: released) }
        )
        defer { first.cleanUp() }
        let job = try await capture(
            first, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(first, job)
        await first.outbox.drain()
        let draft = try #require(await first.outbox.cancel(job.id))
        let wanted = editedDraft(draft, picking: try newPicture(first))
        let resubmitted = await first.outbox.resubmit(job.id, draft: wanted)
        #expect(resubmitted == .accepted)
        let minted = try #require(await first.repository.job(job.id)?.editKey)
        #expect(minted != job.idempotencyKey.uuidString)
        _ = try await stagedUpload(first, job.id)

        let parked = Task { await first.outbox.drain() }
        #expect(
            await entered.wait(within: 2), "the PATCH never reached the completion double")

        // The create is resolved and written down, and nothing of the edit has reached the wire.
        #expect(first.memoPatches.count == 0)
        let carried = try #require(await first.repository.job(job.id))
        #expect(carried.resolvedMemoUID == "m1")
        #expect(carried.editKey == minted)
        // Asserted on the files, not on the manifest: a manifest that still lists three pictures
        // over a media directory that lost one is exactly the state this has to rule out.
        let digests = try carried.files.map {
            try digest(first.repository.mediaURL(job: carried, file: $0))
        }
        #expect(digests.count == 3)

        let second = try harness(root: first.root, server: server)
        // Read BEFORE the edit is driven home: an acknowledged edit takes the capture and the
        // originals it held with it, so the bytes the relaunch FOUND are what this can be about.
        let afterwards = try carried.files.map {
            try digest(second.repository.mediaURL(job: carried, file: $0))
        }
        #expect(afterwards == digests)
        await settle(second, job.id)

        #expect(second.memoPatches.count == 1)
        #expect(server.editApplications == 1)
        #expect(server.memoCount == 1)
        let memo = try #require(server.memo("m1"))
        #expect(memo.content == "the pier, the day after")
        #expect(memo.attachmentUIDs == ["att-u1", "att-uC", "att-u2"])
        // The job is deleted only once the edit is acknowledged, and the pictures it held are
        // still the same bytes it went into the relaunch with.
        let remaining = await second.repository.job(job.id)
        #expect(remaining == nil)

        // Letting the parked call go only now keeps the counts above about the lifetime they were
        // taken in, and leaves no task running past the end of the case.
        await released.open()
        await parked.value
    }

    @Test("a relaunch after the edit was sent replays it byte for byte")
    func aRelaunchAfterTheEditReplaysIt() async throws {
        let server = KeyedMemoServer(losingResponses: 1, losingPatchResponses: 1)
        let first = try harness(server: server)
        defer { first.cleanUp() }
        let job = try await capture(
            first, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(first, job)
        await first.outbox.drain()
        let draft = try #require(await first.outbox.cancel(job.id))
        let wanted = editedDraft(draft, picking: try newPicture(first))
        let resubmitted = await first.outbox.resubmit(job.id, draft: wanted)
        #expect(resubmitted == .accepted)
        let minted = try #require(await first.repository.job(job.id)?.editKey)
        #expect(minted != job.idempotencyKey.uuidString)
        _ = try await stagedUpload(first, job.id)
        await settle(first, job.id)

        // The edit went out and its answer never came back, which no client can tell from an edit
        // that never landed — so the job is still here, still carrying what it needs to ask again.
        #expect(first.memoPatches.count == 1)
        #expect(server.editApplications == 1)
        let carried = try #require(await first.repository.job(job.id))
        #expect(carried.resolvedMemoUID == "m1")
        #expect(carried.editKey == minted)
        let mediaBefore = try carried.files.map {
            try Data(contentsOf: first.repository.mediaURL(job: carried, file: $0))
        }

        // The backoff that lost answer wrote is honoured across the relaunch too, so the second
        // lifetime reads the same manifest on a clock that has moved past the wait.
        let later = MutableClock(carried.nextAttemptAt.addingTimeInterval(1))
        let second = try harness(root: first.root, server: server, clock: later)
        // A replay is only byte-for-byte if the bytes are still there to send: the originals the
        // first lifetime staged have to survive its death untouched.
        let survived = try #require(await second.repository.job(job.id))
        let mediaAfter = try survived.files.map {
            try Data(contentsOf: second.repository.mediaURL(job: survived, file: $0))
        }
        #expect(mediaBefore == mediaAfter, "the originals did not survive the relaunch")
        #expect(mediaAfter.allSatisfy { !$0.isEmpty })
        await settle(second, job.id)

        // Two transmissions across the two lifetimes, byte-identical and under the same key, and
        // ONE application: the key is what the server answers the second one from.
        #expect(second.memoPatches.count == 1)
        let transmissions = first.memoPatches + second.memoPatches
        #expect(transmissions.count == 2)
        #expect(transmissions[0].httpBody == transmissions[1].httpBody)
        let replayed = try sent(transmissions[1])["edit_key"] as? String
        #expect(replayed == minted)
        #expect(server.editApplications == 1)
        #expect(server.memoCount == 1)
        #expect(first.memoPosts.count + second.memoPosts.count == 2)
        let memo = try #require(server.memo("m1"))
        #expect(memo.attachmentUIDs == ["att-u1", "att-uC", "att-u2"])
        let remaining = await second.repository.job(job.id)
        #expect(remaining == nil)
    }

    // MARK: - When the confirmed bytes last moved

    @Test("the last-progress instant moves only when confirmed bytes do")
    func lastProgressFollowsConfirmedBytes() async throws {
        let harness = try harness()
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [(name: "a.heic", bytes: 400)])
        await harness.outbox.refresh()
        let first = try #require(harness.outbox.lastProgressAt[job.id])

        // A failed answer is not progress: the attempt moved, the bytes did not.
        var failed = try await standing(harness, job) { candidate in
            candidate.attemptCount += 1
            candidate.lastError = "the server said nothing"
        }
        await harness.outbox.refresh()
        #expect(harness.outbox.lastProgressAt[job.id] == first)

        failed = try await standing(harness, failed) { candidate in
            candidate.files[0].bytesConfirmed = 200
        }
        await harness.outbox.refresh()
        let moved = try #require(harness.outbox.lastProgressAt[job.id])
        #expect(moved > first)

        // Nor is a retry: a stalled upload that keeps being tried has not confirmed a byte since,
        // and that is the whole fact this instant is kept for.
        _ = try await standing(harness, failed) { candidate in
            candidate.attemptCount += 1
        }
        await harness.outbox.refresh()
        #expect(harness.outbox.lastProgressAt[job.id] == moved)
    }

    // MARK: - The edit is one logical edit, sent once it can be

    /// A restored draft with the text changed and its pictures left alone: an edit that needs no
    /// staged upload, so a case about the edit's own lifetime is not also about the chunk pipeline.
    private func textEdited(_ draft: RestoredDraft) -> RestoredDraft {
        var edited = draft
        edited.content = "the pier, the day after"
        return edited
    }

    @Test("a refused edit waits out its backoff and is replayed under the key it was minted with")
    func aRefusedEditWaitsItsBackoffAndIsReplayed() async throws {
        let clock = MutableClock(Date().addingTimeInterval(60))
        let server = KeyedMemoServer(losingResponses: 1, losingPatchResponses: 1)
        let harness = try harness(server: server, clock: clock)
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        let resubmitting = Task { await harness.outbox.resubmit(job.id, draft: textEdited(draft)) }
        #expect(await resubmitting.value == .accepted)

        #expect(harness.memoPatches.count == 1)
        let carried = try #require(await harness.repository.job(job.id))
        let minted = try #require(carried.editKey)
        #expect(
            carried.editUnansweredSince != nil,
            "a lost answer gave the body back, so a second edit could replace the key")
        // The control for the line after it: the refusal really did space the next attempt out,
        // so a second pass finding nothing to do is the backoff and not an empty queue.
        #expect(carried.nextAttemptAt > clock.now)

        await harness.outbox.drain()
        #expect(harness.memoPatches.count == 1, "a pass inside the backoff sent the edit again")

        clock.advance(carried.nextAttemptAt.timeIntervalSince(clock.now) + 1)
        await settle(harness, job.id)

        let transmissions = harness.memoPatches
        #expect(transmissions.count == 2, "the retry slot was never given back")
        for transmission in transmissions {
            #expect(try sent(transmission)["edit_key"] as? String == minted)
        }
        #expect(server.editApplications == 1)
        #expect(await harness.repository.job(job.id) == nil)
    }

    @Test("a picture staged after the create resolved goes up before the edit that names it")
    func aStagedPictureUploadsBeforeTheEdit() async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [(name: "a.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        // The state a relaunch finds: the server took the memo and the answer was lost, so the
        // create's own resolution is written down by hand rather than raced for.
        _ = try await standing(harness, try #require(await harness.repository.job(job.id))) {
            $0.resolvedMemoUID = "m1"
            $0.editKey = UUID().uuidString
            $0.files[0].attachmentUID = "att-u1"
        }
        let draft = try #require(await harness.outbox.cancel(job.id))
        var picked = draft
        picked.pictures.append(try newPicture(harness))
        let resubmitting = Task { await harness.outbox.resubmit(job.id, draft: picked) }
        #expect(await resubmitting.value == .accepted)

        #expect(
            harness.memoPatches.count == 0,
            "the edit went out naming a picture the server does not have"
        )
        #expect(harness.uploadPosts.count == 1, "the staged picture never got an upload session")

        _ = try await stagedUpload(harness, job.id)
        await settle(harness, job.id)

        #expect(harness.memoPatches.count == 1)
        let body = try sent(try #require(harness.memoPatches.first))
        #expect(body["upload_uids"] as? [String] == ["uC"])
        #expect(body["attachment_uids"] as? [String] == ["att-u1", "uC"])
        #expect(await harness.repository.job(job.id) == nil)
    }

    @Test("a second cancel hands back the edited draft, not the one the capture was made with")
    func aSecondCancelHandsBackTheEditedDraft() async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 2))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        var edited = draft
        edited.content = "the pier, the day after"
        edited.visibility = "PUBLIC"
        edited.capturedAt = Self.edited
        let survivor = draft.pictures[1]
        edited.pictures = [survivor]
        let resubmitting = Task { await harness.outbox.resubmit(job.id, draft: edited) }
        #expect(await resubmitting.value == .accepted)

        let again = try #require(await harness.outbox.cancel(job.id))
        #expect(again.content == "the pier, the day after")
        #expect(again.visibility == "PUBLIC")
        #expect(again.capturedAt == Self.edited)
        #expect(again.pictures.map(\.id) == [survivor.id])
    }

    @Test("an edit already on the wire cannot be taken back until it is answered")
    func aTransmittedEditCannotBeCancelled() async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(
            server: KeyedMemoServer(losingResponses: 1),
            completion: { PatchParking($0, entered: entered, released: released) }
        )
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        // Its own drain is what reaches the parked edit, so the call has to be left running.
        let resubmitting = Task { await harness.outbox.resubmit(job.id, draft: textEdited(draft)) }
        #expect(
            await entered.wait(within: 2), "the edit never reached the completion double")

        #expect(await harness.outbox.cancel(job.id) == nil, "an edit in flight was taken back")
        let carried = try #require(await harness.repository.job(job.id))
        #expect(carried.editUnansweredSince != nil)
        #expect(carried.cancelledAt == nil, "the refused cancel marked the capture anyway")

        await released.open()
        #expect(await resubmitting.value == .accepted)
    }

    @Test("a second edit is sent under a key of its own")
    func aSecondEditIsSentUnderItsOwnKey() async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 2))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        let firstResubmit = Task { await harness.outbox.resubmit(job.id, draft: textEdited(draft)) }
        #expect(await firstResubmit.value == .accepted)
        let firstKey = try #require(await harness.repository.job(job.id)?.editKey)

        let again = try #require(await harness.outbox.cancel(job.id))
        var second = again
        second.content = "the pier, a week later"
        let secondResubmit = Task { await harness.outbox.resubmit(job.id, draft: second) }
        #expect(await secondResubmit.value == .accepted)

        #expect(harness.memoPatches.count == 1)
        let key = try sent(try #require(harness.memoPatches.first))["edit_key"] as? String
        #expect(key != firstKey, "the second edit reused the first edit's key")
        #expect(key != job.idempotencyKey.uuidString, "the edit went out under the create's key")
    }

    @Test("Try again does nothing to a capture whose edit is already claimed")
    func retryDuringAClaimedEditIsANoOp() async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(
            server: KeyedMemoServer(losingResponses: 1),
            completion: { PatchParking($0, entered: entered, released: released) }
        )
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        // Its own drain is what reaches the parked edit, so the call has to be left running.
        let resubmitting = Task { await harness.outbox.resubmit(job.id, draft: textEdited(draft)) }
        #expect(
            await entered.wait(within: 2), "the edit never reached the completion double")
        let parked = try #require(await harness.repository.job(job.id))
        #expect(parked.editUnansweredSince != nil, "the premise: the edit is claimed")

        await harness.outbox.retry(job.id)

        let after = try #require(await harness.repository.job(job.id))
        // Whole-manifest equality, because a hand retry here could go wrong in two ways at once:
        // by minting a term for a transfer nobody scheduled, and by moving the job's own state.
        #expect(after == parked, "Try again moved a capture whose edit is claimed")

        await released.open()
        #expect(await resubmitting.value == .accepted)
    }

    @Test("an applied edit whose fenced delete lost the manifest replays the same key")
    func anAppliedEditThatLosesItsFenceKeepsTheJobAndReplaysTheKey() async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(
            server: KeyedMemoServer(losingResponses: 1),
            completion: { PatchParking($0, entered: entered, released: released) }
        )
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [(name: "a.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        // The state a relaunch finds: the server took the memo and the answer was lost.
        _ = try await standing(harness, try #require(await harness.repository.job(job.id))) {
            $0.resolvedMemoUID = "m1"
            $0.editKey = UUID().uuidString
            $0.files[0].attachmentUID = "att-u1"
        }
        let draft = try #require(await harness.outbox.cancel(job.id))
        let resubmitting = Task { await harness.outbox.resubmit(job.id, draft: textEdited(draft)) }
        #expect(
            await entered.wait(within: 2), "the edit never reached the completion double")
        // The manifest moves while the PATCH is out, so the delete that follows it is fenced off
        // the version it was written against — the one thing that must not destroy the capture.
        _ = try await standing(harness, try #require(await harness.repository.job(job.id))) {
            $0.lastError = "moved under the edit"
        }
        await released.open()
        #expect(await resubmitting.value == .accepted)

        let survivor = try #require(
            await harness.repository.job(job.id),
            "the applied edit destroyed a manifest it no longer owned")
        #expect(survivor.pendingEdit != nil)
        let key = try #require(survivor.editKey)

        await settle(harness, job.id)

        #expect(harness.memoPatches.count == 2, "the edit was never tried again")
        #expect(try sent(harness.memoPatches[1])["edit_key"] as? String == key)
        #expect(harness.server.editApplications == 1, "the replay made a second edit")
        #expect(await harness.repository.job(job.id) == nil)
    }

    /// The fence can hold and the removal still fail. A delete that answered yes without asking
    /// the disk left the claim kept on a capture still standing, and every later pass of this
    /// launch refused it before sending anything.
    @Test("an applied edit whose manifest could not be removed replays the same key")
    func anAppliedEditWhoseRemovalFailedKeepsTheJobAndReplaysTheKey() async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(
            server: KeyedMemoServer(losingResponses: 1),
            completion: { PatchParking($0, entered: entered, released: released) }
        )
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [(name: "a.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        // The state a relaunch finds: the server took the memo and the answer was lost.
        _ = try await standing(harness, try #require(await harness.repository.job(job.id))) {
            $0.resolvedMemoUID = "m1"
            $0.editKey = UUID().uuidString
            $0.files[0].attachmentUID = "att-u1"
        }
        let draft = try #require(await harness.outbox.cancel(job.id))
        let resubmitting = Task { await harness.outbox.resubmit(job.id, draft: textEdited(draft)) }
        #expect(
            await entered.wait(within: 2), "the edit never reached the completion double")
        // Nothing moves the manifest: the fence holds, and only the removal fails.
        let restore = try Fixture.permissions(
            0o500, on: harness.root.appending(path: "outbox/jobs"))
        defer { restore() }
        await released.open()
        #expect(await resubmitting.value == .accepted)

        let survivor = try #require(
            await harness.repository.job(job.id), "the premise: the manifest could not be removed")
        #expect(survivor.pendingEdit != nil)
        let key = try #require(survivor.editKey)

        restore()
        await settle(harness, job.id)

        try #require(harness.memoPatches.count == 2, "the kept claim refused every later pass")
        #expect(try sent(harness.memoPatches[1])["edit_key"] as? String == key)
        #expect(harness.server.editApplications == 1, "the replay made a second edit")
        #expect(await harness.repository.job(job.id) == nil)
    }

    @Test("an edit whose answer was lost holds the capture until the server answers definitely")
    func aLostEditAnswerKeepsTheCaptureUntilItIsSettled() async throws {
        let clock = MutableClock(Date().addingTimeInterval(60))
        let server = KeyedMemoServer(losingResponses: 1, losingPatchResponses: 1)
        let harness = try harness(server: server, clock: clock)
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        #expect(await harness.outbox.resubmit(job.id, draft: textEdited(draft)) == .accepted)

        let carried = try #require(await harness.repository.job(job.id))
        let minted = try #require(carried.editKey)
        #expect(
            carried.editUnansweredSince != nil,
            "a lost answer gave the body back, so a second edit could replace the key")
        #expect(await harness.outbox.cancel(job.id) == nil)
        #expect(
            await harness.outbox.resubmit(job.id, draft: textEdited(draft))
                == .refused(.editUnanswered))

        clock.advance(carried.nextAttemptAt.timeIntervalSince(clock.now) + 1)
        await settle(harness, job.id)

        let transmissions = harness.memoPatches
        #expect(transmissions.count == 2, "the retry slot was never given back")
        for transmission in transmissions {
            #expect(try sent(transmission)["edit_key"] as? String == minted)
        }
        #expect(server.editApplications == 1)
    }

    @Test("an original the create's answer never named is sent again and the edit names both")
    func anUnnamedRetainedOriginalIsSentAgainAndTheEditNamesBoth() async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        // A create whose answer named one of the two originals: the other can be named by nothing
        // the memo holds, which is the state the re-submit has to make nameable again.
        let prepared = try await standing(
            harness, try #require(await harness.repository.job(job.id))
        ) {
            $0.resolvedMemoUID = "m1"
            $0.editKey = UUID().uuidString
            $0.files[0].attachmentUID = "att-u1"
            $0.files[1].attachmentUID = nil
        }
        let draft = try #require(await harness.outbox.cancel(job.id))

        #expect(await harness.outbox.resubmit(job.id, draft: textEdited(draft)) == .accepted)

        let staged = try #require(await harness.repository.job(job.id))
        #expect(staged.files[1].stagedForEdit == true)
        #expect(
            staged.files[1].uploadUID != prepared.files[1].uploadUID,
            "the unnamed original kept the uid the create's upload consumed")
        #expect(staged.files[1].bytesConfirmed == 0)
        #expect(staged.files[0].stagedForEdit != true, "a named original was sent again")

        _ = try await stagedUpload(harness, job.id)
        await settle(harness, job.id)

        let body = try sent(try #require(harness.memoPatches.first))
        #expect(body["attachment_uids"] as? [String] == ["att-u1", "uC"])
        #expect(body["upload_uids"] as? [String] == ["uC"])
    }

    @Test("an original whose bytes this device no longer holds is taken, then stops the change")
    func anOriginalWhoseBytesAreGoneHoldsTheCapture() async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let prepared = try await standing(
            harness, try #require(await harness.repository.job(job.id))
        ) {
            $0.resolvedMemoUID = "m1"
            $0.editKey = UUID().uuidString
            $0.files[0].attachmentUID = "att-u1"
            $0.files[1].attachmentUID = nil
        }
        let draft = try #require(await harness.outbox.cancel(job.id))
        try FileManager.default.removeItem(
            at: harness.repository.mediaURL(job: prepared, file: prepared.files[1]))

        // The editor is not where a retained original is missed: the sheet asked for a change it
        // could describe, and the one place that can tell is the drain that has to name the file.
        #expect(await harness.outbox.resubmit(job.id, draft: textEdited(draft)) == .accepted)
        await settle(harness, job.id)

        let held = try #require(await harness.repository.job(job.id))
        #expect(held.state == .held)
        #expect(held.holdReason == .editIncomplete)
        #expect(held.editUnansweredSince == nil, "a change that was never sent froze the capture")
        #expect(held.files[1].stagedForEdit != true, "an unreadable original was staged anyway")
        #expect(harness.memoPatches.isEmpty, "an edit that cannot be completed was sent")
    }

    // MARK: - What an unanswered edit survives

    @Test("a refusal answered before the edit key was read leaves the change unanswered")
    func aRefusalBeforeTheKeyLeavesTheEditUnanswered() async throws {
        let clock = MutableClock(Date().addingTimeInterval(60))
        // Lost first, refused second: the refusal has to find a capture whose edit is already
        // owed, which is the state a replay is answered in.
        let server = KeyedMemoServer(losingResponses: 1, refusingPatchesWith: [503, 401])
        let harness = try harness(server: server, clock: clock)
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        #expect(await harness.outbox.resubmit(job.id, draft: textEdited(draft)) == .accepted)

        let waiting = try #require(await harness.repository.job(job.id))
        clock.advance(waiting.nextAttemptAt.timeIntervalSince(clock.now) + 1)
        await settle(harness, job.id)

        #expect(harness.memoPatches.count == 2, "the refusal was never replayed into")
        let refused = try #require(await harness.repository.job(job.id))
        #expect(refused.state == .held)
        #expect(refused.holdReason == .serverRefused)
        #expect(
            refused.editUnansweredSince != nil,
            "an answer that never looked at the key was read as the edit's fate")
        #expect(await harness.outbox.cancel(job.id) == nil, "the unanswered change was taken back")
        #expect(
            await harness.outbox.resubmit(job.id, draft: textEdited(draft))
                == .refused(.editUnanswered))
    }

    @Test("Try again releases a hold carrying an unanswered edit, and replays the same key")
    func retryReleasesAHoldCarryingAnUnansweredEdit() async throws {
        let clock = MutableClock(Date().addingTimeInterval(60))
        let server = KeyedMemoServer(losingResponses: 1, losingPatchResponses: 1)
        let harness = try harness(server: server, clock: clock)
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        #expect(await harness.outbox.resubmit(job.id, draft: textEdited(draft)) == .accepted)
        let carried = try #require(await harness.repository.job(job.id))
        let minted = try #require(carried.editKey)
        #expect(carried.editUnansweredSince != nil, "the premise: the edit is owed")
        // The hold a capture made under another account wakes up in, reached while its change is
        // still owed: the account is right again, so Try again is the whole way out.
        _ = try await standing(harness, carried) {
            $0.state = .held
            $0.holdReason = .accountMismatch
        }
        clock.advance(600)

        await harness.outbox.retry(job.id)
        await settle(harness, job.id)

        #expect(harness.memoPatches.count == 2, "the held capture never replayed its change")
        for transmission in harness.memoPatches {
            #expect(try sent(transmission)["edit_key"] as? String == minted)
        }
        #expect(server.editApplications == 1)
        #expect(await harness.repository.job(job.id) == nil, "the released capture never finished")
    }

    @Test("a re-submit made before the create resolved still names every picture the memo keeps")
    func aResubmitBeforeTheCreateResolvesNamesEveryPicture() async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        // The premise: nothing has resolved yet, so the re-submit cannot make anything nameable
        // against a memo it cannot name.
        #expect(await harness.repository.job(job.id)?.resolvedMemoUID == nil)
        let draft = try #require(await harness.outbox.cancel(job.id))
        let wanted = editedDraft(draft, picking: try newPicture(harness))
        #expect(await harness.outbox.resubmit(job.id, draft: wanted) == .accepted)
        _ = try await stagedUpload(harness, job.id)

        await settle(harness, job.id, passes: 6)

        #expect(harness.memoPatches.count == 1, "the edit never reached the wire")
        let body = try sent(try #require(harness.memoPatches.first))
        #expect(
            (body["attachment_uids"] as? [String])?.count == 3,
            "the edit dropped a picture the memo keeps")
        #expect(await harness.repository.job(job.id) == nil)
    }

    @Test("a relaunch on a manifest whose retained original is unnamed sends it again")
    func aRelaunchRecoversAnUnnamedRetainedOriginal() async throws {
        let server = KeyedMemoServer(losingResponses: 1)
        let first = try harness(server: server)
        defer { first.cleanUp() }
        let job = try await capture(
            first, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(first, job)
        await first.outbox.drain()
        // The manifest a relaunch finds: the create committed, one of the two originals named by
        // the memo, the edit written down and not yet on the wire.
        let prepared = try await standing(
            first, try #require(await first.repository.job(job.id))
        ) {
            // Planted as a resolved create moving on to its pending edit, no backoff standing.
            $0.attemptCount = 0
            $0.nextAttemptAt = .distantPast
            $0.resolvedMemoUID = "m1"
            $0.editKey = UUID().uuidString
            $0.files[0].attachmentUID = "att-u1"
            $0.files[1].attachmentUID = nil
            $0.pendingEdit = PendingEdit(
                content: "the pier, the day after",
                visibility: "PUBLIC",
                capturedAt: Self.edited,
                fileIDs: $0.files.map(\.id)
            )
        }

        let second = try harness(root: first.root, server: server)
        await second.outbox.drain()

        let staged = try #require(await second.repository.job(job.id))
        #expect(
            staged.files[1].stagedForEdit == true,
            "the relaunch left an original the memo cannot name unnameable")
        #expect(staged.files[1].bytesConfirmed == 0)
        #expect(
            staged.files[1].uploadUID != prepared.files[1].uploadUID,
            "the unnamed original kept the uid the create's upload consumed")
        #expect(staged.files[0].stagedForEdit != true, "a named original was sent again")

        _ = try await stagedUpload(second, job.id)
        await settle(second, job.id, passes: 6)

        #expect(second.memoPatches.count == 1)
        let body = try sent(try #require(second.memoPatches.first))
        #expect(body["attachment_uids"] as? [String] == ["att-u1", "uC"])
        #expect(await second.repository.job(job.id) == nil)
    }

    // MARK: - What settles the change, and what only stops it

    @Test("a refusal the frozen body earned settles the change and gives the capture back")
    func aRefusalDecidedOnTheFrozenBodySettlesTheEdit() async throws {
        let harness = try harness(
            server: KeyedMemoServer(losingResponses: 1, refusingPatchesWith: [422]))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        #expect(await harness.outbox.resubmit(job.id, draft: textEdited(draft)) == .accepted)
        await settle(harness, job.id)

        let refused = try #require(await harness.repository.job(job.id))
        #expect(refused.state == .held)
        #expect(
            refused.editUnansweredSince == nil,
            "an answer about this body left the change owed")
        #expect(
            await harness.outbox.cancel(job.id) != nil,
            "a settled change kept the capture frozen")
    }

    @Test("a memo that is gone answers nothing about the change, so the capture stays frozen")
    func aMemoGoneRefusalDoesNotSettleTheEdit() async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        // Pointed at a memo the server never committed, which is how the real 404 is earned:
        // answered before the key is looked up.
        _ = try await standing(harness, try #require(await harness.repository.job(job.id))) {
            $0.resolvedMemoUID = "m404"
            // The answer that committed it named both pictures; a manifest without them says the
            // create folded them away, which is a different witness.
            $0.files[0].attachmentUID = "att-u1"
            $0.files[1].attachmentUID = "att-u2"
        }
        #expect(await harness.outbox.resubmit(job.id, draft: textEdited(draft)) == .accepted)
        await settle(harness, job.id)

        let held = try #require(await harness.repository.job(job.id))
        #expect(held.state == .held)
        #expect(held.holdReason == .memoGone)
        #expect(held.editUnansweredSince != nil, "an answer about the memo was read as the key's")
        #expect(await harness.outbox.cancel(job.id) == nil, "the owed change was taken back")
    }

    @Test("Try again does nothing while this launch is still transmitting the change")
    func retryWhileTheEditIsClaimedInThisLaunchIsANoOp() async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(
            server: KeyedMemoServer(losingResponses: 1),
            completion: { PatchParking($0, entered: entered, released: released) }
        )
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        // Its own drain is what reaches the parked edit, so the call has to be left running.
        let resubmitting = Task { await harness.outbox.resubmit(job.id, draft: textEdited(draft)) }
        #expect(await entered.wait(within: 2), "the edit never reached the completion double")
        let parked = try #require(await harness.repository.job(job.id))
        #expect(parked.editUnansweredSince != nil, "the premise: the change is claimed")

        await harness.outbox.retry(job.id)

        let after = try #require(await harness.repository.job(job.id))
        #expect(after == parked, "Try again moved a capture whose transmission is outstanding")
        #expect(harness.memoPatches.isEmpty, "a claimed change went out a second time")

        await released.open()
        #expect(await resubmitting.value == .accepted)
    }

    @Test("an original this device can no longer read stops the change before it is claimed")
    func anUnreadableRetainedOriginalHoldsBeforeTheClaim() async throws {
        let server = KeyedMemoServer(losingResponses: 1)
        let first = try harness(server: server)
        defer { first.cleanUp() }
        let job = try await capture(
            first, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(first, job)
        await first.outbox.drain()
        let prepared = try await standing(
            first, try #require(await first.repository.job(job.id))
        ) {
            $0.resolvedMemoUID = "m1"
            $0.editKey = UUID().uuidString
            $0.files[0].attachmentUID = "att-u1"
            $0.files[1].attachmentUID = nil
            $0.pendingEdit = PendingEdit(
                content: "the pier, the day after",
                visibility: "PUBLIC",
                capturedAt: Self.edited,
                fileIDs: $0.files.map(\.id)
            )
        }
        try FileManager.default.removeItem(
            at: first.repository.mediaURL(job: prepared, file: prepared.files[1]))

        let second = try harness(root: first.root, server: server)
        await second.outbox.drain()

        let held = try #require(await second.repository.job(job.id))
        #expect(held.state == .held)
        #expect(held.holdReason == .editIncomplete)
        #expect(
            held.editUnansweredSince == nil,
            "a change that was never sent froze the capture")
        #expect(held.files[1].stagedForEdit != true, "an unreadable original was staged anyway")
        #expect(second.memoPatches.isEmpty, "a change that cannot be built was sent")
    }

    @Test("a kept picture the manifest no longer lists stops the change at the request")
    func aKeptPictureWithNoFileHoldsAtThePreparation() async throws {
        let entered = Latch()
        let released = Latch()
        let harness = try harness(
            server: KeyedMemoServer(losingResponses: 1),
            completion: { PatchParking($0, entered: entered, released: released) }
        )
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        // Every file the manifest holds is complete, so nothing is re-staged and the gate passes:
        // the kept picture that names no file can surface nowhere but the request itself.
        _ = try await standing(harness, try #require(await harness.repository.job(job.id))) {
            // Planted as a resolved create moving on to its pending edit, no backoff standing.
            $0.attemptCount = 0
            $0.nextAttemptAt = .distantPast
            $0.resolvedMemoUID = "m1"
            $0.editKey = UUID().uuidString
            $0.files[0].attachmentUID = "att-u1"
            $0.files[1].attachmentUID = "att-u2"
            $0.pendingEdit = PendingEdit(
                content: "the pier, the day after",
                visibility: "PUBLIC",
                capturedAt: Self.edited,
                fileIDs: $0.files.map(\.id) + [UUID()]
            )
        }

        await harness.outbox.drain()

        let held = try #require(await harness.repository.job(job.id))
        #expect(held.state == .held)
        #expect(held.holdReason == .editIncomplete)
        #expect(held.editUnansweredSince == nil, "a change that was never built froze the capture")
        #expect(harness.memoPatches.isEmpty)
        #expect(
            await entered.wait(within: 1) == false,
            "a request that could not be built was sent anyway")
        await released.open()
    }

    @Test("a change that was never built can still be taken back after Try again")
    func aChangeHeldBeforeTheClaimStaysTakeBackable() async throws {
        let harness = try harness(server: KeyedMemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        _ = try await standing(harness, try #require(await harness.repository.job(job.id))) {
            // Planted as a resolved create moving on to its pending edit, no backoff standing.
            $0.attemptCount = 0
            $0.nextAttemptAt = .distantPast
            $0.resolvedMemoUID = "m1"
            $0.editKey = UUID().uuidString
            $0.files[0].attachmentUID = "att-u1"
            $0.files[1].attachmentUID = "att-u2"
            $0.pendingEdit = PendingEdit(
                content: "the pier, the day after",
                visibility: "PUBLIC",
                capturedAt: Self.edited,
                fileIDs: $0.files.map(\.id) + [UUID()]
            )
        }
        await harness.outbox.drain()
        #expect(await harness.repository.job(job.id)?.holdReason == .editIncomplete)

        await harness.outbox.retry(job.id)
        await settle(harness, job.id, passes: 2)

        let again = try #require(await harness.repository.job(job.id))
        #expect(
            again.holdReason == .editIncomplete,
            "a second attempt built what the first could not")
        #expect(again.editUnansweredSince == nil, "a re-entry that never reached the wire froze it")
        #expect(harness.memoPatches.isEmpty)
        #expect(
            await harness.outbox.cancel(job.id) != nil,
            "a change that was never sent could not be taken back")
    }
}

/// The upload sessions the server opened: a distinct uid for each, and the file each was for.
private final class IssuedUploads: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]

    func issue(for request: URLRequest) -> String {
        let start = request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let filename = start?["filename"] as? String ?? "unnamed"
        return lock.withLock {
            let uid = "up\(files.count + 1)"
            files[uid] = filename
            return uid
        }
    }

    /// The file an attachment the memo carries was uploaded from, nil for one never issued.
    func filename(of attachment: String) -> String? {
        lock.withLock { files[String(attachment.dropFirst("att-".count))] }
    }
}

// MARK: - An edit job: files added to an existing memo (MEMNG-954)

extension KeyedMemoServer {
    /// A memo the server already holds, as an existing memo an edit job is owed to.
    func seed(uid: String, attachmentUIDs: [String], content: String = "the dock") {
        lock.withLock {
            memos[uid] = Memo(
                uid: uid, attachmentUIDs: attachmentUIDs, content: content, createdAt: nil,
                visibility: "PRIVATE")
            order.append(uid)
        }
    }
}

/// The edit job end to end against the keyed server: its file goes up on the whole lane, and the
/// PATCH that names it is the terminal action, under the ONE key minted when the job was written.
extension PatchCompletionTests {
    private static let editedMemo = "m9"

    private func editOrder() -> MemoEditOrder {
        MemoEditOrder(
            memoUID: Self.editedMemo, content: "the dock, later", visibility: nil, createdAt: nil,
            pictures: [.kept("att-old"), .adding(0)])
    }

    /// Queues the edit through the facade, lets its one file arrive on the whole lane, and waits
    /// for the first PATCH. Returns the harness, the job and the key it was written with.
    private func editJobSent(
        server: KeyedMemoServer, clock: MutableClock
    ) async throws -> (Patching, UploadJob, String) {
        let session = ScriptedUploadTaskSession(onCancel: .leavesListing(after: 1))
        let delegate = UploadSessionDelegate()
        server.seed(uid: Self.editedMemo, attachmentUIDs: ["att-old"])
        let harness = try harness(
            server: server, clock: clock,
            uploads: BackgroundUploadScheduler(session: session, delegate: delegate))
        let url = try Fixture.file(in: harness.root, named: "dock.heic", bytes: 1000)
        let source = StagedSource(url: url, filename: "dock.heic", mime: "image/heic")
        #expect(await harness.outbox.enqueueEdit(editOrder(), sources: [source]) == .queued)
        let job = try #require(try await harness.repository.loadJobs().first)
        let minted = try #require(job.editKey, "the edit job was written without a key")
        #expect(job.memoEdit != nil)
        #expect(harness.memoPatches.isEmpty, "the PATCH went out before its file was up")
        if session.createdTasks.isEmpty { await harness.outbox.drain() }
        #expect(harness.memoPosts.isEmpty, "an edit job asked for a new memo")
        let created = try #require(session.createdTasks.last, "the file never went up")
        delegate.deliver(try wholeArrival(of: created))
        var waited = 0
        while harness.memoPatches.isEmpty, waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        return (harness, job, minted)
    }

    @Test("an edit job patches the memo with its upload and its key, and a retry is one change")
    func anEditJobsRetryPresentsTheSameKey() async throws {
        let clock = MutableClock(Date().addingTimeInterval(60))
        // The first PATCH is APPLIED and its answer lost: the ambiguous case a key exists for.
        let server = KeyedMemoServer(losingPatchResponses: 1)
        let (harness, job, minted) = try await editJobSent(server: server, clock: clock)
        defer { harness.cleanUp() }
        #expect(harness.memoPatches.count == 1)
        let backingOff = try #require(await harness.repository.job(job.id))
        #expect(backingOff.editKey == minted, "a lost answer re-keyed the edit")

        clock.advance(backingOff.nextAttemptAt.timeIntervalSince(clock.now) + 1)
        await settle(harness, job.id)

        let transmissions = harness.memoPatches
        #expect(transmissions.count == 2, "the edit was not retried after its answer was lost")
        for transmission in transmissions {
            #expect(transmission.url?.path() == "/api/memos/\(Self.editedMemo)")
            let body = try sent(transmission)
            #expect(body["edit_key"] as? String == minted)
            #expect(body["upload_uids"] as? [String] == ["uC"])
            #expect(body["attachment_uids"] as? [String] == ["att-old", "uC"])
            #expect(body["content"] as? String == "the dock, later")
            // Neither stated by this edit, so neither is sent: a PATCH is a partial update.
            #expect(body["created_at"] == nil)
            #expect(body["visibility"] == nil)
        }
        #expect(server.editApplications == 1, "the retried PATCH was applied a second time")
        #expect(server.memoCount == 1)
        #expect(server.memo(Self.editedMemo)?.content == "the dock, later")
        #expect(server.memo(Self.editedMemo)?.attachmentUIDs == ["att-old", "att-uC"])
        #expect(await harness.repository.job(job.id) == nil)
    }

    @Test("a 409 on an edit job's PATCH holds it visibly under the key it was minted with")
    func anEditKeyConflictHoldsTheJob() async throws {
        let clock = MutableClock(Date().addingTimeInterval(60))
        let server = KeyedMemoServer(refusingPatchesWith: [409])
        let (harness, job, minted) = try await editJobSent(server: server, clock: clock)
        defer { harness.cleanUp() }
        #expect(harness.memoPatches.count == 1)

        let held = try #require(await harness.repository.job(job.id), "the refused edit vanished")
        #expect(held.holdReason == .serverRefused)
        #expect(held.editKey == minted, "a conflict re-keyed the edit")

        // Held, not backing off: no later pass sends it again, under this key or a new one.
        clock.advance(3600)
        await harness.outbox.drain()
        await harness.outbox.drain()
        #expect(harness.memoPatches.count == 1, "a held edit was sent again by itself")
        #expect(server.editApplications == 0)
        #expect(await harness.repository.job(job.id)?.editKey == minted)
    }

    @Test("an edit job survives a reopen of its repository with its key, memo and files")
    func anEditJobSurvivesAKill() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try OutboxRepository(root: root.appending(path: "outbox"))
        let url = try Fixture.file(in: root, named: "dock.heic", bytes: 1000)
        let written = try await first.enqueue(
            content: "ignored", visibility: "PUBLIC", capturedAt: Date(timeIntervalSince1970: 0),
            binding: Fixture.binding(),
            sources: [StagedSource(url: url, filename: "dock.heic", mime: "image/heic")],
            editing: editOrder())

        // A second repository on the same directory: what a relaunch after a kill reads.
        let reopened = try OutboxRepository(root: root.appending(path: "outbox"))
        let read = try #require(try await reopened.loadJobs().first)
        #expect(read == written)
        #expect(read.resolvedMemoUID == Self.editedMemo)
        #expect(read.content == "the dock, later")
        #expect(read.visibility == nil)
        #expect(read.editKey?.isEmpty == false)
        #expect(read.editKey == written.editKey)
        let expected = MemoEdit(
            statesDate: false, pictures: [.kept("att-old"), .added(written.files[0].id)])
        #expect(read.memoEdit == expected)
        #expect(read.files.count == 1)
        #expect(read.files.allSatisfy { $0.stagedForEdit == true })
        #expect(read.transport == .whole)
    }
}

// MARK: - An edit job never becomes a create (review round 1, MEMNG-954)

/// Around the scripted server: the FIRST reachability probe waits for `onProbe` before it is
/// answered. The engine probes after it has read the rows it will drive and before it drives
/// them, so a write made here is one the pass's own copies do not know — the instant a file's
/// answer lands while a pass is already under way.
final class ProbeHookHTTP: OutboxHTTPPerforming, @unchecked Sendable {
    private let inner: ScriptedHTTP
    private let onProbe: @Sendable () async -> Void
    private let lock = NSLock()
    private var fired = false

    init(_ inner: ScriptedHTTP, onProbe: @escaping @Sendable () async -> Void) {
        self.inner = inner
        self.onProbe = onProbe
    }

    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        if request.url?.path() == "/health" {
            let first = lock.withLock {
                defer { fired = true }
                return !fired
            }
            if first { await onProbe() }
        }
        return try await inner.perform(request, under: authority)
    }
}

extension PatchCompletionTests {
    /// The whole planner asked about an edit job whose every file is up answers the PATCH, open or
    /// closed — never a create, which would post the edit's files as a second memo.
    @Test("the whole planner answers a finished edit job with its PATCH, never a memo create")
    func plannerNeverCreatesForAnEditJob() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        let url = try Fixture.file(in: root, named: "dock.heic", bytes: 1000)
        var job = try await repository.enqueue(
            content: "ignored", visibility: nil, capturedAt: Date(timeIntervalSince1970: 0),
            binding: Fixture.binding(),
            sources: [StagedSource(url: url, filename: "dock.heic", mime: "image/heic")],
            editing: editOrderForReview())
        job.files[0].uploadUID = "uC"
        job.files[0].bytesConfirmed = job.files[0].byteSize
        for open in [true, false] {
            let action = OutboxPlanner.nextWholeAction(
                for: job, credentials: Fixture.credentials(), now: Date(), schedulingOpen: open)
            #expect(action == .patchMemo, "open=\(open) answered \(action)")
        }
        // And the request builder refuses it outright, so no path can post it.
        #expect(throws: OutboxRequests.Failure.editIsNotACreate) {
            try OutboxRequests.createMemo(
                baseURL: Fixture.credentials().serverBaseURL, token: "t", job: job)
        }
    }

    /// The race the review found: the pass reads the edit job while its file is still going up,
    /// the file's answer lands before the pass drives it, and the whole lane re-reads the row with
    /// every file up. That row is handed back to the edit branch and PATCHed under its key — never
    /// created as a second memo.
    @Test("an edit job whose last file lands mid-pass is PATCHed from its re-read row, not created")
    func anEditJobFinishedMidPassIsPatchedNotCreated() async throws {
        let clock = MutableClock(Date().addingTimeInterval(60))
        let server = KeyedMemoServer()
        server.seed(uid: "m9", attachmentUIDs: ["att-old"])
        let session = ScriptedUploadTaskSession(onCancel: .leavesListing(after: 1))
        let box = EditJobRepositoryBox()
        let harness = try harness(
            server: server, clock: clock,
            uploads: BackgroundUploadScheduler(session: session, delegate: UploadSessionDelegate()),
            performer: { inner in
                ProbeHookHTTP(inner) {
                    // The file's answer, landing after the pass read the row.
                    guard let repository = box.repository,
                        var row = try? await repository.loadJobs().first
                    else { return }
                    row.files[0].uploadUID = "uC"
                    row.files[0].bytesConfirmed = row.files[0].byteSize
                    try? await repository.save(row)
                }
            })
        defer { harness.cleanUp() }
        box.repository = harness.repository
        let url = try Fixture.file(in: harness.root, named: "dock.heic", bytes: 1000)
        let written = try await harness.repository.enqueue(
            content: "ignored", visibility: nil, capturedAt: clock.now,
            binding: Fixture.binding(),
            sources: [StagedSource(url: url, filename: "dock.heic", mime: "image/heic")],
            editing: editOrderForReview())
        let minted = try #require(written.editKey)

        await harness.outbox.drain()
        await settle(harness, written.id)

        #expect(harness.memoPosts.isEmpty, "an edit job was posted as a new memo")
        #expect(server.memoCount == 1, "a second memo was created")
        #expect(harness.memoPatches.count == 1)
        let body = try sent(try #require(harness.memoPatches.first))
        #expect(body["edit_key"] as? String == minted)
        #expect(body["upload_uids"] as? [String] == ["uC"])
        #expect(server.memo("m9")?.attachmentUIDs == ["att-old", "att-uC"])
    }

    /// The repository's own guard, pinned apart from the store's question: a second edit job for
    /// a memo that still owes one is refused in the call that would write it, so one memo never
    /// owes two frozen PATCHes that would undo each other (review round 2).
    @Test("the repository writes one edit job per memo: a second enqueue for it is refused")
    func repositoryRefusesASecondEditJobForOneMemo() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        let first = try Fixture.file(in: root, named: "dock.heic", bytes: 1000)
        let second = try Fixture.file(in: root, named: "pier.heic", bytes: 1200)
        let written = try await repository.enqueue(
            content: "ignored", visibility: nil, capturedAt: Date(timeIntervalSince1970: 0),
            binding: Fixture.binding(),
            sources: [StagedSource(url: first, filename: "dock.heic", mime: "image/heic")],
            editing: editOrderForReview())

        await #expect(throws: OutboxStorageError.editPending) {
            try await repository.enqueue(
                content: "ignored", visibility: nil, capturedAt: Date(timeIntervalSince1970: 1),
                binding: Fixture.binding(),
                sources: [StagedSource(url: second, filename: "pier.heic", mime: "image/heic")],
                editing: editOrderForReview())
        }

        let jobs = try await repository.loadJobs()
        #expect(jobs.map(\.id) == [written.id], "the second edit was written beside the first")
    }

    private func editOrderForReview() -> MemoEditOrder {
        MemoEditOrder(
            memoUID: "m9", content: "the dock, later", visibility: nil, createdAt: nil,
            pictures: [.kept("att-old"), .adding(0)])
    }
}

/// Set once the harness exists; read by the probe hook, which is built before it.
final class EditJobRepositoryBox: @unchecked Sendable {
    var repository: OutboxRepository?
}
