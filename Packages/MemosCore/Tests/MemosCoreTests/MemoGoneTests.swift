import Foundation
import MemosAPI
import Testing

@testable import MemosCore

private let deleteMemoOperation = "delete_memo_api_memos__uid__delete"
private let patchMemoOperation = "patch_memo_api_memos__uid__patch"

/// The body the server sends with a 404 on a memo, so the client takes the documented case rather
/// than failing to read it and reporting a decoding problem instead.
private let goneBody = #"{"detail":"No such memo"}"#

/// A memo that is not there any more, on the three writes that can meet one.
///
/// The contract used to leave the 404 undocumented, so it arrived as `.undocumented(404)` and was
/// thrown as `APIError.fromStatus(404)`; it is a case of its own now. Nothing about what the app
/// does with it may have moved, and only a test that scripts the status can say so — the switch
/// still compiles either way.
@MainActor
@Suite("A memo that is already gone")
struct MemoGoneTests {
    @Test("a delete answered 404 leaves the row where it is and says why")
    func deleteKeepsTheRow() async {
        let client = Stub.client { _, _, operation in
            operation == deleteMemoOperation
                ? Stub.json(goneBody, status: .notFound)
                : Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
        }
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(!(await store.delete(uid: "a", using: client.handle)))
        #expect(store.memos.map(\.uid) == ["a", "b"], "nothing was removed on a 404")
        #expect(store.lastError != nil)
    }

    @Test("a task toggle answered 404 rolls the tick back and lets the memo be tapped again")
    func toggleRollsBackAndReleasesTheClaim() async {
        let patches = Counter()
        let client = Stub.client { _, _, operation in
            if operation == patchMemoOperation {
                patches.increment()
                return Stub.json(goneBody, status: .notFound)
            }
            let list = """
                {"items":[\(Stub.memo(uid: "a", content: "- [ ] milk"))],\
                "nextCursor":null,"totalCount":null}
                """
            return Stub.json(list)
        }
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let before = store.memos.first?.content

        #expect(
            !(await store.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL))
        )
        #expect(store.memos.first?.content == before, "the optimistic tick is undone")
        #expect(store.lastError != nil)
        // The claim, observed the only way a caller can: a second tap that is taken at all. Held
        // past a refusal, it would refuse every later toggle of this memo for the rest of the run.
        _ = await store.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL)
        #expect(patches.count == 2, "the second tap sent nothing, so the claim outlived its request")
    }

    @Test("an edit answered 404 is the server's no, and the words stay in the sheet")
    func editIsRejected() async {
        let client = Stub.client { _, _, operation in
            operation == patchMemoOperation
                ? Stub.json(goneBody, status: .notFound)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let before = store.memos.first?.content

        let outcome = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(outcome == .failed(.rejection))
        #expect(store.memos.first?.content == before, "nothing was applied from a refusal")
    }
}
