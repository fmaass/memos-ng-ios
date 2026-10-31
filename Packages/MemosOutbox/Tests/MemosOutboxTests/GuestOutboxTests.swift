import CryptoKit
import Foundation
import Testing

@testable import MemosOutbox

private let mib: Int64 = 1024 * 1024

private func guestCredentials(epoch: Int = 0) -> OutboxCredentials {
    OutboxCredentials(
        serverBaseURL: GuestDoor.baseURL, ownerSubject: "device-1", token: "guest-token",
        epoch: epoch, kind: .guest
    )
}

private func guestBinding() -> AccountBinding {
    AccountBinding(serverBaseURL: GuestDoor.baseURL, ownerSubject: "device-1", kind: .guest)
}

@Suite("Guest: every PATCH body is held to the door's 64 MiB ceiling")
struct GuestPatchPlanTests {
    @Test("the empty file, one byte, exactly the ceiling, one past it")
    func boundaries() {
        let limit = GuestPatchPlan.ceiling
        #expect(GuestPatchPlan.bodies(from: 0, byteSize: 0, limit: limit).isEmpty)
        #expect(GuestPatchPlan.bodies(from: 0, byteSize: 1, limit: limit) == [0..<1])
        #expect(
            GuestPatchPlan.bodies(from: 0, byteSize: 64 * mib, limit: limit) == [0..<(64 * mib)])
        #expect(
            GuestPatchPlan.bodies(from: 0, byteSize: 64 * mib + 1, limit: limit)
                == [0..<(64 * mib), (64 * mib)..<(64 * mib + 1)])
    }

    @Test("a 300 MB video and an odd resume offset: contiguous, complete, none over 64 MiB")
    func largeAndResumed() {
        let size: Int64 = 300_000_000
        for offset: Int64 in [0, 12_345_677] {
            // A manifest slice larger than the door accepts is still cut to the ceiling.
            let bodies = GuestPatchPlan.bodies(from: offset, byteSize: size, limit: 200 * mib)
            #expect(bodies.first?.lowerBound == offset)
            #expect(bodies.last?.upperBound == size)
            #expect(bodies.allSatisfy { $0.upperBound - $0.lowerBound <= 64 * mib })
            #expect(zip(bodies, bodies.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        }
    }

    @Test("a reported limit is used below the ceiling and never above it")
    func reportedLimit() {
        #expect(GuestPatchPlan.limit(reported: nil) == GuestPatchPlan.ceiling)
        #expect(GuestPatchPlan.limit(reported: 0) == GuestPatchPlan.ceiling)
        #expect(GuestPatchPlan.limit(reported: -5) == GuestPatchPlan.ceiling)
        #expect(GuestPatchPlan.limit(reported: 1 * mib) == 1 * mib)
        #expect(GuestPatchPlan.limit(reported: 128 * mib) == GuestPatchPlan.ceiling)
    }

    @Test("a resume offset beyond the local file is refused, at or below it is used")
    func resumeBeyondFile() throws {
        #expect(try GuestPatchPlan.resumeOffset(reported: 10, byteSize: 10) == 10)
        #expect(try GuestPatchPlan.resumeOffset(reported: 0, byteSize: 10) == 0)
        #expect(throws: GuestPatchPlan.ResumeRefusal.offsetBeyondFile(reported: 11, byteSize: 10)) {
            try GuestPatchPlan.resumeOffset(reported: 11, byteSize: 10)
        }
    }
}

@Suite("Guest: the door's wire answers")
struct GuestWireTests {
    private func answer(_ object: [String: Any]) -> GuestWire.UploadAnswer? {
        GuestWire.decode(
            GuestWire.UploadAnswer.self, from: try! JSONSerialization.data(withJSONObject: object))
    }

    @Test("already received, a missing or empty uid, and the slice clamp")
    func uploadStart() {
        #expect(answer(["already_received": true])?.start == .alreadyReceived)
        #expect(answer(["chunk_size": 1024])?.start == nil)
        #expect(answer(["upload_uid": "", "chunk_size": 1024])?.start == nil)
        let huge = answer(["upload_uid": "u1", "chunk_size": 128 * 1024 * 1024])?.start
        #expect(
            huge == .session(.init(uploadUID: "u1", chunkSize: 64 * 1024 * 1024, bytesReceived: 0)))
        let small = answer(["upload_uid": "u1", "chunk_size": 5_242_880, "bytes_received": 7])?
            .start
        #expect(small == .session(.init(uploadUID: "u1", chunkSize: 5_242_880, bytesReceived: 7)))
        let capped = answer([
            "upload_uid": "u1", "chunk_size": 5_242_880, "max_patch_bytes": 1_048_576,
        ])?.start
        #expect(capped == .session(.init(uploadUID: "u1", chunkSize: 1_048_576, bytesReceived: 0)))
    }

    @Test("a pass link is read only from the door's own https origin")
    func passLink() {
        let secret = { GuestDoor.secret(fromPassLink: URL(string: $0)!) }
        #expect(secret("https://trip.discomarder.live/p/abc123") == "abc123")
        #expect(secret("https://TRIP.discomarder.live/p/abc123") == "abc123")
        #expect(secret("http://trip.discomarder.live/p/abc123") == nil)
        #expect(secret("https://trip.discomarder.live.evil.example/p/abc123") == nil)
        #expect(secret("https://memos.discomarder.live/p/abc123") == nil)
        #expect(secret("https://trip.discomarder.live:8443/p/abc123") == nil)
        #expect(secret("https://trip.discomarder.live/p/abc123/more") == nil)
        #expect(secret("https://trip.discomarder.live/x/abc123") == nil)
        #expect(secret("https://trip.discomarder.live/p/") == nil)
    }
}

@Suite("Guest: an ended pass ends the guest credential only")
struct GuestRefusalTests {
    @Test("a guest 410 is about the credential; a member 410 is not")
    func guestGoneVsMemberGone() {
        let guest = OutboxRefusal(statusCode: 410, issuedUnder: 3, what: "upload", kind: .guest)
        #expect(guest.concernsCredential)
        if case .hold(let reason, let message) = guest.disposition(assumingCurrent: true) {
            #expect(reason == .signInRequired)
            #expect(message.contains("trip pass has ended"))
        } else {
            Issue.record("a guest 410 under the current pass did not hold")
        }
        if case .backOff = guest.disposition(assumingCurrent: false) {
        } else {
            Issue.record("a guest 410 under a replaced pass stranded the capture")
        }
        let member = OutboxRefusal(statusCode: 410, issuedUnder: 3, what: "upload")
        #expect(!member.concernsCredential)
        if case .hold(let reason, _) = member.disposition(assumingCurrent: true) {
            #expect(reason != .signInRequired)
        }
    }

    @Test("a guest 401 holds under its own sentence, a member 401 keeps the member's")
    func guestUnauthorized() {
        let guest = OutboxRefusal(statusCode: 401, issuedUnder: 1, what: "upload", kind: .guest)
        let member = OutboxRefusal(statusCode: 401, issuedUnder: 1, what: "upload")
        #expect(
            guest.disposition(assumingCurrent: true)
                == .hold(.signInRequired, "This trip pass has ended."))
        #expect(
            member.disposition(assumingCurrent: true)
                == .hold(.signInRequired, "Sign in again to send this memo."))
    }
}

@Suite("Guest: bindings and licences carry the kind without changing a member's bytes")
struct GuestBindingTests {
    @Test("a member binding is written without the key; a spelled-out member decodes equal")
    func memberUnchanged() throws {
        let member = Fixture.binding()
        let encoded = try JSONEncoder().encode(member)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["kind"] == nil)
        #expect(Set(object?.keys.map { $0 } ?? []) == ["serverBaseURL", "ownerSubject"])
        let spelled = Data(
            #"{"serverBaseURL":"https://memos.example.invalid","ownerSubject":"fabian","kind":"member"}"#
                .utf8)
        #expect(try JSONDecoder().decode(AccountBinding.self, from: spelled) == member)
    }

    @Test("a guest binding round-trips and matches only guest credentials")
    func guestRoundTrip() throws {
        let guest = guestBinding()
        let decoded = try JSONDecoder().decode(
            AccountBinding.self, from: try JSONEncoder().encode(guest))
        #expect(decoded == guest)
        #expect(decoded.credentialKind == .guest)
        #expect(guest.matches(guestCredentials()))
        var member = guestCredentials()
        member.kind = .member
        #expect(!guest.matches(member))
        #expect(
            !AccountBinding(serverBaseURL: GuestDoor.baseURL, ownerSubject: "device-1").matches(
                guestCredentials()))
    }

    @Test("a published licence keeps its kind; a member licence has no kind key")
    func licence() throws {
        let guest = PublishedLicence(binding: guestBinding(), incarnation: UUID())
        let back = try JSONDecoder().decode(
            PublishedLicence.self, from: try JSONEncoder().encode(guest))
        #expect(back == guest)
        #expect(back.binding.credentialKind == .guest)
        let member = PublishedLicence(binding: Fixture.binding(), incarnation: nil)
        let raw = try JSONEncoder().encode(member)
        let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        #expect(object?["kind"] == nil)
        #expect(try JSONDecoder().decode(PublishedLicence.self, from: raw) == member)
    }
}

@Suite("Guest: requests go to the guest door's routes, members' stay as they were")
struct GuestRequestTests {
    private let file = OutboxFile(
        relativePath: "f0", filename: "beach.heic", mime: "image/heic", byteSize: 1234,
        lastModified: Date(timeIntervalSince1970: 1_700_000_000))

    @Test("the guest create carries sha256 to /api/guest/uploads on the door")
    func guestCreate() throws {
        let request = try OutboxRequests.startUpload(
            baseURL: GuestDoor.baseURL, token: "guest-token", file: file, kind: .guest,
            sha256: "ab12")
        #expect(request.url?.absoluteString == "https://trip.discomarder.live/api/guest/uploads")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer guest-token")
        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(object?["sha256"] as? String == "ab12")
        #expect(object?["size"] as? Int == 1234)
        #expect(object?["filename"] as? String == "beach.heic")
    }

    @Test("the member create is byte-identical to the member wire body, with no sha256")
    func memberCreate() throws {
        let request = try OutboxRequests.startUpload(
            baseURL: Fixture.server, token: "pat-token", file: file)
        #expect(request.url?.absoluteString == "https://memos.example.invalid/api/uploads")
        let expected = try OutboxWire.encode(
            OutboxWire.UploadStart(
                filename: "beach.heic", mime: "image/heic", size: 1234,
                lastModified: 1_700_000_000_000))
        #expect(request.httpBody == expected)
        #expect(
            String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("sha256") == false)
    }

    @Test("chunk and offset HEAD address the guest upload by uid; member paths unchanged")
    func chunkAndHead() {
        let chunk = OutboxRequests.chunk(
            baseURL: GuestDoor.baseURL, token: "t", uploadUID: "u9", offset: 5, kind: .guest)
        #expect(chunk.url?.absoluteString == "https://trip.discomarder.live/api/guest/uploads/u9")
        #expect(chunk.httpMethod == "PATCH")
        #expect(chunk.value(forHTTPHeaderField: "Upload-Offset") == "5")
        let head = OutboxRequests.offset(
            baseURL: GuestDoor.baseURL, token: "t", uploadUID: "u9", kind: .guest)
        #expect(head.url?.absoluteString == "https://trip.discomarder.live/api/guest/uploads/u9")
        #expect(head.httpMethod == "HEAD")
        let member = OutboxRequests.chunk(
            baseURL: Fixture.server, token: "t", uploadUID: "u9", offset: 5)
        #expect(member.url?.absoluteString == "https://memos.example.invalid/api/uploads/u9")
        let memberHead = OutboxRequests.offset(baseURL: Fixture.server, token: "t", uploadUID: "u9")
        #expect(memberHead.url?.absoluteString == "https://memos.example.invalid/api/uploads/u9")
    }
}

@Suite("Guest: the planner")
struct GuestPlannerTests {
    private static let now = Date(timeIntervalSince1970: 1000)

    private static func job(_ files: [OutboxFile], binding: AccountBinding = guestBinding())
        -> UploadJob
    {
        var job = UploadJob(content: "trip", capturedAt: now, files: files, binding: binding)
        job.nextAttemptAt = now
        return job
    }

    private static func file(_ name: String, size: Int64) -> OutboxFile {
        OutboxFile(relativePath: name, filename: name, mime: "image/heic", byteSize: size)
    }

    @Test("a file the door already holds is never started; the next one is")
    func skipsAlreadyReceived() {
        var received = Self.file("a.heic", size: 10)
        received.alreadyReceived = true
        let pending = Self.file("b.heic", size: 10)
        let job = Self.job([received, pending])
        #expect(
            OutboxPlanner.nextAction(for: job, credentials: guestCredentials(), now: Self.now)
                == .startUpload(fileID: pending.id))
        let all = Self.job([received])
        #expect(
            OutboxPlanner.nextAction(for: all, credentials: guestCredentials(), now: Self.now)
                == .createMemo)
    }

    @Test("an empty guest file is held before any request; a member's is not")
    func emptyGuestFile() {
        let empty = Self.job([Self.file("zero.heic", size: 0)])
        #expect(
            OutboxPlanner.nextAction(for: empty, credentials: guestCredentials(), now: Self.now)
                == .hold(.serverRefused))
        #expect(
            OutboxPlanner.holdMessage(
                for: .serverRefused, of: empty, credentials: guestCredentials())?.contains("empty")
                == true)
        let member = Self.job([Self.file("zero.heic", size: 0)], binding: Fixture.binding())
        #expect(
            OutboxPlanner.nextAction(for: member, credentials: Fixture.credentials(), now: Self.now)
                != .hold(.serverRefused))
    }

    @Test("a guest resume at an odd offset with an oversized slice sends at most 64 MiB")
    func guestResumeCapped() throws {
        var file = Self.file("v.mov", size: 300_000_000)
        file.uploadUID = "u1"
        file.chunkSize = Int(200 * mib)
        file.bytesConfirmed = 12_345_677
        let guest = OutboxPlanner.nextAction(
            for: Self.job([file]), credentials: guestCredentials(), now: Self.now)
        #expect(guest == .uploadChunk(fileID: file.id, offset: 12_345_677, length: Int(64 * mib)))
        // The member lane keeps the slice its server handed out.
        let member = OutboxPlanner.nextAction(
            for: Self.job([file], binding: Fixture.binding()), credentials: Fixture.credentials(),
            now: Self.now)
        #expect(member == .uploadChunk(fileID: file.id, offset: 12_345_677, length: Int(200 * mib)))
    }
}

@Suite("Guest: the completion")
struct GuestCompletionTests {
    private static func job(uids: [String?], content: String = "sunset") -> UploadJob {
        UploadJob(
            content: content, capturedAt: Date(timeIntervalSince1970: 1000),
            files: uids.enumerated().map { index, uid in
                var file = OutboxFile(
                    relativePath: "f\(index)", filename: "f\(index).heic", mime: "image/heic",
                    byteSize: 10)
                file.uploadUID = uid
                if uid == nil { file.alreadyReceived = true }
                return file
            },
            binding: guestBinding())
    }

    @Test("posts upload_uids and caption to /api/guest/memos and reads the batch")
    func posts() async throws {
        let http = ScriptedHTTP { _ in
            ScriptedHTTP.json(["batch_id": "b-1", "status": "received"], status: 201)
        }
        let outcome = await GuestCompletionEndpoint(http: http).create(
            job: Self.job(uids: ["u1", nil, "u2"]), credentials: guestCredentials(),
            under: SendAuthority({ true }))
        #expect(outcome == .created(uid: "b-1"))
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://trip.discomarder.live/api/guest/memos")
        #expect(request.httpMethod == "POST")
        let object =
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            as? [String: Any]
        #expect(object?["upload_uids"] as? [String] == ["u1", "u2"])
        #expect(object?["caption"] as? String == "sunset")
    }

    @Test("an empty caption is sent as no caption")
    func emptyCaption() async throws {
        let http = ScriptedHTTP { _ in ScriptedHTTP.json(["batch_id": "b-2"], status: 201) }
        _ = await GuestCompletionEndpoint(http: http).create(
            job: Self.job(uids: ["u1"], content: ""), credentials: guestCredentials(),
            under: SendAuthority({ true }))
        let body = try #require(http.requests.first?.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(object?["caption"] == nil || object?["caption"] is NSNull)
    }

    @Test("a capture whose every file was already received sends nothing")
    func emptyListSendsNothing() async {
        let http = ScriptedHTTP { _ in OutboxHTTPResponse(statusCode: 500) }
        let job = Self.job(uids: [nil, nil])
        let outcome = await GuestCompletionEndpoint(http: http).create(
            job: job, credentials: guestCredentials(), under: SendAuthority({ true }))
        #expect(http.requests.isEmpty)
        #expect(outcome == .created(uid: job.idempotencyKey.uuidString))
    }

    @Test("a 401 and a 410 are guest refusals carrying the presenting epoch")
    func refusalsCarryEpoch() async throws {
        for status in [401, 410] {
            let http = ScriptedHTTP { _ in OutboxHTTPResponse(statusCode: status) }
            let outcome = await GuestCompletionEndpoint(http: http).create(
                job: Self.job(uids: ["u1"]), credentials: guestCredentials(epoch: 7),
                under: SendAuthority({ true }))
            guard case .refused(_, let refusal?) = outcome else {
                Issue.record("\(status) was not a typed refusal: \(outcome)")
                continue
            }
            #expect(refusal.kind == .guest)
            #expect(refusal.issuedUnder == 7)
            #expect(refusal.statusCode == status)
            #expect(refusal.concernsCredential)
        }
    }

    @Test("a refusal earned by a pass since replaced is retried, not held")
    func replacedPassRetries() async {
        let http = ScriptedHTTP { _ in OutboxHTTPResponse(statusCode: 410) }
        let replaced = SendAuthority({ false })
        let outcome = await GuestCompletionEndpoint(http: http).create(
            job: Self.job(uids: ["u1"]), credentials: guestCredentials(), under: replaced)
        // The scripted performer refuses a withdrawn authority before it sends, which is itself a
        // retry; either way nothing holds.
        if case .retry = outcome {} else { Issue.record("held on a replaced pass: \(outcome)") }
    }
}

@Suite("Guest: the engine on the chunk lane")
struct GuestEngineTests {
    private struct Harness {
        let root: URL
        let repository: OutboxRepository
        let scheduler: ScriptedScheduler
        let engine: OutboxEngine
        let job: UploadJob
        let source: URL
        let preferencesName: String

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            Fixture.forgetting(preferencesName)
        }
    }

    private func harness(
        http: ScriptedHTTP, credentials: OutboxCredentials, binding: AccountBinding,
        bytes: Int = 1000
    ) async throws -> Harness {
        let root = try Fixture.temporaryDirectory()
        let provider = StaticCredentials(credentials: credentials)
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        let source = try Fixture.file(in: root, named: "one.heic", bytes: bytes)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let job = try await repository.enqueue(
            content: "at the lake", visibility: nil, capturedAt: now, binding: binding,
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")])
        let scheduler = ScriptedScheduler()
        let preferences = Fixture.preferences()
        let engine = OutboxEngine(
            repository: repository,
            credentials: provider,
            http: http,
            scheduler: scheduler,
            completion: GuestCompletionEndpoint(http: http),
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: { now }
        )
        return Harness(
            root: root, repository: repository, scheduler: scheduler, engine: engine, job: job,
            source: source, preferencesName: preferences.name)
    }

    private static func door(create: OutboxHTTPResponse, head: Int = 0) -> ScriptedHTTP {
        ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"): return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/guest/uploads"): return create
            case ("HEAD", _):
                return OutboxHTTPResponse(statusCode: 200, headers: ["Upload-Offset": String(head)])
            case ("POST", "/api/guest/memos"):
                return ScriptedHTTP.json(["batch_id": "b-1"], status: 201)
            default: return OutboxHTTPResponse(statusCode: 500)
            }
        }
    }

    @Test("an already-received create sends no PATCH, and its body carried the sha256")
    func alreadyReceived() async throws {
        let http = Self.door(create: ScriptedHTTP.json(["already_received": true], status: 201))
        let harness = try await harness(
            http: http, credentials: guestCredentials(), binding: guestBinding())
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.scheduler.uploads.isEmpty, "a PATCH was scheduled for received bytes")
        #expect(http.requests(method: "PATCH").isEmpty)
        let create = try #require(
            http.requests(method: "POST").first { $0.url?.path() == "/api/guest/uploads" })
        #expect(create.url?.host() == "trip.discomarder.live")
        let object =
            try JSONSerialization.jsonObject(with: create.httpBody ?? Data())
            as? [String: Any]
        let expected = SHA256.hash(data: try Data(contentsOf: harness.source))
            .map { String(format: "%02x", $0) }.joined()
        #expect(object?["sha256"] as? String == expected)
        // Every file was received, so the completion has nothing to link and sends nothing.
        #expect(!http.requests.contains { $0.url?.path() == "/api/guest/memos" })
        #expect(await harness.repository.job(harness.job.id) == nil, "the capture did not finish")
    }

    @Test("a guest create answered 410 holds as an ended pass; a member's 410 does not")
    func goneCreate() async throws {
        let gone = OutboxHTTPResponse(statusCode: 410)
        let guest = try await harness(
            http: Self.door(create: gone), credentials: guestCredentials(), binding: guestBinding())
        defer { guest.cleanUp() }
        await guest.engine.drain()
        let held = try #require(await guest.repository.job(guest.job.id))
        #expect(held.state == .held)
        #expect(held.holdReason == .signInRequired)
        #expect(held.lastError?.contains("trip pass has ended") == true)

        let memberHTTP = ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"): return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/uploads"): return gone
            default: return OutboxHTTPResponse(statusCode: 500)
            }
        }
        let member = try await harness(
            http: memberHTTP, credentials: Fixture.credentials(), binding: Fixture.binding())
        defer { member.cleanUp() }
        await member.engine.drain()
        let memberJob = try #require(await member.repository.job(member.job.id))
        #expect(memberJob.holdReason != .signInRequired)
    }

    @Test("a HEAD claiming more bytes than the file has holds instead of marking it sent")
    func offsetBeyondFile() async throws {
        let http = Self.door(
            create: ScriptedHTTP.json(
                ["upload_uid": "g1", "chunk_size": 400, "bytes_received": 0], status: 201),
            head: 5000)
        let harness = try await harness(
            http: http, credentials: guestCredentials(), binding: guestBinding())
        defer { harness.cleanUp() }
        await harness.engine.drain()
        let sent = try #require(harness.scheduler.uploads.first)

        await harness.engine.handle(
            ChunkResult(
                identity: sent.identity, statusCode: 409,
                epoch: harness.scheduler.epoch(of: sent.identity)))

        let saved = try #require(await harness.repository.job(harness.job.id))
        #expect(saved.state == .held)
        #expect(saved.holdReason == .serverRefused)
        #expect(saved.files[0].bytesConfirmed == 0)
        #expect(http.requests(method: "HEAD").first?.url?.path() == "/api/guest/uploads/g1")
    }

    @Test("a capture deleted while its digest is read is neither created on the door nor revived")
    func deletedDuringDigest() async throws {
        let http = Self.door(
            create: ScriptedHTTP.json(
                ["upload_uid": "g1", "chunk_size": 400, "bytes_received": 0], status: 201))
        let harness = try await harness(
            http: http, credentials: guestCredentials(), binding: guestBinding())
        defer { harness.cleanUp() }
        let repository = harness.repository
        let job = harness.job
        await harness.engine.holdAfterDigest { await repository.delete(job) }

        await harness.engine.drain()

        #expect(
            !http.requests.contains { $0.url?.path() == "/api/guest/uploads" },
            "a create went out for a capture deleted during its digest")
        #expect(harness.scheduler.uploads.isEmpty)
        #expect(await repository.job(job.id) == nil, "the deleted capture came back")
    }
}

@Suite("Guest: the file digest is streamed and read off the engine")
struct GuestDigestTests {
    @Test("a multi-megabyte file hashes to its known SHA-256; so does the FIPS 'abc' vector")
    func knownVectors() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // 2.5 MiB + 3: three whole reads of the hasher's megabyte and a short tail, so a buffer
        // that dropped or repeated a read boundary hashes differently. Vector computed with
        // Python hashlib over the same `Fixture.content` bytes.
        let large = try Fixture.file(in: root, named: "video.mov", bytes: 2_621_443)
        #expect(
            await OutboxEngine.digest(of: large)
                == "d65729a2959c5986fd3fc10e47c7e1be4e6eed9d35bacf4df3910a42eb9ac4f0")
        let abc = root.appending(path: "abc")
        try Data("abc".utf8).write(to: abc)
        #expect(
            await OutboxEngine.digest(of: abc)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(await OutboxEngine.digest(of: root.appending(path: "missing")) == nil)
    }
}

@MainActor
@Suite("Guest: the composed guest outbox and its own background session")
struct GuestLiveOutboxTests {
    private static func eventually(_ condition: @MainActor () async -> Bool) async throws -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test("a guest-composed outbox creates on /api/guest/uploads and completes on /api/guest/memos")
    func routesOnlyToTheDoor() async throws {
        let root = try Fixture.temporaryDirectory()
        let preferences = Fixture.preferences()
        defer {
            try? FileManager.default.removeItem(at: root)
            Fixture.forgetting(preferences.name)
        }
        let provider = StaticCredentials(credentials: guestCredentials())
        let repository = try OutboxRepository(
            root: root.appending(path: "guest-outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 1000)
        let job = try await repository.enqueue(
            content: "at the lake", visibility: nil, capturedAt: Date(), binding: guestBinding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")])
        let http = ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"): return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/guest/uploads"):
                return ScriptedHTTP.session(uid: "g1", chunkSize: 4000, received: 0)
            case ("POST", "/api/guest/memos"):
                return ScriptedHTTP.json(["batch_id": "b-1"], status: 201)
            default: return OutboxHTTPResponse(statusCode: 500)
            }
        }
        let scheduler = ScriptedScheduler()
        let handler = AttemptHandlerBox()
        let outbox = Outbox.guestComposed(
            repository: repository,
            credentials: provider,
            http: http,
            chunks: scheduler,
            attachChunks: { attached in handler.value = attached },
            network: StubNetworkPath(),
            preferences: preferences.store
        )
        await outbox.adopt()
        await outbox.appBecameActive().value

        let chunk = try #require(scheduler.uploads.first, "no chunk was scheduled")
        #expect(chunk.url?.path() == "/api/guest/uploads/g1")
        let answer = try JSONSerialization.data(
            withJSONObject: ["upload_uid": "g1", "chunk_size": 4000, "bytes_received": 1000])
        let attached = try #require(handler.value, "the chunk lane was never attached")
        await attached.handle(
            ChunkResult(
                identity: chunk.identity, statusCode: 200, body: answer,
                epoch: scheduler.epoch(of: chunk.identity)))
        await outbox.drain()

        #expect(
            try await Self.eventually { await repository.job(job.id) == nil },
            "the capture did not finish")
        let paths = http.requests.compactMap { $0.url?.path() }
        #expect(paths.filter { $0 == "/api/guest/uploads" }.count == 1)
        #expect(paths.filter { $0 == "/api/guest/memos" }.count == 1)
        let allowed: Set<String> = ["/health", "/api/guest/uploads", "/api/guest/memos"]
        #expect(
            paths.allSatisfy { allowed.contains($0) },
            "a guest capture reached a member route: \(paths)")
        #expect(http.requests.allSatisfy { $0.url?.host() == "trip.discomarder.live" })
    }

    @Test("the guest session is its own, is answered for, and reports under its own name")
    func ownSession() async throws {
        #expect(OutboxSession.guestIdentifier != OutboxSession.identifier)
        #expect(OutboxSession.guestIdentifier != OutboxUploadSession.identifier)
        let configuration = OutboxSession.backgroundConfiguration(
            appGroup: "group.test.invalid", identifier: OutboxSession.guestIdentifier)
        #expect(configuration.identifier == OutboxSession.guestIdentifier)
        #expect(configuration.sharedContainerIdentifier == "group.test.invalid")
        #expect(
            OutboxSession.backgroundConfiguration(appGroup: "group.test.invalid").identifier
                == OutboxSession.identifier)

        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        let delegate = OutboxSessionDelegate(
            completion: box, identifier: OutboxSession.guestIdentifier)
        var guest = 0
        let wake = try #require(
            box.beginWake(for: OutboxSession.guestIdentifier) { guest += 1 },
            "a guest wake was not recognised as this outbox's")

        delegate.urlSessionDidFinishEvents(
            forBackgroundURLSession: URLSession(configuration: .ephemeral))
        #expect(
            try await Self.eventually { box.hasFinished(OutboxSession.guestIdentifier) })
        #expect(!box.hasFinished(OutboxSession.identifier))
        wake.leave()
        #expect(guest == 1)
    }
}

@Suite("Guest: a capture for the trip carries a file")
struct GuestCaptureNeedsAFileTests {
    // Mutation that turns it red: delete the guest-without-files guard in
    // `OutboxRepository.enqueue`, so a caption-only guest capture is written to the queue.
    @Test("a guest capture with no file is refused and writes nothing; one with a file is kept")
    func guestCaptureWithoutFilesIsRefused() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // No credential predicate: the refusal is decided before anything is sent or leased.
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        await #expect(throws: OutboxStorageError.guestCaptureWithoutFiles) {
            try await repository.enqueue(
                content: "only a caption", visibility: nil, capturedAt: now,
                binding: guestBinding(), sources: [])
        }
        let refused = try await repository.loadJobs()
        #expect(refused.isEmpty)

        // The two neighbours stay as they were: a guest capture WITH a file, and a member's
        // words-only memo, are both kept.
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 10)
        let photo = try await repository.enqueue(
            content: "", visibility: nil, capturedAt: now, binding: guestBinding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")])
        let member = AccountBinding(
            serverBaseURL: URL(string: "https://memos.example.invalid")!, ownerSubject: "users/1"
        )
        let words = try await repository.enqueue(
            content: "a memo", visibility: nil, capturedAt: now, binding: member, sources: [])
        let kept = try await Set(repository.loadJobs().map(\.id))
        #expect(kept == [photo.id, words.id])
    }
}
