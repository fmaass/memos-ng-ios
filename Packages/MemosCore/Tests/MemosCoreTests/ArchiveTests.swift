import Foundation
import MemosAPI
import MemosCore
import Testing

private let patchMemoOperation = "patch_memo_api_memos__uid__patch"
private let getMemoOperation = "get_memo_api_memos__uid__get"

/// Archiving a memo, and what the list it was in does about it.
///
/// The write itself is one boolean on a patch, so the interesting half is everywhere else: a memo
/// archived out of a plain timeline has left that list, a memo restored out of the archived-only
/// list has left THAT one, and a list that asked for both keeps it either way. Getting that wrong
/// does not look like a bug — it looks like the app losing a memo, or keeping one that the next
/// refresh silently removes.
@MainActor
@Suite("Archive")
struct ArchiveTests {
    @Test("the archive scope decides which memos a list still admits")
    func admissionFollowsTheScope() {
        let active = Memo.archiveStub(uid: "a")
        let archived = Memo.archiveStub(uid: "b", archivedAt: Date(timeIntervalSince1970: 100))

        #expect(MemoQuery.empty.admitsArchiveState(of: active))
        #expect(!MemoQuery.empty.admitsArchiveState(of: archived))

        let including = MemoQuery(includeArchived: true)
        #expect(including.admitsArchiveState(of: active))
        #expect(including.admitsArchiveState(of: archived))

        let only = MemoQuery(archivedOnly: true)
        #expect(!only.admitsArchiveState(of: active))
        #expect(only.admitsArchiveState(of: archived))

        // The server's own precedence, mirrored: `archived_only` wins outright, so a query that
        // says both is the archived-only one.
        let both = MemoQuery(includeArchived: true, archivedOnly: true)
        #expect(!both.admitsArchiveState(of: active))
        #expect(both.admitsArchiveState(of: archived))
    }

    @Test("archiving asks for it by name and takes the memo out of the timeline")
    func archivingRemovesFromTheTimeline() async throws {
        let store = TimelineStore()
        let sent = LockedValue<[String: Any]>([:])
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
            }
            sent.set(try await Stub.body(body))
            return Stub.json(Stub.memo(uid: "a", archivedAt: "2026-08-27T10:00:00Z"))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let archived = await store.setArchived(
            true,
            uid: "a",
            using: client.handle,
            baseURL: Stub.baseURL
        )

        #expect(archived)
        #expect(sent.get()["archived"] as? Bool == true)
        // Nothing else is named: a patch is a partial update, and an archive that also sent the
        // content would rewrite a memo somebody edited in the web app a moment ago.
        #expect(sent.get()["content"] == nil)
        #expect(store.memos.map(\.uid) == ["b"])
        #expect(store.lastError == nil)
    }

    @Test("restoring takes the memo out of the archived-only list")
    func restoringRemovesFromTheArchive() async throws {
        let store = TimelineStore(query: MemoQuery(archivedOnly: true))
        let sent = LockedValue<[String: Any]>([:])
        let client = Stub.client { _, body, operation in
            guard operation == patchMemoOperation else {
                return Stub.json(
                    Stub.page([Stub.memo(uid: "a", archivedAt: "2026-08-27T10:00:00Z")])
                )
            }
            sent.set(try await Stub.body(body))
            return Stub.json(Stub.memo(uid: "a"))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["a"])

        let restored = await store.setArchived(
            false, uid: "a", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(restored)
        #expect(sent.get()["archived"] as? Bool == false)
        #expect(store.memos.isEmpty)
    }

    @Test("a list that asked for the archived ones too keeps the memo, marked")
    func includingKeepsTheMemo() async {
        let store = TimelineStore(query: MemoQuery(includeArchived: true))
        let client = Stub.client { _, _, operation in
            operation == patchMemoOperation
                ? Stub.json(Stub.memo(uid: "a", archivedAt: "2026-08-27T10:00:00Z"))
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.setArchived(true, uid: "a", using: client.handle, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["a"])
        #expect(store.memos[0].isArchived)
    }

    @Test("an archive the server refuses leaves the memo exactly where it was")
    func refusedArchiveChangesNothing() async {
        let store = TimelineStore()
        let client = Stub.client { _, _, operation in
            operation == patchMemoOperation
                ? Stub.empty(.internalServerError)
                : Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let archived = await store.setArchived(
            true,
            uid: "a",
            using: client.handle,
            baseURL: Stub.baseURL
        )

        #expect(!archived)
        // The row is still there and still says it is not archived: nothing moved before the
        // server answered, so there is nothing left claiming an archive that did not happen.
        #expect(store.memos.map(\.uid) == ["a", "b"])
        #expect(!store.memos[0].isArchived)
        #expect(store.lastError != nil)
    }

    @Test("a 401 on an archive ends the session")
    func unauthorizedArchiveEndsTheSession() async {
        let ended = Counter()
        let store = TimelineStore(onUnauthorized: { ended.increment() })
        let client = Stub.client { _, _, operation in
            operation == patchMemoOperation
                ? Stub.empty(.unauthorized)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.setArchived(true, uid: "a", using: client.handle, baseURL: Stub.baseURL)

        #expect(ended.count == 1)
    }

    @Test("a memo archived somewhere else leaves the list on the next read of it")
    func archivedElsewhereLeavesOnRead() async {
        let store = TimelineStore()
        let client = Stub.client { _, _, operation in
            operation == getMemoOperation
                ? Stub.json(Stub.memo(uid: "a", archivedAt: "2026-08-27T10:00:00Z"))
                : Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
        }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.refreshMemo(uid: "a", using: client.handle, baseURL: Stub.baseURL)

        // The reconciling read is the only thing that can notice an archive made in the web app,
        // and it reaches the same conclusion the app's own archive does.
        #expect(store.memos.map(\.uid) == ["b"])
    }
}

extension Memo {
    /// A memo with nothing interesting about it but the fields a test names.
    static func archiveStub(uid: String, archivedAt: Date? = nil) -> Memo {
        Memo(
            uid: uid,
            owner: "fabian",
            mine: true,
            content: "hello",
            visibility: .private,
            pinned: false,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            archivedAt: archivedAt
        )
    }
}
