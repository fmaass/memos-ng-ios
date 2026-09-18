import Foundation
import HTTPTypes
import MemosAPI
import MemosOutbox
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let listMemosOperation = "list_memos_api_memos_get"
private let patchMemoOperation = "patch_memo_api_memos__uid__patch"
private let startUploadOperation = "start_upload_api_uploads_post"
private let appendChunkOperation = "append_chunk_api_uploads__upload_uid__patch"

/// A file on disk with known contents, cleaned up by the test that made it.
private func stagedFile(named name: String = "picked.jpg") throws -> StagedSource {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString)-\(name)")
    try Data(repeating: 0x41, count: 8).write(to: url)
    return StagedSource(url: url, filename: name, mime: "image/jpeg")
}

/// WHY an edit did not go through, which is a different question from whether it did.
///
/// Until now the answer was a Bool and a sentence in the store's global error line, so the sheet
/// could only ever say the same thing: that the memo could not be saved and nothing was changed on
/// the server. One of those failures — a patch that went out and whose answer was lost — is the one
/// case where that claim is false, and it is the case where saying it is worst: somebody is told
/// their edit did not happen when it may well have.
@MainActor
@Suite("Why a compose failed")
struct ComposeFailureTests {
    /// The upload never got off the device. Nothing was patched, so nothing changed — and the
    /// outcome says so, which is what licenses the sheet's sentence.
    @Test("an upload that never reached the server is a transport failure that sent nothing")
    func uploadTransportFailureSaysNothingWasSent() async throws {
        let file = try stagedFile()
        defer { try? FileManager.default.removeItem(at: file.url) }
        let store = TimelineStore()
        let patches = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation: throw URLError(.notConnectedToInternet)
            case patchMemoOperation:
                patches.increment()
                return Stub.json(Stub.memo(uid: "a", content: "edited"))
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let outcome = await store.edit(
            uid: "a", content: "edited", attaching: [file],
            using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.transport(sent: false)))
        #expect(patches.count == 0, "the patch went out after the upload had failed")
    }

    /// The patch WENT. Its answer did not come back — and the one thing this app may not say then
    /// is that nothing was changed.
    @Test("a patch whose answer never came back could not be confirmed")
    func lostPatchAnswerIsUnconfirmed() async throws {
        let store = TimelineStore()
        let client = Stub.client { _, _, operation in
            switch operation {
            case patchMemoOperation: throw URLError(.networkConnectionLost)
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let outcome = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.transport(sent: true)))
    }

    /// The retry that follows it is the SAME edit, under the same key — which is what makes the
    /// "try again" the sheet offers safe to take up. The server answers a replay rather than
    /// applying the edit twice.
    @Test("the retry after a lost answer carries the key the lost request carried")
    func theRetryKeepsTheEditKey() async throws {
        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let answer = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            switch operation {
            case patchMemoOperation:
                let sent = try await Stub.body(body)
                keys.set(keys.get() + [(sent["edit_key"] as? String) ?? ""])
                guard answer.get() else { throw URLError(.networkConnectionLost) }
                return Stub.json(Stub.memo(uid: "a", content: "edited"))
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let first = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        )
        answer.set(true)
        let second = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(first == .failed(.transport(sent: true)))
        #expect(second == .saved)
        #expect(keys.get().count == 2)
        #expect(keys.get()[0] == keys.get()[1], "the retry minted a new key and would apply twice")
    }

    @Test("a session the server no longer accepts is an authorization failure, not a refusal")
    func unauthorizedIsItsOwnCategory() async throws {
        let store = TimelineStore()
        let client = Stub.client { _, _, operation in
            switch operation {
            case patchMemoOperation: return Stub.empty(.unauthorized)
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let outcome = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.authorization))
    }

    @Test("a server that answers no is a rejection, and the memo is untouched")
    func refusalIsARejection() async throws {
        let store = TimelineStore()
        let client = Stub.client { _, _, operation in
            switch operation {
            case patchMemoOperation: return Stub.empty(.unprocessableContent)
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let outcome = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.rejection))
    }

    @Test("a save that worked is saved, whatever else is in the list (the control)")
    func theControl() async throws {
        let store = TimelineStore()
        let client = Stub.client { _, _, operation in
            switch operation {
            case patchMemoOperation: return Stub.json(Stub.memo(uid: "a", content: "edited"))
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let outcome = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .saved)
        #expect(outcome.failure == nil)
    }

    /// A 2xx the client cannot read is not a refusal. The request went out and the server may well
    /// have applied it, so the one thing this may not say is that nothing was changed.
    @Test("a success the client cannot decode could not be confirmed, and is not a rejection")
    func anUndecodableSuccessIsUnconfirmed() async throws {
        let store = TimelineStore()
        let client = Stub.client { _, _, operation in
            switch operation {
            // 200, with a body that is not a memo. What the transport did is not in doubt; what
            // the server did with it is.
            case patchMemoOperation: return Stub.json(#"{"not":"a memo"}"#)
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let outcome = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.transport(sent: true)))
        #expect(outcome != .failed(.rejection), "an unreadable success was reported as a refusal")
    }

    /// The retry of a media edit is the same edit, even though the file has been imported again.
    ///
    /// A retry re-exports the picker's file under a new temporary name, so the url and the
    /// modification date both move. Keyed on those, the same photograph on the same memo would mint
    /// a NEW edit key and the server would apply a retry of a lost save a second time instead of
    /// replaying it — which is the one thing the key exists to prevent.
    @Test("a file imported again under the same identity keeps the edit key")
    func theEditKeySurvivesAReImport() async throws {
        let first = try stagedFile(named: "holiday.jpg")
        let second = try stagedFile(named: "holiday.jpg")
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }
        // The SAME attachment, imported twice: two paths, one identity.
        let identity = UUID()
        let attempt = StagedSource(
            url: first.url, filename: first.filename, mime: first.mime, identity: identity)
        let retried = StagedSource(
            url: second.url, filename: second.filename, mime: second.mime, identity: identity)
        #expect(attempt.url != retried.url, "control: the retry really did re-import the file")

        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let answer = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(
                    #"{"upload_uid":"u1","chunk_size":64,"bytes_received":0}"#, status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                return Stub.json(
                    """
                    {"upload_uid":"u1","chunk_size":64,"bytes_received":\(data.count)}
                    """)
            case patchMemoOperation:
                let sent = try await Stub.body(body)
                keys.set(keys.get() + [(sent["edit_key"] as? String) ?? ""])
                guard answer.get() else { throw URLError(.networkConnectionLost) }
                return Stub.json(Stub.memo(uid: "a", content: "edited"))
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let lost = await store.edit(
            uid: "a", content: "edited", attaching: [attempt],
            using: client.handle, baseURL: Stub.baseURL
        )
        answer.set(true)
        let repeated = await store.edit(
            uid: "a", content: "edited", attaching: [retried],
            using: client.handle, baseURL: Stub.baseURL
        )

        #expect(lost == .failed(.transport(sent: true)))
        #expect(repeated == .saved)
        let sentKeys = keys.get()
        try #require(sentKeys.count == 2, "the patch was not reached twice: \(sentKeys)")
        #expect(
            sentKeys[0] == sentKeys[1],
            "the re-imported file minted a new key, so the retry would apply the edit twice")
    }

    /// The other half of the edit key, and the dangerous one: two DIFFERENT files must never share
    /// an identity. Two photographs called the same thing in two directories — which is what
    /// "replace the picture with the other one" produces — keyed the same would let the second save
    /// be answered as a replay of the first, and the memo would keep the file nobody wanted with
    /// nothing said about it.
    @Test("two different files with the same name are two different edits")
    func sameNameDifferentFileIsADifferentEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let one = root.appending(path: "one")
        let two = root.appending(path: "two")
        for directory in [one, two] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        func staged(in directory: URL, bytes: UInt8) throws -> StagedSource {
            let url = directory.appending(path: "photo.jpg")
            try Data(repeating: bytes, count: 8).write(to: url)
            // No identity: this is a source nothing imported — the case the fallback is for.
            return StagedSource(url: url, filename: "photo.jpg", mime: "image/jpeg")
        }
        let first = try staged(in: one, bytes: 0x41)
        let second = try staged(in: two, bytes: 0x42)
        #expect(first.filename == second.filename, "control: the two files are named the same")
        #expect(
            first.editIdentity != second.editIdentity,
            "two different files share an edit identity, so one can replay the other")

        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let answer = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(
                    #"{"upload_uid":"u1","chunk_size":64,"bytes_received":0}"#, status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                return Stub.json(
                    """
                    {"upload_uid":"u1","chunk_size":64,"bytes_received":\(data.count)}
                    """)
            case patchMemoOperation:
                let sent = try await Stub.body(body)
                keys.set(keys.get() + [(sent["edit_key"] as? String) ?? ""])
                guard answer.get() else { throw URLError(.networkConnectionLost) }
                return Stub.json(Stub.memo(uid: "a", content: "edited"))
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        // The first save is uncertain: it went out and its answer was lost.
        let uncertain = await store.edit(
            uid: "a", content: "edited", attaching: [first],
            using: client.handle, baseURL: Stub.baseURL
        )
        answer.set(true)
        // Then the picture is REPLACED with the other one and saved again.
        let replaced = await store.edit(
            uid: "a", content: "edited", attaching: [second],
            using: client.handle, baseURL: Stub.baseURL
        )

        #expect(uncertain == .failed(.transport(sent: true)))
        #expect(replaced == .saved)
        let sentKeys = keys.get()
        try #require(sentKeys.count == 2, "the patch was not reached twice: \(sentKeys)")
        #expect(
            sentKeys[0] != sentKeys[1],
            "the replacement was sent under the replaced file's key, so the server can replay it")
    }

    /// The same danger from the other direction, and the one a path cannot answer: the file at
    /// `…/photo.jpg` is REPLACED — same name, same place, different picture. Named by where it is,
    /// the second save would go out under the first one's key and the server would replay the edit
    /// that carried the old bytes: 200, and the replacement nowhere.
    @Test("replacing the bytes at one path is a different edit")
    func replacingTheBytesAtOnePathIsADifferentEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "photo.jpg")

        try Data(repeating: 0x41, count: 8).write(to: url)
        let first = StagedSource(url: url, filename: "photo.jpg", mime: "image/jpeg")
        // The person picks another picture, and it lands at the same place.
        try Data(repeating: 0x42, count: 8).write(to: url)
        let second = StagedSource(url: url, filename: "photo.jpg", mime: "image/jpeg")
        #expect(first.url == second.url, "control: the two imports really are at one path")
        #expect(
            first.editIdentity != second.editIdentity,
            "a re-import at the same path kept the old file's identity")

        let store = TimelineStore()
        let keys = LockedValue<[String]>([])
        let answer = LockedValue<Bool>(false)
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(
                    #"{"upload_uid":"u1","chunk_size":64,"bytes_received":0}"#, status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                return Stub.json(
                    """
                    {"upload_uid":"u1","chunk_size":64,"bytes_received":\(data.count)}
                    """)
            case patchMemoOperation:
                let sent = try await Stub.body(body)
                keys.set(keys.get() + [(sent["edit_key"] as? String) ?? ""])
                guard answer.get() else { throw URLError(.networkConnectionLost) }
                return Stub.json(Stub.memo(uid: "a", content: "edited"))
            default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let uncertain = await store.edit(
            uid: "a", content: "edited", attaching: [first],
            using: client.handle, baseURL: Stub.baseURL
        )
        answer.set(true)
        let replaced = await store.edit(
            uid: "a", content: "edited", attaching: [second],
            using: client.handle, baseURL: Stub.baseURL
        )

        #expect(uncertain == .failed(.transport(sent: true)))
        #expect(replaced == .saved)
        let sentKeys = keys.get()
        try #require(sentKeys.count == 2, "the patch was not reached twice: \(sentKeys)")
        #expect(
            sentKeys[0] != sentKeys[1],
            "the replacement went out under the replaced file's key, so it can be replayed away")
    }

    /// The shape the app ACTUALLY meets: a session's client is built on an installed credential,
    /// so its 401 is a `CredentialRefusal` carrying the epoch the request presented, inside the
    /// generated client's envelope. Read as an opaque error that is a session failure reported as
    /// the server refusing somebody's words — and a `classify` that stopped reaching through the
    /// envelope would say exactly that.
    @Test("an upload refused through an installed client is an authorization failure")
    func anInstalledClientsUploadRefusalIsAuthorization() async throws {
        let thrown = try #require(
            await Stub.uploadRefusalFromAnInstalledClient(),
            "the upload was not refused, so this asserts nothing"
        )

        #expect(ComposeFailure.classify(thrown, sent: false) == .authorization)
        // The premise, asserted rather than assumed: it really is the wrapped refusal, and the
        // epoch the request presented really did travel out with it.
        #expect(StoreFailure.refusal(thrown) == CredentialRefusal(issuedUnder: 0))
    }

    @Test("an upload refused for an ended session is an authorization failure, not a rejection")
    func aCarriedUnauthorizedIsAuthorization() {
        // The REAL wrapper the upload throws, not a synthetic one: `MediaUpload` reports an ended
        // session as a refusal carrying the API error, and read as an opaque error it looks exactly
        // like the server refusing somebody's words.
        // The BARE-TOKEN lane: a client with no credential behind it still reports its 401 as a
        // plain `APIError`, and this wrapper is what carries it. Kept because that lane is real —
        // the share extension's — not because it stands in for the one below.
        let refused = MediaUploadError.refused(.unauthorized)
        #expect(ComposeFailure.classify(refused, sent: false) == .authorization)
        // And one that really IS a refusal stays a rejection.
        #expect(
            ComposeFailure.classify(MediaUploadError.refused(.server(status: 500)), sent: false)
                == .rejection)
    }

    /// The two statuses this server never emits itself: something in front of it answered, and the
    /// memo's fate is unknown rather than refused. The sentence that follows from `sent: true` is
    /// the one about an answer that never came back, which is the only honest thing to say when a
    /// proxy gave up on a request that had already gone out.
    @Test("a proxy's own answer is a transport failure, and carries what the caller knew")
    func gatewayStatusesAreTransportFailures() {
        #expect(ComposeFailure.classify(APIError.server(status: 502), sent: true)
            == .transport(sent: true))
        #expect(ComposeFailure.classify(APIError.server(status: 504), sent: true)
            == .transport(sent: true))
        #expect(ComposeFailure.classify(APIError.server(status: 502), sent: false)
            == .transport(sent: false))
        #expect(ComposeFailure.classify(APIError.server(status: 504), sent: false)
            == .transport(sent: false))
    }

    /// The counterweight: a server that answers for itself keeps its own card, whatever the status
    /// looks like. 503 is the one this server really does emit under load.
    @Test("a status the server answered with is a rejection, and stays one")
    func answeredStatusesStayRejections() {
        #expect(ComposeFailure.classify(APIError.server(status: 503), sent: true) == .rejection)
        #expect(ComposeFailure.classify(APIError.server(status: 500), sent: true) == .rejection)
        #expect(ComposeFailure.classify(APIError.unauthorized, sent: true) == .authorization)
    }

    @Test("the classification of an error is about the error, not about the message")
    func classification() {
        #expect(
            ComposeFailure.classify(URLError(.notConnectedToInternet), sent: false)
                == .transport(sent: false))
        #expect(
            ComposeFailure.classify(URLError(.notConnectedToInternet), sent: true)
                == .transport(sent: true))
        #expect(ComposeFailure.classify(APIError.unauthorized, sent: true) == .authorization)
        // Wrapped, which is how the generated client hands one back.
        let wrapped = NSError(
            domain: "GeneratedClient", code: 1,
            userInfo: [NSUnderlyingErrorKey: APIError.unauthorized as NSError])
        #expect(ComposeFailure.classify(wrapped, sent: true) == .authorization)
        #expect(ComposeFailure.classify(APIError.server(status: 500), sent: true) == .rejection)
        #expect(
            ComposeFailure.classify(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), sent: false)
                == .storage)
    }
}
