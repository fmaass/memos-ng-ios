import Foundation
import MemosOutbox
import Testing

@Suite("Naming the memo's pictures in an edit")
struct PatchIdentityTests {
    private func edited(
        files: [OutboxFile],
        fileIDs: [UUID]? = nil
    ) -> UploadJob {
        var job = Fixture.job(files: files)
        job.visibility = "PRIVATE"
        job.resolvedMemoUID = "m1"
        job.editKey = UUID().uuidString
        job.pendingEdit = PendingEdit(
            content: "the pier, the day after",
            visibility: "PUBLIC",
            capturedAt: Date(timeIntervalSince1970: 1_751_111_111),
            fileIDs: fileIDs ?? files.map(\.id)
        )
        return job
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("two captures the server stored once both answer to the one attachment")
    func identicalBytesBindToOneUID() {
        let first = Fixture.file(uploadUID: "u1")
        let second = Fixture.file(uploadUID: "u2")
        let binding = OutboxAttachmentIdentity.bind(
            files: [first, second],
            digests: [first.id: "d", second.id: "d"],
            answer: [ResolvedAttachment(uid: "att-1", sha256: "d")]
        )
        #expect(binding[first.id] == "att-1")
        #expect(binding[second.id] == "att-1")
    }

    @Test("an answer that names no bytes is read in order, and only when it is complete")
    func positionalWhenTheCountsAgree() {
        let first = Fixture.file(uploadUID: "u1")
        let second = Fixture.file(uploadUID: "u2")
        let binding = OutboxAttachmentIdentity.bind(
            files: [first, second],
            digests: [:],
            answer: [
                ResolvedAttachment(uid: "att-1", sha256: nil),
                ResolvedAttachment(uid: "att-2", sha256: nil),
            ]
        )
        #expect(binding[first.id] == "att-1")
        #expect(binding[second.id] == "att-2")
    }

    /// A replayed create answers with the memo's CURRENT pictures. A digest there that matches
    /// nothing here is the server naming other bytes — a picture another client replaced — and
    /// order must not name this device's original as it.
    @Test(
        "a complete answer whose digests match nothing leaves every picture unnamed",
        arguments: [["other-1", "other-2"], ["other-1", nil]] as [[String?]]
    )
    func unboundWhenPresentDigestsDisagree(answered: [String?]) {
        let first = Fixture.file(uploadUID: "u1")
        let second = Fixture.file(uploadUID: "u2")
        let binding = OutboxAttachmentIdentity.bind(
            files: [first, second],
            digests: [first.id: "d1", second.id: "d2"],
            answer: [
                ResolvedAttachment(uid: "att-1", sha256: answered[0]),
                ResolvedAttachment(uid: "att-2", sha256: answered[1]),
            ]
        )
        #expect(binding.isEmpty, "order named a picture the server's digest says is not it")
    }

    @Test("a short answer nothing matches leaves every picture unnamed rather than guessed")
    func unboundWhenTheCountsDiffer() {
        let first = Fixture.file(uploadUID: "u1")
        let second = Fixture.file(uploadUID: "u2")
        let binding = OutboxAttachmentIdentity.bind(
            files: [first, second],
            digests: [first.id: "d1", second.id: "d2"],
            answer: [ResolvedAttachment(uid: "att-1", sha256: "elsewhere")]
        )
        #expect(binding.isEmpty)
    }

    @Test("an edit names the folded attachment once for every picture that resolved to it")
    func dedupedPicturesAreBothNamed() throws {
        var first = Fixture.file(uploadUID: "u1")
        var second = Fixture.file(uploadUID: "u2")
        first.attachmentUID = "att-1"
        second.attachmentUID = "att-1"
        let job = edited(files: [first, second])
        let request = try OutboxRequests.patchMemo(
            baseURL: Fixture.server, token: "pat-token", job: job)
        #expect(try body(request)["attachment_uids"] as? [String] == ["att-1", "att-1"])
    }

    @Test("an edit that cannot name a kept picture is not sent at all")
    func anUnnamedOriginalRefusesTheWholeEdit() throws {
        let kept = Fixture.file(uploadUID: "u1")
        var added = Fixture.file(uploadUID: "u2")
        added.stagedForEdit = true

        #expect(throws: OutboxRequests.Failure.incompleteEdit) {
            _ = try OutboxRequests.patchMemo(
                baseURL: Fixture.server, token: "pat-token", job: edited(files: [kept, added]))
        }

        // The control the throw needs: the same edit with that original named goes out whole, so
        // what stopped the request above was the picture nothing could name.
        var named = kept
        named.attachmentUID = "att-1"
        let request = try OutboxRequests.patchMemo(
            baseURL: Fixture.server, token: "pat-token", job: edited(files: [named, added]))
        #expect(try body(request)["attachment_uids"] as? [String] == ["att-1", "u2"])
    }

    @Test("the create's answer hands back the bytes each attachment was stored under")
    func completionCarriesTheDigest() async {
        let file = Fixture.file(uploadUID: "u1", byteSize: 10, bytesConfirmed: 10)
        let job = Fixture.job(files: [file])
        let http = ScriptedHTTP { _ in
            ScriptedHTTP.json(
                ["uid": "m1", "attachments": [["uid": "att-1", "sha256": "d1"]]], status: 201)
        }
        let outcome = await MemoCompletionEndpoint(http: http).create(
            job: job, credentials: Fixture.credentials(), under: .unfenced)
        let named = ResolvedAttachment(uid: "att-1", sha256: "d1")
        #expect(outcome == .created(uid: "m1", attachments: [named]))
    }
}
