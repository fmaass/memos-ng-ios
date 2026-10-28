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

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["a", "b"])
        #expect(store.hasMore)
        #expect(store.lastError == nil)
    }

    @Test("a page without a cursor is the last one")
    func refreshWithoutCursor() async {
        let store = TimelineStore()
        let client = Stub.client { _, _, _ in Stub.json(Stub.memoList(["a"], nextCursor: nil)) }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

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

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

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

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

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

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

        #expect(calls.count == 1)
    }

    @Test("a 401 ends the session instead of being retried")
    func unauthorizedSignsOut() async {
        let signedOut = Counter()
        let store = TimelineStore(onUnauthorized: { _ in
            signedOut.increment()
            return .endedSession
        })
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(signedOut.count == 1)
        #expect(store.memos.isEmpty)
        #expect(store.lastError != nil)
    }

    @Test("a server fault is reported without ending the session")
    func serverFaultKeepsSession() async {
        let signedOut = Counter()
        let store = TimelineStore(onUnauthorized: { _ in
            signedOut.increment()
            return .endedSession
        })
        let client = Stub.client { _, _, _ in Stub.empty(.internalServerError) }

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(signedOut.count == 0)
        #expect(store.lastError != nil)
    }

    @Test("the pagination trigger fires only near the end, and only when there is more")
    func paginationTrigger() async {
        let store = TimelineStore(pageSize: 4)
        let client = Stub.client { _, _, _ in
            Stub.json(Stub.memoList(["a", "b", "c", "d"], nextCursor: "cursor-1"))
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(!store.shouldLoadMore(after: 0, lookahead: 3))
        #expect(store.shouldLoadMore(after: 1, lookahead: 3))
        #expect(store.shouldLoadMore(after: 3, lookahead: 3))
    }
}

// MARK: - writes

extension TimelineStoreTests {
    private func seeded(_ uids: [String], client: any APIProtocol) async -> TimelineStore {
        let store = TimelineStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
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

        #expect(await store.create(content: "hello", using: client.handle, baseURL: Stub.baseURL))
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

        #expect(!(await store.create(content: "", using: client.handle, baseURL: Stub.baseURL)))
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

        let edited = await store.edit(
            uid: "a", content: "edited", using: client.handle, baseURL: Stub.baseURL
        ).isSaved
        #expect(edited)
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
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved
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
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved
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
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved
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

        #expect(await store.create(content: "hello", using: client.handle, baseURL: Stub.baseURL))
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
            using: client.handle,
            baseURL: Stub.baseURL
        ).isSaved
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

        #expect(await store.delete(uid: "a", using: client.handle))
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

        #expect(!(await store.delete(uid: "a", using: client.handle)))
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

        #expect(await store.setPinned(true, uid: "b", using: client.handle, baseURL: Stub.baseURL))
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
            await store.setVisibility(
                .cleared(.public),
                uid: "a",
                using: client.handle,
                baseURL: Stub.baseURL
            )
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
            await store.toggleTask(at: 0, in: "a", using: client.handle, baseURL: Stub.baseURL)
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

        #expect(await store.setPinned(false, uid: "a", using: client.handle, baseURL: Stub.baseURL))
        #expect(paths.get().contains { $0.hasSuffix("/a/unpin") })
        #expect(store.memos.first?.pinned == false)
    }

    @Test("a 403 on a write reports without ending the session")
    func forbiddenWriteDoesNotSignOut() async {
        let unauthorizedCalled = LockedValue<Bool>(false)
        let store = TimelineStore(onUnauthorized: { _ in
            unauthorizedCalled.set(true)
            return .endedSession
        })
        let client = Stub.client { _, _, operation in
            operation == "delete_memo_api_memos__uid__delete"
                ? Stub.empty(.forbidden)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(!(await store.delete(uid: "a", using: client.handle)))
        #expect(!unauthorizedCalled.get(), "someone else's memo must not cost this session")
        #expect(store.lastError != nil)
    }

    @Test("a 401 on a write does end the session")
    func unauthorizedWriteSignsOut() async {
        let unauthorizedCalled = LockedValue<Bool>(false)
        let store = TimelineStore(onUnauthorized: { _ in
            unauthorizedCalled.set(true)
            return .endedSession
        })
        let client = Stub.client { _, _, operation in
            operation == "delete_memo_api_memos__uid__delete"
                ? Stub.empty(.unauthorized)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(!(await store.delete(uid: "a", using: client.handle)))
        #expect(unauthorizedCalled.get())
    }

    // MARK: - the query the list is asking for

    /// The query parameters of one request, as the server would read them: repeated names kept in
    /// order, percent-encoding undone. Reading them back off the URL is the point — the claim is
    /// about what actually left the app, not about what the store meant to send.
    private static func sent(_ path: String) -> [String: [String]] {
        var parsed: [String: [String]] = [:]
        for item in URLComponents(string: path)?.queryItems ?? [] {
            parsed[item.name, default: []].append(item.value ?? "")
        }
        return parsed
    }

    /// Keeps a request open until the test lets it go. `nonisolated static`, because the scripted
    /// transport runs off the main actor. (The pagination-fence suite holds its own copy: the two
    /// suites share no state, and a helper reaching across them would couple them.)
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("a filtered page sends every filter on the second page too")
    func everyFilterTravelsOnEveryPage() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            return path.contains("cursor=page-2")
                ? Stub.json(Stub.memoList(["b"], nextCursor: nil))
                : Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let store = TimelineStore(
            pageSize: 1,
            query: MemoQuery(
                term: "travel",
                anchor: .day(year: 2026, month: 8, day: 24),
                tags: ["trip", "food"],
                visibility: .protected,
                includeArchived: true
            ),
            calendar: calendar
        )

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["a", "b"])
        let requests = paths.get().map { Self.sent($0) }
        #expect(requests.count == 2)
        // The server's cursor carries no filter state — it is base64 `created_at|id`
        // (`app/services/memos.py:43-49`) — so a filter the second page forgets silently widens
        // the list halfway down it.
        for (index, request) in requests.enumerated() {
            let page = index + 1
            #expect(request["q"] == ["travel"], "page \(page) dropped the term")
            #expect(
                request["created_before"] == ["2026-08-24T22:00:00Z"],
                "page \(page) dropped the date bound"
            )
            #expect(request["tag"] == ["trip", "food"], "page \(page) dropped a tag")
            #expect(request["visibility"] == ["PROTECTED"], "page \(page) dropped the visibility")
            #expect(request["include_archived"] == ["true"], "page \(page) dropped the archives")
            #expect(request["archived_only"] == nil, "page \(page) invented archived-only")
            #expect(request["limit"] == ["1"])
        }
        #expect(requests[0]["cursor"] == nil, "the first page asked from a cursor")
        #expect(
            requests[1]["cursor"] == ["page-2"],
            "control: the second request really is the next page"
        )
    }

    /// The regression that guards everything else in this phase: with no query, the request is
    /// EXACTLY the one this app sent before it could be filtered at all — the parameter names are
    /// asserted as a whole set, so a filter sent as `false` or `""` fails here.
    @Test("an empty query asks for exactly the plain timeline page")
    func anEmptyQuerySendsCursorAndLimitOnly() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            return path.contains("cursor=page-2")
                ? Stub.json(Stub.memoList(["b"], nextCursor: nil))
                : Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
        }
        let store = TimelineStore(pageSize: 1)
        #expect(store.query.isEmpty, "the default query is the plain timeline")

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

        let requests = paths.get().map { Self.sent($0) }
        #expect(requests.count == 2)
        #expect(Set(requests[0].keys) == ["limit"], "the plain first page carried a filter")
        #expect(
            Set(requests[1].keys) == ["cursor", "limit"],
            "the plain next page carried a filter"
        )
        #expect(requests[0]["limit"] == ["1"])
        #expect(requests[1]["cursor"] == ["page-2"])
        #expect(store.memos.map(\.uid) == ["a", "b"])
    }

    /// The fence, extended: a page is a continuation of a QUERY as much as of a list, and one that
    /// answers a superseded term carries rows nobody asked for and a cursor into a lineage nobody
    /// is reading.
    @Test("a page for a superseded query is dropped")
    func aPageForASupersededQueryIsDropped() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if path.contains("cursor=page-2") {
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.json(Stub.memoList(["unfiltered"], nextCursor: "page-3"))
            }
            return Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
        }
        let store = TimelineStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["a"])

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        store.setQuery(MemoQuery(term: "travel"))
        release.set(true)
        await inFlight.value

        #expect(
            store.memos.map(\.uid) == ["a"],
            "a page answering the unfiltered list was merged into a filtered one"
        )
        #expect(store.query == MemoQuery(term: "travel"))
        // The cursor is the damage that outlives the merge: adopted, every later page would walk
        // the unfiltered lineage while the list claims to be a search.
        #expect(
            !store.shouldLoadMore(after: 0),
            "the superseded page's cursor became the filtered list's cursor"
        )
        #expect(
            !paths.get().contains { $0.contains("cursor=page-3") },
            "the dropped page's cursor was asked for"
        )
        #expect(
            paths.get().contains { $0.contains("cursor=page-2") },
            "control: the page that was dropped is one this store really did ask for"
        )
    }

    @Test("setting the same query again does not disturb a page in flight")
    func settingAnUnchangedQueryChangesNothing() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("cursor=page-2") else {
                return Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
            }
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(Stub.memoList(["b"], nextCursor: nil))
        }
        let store = TimelineStore(pageSize: 1, query: MemoQuery(term: "travel"))
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        store.setQuery(MemoQuery(term: "travel"))
        release.set(true)
        await inFlight.value

        #expect(store.memos.map(\.uid) == ["a", "b"], "re-asking the same thing threw a page away")
        #expect(!store.hasMore)
    }

    /// A new query has to be able to READ, not merely to be recorded.
    ///
    /// The request the old query has in flight is exactly what a person changing a filter is
    /// waiting for the end of, so a "one refresh at a time" rule that counts it turns the change
    /// into nothing at all: fenced, unread, and no trigger left to try again.
    @Test("a refresh for a new query is not blocked by the old query's request")
    func aNewQueryRefreshesWhileTheOldOneIsStillInFlight() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("q=travel") else {
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.json(Stub.memoList(["unfiltered"], nextCursor: "page-2"))
            }
            return Stub.json(Stub.memoList(["travelled"], nextCursor: nil))
        }
        let store = TimelineStore(pageSize: 1)

        let inFlight = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        store.setQuery(MemoQuery(term: "travel"))
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["travelled"], "the new query never got to read anything")
        #expect(!store.isLoading, "the store still says it is loading a query nobody is reading")

        release.set(true)
        await inFlight.value

        #expect(store.memos.map(\.uid) == ["travelled"], "the superseded page landed anyway")
        #expect(!store.isLoading)
        #expect(store.lastError == nil)
    }

    /// A failure belongs to the request that suffered it. One arriving late from a query nobody is
    /// reading must not put an error over a list that loaded perfectly well — and a 401 from it
    /// must not end the session, because the current query's own request asks the same question
    /// and is the one entitled to answer it.
    @Test("a failure from a superseded query is not reported")
    func aFailureFromASupersededQueryIsDropped() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let unauthorizedCalled = LockedValue<Bool>(false)
        let travelPages = Counter()
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("q=travel") else {
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.empty(.unauthorized)
            }
            travelPages.increment()
            return travelPages.count == 1
                ? Stub.json(Stub.memoList(["travelled"], nextCursor: nil))
                : Stub.empty(.unauthorized)
        }
        let store = TimelineStore(
            pageSize: 1,
            onUnauthorized: { _ in
                unauthorizedCalled.set(true)
                return .endedSession
            }
        )

        let inFlight = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        store.setQuery(MemoQuery(term: "travel"))
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["travelled"])

        release.set(true)
        await inFlight.value

        #expect(store.lastError == nil, "a failure nobody was waiting for was put on screen")
        #expect(!unauthorizedCalled.get(), "a superseded request ended the session")
        #expect(store.memos.map(\.uid) == ["travelled"], "the failed request disturbed the list")

        // Control: the fence drops errors from a superseded lineage, not errors as such — the
        // current query's own 401 still reports and still ends the session.
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.lastError != nil, "control: a current failure was swallowed too")
        #expect(unauthorizedCalled.get(), "control: a current 401 no longer ends the session")
    }

    @Test("a superseded next page that fails leaves the current list alone")
    func aFailedSupersededNextPageIsNotReported() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            if path.contains("cursor=page-2") {
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.empty(.internalServerError)
            }
            return Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
        }
        let store = TimelineStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        store.setQuery(MemoQuery(term: "travel"))
        release.set(true)
        await inFlight.value

        #expect(store.lastError == nil, "a next page nobody is reading reported its failure")
        #expect(store.memos.map(\.uid) == ["a"])
    }
}

// MARK: - a newly documented 503 is answered as its undocumented self was

extension TimelineStoreTests {
    private static let unavailableSentence = APIError.server(status: 503).errorDescription

    /// The list every case below starts from, with `operation` answered by the database-busy 503.
    private func seededBusy(on operation: String) async -> (TimelineStore, any APIProtocol) {
        let client = Stub.client { _, _, asked in
            asked == operation
                ? Stub.databaseBusy() : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        return (await seeded(["a"], client: client), client)
    }

    @Test("a 503 to a memo delete keeps the row and says HTTP 503, as before v2.1.0")
    func deleteUnavailable() async {
        let (store, client) = await seededBusy(on: "delete_memo_api_memos__uid__delete")

        #expect(!(await store.delete(uid: "a", using: client.handle)))
        #expect(store.memos.map(\.uid) == ["a"])
        #expect(store.lastError == Self.unavailableSentence)
    }

    @Test("a 503 to a pin is reported as HTTP 503, as before v2.1.0")
    func pinUnavailable() async {
        let (store, client) = await seededBusy(on: "pin_memo_api_memos__uid__pin_post")

        let pinned = await store.setPinned(
            true, uid: "a", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(!pinned)
        #expect(store.lastError == Self.unavailableSentence)
    }

    @Test("a 503 to an unpin is reported as HTTP 503, as before v2.1.0")
    func unpinUnavailable() async {
        let (store, client) = await seededBusy(on: "unpin_memo_api_memos__uid__unpin_post")

        let unpinned = await store.setPinned(
            false, uid: "a", using: client.handle, baseURL: Stub.baseURL
        )

        #expect(!unpinned)
        #expect(store.lastError == Self.unavailableSentence)
    }

    /// Unreadable, not gone: only a 404 says a memo is no longer there.
    @Test("a 503 to a single-memo read makes a jump unreadable, as before v2.1.0")
    func jumpUnavailable() async {
        let (store, client) = await seededBusy(on: "get_memo_api_memos__uid__get")

        let outcome = await store.jump(
            to: "a", calendar: Calendar(identifier: .gregorian), using: client.handle,
            baseURL: Stub.baseURL
        )

        #expect(outcome == .unreadable)
    }

    /// A failed read, never a refusal: the session is not asked to end.
    @Test("a 503 to a reconciling read is a read that did not happen, as before v2.1.0")
    func reconcilingReadUnavailable() async {
        let signedOut = Counter()
        let store = TimelineStore(onUnauthorized: { _ in
            signedOut.increment()
            return .endedSession
        })
        let client = Stub.client { _, _, asked in
            asked == "get_memo_api_memos__uid__get"
                ? Stub.databaseBusy() : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let read = await store.refreshMemo(uid: "a", using: client.handle, baseURL: Stub.baseURL)

        #expect(!read)
        #expect(signedOut.count == 0)
        #expect(store.memos.map(\.uid) == ["a"])
    }
}

extension TimelineStoreTests {
    @Test("a proxy's HTML 503 to a memo delete says HTTP 503, as before v2.1.0")
    func deleteProxyPage() async {
        let client = Stub.client { _, _, asked in
            asked == "delete_memo_api_memos__uid__delete"
                ? Stub.proxyPage(.serviceUnavailable)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        let store = await seeded(["a"], client: client)

        #expect(!(await store.delete(uid: "a", using: client.handle)))
        #expect(store.memos.map(\.uid) == ["a"])
        #expect(store.lastError == APIError.server(status: 503).errorDescription)
    }

    /// The keyed create's 503 was documented before v2.1.0 as the race that stored nothing, and an
    /// unreadable one never was that answer: it is left to fail as it always did, not read as 503.
    @Test("a proxy's HTML 503 to a create is not turned into the race answer")
    func createProxyPageIsLeftAlone() async {
        let client = Stub.client { _, _, asked in
            asked == "create_memo_api_memos_post"
                ? Stub.proxyPage(.serviceUnavailable)
                : Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        let store = await seeded(["a"], client: client)

        #expect(!(await store.create(content: "x", using: client.handle, baseURL: Stub.baseURL)))
        #expect(store.lastError != nil)
        #expect(store.lastError != APIError.server(status: 503).errorDescription)
    }
}
