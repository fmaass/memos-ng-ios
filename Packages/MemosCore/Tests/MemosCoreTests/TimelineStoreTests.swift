import Foundation
import MemosAPI
import MemosCore
import Testing

@MainActor
@Suite("TimelineStore")
struct TimelineStoreTests {
    @Test("a first page is mapped and the server's cursor decides whether there is more")
    func refreshMapsPage() async {
        let store = TimelineStore(pageSize: 2)
        let client = Stub.client { _, _, _ in
            Stub.json(Stub.memoList(["a", "b"], nextCursor: "cursor-1"))
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["a", "b"])
        #expect(store.hasMore)
        #expect(store.lastError == nil)
    }

    @Test("a page without a cursor is the last one")
    func refreshWithoutCursor() async {
        let store = TimelineStore()
        let client = Stub.client { _, _, _ in Stub.json(Stub.memoList(["a"], nextCursor: nil)) }

        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(!store.hasMore)
        #expect(!store.shouldLoadMore(after: 0))
    }

    @Test("the next page is requested with the cursor the server returned")
    func loadMoreSendsCursor() async {
        let store = TimelineStore(pageSize: 2)
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            return path.contains("cursor=cursor-1")
                ? Stub.json(Stub.memoList(["c"], nextCursor: nil))
                : Stub.json(Stub.memoList(["a", "b"], nextCursor: "cursor-1"))
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        await store.loadMore(using: client, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["a", "b", "c"])
        #expect(paths.get().count == 2)
        #expect(paths.get()[0].contains("limit=2"))
        #expect(paths.get()[1].contains("cursor=cursor-1"))
        #expect(!store.hasMore)
    }

    @Test("an overlapping page does not show the same memo twice")
    func loadMoreDeduplicates() async {
        let store = TimelineStore(pageSize: 2)
        let client = Stub.client { request, _, _ in
            (request.path ?? "").contains("cursor=cursor-1")
                ? Stub.json(Stub.memoList(["b", "c"], nextCursor: nil))
                : Stub.json(Stub.memoList(["a", "b"], nextCursor: "cursor-1"))
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        await store.loadMore(using: client, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["a", "b", "c"])
    }

    @Test("loadMore does nothing without a cursor")
    func loadMoreNeedsCursor() async {
        let store = TimelineStore()
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        await store.refresh(using: client, baseURL: Stub.baseURL)
        await store.loadMore(using: client, baseURL: Stub.baseURL)

        #expect(calls.count == 1)
    }

    @Test("a 401 ends the session instead of being retried")
    func unauthorizedSignsOut() async {
        let signedOut = Counter()
        let store = TimelineStore(onUnauthorized: { signedOut.increment() })
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }

        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(signedOut.count == 1)
        #expect(store.memos.isEmpty)
        #expect(store.lastError != nil)
    }

    @Test("a server fault is reported without ending the session")
    func serverFaultKeepsSession() async {
        let signedOut = Counter()
        let store = TimelineStore(onUnauthorized: { signedOut.increment() })
        let client = Stub.client { _, _, _ in Stub.empty(.internalServerError) }

        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(signedOut.count == 0)
        #expect(store.lastError != nil)
    }

    @Test("the pagination trigger fires only near the end, and only when there is more")
    func paginationTrigger() async {
        let store = TimelineStore(pageSize: 4)
        let client = Stub.client { _, _, _ in
            Stub.json(Stub.memoList(["a", "b", "c", "d"], nextCursor: "cursor-1"))
        }
        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(!store.shouldLoadMore(after: 0, lookahead: 3))
        #expect(store.shouldLoadMore(after: 1, lookahead: 3))
        #expect(store.shouldLoadMore(after: 3, lookahead: 3))
    }
}

// MARK: - writes

extension TimelineStoreTests {
    private func seeded(_ uids: [String], client: any APIProtocol) async -> TimelineStore {
        let store = TimelineStore()
        await store.refresh(using: client, baseURL: Stub.baseURL)
        return store
    }

    @Test("a created memo enters at the position its pin flag earns")
    func createInsertsSorted() async {
        let client = Stub.client { request, _, operation in
            operation == "create_memo_api_memos_post"
                ? Stub.json(Stub.memo(uid: "new"), status: .created)
                : Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
        }
        let store = await seeded(["a", "b"], client: client)

        #expect(await store.create(content: "hello", using: client, baseURL: Stub.baseURL))
        #expect(store.memos.map(\.uid) == ["new", "a", "b"])
    }

    @Test("a rejected create reports and adds nothing")
    func createRejected() async {
        let client = Stub.client { _, _, operation in
            operation == "create_memo_api_memos_post"
                ? Stub.empty(.unprocessableContent)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        let store = await seeded(["a"], client: client)

        #expect(!(await store.create(content: "", using: client, baseURL: Stub.baseURL)))
        #expect(store.memos.count == 1)
        #expect(store.lastError != nil)
    }

    @Test("an edit replaces the loaded copy with the server's")
    func editApplies() async {
        let client = Stub.client { _, _, operation in
            operation == "patch_memo_api_memos__uid__patch"
                ? Stub.json(Stub.memo(uid: "a", content: "edited"))
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        let store = await seeded(["a"], client: client)

        #expect(await store.edit(uid: "a", content: "edited", using: client, baseURL: Stub.baseURL))
        #expect(store.memos.first?.content == "edited")
    }

    @Test("a delete removes the row only on the server's word")
    func deleteRemovesOnNoContent() async {
        let client = Stub.client { _, _, operation in
            operation == "delete_memo_api_memos__uid__delete"
                ? Stub.empty(.noContent)
                : Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
        }
        let store = await seeded(["a", "b"], client: client)

        #expect(await store.delete(uid: "a", using: client))
        #expect(store.memos.map(\.uid) == ["b"])
    }

    @Test("a failed delete keeps the row and says why")
    func deleteKeepsOnFailure() async {
        let client = Stub.client { _, _, operation in
            operation == "delete_memo_api_memos__uid__delete"
                ? Stub.empty(.internalServerError)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        let store = await seeded(["a"], client: client)

        #expect(!(await store.delete(uid: "a", using: client)))
        #expect(store.memos.count == 1)
        #expect(store.lastError != nil)
    }

    @Test("pinning routes through the pin endpoint and moves the memo to the front")
    func pinRoutesAndReorders() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            paths.set(paths.get() + [request.path ?? ""])
            return operation == "pin_memo_api_memos__uid__pin_post"
                ? Stub.json(Stub.memo(uid: "b", pinned: true))
                : Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
        }
        let store = await seeded(["a", "b"], client: client)

        #expect(await store.setPinned(true, uid: "b", using: client, baseURL: Stub.baseURL))
        #expect(
            store.memos.map(\.uid) == ["b", "a"], "the pinned memo leads the pinned-first list")
        #expect(paths.get().contains { $0.hasSuffix("/b/pin") })
    }

    @Test("a visibility change patches and applies the server's answer")
    func visibilityPatches() async {
        let client = Stub.client { _, _, operation in
            operation == "patch_memo_api_memos__uid__patch"
                ? Stub.json(Stub.memo(uid: "a", visibility: "PUBLIC"))
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        let store = await seeded(["a"], client: client)

        #expect(
            await store.setVisibility(.public, uid: "a", using: client, baseURL: Stub.baseURL)
        )
        #expect(store.memos.first?.visibility == .public)
    }

    @Test("a task toggle shows immediately and rolls back when the server refuses")
    func toggleRollsBack() async throws {
        let patchEntered = LockedValue<Bool>(false)
        let patchRelease = LockedValue<Bool>(false)
        let client = Stub.client { _, _, operation in
            if operation == "patch_memo_api_memos__uid__patch" {
                patchEntered.set(true)
                // Hold the request open so the test can look at the screen mid-flight.
                while !patchRelease.get() {
                    try await Task.sleep(for: .milliseconds(1))
                }
                return Stub.empty(.internalServerError)
            }
            let list = """
                {"items":[\(Stub.memo(uid: "a", content: "- [ ] milk"))],\
                "nextCursor":null,"totalCount":null}
                """
            return Stub.json(list)
        }
        let store = await seeded(["a"], client: client)
        let before = store.memos.first?.content

        let inFlight = Task {
            await store.toggleTask(at: 0, in: "a", using: client, baseURL: Stub.baseURL)
        }
        while !patchEntered.get() {
            await Task.yield()
        }
        // The whole point of optimism: the checkbox flipped BEFORE the server answered.
        #expect(store.memos.first?.content == "- [x] milk")

        patchRelease.set(true)
        let toggled = await inFlight.value

        #expect(!toggled)
        #expect(store.memos.first?.content == before, "the flip is undone when the PATCH fails")
        #expect(store.lastError != nil)
    }

    @Test("unpinning routes through the unpin endpoint and leaves the pinned section")
    func unpinRoutesAndReorders() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            paths.set(paths.get() + [request.path ?? ""])
            if operation == "unpin_memo_api_memos__uid__unpin_post" {
                return Stub.json(Stub.memo(uid: "a", pinned: false))
            }
            let list = """
                {"items":[\(Stub.memo(uid: "a", pinned: true)),\(Stub.memo(uid: "b"))],\
                "nextCursor":null,"totalCount":null}
                """
            return Stub.json(list)
        }
        let store = await seeded(["a", "b"], client: client)

        #expect(await store.setPinned(false, uid: "a", using: client, baseURL: Stub.baseURL))
        #expect(paths.get().contains { $0.hasSuffix("/a/unpin") })
        #expect(store.memos.first?.pinned == false)
    }

    @Test("a 403 on a write reports without ending the session")
    func forbiddenWriteDoesNotSignOut() async {
        let unauthorizedCalled = LockedValue<Bool>(false)
        let store = TimelineStore(onUnauthorized: { unauthorizedCalled.set(true) })
        let client = Stub.client { _, _, operation in
            operation == "delete_memo_api_memos__uid__delete"
                ? Stub.empty(.forbidden)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(!(await store.delete(uid: "a", using: client)))
        #expect(!unauthorizedCalled.get(), "someone else's memo must not cost this session")
        #expect(store.lastError != nil)
    }

    @Test("a 401 on a write does end the session")
    func unauthorizedWriteSignsOut() async {
        let unauthorizedCalled = LockedValue<Bool>(false)
        let store = TimelineStore(onUnauthorized: { unauthorizedCalled.set(true) })
        let client = Stub.client { _, _, operation in
            operation == "delete_memo_api_memos__uid__delete"
                ? Stub.empty(.unauthorized)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(!(await store.delete(uid: "a", using: client)))
        #expect(unauthorizedCalled.get())
    }
}
