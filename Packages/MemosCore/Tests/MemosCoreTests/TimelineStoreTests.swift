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

    @Test("an edit replaces the loaded copy with the server's, and says nothing about the date")
    func editApplies() async throws {
        let sent = LockedValue<Data?>(nil)
        let client = Stub.client { _, body, operation in
            guard operation == "patch_memo_api_memos__uid__patch" else {
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
            sent.set(try await Stub.bytes(body))
            return Stub.json(Stub.memo(uid: "a", content: "edited"))
        }
        let store = await seeded(["a"], client: client)

        #expect(await store.edit(uid: "a", content: "edited", using: client, baseURL: Stub.baseURL))
        #expect(store.memos.first?.content == "edited")
        // A PATCH is a partial update: an edit that never touched the date must not carry one, or
        // every typo fixed would rewrite the display date to whatever the editor happened to hold.
        let body = Stub.object(sent.get())
        #expect(body["content"] as? String == "edited", "positive control: the body was read")
        #expect(body["created_at"] == nil)
    }

    /// Three memos on three days, newest first — the list before anything is re-dated.
    private static let datedPage = Stub.page([
        Stub.memo(uid: "a", createdAt: "2026-08-23T09:00:00Z"),
        Stub.memo(uid: "b", createdAt: "2026-08-22T09:00:00Z"),
        Stub.memo(uid: "c", createdAt: "2026-08-21T09:00:00Z"),
    ])

    private func instant(_ iso: String) throws -> Date {
        try Date.ISO8601FormatStyle().parse(iso)
    }

    @Test("an edit that moves the date sends it and re-files the memo under its new day")
    func editDateMovesTheMemo() async throws {
        let sent = LockedValue<Data?>(nil)
        let moved = "2026-08-20T14:30:00Z"
        let page = Self.datedPage
        let client = Stub.client { _, body, operation in
            guard operation == "patch_memo_api_memos__uid__patch" else {
                return Stub.json(page)
            }
            sent.set(try await Stub.bytes(body))
            return Stub.json(Stub.memo(uid: "b", createdAt: moved))
        }
        let store = await seeded(["a", "b", "c"], client: client)
        #expect(store.memos.map(\.uid) == ["a", "b", "c"])

        let chosen = try instant(moved)
        let edited = await store.edit(
            uid: "b",
            content: "same words",
            createdAt: chosen,
            using: client,
            baseURL: Stub.baseURL
        )
        #expect(edited)

        // The date the editor chose is what went on the wire, to the second.
        let wire = try #require(Stub.object(sent.get())["created_at"] as? String)
        let parsed = try instant(wire)
        #expect(parsed == chosen, "sent \(wire)")
        // And the memo has left the day it was under: it is the oldest one loaded now.
        #expect(store.memos.map(\.uid) == ["a", "c", "b"])
        #expect(store.memos.last?.createdAt == chosen)
    }

    @Test("a memo re-dated forward climbs back to the top of the list")
    func editDateForwardMovesTheMemo() async throws {
        let moved = "2026-08-24T08:00:00Z"
        let page = Self.datedPage
        let client = Stub.client { _, _, operation in
            operation == "patch_memo_api_memos__uid__patch"
                ? Stub.json(Stub.memo(uid: "c", createdAt: moved))
                : Stub.json(page)
        }
        let store = await seeded(["a", "b", "c"], client: client)
        let chosen = try instant(moved)

        let edited = await store.edit(
            uid: "c",
            content: "same words",
            createdAt: chosen,
            using: client,
            baseURL: Stub.baseURL
        )
        #expect(edited)
        #expect(store.memos.map(\.uid) == ["c", "a", "b"])
    }

    @Test("a memo re-dated onto a timestamp others hold does not jump ahead of them")
    func reDatingOntoATieKeepsTheRowsThatWereThere() async throws {
        // a and b share one instant exactly — two memos backdated to the same minute, which the
        // picker makes easy. c is re-dated onto that same instant.
        let tied = "2026-08-22T09:00:00Z"
        let page = Stub.page([
            Stub.memo(uid: "a", createdAt: tied),
            Stub.memo(uid: "b", createdAt: tied),
            Stub.memo(uid: "c", createdAt: "2026-08-21T09:00:00Z"),
        ])
        let client = Stub.client { _, _, operation in
            operation == "patch_memo_api_memos__uid__patch"
                ? Stub.json(Stub.memo(uid: "c", createdAt: tied))
                : Stub.json(page)
        }
        let store = await seeded(["a", "b", "c"], client: client)
        let chosen = try instant(tied)

        let edited = await store.edit(
            uid: "c",
            content: "same words",
            createdAt: chosen,
            using: client,
            baseURL: Stub.baseURL
        )
        #expect(edited)
        // The server settles a tie by `id DESC` and never sends the id (see `TimelineTie`), so an
        // existing memo does not overtake the rows already on that timestamp. A comparator that
        // treated a tie as "newer" would answer ["c", "a", "b"] here.
        #expect(store.memos.map(\.uid) == ["a", "b", "c"])
        #expect(store.memos.map(\.createdAt) == [chosen, chosen, chosen])
    }

    @Test("a memo the server has just created still leads at an identical timestamp")
    func aNewMemoLeadsATie() async throws {
        // The same tie, from the other side: a create holds the highest id in existence, so
        // `id DESC` puts it first — and the app says so rather than filing it behind.
        let tied = "2026-08-22T09:00:00Z"
        let page = Stub.page([
            Stub.memo(uid: "a", createdAt: tied),
            Stub.memo(uid: "b", createdAt: tied),
        ])
        let client = Stub.client { _, _, operation in
            operation == "create_memo_api_memos_post"
                ? Stub.json(Stub.memo(uid: "new", createdAt: tied), status: .created)
                : Stub.json(page)
        }
        let store = await seeded(["a", "b"], client: client)

        #expect(await store.create(content: "hello", using: client, baseURL: Stub.baseURL))
        #expect(store.memos.map(\.uid) == ["new", "a", "b"])
    }

    @Test("a pinned memo that is re-dated stays in the pinned block")
    func reDatingKeepsThePinnedBlock() async throws {
        let moved = "2026-08-01T08:00:00Z"
        let page = Stub.page([
            Stub.memo(uid: "p", pinned: true, createdAt: "2026-08-23T09:00:00Z"),
            Stub.memo(uid: "a", createdAt: "2026-08-22T09:00:00Z"),
        ])
        let client = Stub.client { _, _, operation in
            operation == "patch_memo_api_memos__uid__patch"
                ? Stub.json(Stub.memo(uid: "p", pinned: true, createdAt: moved))
                : Stub.json(page)
        }
        let store = await seeded(["p", "a"], client: client)
        let chosen = try instant(moved)

        let edited = await store.edit(
            uid: "p",
            content: "same words",
            createdAt: chosen,
            using: client,
            baseURL: Stub.baseURL
        )
        #expect(edited)
        // Older than the memo below it and still above it: pinned-first outranks the date, which
        // is how the server orders the page this list is a copy of.
        #expect(store.memos.map(\.uid) == ["p", "a"])
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
