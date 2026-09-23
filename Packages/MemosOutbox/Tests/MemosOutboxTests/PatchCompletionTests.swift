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
private final class MemoServer: @unchecked Sendable {
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

    init(losingResponses: Int = 0, losingPatchResponses: Int = 0, replayStatus: Int = 201) {
        lostCreateResponses = losingResponses
        lostPatchResponses = losingPatchResponses
        self.replayStatus = replayStatus
    }

    var memoCount: Int { lock.withLock { order.count } }
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
        credentials: OutboxCredentials,
        under authority: SendAuthority
    ) async -> MemoPatchOutcome {
        await entered.open()
        await released.wait()
        return await inner.patch(job: job, credentials: credentials, under: authority)
    }
}

@MainActor
private struct Patching {
    let root: URL
    let repository: OutboxRepository
    let http: ScriptedHTTP
    let server: MemoServer
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
        server: MemoServer = MemoServer(),
        clock: MutableClock? = nil,
        completion: (@Sendable (any MemoCompleting) -> any MemoCompleting)? = nil
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
                return ScriptedHTTP.session(uid: "uC", chunkSize: 5 * 1024 * 1024, received: 0)
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
        let endpoint = MemoCompletionEndpoint(http: http)
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
            http: http,
            scheduler: ScriptedScheduler(),
            completion: completion?(endpoint) ?? endpoint,
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: tick
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

    // MARK: - 2f: the edited restored draft, the full edit

    @Test("an edited restored draft becomes one memo carrying every edit")
    func theEditedDraftIsAppliedAsOneEdit() async throws {
        let harness = try harness(server: MemoServer(losingResponses: 1))
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
        #expect(resubmitted)
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

    // MARK: - rulings 7 and 8: the replayed create is one memo

    @Test("a replay answered 201 with the same uid makes no second memo", arguments: [201, 200])
    func aReplayedCreateIsOneMemo(status: Int) async throws {
        let harness = try harness(
            server: MemoServer(losingResponses: 1, replayStatus: status))
        defer { harness.cleanUp() }
        let job = try await capture(harness, files: [(name: "a.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        let resubmitted = await harness.outbox.resubmit(job.id, draft: draft)
        #expect(resubmitted)
        await settle(harness, job.id)

        #expect(harness.server.memoCount == 1)
        #expect(harness.memoPosts.count == 2)
        #expect(harness.memoPosts[1].httpBody == harness.memoPosts[0].httpBody)
        // Unedited: the create IS the whole answer, so no edit is sent at all.
        #expect(harness.memoPatches.count == 0)
        let remaining = await harness.repository.job(job.id)
        #expect(remaining == nil)
    }

    // MARK: - premise charge (iv): a create and an edit, never both, never neither

    @Test("a resubmit sends an edit exactly when there is one", arguments: [true, false])
    func createAndEditAreExclusive(editing: Bool) async throws {
        let harness = try harness(server: MemoServer(losingResponses: 1))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        let wanted = editing ? editedDraft(draft, picking: try newPicture(harness)) : draft
        let resubmitted = await harness.outbox.resubmit(job.id, draft: wanted)
        #expect(resubmitted)
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

    // MARK: - 2h: the job survives the replay, and a relaunch drives the edit home

    @Test("a relaunch before the edit was sent drives it home")
    func aRelaunchBeforeTheEditFinishesIt() async throws {
        let server = MemoServer(losingResponses: 1)
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
        #expect(resubmitted)
        let minted = try #require(await first.repository.job(job.id)?.editKey)
        #expect(minted != job.idempotencyKey.uuidString)
        _ = try await stagedUpload(first, job.id)

        let parked = Task { await first.outbox.drain() }
        await entered.wait()

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
        let server = MemoServer(losingResponses: 1, losingPatchResponses: 1)
        let first = try harness(server: server)
        defer { first.cleanUp() }
        let job = try await capture(
            first, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(first, job)
        await first.outbox.drain()
        let draft = try #require(await first.outbox.cancel(job.id))
        let wanted = editedDraft(draft, picking: try newPicture(first))
        let resubmitted = await first.outbox.resubmit(job.id, draft: wanted)
        #expect(resubmitted)
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

    // MARK: - item 4's outbox half: when the confirmed bytes last moved

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

    // MARK: - F8/F3/N1/N2: the edit is one logical edit, sent once it can be

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
        let server = MemoServer(losingResponses: 1, losingPatchResponses: 1)
        let harness = try harness(server: server, clock: clock)
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        let resubmitting = Task { await harness.outbox.resubmit(job.id, draft: textEdited(draft)) }
        #expect(await resubmitting.value)

        #expect(harness.memoPatches.count == 1)
        let carried = try #require(await harness.repository.job(job.id))
        let minted = try #require(carried.editKey)
        #expect(carried.editSentAt == nil, "a refused edit is still marked as in flight")
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
        let harness = try harness(server: MemoServer(losingResponses: 1))
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
        #expect(await resubmitting.value)

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
        let harness = try harness(server: MemoServer(losingResponses: 2))
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
        #expect(await resubmitting.value)

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
            server: MemoServer(losingResponses: 1),
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
        await entered.wait()

        #expect(await harness.outbox.cancel(job.id) == nil, "an edit in flight was taken back")
        let carried = try #require(await harness.repository.job(job.id))
        #expect(carried.editSentAt != nil)
        #expect(carried.cancelledAt == nil, "the refused cancel marked the capture anyway")

        await released.open()
        #expect(await resubmitting.value)
    }

    @Test("a second edit is sent under a key of its own")
    func aSecondEditIsSentUnderItsOwnKey() async throws {
        let harness = try harness(server: MemoServer(losingResponses: 2))
        defer { harness.cleanUp() }
        let job = try await capture(
            harness, files: [(name: "a.heic", bytes: 400), (name: "b.heic", bytes: 400)])
        _ = try await uploaded(harness, job)
        await harness.outbox.drain()
        let draft = try #require(await harness.outbox.cancel(job.id))
        let firstResubmit = Task { await harness.outbox.resubmit(job.id, draft: textEdited(draft)) }
        #expect(await firstResubmit.value)
        let firstKey = try #require(await harness.repository.job(job.id)?.editKey)

        let again = try #require(await harness.outbox.cancel(job.id))
        var second = again
        second.content = "the pier, a week later"
        let secondResubmit = Task { await harness.outbox.resubmit(job.id, draft: second) }
        #expect(await secondResubmit.value)

        #expect(harness.memoPatches.count == 1)
        let key = try sent(try #require(harness.memoPatches.first))["edit_key"] as? String
        #expect(key != firstKey, "the second edit reused the first edit's key")
        #expect(key != job.idempotencyKey.uuidString, "the edit went out under the create's key")
    }
}
