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

    @Test("the classification of an error is about the error, not about the message")
    func classification() {
        #expect(
            ComposeFailure.classify(URLError(.notConnectedToInternet), sent: false)
                == .transport(sent: false))
        #expect(
            ComposeFailure.classify(URLError(.notConnectedToInternet), sent: true)
                == .transport(sent: true))
        #expect(ComposeFailure.classify(APIError.unauthorized, sent: true) == .authorization)
        #expect(ComposeFailure.classify(APIError.server(status: 500), sent: true) == .rejection)
        #expect(
            ComposeFailure.classify(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), sent: false)
                == .storage)
    }
}
