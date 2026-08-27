import Foundation
import MemosAPI
import MemosOutbox
import Testing

@testable import MemosCore

private let listMemosOperation = "list_memos_api_memos_get"
private let patchMemoOperation = "patch_memo_api_memos__uid__patch"
private let startUploadOperation = "start_upload_api_uploads_post"
private let appendChunkOperation = "append_chunk_api_uploads__upload_uid__patch"

/// One upload session's answer, in the shape the server sends it.
private func uploadOut(uid: String, chunkSize: Int, received: Int) -> String {
    """
    {"upload_uid":"\(uid)","chunk_size":\(chunkSize),"bytes_received":\(received)}
    """
}

/// A file on disk with known contents, cleaned up by the test that made it.
private func stagedFile(bytes: Int, named name: String = "picked.jpg") throws -> StagedSource {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString)-\(name)")
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return StagedSource(url: url, filename: name, mime: "image/jpeg")
}

/// Editing a memo and attaching media to it in the same breath — the FOREGROUND lane, which is
/// deliberately not the outbox.
///
/// Two things are being held here. The request shape: files become upload sessions, and the memo
/// patch names those sessions in `upload_uids` (the server finalizes them as part of the write, so
/// nothing here calls `/finalize`). And the rollback: an edit with media either happens whole or
/// does not happen at all, because half of it is a memo somebody has to repair by hand.
@MainActor
@Suite("Editing a memo with media")
struct MediaEditTests {
    @Test("an edit with no files sends no upload_uids at all")
    func editWithoutFilesNamesNoUploads() async throws {
        let store = TimelineStore()
        let sent = LockedValue<[String: Any]>([:])
        let uploads = Counter()
        let client = Stub.client { _, body, operation in
            switch operation {
            case patchMemoOperation:
                sent.set(try await Stub.body(body))
                return Stub.json(Stub.memo(uid: "a", content: "edited"))
            case startUploadOperation:
                uploads.increment()
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "edited", using: client, baseURL: Stub.baseURL
        )

        #expect(saved)
        #expect(sent.get()["content"] as? String == "edited")
        // ABSENT, not empty: `upload_uids` on a patch ADDS attachments, so an array sent on every
        // edit would be a field the server has to ignore rather than a statement about this one.
        #expect(sent.get()["upload_uids"] == nil)
        #expect(uploads.count == 0)
        #expect(store.memos[0].content == "edited")
    }

    @Test("a picked file becomes an upload session the memo patch names")
    func editWithOneFile() async throws {
        let file = try stagedFile(bytes: 12)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let sent = LockedValue<[String: Any]>([:])
        let started = LockedValue<[String: Any]>([:])
        let chunkBytes = LockedValue<Int>(0)
        let finalizes = Counter()
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                started.set(try await Stub.body(body))
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                chunkBytes.set(chunkBytes.get() + data.count)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: data.count))
            case patchMemoOperation:
                sent.set(try await Stub.body(body))
                return Stub.json(Stub.memo(uid: "a", content: "with a photo"))
            case "finalize_upload_api_uploads__upload_uid__finalize_post":
                finalizes.increment()
                return Stub.empty(.ok)
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a",
            content: "with a photo",
            attaching: [file],
            using: client,
            baseURL: Stub.baseURL
        )

        #expect(saved)
        #expect(started.get()["filename"] as? String == "picked.jpg")
        #expect(started.get()["mime"] as? String == "image/jpeg")
        #expect(started.get()["size"] as? Int == 12)
        #expect(chunkBytes.get() == 12)
        #expect(sent.get()["upload_uids"] as? [String] == ["u1"])
        // The memo write is what finalizes a pending upload (memos-ng "finalize-on-post"); a
        // client that finalized for itself would produce an attachment belonging to no memo.
        #expect(finalizes.count == 0)
    }

    @Test("a file larger than one chunk is sent in the pieces the server asks for")
    func chunksFollowTheServer() async throws {
        let file = try stagedFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let offsets = LockedValue<[Int]>([])
        let received = LockedValue<Int>(0)
        let client = Stub.client { request, body, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: 0), status: .created)
            case appendChunkOperation:
                let offset = request.headerFields.first {
                    $0.name.canonicalName == "upload-offset"
                }
                offsets.set(offsets.get() + [Int(offset?.value ?? "-1") ?? -1])
                let data = try await Stub.bytes(body)
                received.set(received.get() + data.count)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 4, received: received.get()))
            case patchMemoOperation:
                return Stub.json(Stub.memo(uid: "a"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "big", attaching: [file], using: client, baseURL: Stub.baseURL
        )

        #expect(saved)
        // Three chunks: 4, 4, 2 — each starting where the SERVER said it now holds up to, which is
        // the only number a resume could ever agree with.
        #expect(offsets.get() == [0, 4, 8])
        #expect(received.get() == 10)
    }

    @Test("an upload that fails leaves the memo untouched and never patches it")
    func failedUploadDoesNotPatch() async throws {
        let file = try stagedFile(bytes: 8)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let patches = Counter()
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case appendChunkOperation:
                return Stub.empty(.internalServerError)
            case patchMemoOperation:
                patches.increment()
                return Stub.json(Stub.memo(uid: "a", content: "never"))
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "never", attaching: [file], using: client, baseURL: Stub.baseURL
        )

        #expect(!saved)
        // THE rollback: no patch was ever sent, so the memo still says what it said. Half an edit
        // — new text with the photo missing — is the state nobody can repair from the app.
        #expect(patches.count == 0)
        #expect(store.memos[0].content == "hello")
        #expect(store.lastError != nil)
    }

    @Test("a patch refused after the uploads leaves the memo as it was")
    func refusedPatchLeavesTheMemo() async throws {
        let file = try stagedFile(bytes: 4)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let store = TimelineStore()
        let client = Stub.client { _, body, operation in
            switch operation {
            case startUploadOperation:
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: 0), status: .created)
            case appendChunkOperation:
                let data = try await Stub.bytes(body)
                return Stub.json(uploadOut(uid: "u1", chunkSize: 64, received: data.count))
            case patchMemoOperation:
                return Stub.empty(.conflict)
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "refused", attaching: [file], using: client, baseURL: Stub.baseURL
        )

        #expect(!saved)
        #expect(store.memos[0].content == "hello")
        #expect(store.memos[0].attachments.isEmpty)
        #expect(store.lastError != nil)
    }

    @Test("a 401 during an upload ends the session")
    func unauthorizedUploadEndsTheSession() async throws {
        let file = try stagedFile(bytes: 4)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let ended = Counter()
        let store = TimelineStore(onUnauthorized: { ended.increment() })
        let client = Stub.client { _, _, operation in
            switch operation {
            case startUploadOperation:
                return Stub.empty(.unauthorized)
            default:
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        await store.edit(
            uid: "a", content: "no", attaching: [file], using: client, baseURL: Stub.baseURL
        )

        // The upload lane wraps the API's own error to say which step failed; the wrapping must
        // not cost a 401 its identity, or a dead credential never ends the session.
        #expect(ended.count == 1)
    }

    @Test("a server that names no chunk size gets one, not a loop that sends nothing")
    func chunkSizeFallback() {
        #expect(MediaUpload.usableChunkSize(0) == MediaUpload.fallbackChunkSize)
        #expect(MediaUpload.usableChunkSize(-1) == MediaUpload.fallbackChunkSize)
        // The control: a size the server DID name is the one used, so the fallback above is a
        // fallback rather than the only answer.
        #expect(MediaUpload.usableChunkSize(64) == 64)
    }

    @Test("a file that cannot be read is reported and nothing is sent")
    func unreadableFileIsReported() async {
        let missing = StagedSource(
            url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg"),
            filename: "gone.jpg",
            mime: "image/jpeg"
        )
        let store = TimelineStore()
        let requests = Counter()
        let client = Stub.client { _, _, operation in
            if operation != listMemosOperation { requests.increment() }
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let saved = await store.edit(
            uid: "a", content: "no", attaching: [missing], using: client, baseURL: Stub.baseURL
        )

        #expect(!saved)
        #expect(requests.count == 0)
        #expect(store.lastError != nil)
    }
}
