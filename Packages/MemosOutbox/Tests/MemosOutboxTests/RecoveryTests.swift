import CryptoKit
import Foundation
import MemosOutbox
import Testing

/// A server whose answer to a create can name FEWER pictures than the create sent.
///
/// It keeps one attachment for a picture it recognises as a copy of one it already holds — a print
/// made from a screen — and names the one it kept by the bytes it kept. That is the only thing this
/// double does that the one in `PatchCompletionTests` does not, and it is the whole premise here:
/// the answer is shorter than the list that was sent, so identity by content names the screen and
/// the print is left nameable by nothing.
private final class MemoServer: @unchecked Sendable {
    struct Memo {
        var uid: String
        var attachmentUIDs: [String]
        /// The digest the answer reports for an attachment, where the server has one to report.
        var digests: [String: String]
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
    private var foldedOnto: String?

    init(losingResponses: Int = 0) {
        lostCreateResponses = losingResponses
    }

    func memo(_ uid: String) -> Memo? { lock.withLock { memos[uid] } }

    /// From here on a create's answer names ONE attachment, carrying this digest.
    func folds(onto digest: String) { lock.withLock { foldedOnto = digest } }

    func answerCreate(to request: URLRequest) -> OutboxHTTPResponse {
        let object = Self.object(request)
        let key = object["idempotency_key"] as? String ?? ""
        let uploads = object["upload_uids"] as? [String] ?? []
        return lock.withLock {
            let uid: String
            if let existing = committed[key] {
                uid = existing
            } else {
                uid = "m\(order.count + 1)"
                committed[key] = uid
                order.append(uid)
                var uids = uploads.map { "att-\($0)" }
                var digests: [String: String] = [:]
                if let foldedOnto, let kept = uids.first {
                    uids = [kept]
                    digests[kept] = foldedOnto
                }
                memos[uid] = Memo(
                    uid: uid,
                    attachmentUIDs: uids,
                    digests: digests,
                    content: object["content"] as? String,
                    createdAt: object["created_at"] as? String,
                    visibility: object["visibility"] as? String
                )
            }
            guard lostCreateResponses == 0 else {
                lostCreateResponses -= 1
                return OutboxHTTPResponse(statusCode: 503)
            }
            return ScriptedHTTP.json(Self.body(memos[uid]!), status: 201)
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
                if let listed = object["attachment_uids"] as? [String] {
                    let supplied = Set(object["upload_uids"] as? [String] ?? [])
                    memo.attachmentUIDs = listed.map { supplied.contains($0) ? "att-\($0)" : $0 }
                }
                memos[uid] = memo
            }
            return ScriptedHTTP.json(Self.body(memo), status: 200)
        }
    }

    private static func body(_ memo: Memo) -> [String: Any] {
        let attachments: [[String: Any]] = memo.attachmentUIDs.enumerated().map {
            var entry: [String: Any] = ["uid": $1, "position": $0]
            if let digest = memo.digests[$1] { entry["sha256"] = digest }
            return entry
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

private struct Recovering {
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

    /// Edits only: a chunk is a PATCH as well, and it goes to the upload session, not to the memo.
    var memoPatches: [URLRequest] {
        http.requests(method: "PATCH").filter {
            ($0.url?.path() ?? "").hasPrefix("/api/memos/")
        }
    }
}

/// Sending again an original the create's answer never named.
///
/// Its own file, and its own server: the premise is an answer SHORTER than the list that was sent,
/// which the completion witnesses' server cannot produce, and a case about the recovery is a case
/// about what the queue does with a picture nothing can name.
@MainActor
@Suite("A picture the create's answer never named")
struct RecoveryTests {
    private func harness(server: MemoServer = MemoServer()) throws -> Recovering {
        let root = try Fixture.temporaryDirectory()
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
        let outbox = Outbox(
            repository: repository,
            credentials: provider,
            http: http,
            scheduler: ScriptedScheduler(),
            completion: MemoCompletionEndpoint(http: http),
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: Date.init
        )
        return Recovering(
            root: root,
            repository: repository,
            http: http,
            server: server,
            outbox: outbox,
            preferencesName: preferences.name
        )
    }

    private static let captured = Date(timeIntervalSince1970: 1_750_000_000)

    private func capture(
        _ harness: Recovering,
        files: [(name: String, bytes: Int)]
    ) async throws -> UploadJob {
        var sources: [StagedSource] = []
        for file in files {
            let url = try Fixture.file(in: harness.root, named: file.name, bytes: file.bytes)
            sources.append(StagedSource(url: url, filename: file.name, mime: "image/heic"))
        }
        return try await harness.repository.enqueue(
            content: "the pier, twice",
            visibility: "PRIVATE",
            capturedAt: Self.captured,
            binding: Fixture.binding(),
            sources: sources
        )
    }

    @discardableResult
    private func standing(
        _ harness: Recovering,
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
    private func uploaded(_ harness: Recovering, _ job: UploadJob) async throws -> UploadJob {
        try await standing(harness, job) { candidate in
            for index in candidate.files.indices {
                candidate.files[index].uploadUID = "u\(index + 1)"
                candidate.files[index].bytesConfirmed = candidate.files[index].byteSize
            }
        }
    }

    /// The uid a picture uploads under once the queue has staged it for sending again: the
    /// scheduler double swallows the chunks, so the bytes are marked arrived here instead.
    @discardableResult
    private func staged(_ harness: Recovering, _ jobID: UUID) async throws -> UploadJob {
        let job = try #require(await harness.repository.job(jobID))
        let index = try #require(job.files.firstIndex { !$0.isComplete })
        return try await standing(harness, job) { candidate in
            candidate.files[index].uploadUID = "uC"
            candidate.files[index].bytesConfirmed = candidate.files[index].byteSize
        }
    }

    /// Drains until the job is gone or the passes run out: the create's resolution, the recovery
    /// and the edit are separate advances by construction, and pinning their number would assert
    /// the engine's loop shape rather than what reached the wire.
    private func settle(_ harness: Recovering, _ jobID: UUID, passes: Int = 4) async {
        for _ in 0..<passes {
            if await harness.repository.job(jobID) == nil { return }
            await harness.outbox.drain()
        }
    }

    private func sent(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func hexDigest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @Test("a picture the memo's answer folded away is sent again, and the edit names both")
    func aFoldedOriginalIsSentAgainAndTheEditNamesBoth() async throws {
        let server = MemoServer(losingResponses: 1)
        let harness = try harness(server: server)
        defer { harness.cleanUp() }
        let job = try await capture(
            harness,
            files: [(name: "pier.heic", bytes: 400), (name: "pier - print.heic", bytes: 600)]
        )
        _ = try await uploaded(harness, job)
        // The screen is the copy the server keeps; the print made from it folds onto it, so the
        // answer names one attachment and the print's own bytes appear in it nowhere.
        server.folds(
            onto: try hexDigest(harness.repository.mediaURL(job: job, file: job.files[0])))
        await harness.outbox.drain()
        // The premise: nothing has resolved yet, so the re-submit cannot make anything nameable
        // against a memo it cannot name.
        #expect(await harness.repository.job(job.id)?.resolvedMemoUID == nil)
        let draft = try #require(await harness.outbox.cancel(job.id))
        var edited = draft
        edited.content = "the pier, the day after"
        #expect(await harness.outbox.resubmit(job.id, draft: edited) == .accepted)

        await settle(harness, job.id, passes: 3)

        #expect(
            harness.server.memo("m1")?.attachmentUIDs.count == 1,
            "the premise is gone: the server kept both pictures")
        _ = try #require(
            await harness.repository.job(job.id)?.files.first { $0.stagedForEdit == true },
            "the picture the answer never named was not staged for sending again")
        try await staged(harness, job.id)

        await settle(harness, job.id, passes: 4)

        #expect(harness.memoPatches.count == 1, "the edit never reached the wire")
        let body = try sent(try #require(harness.memoPatches.first))
        #expect(
            (body["attachment_uids"] as? [String])?.count == 2,
            "the edit dropped a picture the memo keeps")
        #expect(await harness.repository.job(job.id) == nil)
    }
}

/// The answer a finished upload leaves behind after the picture it uploaded was staged again.
///
/// At the engine, because `handle` is where a chunk answer is matched against the manifest and
/// nothing above the engine reaches it.
@Suite("A late answer to a picture that was staged again")
struct RecoveredUploadTermTests {
    @Test("the answer the predecessor left behind does not count for the picture that replaced it")
    func aLatePredecessorAnswerDoesNotCreditTheReplacement() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        let uploaded = try #require(
            await harness.repository.save(
                {
                    var candidate = harness.job
                    candidate.resolvedMemoUID = "m1"
                    candidate.files[0].uploadUID = "uA"
                    candidate.files[0].bytesConfirmed = candidate.files[0].byteSize
                    candidate.files[0].uploadAttempt = 3
                    candidate.pendingEdit = PendingEdit(
                        content: "the pier, the day after",
                        visibility: "PRIVATE",
                        capturedAt: harness.now,
                        fileIDs: [candidate.files[0].id]
                    )
                    return candidate
                }(),
                ifStillCurrent: nil,
                matching: harness.job,
                else: harness.job
            )
        )
        let fileID = uploaded.files[0].id

        await harness.engine.drain()

        let recovered = try #require(await harness.reload()?.files[0])
        #expect(
            recovered.stagedForEdit == true && recovered.bytesConfirmed == 0,
            "the picture the memo's answer never named was not staged for sending again")

        // What the task that finished just before the recovery answers with: the same file, the
        // same offset the replacement starts at, and the term the manifest carried when it was
        // sent. Only the term tells the two apart.
        await harness.engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(
                    jobID: harness.job.id, fileID: fileID, offset: 0, attempt: 3),
                statusCode: 200,
                body: ScriptedHTTP.session(
                    uid: "uA", chunkSize: 400, received: Int(uploaded.files[0].byteSize)
                ).body
            )
        )

        let after = try #require(await harness.reload()?.files[0])
        #expect(
            after.bytesConfirmed == 0,
            "the finished predecessor's answer was credited to the picture that replaced it")
        #expect(after.isComplete == false)
    }
}
