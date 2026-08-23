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
