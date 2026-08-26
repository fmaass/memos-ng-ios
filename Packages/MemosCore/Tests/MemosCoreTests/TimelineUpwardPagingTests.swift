import Foundation
import MemosAPI
import MemosCore
import Testing

/// Paging an anchored list towards now (MEMNG-179).
///
/// The bug this suite exists for is not a wrong value anywhere — every request the app sent was
/// correct. It is a direction that did not exist: a jump put a ceiling over the list, `loadMore`
/// walked down from it for ever, and there was no request in the app at all whose answer was the
/// memos ABOVE the ceiling. So these tests are mostly about the request that is now made, and one
/// of them is about the request that still must not be.
@MainActor
@Suite("Timeline upward paging")
struct TimelineUpwardPagingTests {
    /// The calendar the heatmap's days are cut in, which is the calendar an anchor is read in.
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private static let anchored = MemoQuery(anchor: .day(year: 2026, month: 8, day: 24))

    private static func sent(_ path: String) -> [String: [String]] {
        var parsed: [String: [String]] = [:]
        for item in URLComponents(string: path)?.queryItems ?? [] {
            parsed[item.name, default: []].append(item.value ?? "")
        }
        return parsed
    }

    /// The anchored first page: two memos on the 24th, newest first, as the server sends them.
    ///
    /// `nonisolated`, because the scripted transport is called off the main actor and this suite
    /// is on it — a page the handler cannot read is a page that does not compile.
    private nonisolated static let anchoredPage = Stub.page(
        [
            Stub.memo(uid: "a", createdAt: "2026-08-24T18:00:00Z"),
            Stub.memo(uid: "b", createdAt: "2026-08-24T08:00:00Z"),
        ],
        nextCursor: nil
    )

    /// Keeps a request open until the test lets it go. `nonisolated static`, because the scripted
    /// transport runs off the main actor.
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("an anchored list reads the page above it and puts it on top")
    func anAnchoredListPagesTowardsNewer() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            guard path.contains("sort=created_at") else { return Stub.json(Self.anchoredPage) }
            // Ascending: the memos directly above the list, OLDEST first — which is what makes
            // them contiguous with it rather than the newest memos in the account.
            return Stub.json(
                Stub.page(
                    [
                        Stub.memo(uid: "n1", createdAt: "2026-08-25T09:00:00Z"),
                        Stub.memo(uid: "n2", createdAt: "2026-08-26T09:00:00Z"),
                    ],
                    nextCursor: nil
                )
            )
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)

        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(store.hasNewer, "an anchored list believed there was nothing above it")
        let restore = await store.loadNewer(using: client, baseURL: Stub.baseURL)

        // Reversed on the way in: the list stays newest-first from top to bottom, which is the
        // order every other thing that reads `memos` — the day grouping above all — depends on.
        #expect(store.memos.map(\.uid) == ["n2", "n1", "a", "b"])
        #expect(restore == "a", "the reader was not put back on the row they were standing on")
        #expect(!store.hasNewer, "the server said that page was the last one above")

        let upward = try #require(paths.get().last.map { Self.sent($0) })
        // The bound is read from the newest memo ALREADY LOADED, not the anchor's ceiling — and
        // a run STARTS one second below that row: `created_after` is strict, so asking from the
        // row's exact timestamp would strand an unseen sibling written in the same second. The
        // overlap the ease invites comes back and is dropped by uid, which a test below holds.
        #expect(upward["created_after"] == ["2026-08-24T17:59:59Z"])
        #expect(upward["sort"] == ["created_at"])
        #expect(
            upward["created_before"] == nil,
            "the anchor's ceiling travelled on the page that has to climb over it"
        )
        #expect(upward["cursor"] == nil)
        #expect(upward["limit"] == ["2"])
    }

    @Test("the bound moves, so the second page above is not the first one again")
    func theBoundMovesWithEachUpwardPage() async throws {
        let paths = LockedValue<[String]>([])
        // Counted rather than matched on the bound: the assertion below is what reads the bound,
        // and a stub that dispatched on a percent-encoded timestamp would be asserting the
        // encoder as well as the store.
        let upwards = Counter()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            guard path.contains("sort=created_at") else { return Stub.json(Self.anchoredPage) }
            upwards.increment()
            guard upwards.count == 1 else {
                return Stub.json(
                    Stub.page(
                        [Stub.memo(uid: "n3", createdAt: "2026-08-27T09:00:00Z")],
                        nextCursor: nil
                    )
                )
            }
            return Stub.json(
                Stub.page(
                    [
                        Stub.memo(uid: "n1", createdAt: "2026-08-25T09:00:00Z"),
                        Stub.memo(uid: "n2", createdAt: "2026-08-26T09:00:00Z"),
                    ],
                    nextCursor: "up-2"
                )
            )
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)

        await store.refresh(using: client, baseURL: Stub.baseURL)
        await store.loadNewer(using: client, baseURL: Stub.baseURL)
        #expect(store.hasNewer, "the server offered another page above and it was thrown away")
        let restore = await store.loadNewer(using: client, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["n3", "n2", "n1", "a", "b"])
        #expect(restore == "n2", "the reader was put back on a row that is no longer the top one")
        let upward = paths.get().filter { $0.contains("sort=created_at") }.map { Self.sent($0) }
        #expect(upward.count == 2)
        // Required rather than subscripted: an out-of-range index is a process crash, and a
        // crash here would take every later suite down with it instead of failing one test.
        let firstUp = try #require(upward.first)
        let secondUp = try #require(upward.last)
        #expect(firstUp["created_after"] == ["2026-08-24T17:59:59Z"])
        #expect(firstUp["cursor"] == nil)
        // Mid-run, the position is the SERVER's cursor — it carries the (created_at, id) tuple
        // the keyset really orders by. A timestamp recomputed from the loaded rows cannot: a
        // page boundary inside one second of memos would strand that second's unseen half.
        #expect(
            secondUp["cursor"] == ["up-2"],
            "the second page above dropped the server's own continuation"
        )
        #expect(
            secondUp["created_after"] == nil,
            "a timestamp bound rode along with the cursor and narrowed it"
        )
    }

    @Test("a sibling written in the newest row's own second is not stranded")
    func aSameSecondSiblingIsStillReachable() async {
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("sort=created_at") else {
                return Stub.json(Self.anchoredPage)
            }
            // The eased start re-answers the newest loaded row and the sibling that shares its
            // second — which is exactly what the server says for created_after one below it.
            return Stub.json(
                Stub.page(
                    [
                        Stub.memo(uid: "a", createdAt: "2026-08-24T18:00:00Z"),
                        Stub.memo(uid: "a2", createdAt: "2026-08-24T18:00:00Z"),
                    ],
                    nextCursor: nil
                )
            )
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)

        await store.refresh(using: client, baseURL: Stub.baseURL)
        await store.loadNewer(using: client, baseURL: Stub.baseURL)

        #expect(
            store.memos.map(\.uid) == ["a2", "a", "b"],
            "the same-second sibling never reached the list, or the known row was doubled"
        )
    }

    @Test("an overlap-only page is followed to the one above it, not handed back")
    func anOverlapOnlyPageFollowsItsContinuation() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            guard path.contains("sort=created_at") else { return Stub.json(Self.anchoredPage) }
            // The eased start answers with nothing the list does not already have — and a
            // cursor, because newer memos remain beyond the overlap.
            guard path.contains("cursor=") else {
                return Stub.json(
                    Stub.page(
                        [
                            Stub.memo(uid: "a", createdAt: "2026-08-24T18:00:00Z"),
                            Stub.memo(uid: "b", createdAt: "2026-08-24T08:00:00Z"),
                        ],
                        nextCursor: "up-2"
                    )
                )
            }
            return Stub.json(
                Stub.page(
                    [Stub.memo(uid: "n1", createdAt: "2026-08-25T09:00:00Z")],
                    nextCursor: nil
                )
            )
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let restore = await store.loadNewer(using: client, baseURL: Stub.baseURL)

        #expect(
            store.memos.map(\.uid) == ["n1", "a", "b"],
            "the page beyond the overlap never arrived: the reader's top-arrival bought nothing"
        )
        #expect(restore == "a")
        let upward = paths.get().filter { $0.contains("sort=created_at") }.map { Self.sent($0) }
        #expect(upward.count == 2, "the continuation the overlap page carried was not followed")
        #expect(try #require(upward.last)["cursor"] == ["up-2"])
    }

    @Test("a page in flight while a memo is pinned is dropped, not merged")
    func anUpwardPageInFlightAcrossAPinIsDropped() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            if path.contains("/pin") {
                return Stub.json(
                    Stub.memo(uid: "b", pinned: true, createdAt: "2026-08-24T08:00:00Z")
                )
            }
            guard path.contains("sort=created_at") else { return Stub.json(Self.anchoredPage) }
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(
                Stub.page(
                    [Stub.memo(uid: "n1", createdAt: "2026-08-25T09:00:00Z")],
                    nextCursor: nil
                )
            )
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadNewer(using: client, baseURL: Stub.baseURL) }
        let deadline = Date().addingTimeInterval(5)
        while !entered.get(), Date() < deadline {
            await Task.yield()
        }
        #expect(entered.get(), "the page above was never asked for")
        // The pin is a MOVE: the list is pinned-first, and the block in flight was measured
        // against the unpinned order (review round: the pin path bypassed the fence).
        await store.setPinned(true, uid: "b", using: client, baseURL: Stub.baseURL)
        release.set(true)
        let restore = await inFlight.value

        #expect(
            store.memos.map(\.uid) == ["b", "a"],
            "a page measured against the unpinned order was merged around the pinned memo"
        )
        #expect(restore == nil)
    }

    @Test("a page above measured before a memo moved is dropped, not merged")
    func anUpwardPageForAReorderedListIsDropped() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("sort=created_at") else {
                return Stub.json(Self.anchoredPage)
            }
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(
                Stub.page(
                    [Stub.memo(uid: "n1", createdAt: "2026-08-25T09:00:00Z")],
                    nextCursor: nil
                )
            )
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadNewer(using: client, baseURL: Stub.baseURL) }
        let deadline = Date().addingTimeInterval(5)
        while !entered.get(), Date() < deadline {
            await Task.yield()
        }
        #expect(entered.get(), "the page above was never asked for")
        // The server re-dates a loaded memo to ABOVE the block in flight. The block was bounded
        // below the old order: merged anyway, it would sit above rows it is older than, and the
        // next bound - read from the moved row - would skip everything the move jumped over.
        store.apply(
            Memo(
                uid: "b",
                owner: "fabian",
                mine: true,
                content: "b",
                visibility: .private,
                pinned: false,
                createdAt: Date(timeIntervalSince1970: 1_787_994_000),
                updatedAt: Date(timeIntervalSince1970: 1_787_994_000)
            )
        )
        release.set(true)
        let restore = await inFlight.value

        #expect(
            store.memos.map(\.uid) == ["b", "a"],
            "a page measured against the old order was merged over the moved memo"
        )
        #expect(restore == nil)
    }

    @Test("a plain timeline never reads above its own first page")
    func aPlainTimelineNeverReadsUpwards() async {
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        let store = TimelineStore(pageSize: 2, calendar: Self.utc)

        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(!store.hasNewer, "the newest memo there is had something claimed above it")
        let restore = await store.loadNewer(using: client, baseURL: Stub.baseURL)
        #expect(restore == nil)
        #expect(calls.count == 1, "a request went out for a page that cannot exist")

        // Positive control: the same store, anchored, DOES read upwards — so the refusal above is
        // the absence of a ceiling and not an upward path that never works.
        store.setQuery(Self.anchored)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(store.hasNewer)
        await store.loadNewer(using: client, baseURL: Stub.baseURL)
        #expect(calls.count == 3)
    }

    @Test("an anchored query that has not been read yet promises nothing above it")
    func settingAQueryClearsTheUpwardPromise() async {
        let client = Stub.client { _, _, _ in Stub.json(Self.anchoredPage) }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(store.hasNewer)

        store.setQuery(.empty)

        #expect(!store.hasNewer, "a stale upward promise survived the query it belonged to")
    }

    @Test("a memo already loaded is not shown twice by the page above")
    func anOverlappingUpwardPageIsDeduplicated() async {
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("sort=created_at") else {
                return Stub.json(Self.anchoredPage)
            }
            return Stub.json(
                Stub.page(
                    [
                        Stub.memo(uid: "a", createdAt: "2026-08-24T18:00:00Z"),
                        Stub.memo(uid: "n1", createdAt: "2026-08-25T09:00:00Z"),
                    ],
                    nextCursor: nil
                )
            )
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)

        await store.refresh(using: client, baseURL: Stub.baseURL)
        await store.loadNewer(using: client, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["n1", "a", "b"])
    }

    @Test("a page above that adds nothing leaves the reader exactly where they were")
    func anEmptyUpwardPageDoesNotMoveTheReader() async {
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("sort=created_at") else {
                return Stub.json(Self.anchoredPage)
            }
            return Stub.json(Stub.page([], nextCursor: nil))
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let restore = await store.loadNewer(using: client, baseURL: Stub.baseURL)

        #expect(store.memos.map(\.uid) == ["a", "b"])
        // Nil, not "a": the caller scrolls to whatever comes back, and scrolling the reader to a
        // row they are already on is a jolt for nothing.
        #expect(restore == nil)
        #expect(!store.hasNewer, "the top of the account was reached and not noticed")
    }

    @Test("a page above that answers a list that has moved on is dropped")
    func anUpwardPageForASupersededListIsDropped() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("sort=created_at") else {
                return Stub.json(Self.anchoredPage)
            }
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(
                Stub.page(
                    [Stub.memo(uid: "n1", createdAt: "2026-08-25T09:00:00Z")],
                    nextCursor: nil
                )
            )
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadNewer(using: client, baseURL: Stub.baseURL) }
        // Bounded: a page above that is never asked for at all has to FAIL this test, not hang
        // it — an unbounded spin turns one broken expectation into a suite that never ends.
        let deadline = Date().addingTimeInterval(5)
        while !entered.get(), Date() < deadline {
            await Task.yield()
        }
        #expect(entered.get(), "the page above was never asked for")
        store.setQuery(MemoQuery(term: "travel"))
        release.set(true)
        let restore = await inFlight.value

        #expect(
            store.memos.map(\.uid) == ["a", "b"],
            "a page above the anchored list was put on top of a filtered one"
        )
        #expect(restore == nil)
    }

    @Test("every filter travels on the page above, and the ceiling does not")
    func everyFilterTravelsUpwards() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            guard path.contains("sort=created_at") else { return Stub.json(Self.anchoredPage) }
            return Stub.json(Stub.page([], nextCursor: nil))
        }
        let store = TimelineStore(
            pageSize: 2,
            query: MemoQuery(
                term: "travel",
                anchor: .day(year: 2026, month: 8, day: 24),
                tags: ["trip", "food"],
                visibility: .protected,
                includeArchived: true
            ),
            calendar: Self.utc
        )

        await store.refresh(using: client, baseURL: Stub.baseURL)
        await store.loadNewer(using: client, baseURL: Stub.baseURL)

        let upward = try #require(paths.get().last.map { Self.sent($0) })
        #expect(upward["q"] == ["travel"], "the page above dropped the term")
        #expect(upward["tag"] == ["trip", "food"], "the page above dropped a tag")
        #expect(upward["visibility"] == ["PROTECTED"], "the page above dropped the visibility")
        #expect(upward["include_archived"] == ["true"], "the page above dropped the archives")
        #expect(upward["archived_only"] == nil, "the page above invented archived-only")
        #expect(upward["created_before"] == nil, "the page above kept the ceiling it climbs over")
        // Control: the page BELOW is the same filter set with the ceiling still on it, so the
        // absence above is the direction and not a filter that was never sent at all.
        let downward = try #require(paths.get().first.map { Self.sent($0) })
        #expect(downward["created_before"] == ["2026-08-25T00:00:00Z"])
        #expect(downward["sort"] == nil)
    }

    @Test("the trigger for the page above is the top of the list, and only while there is one")
    func theUpwardTriggerIsTheTopOfTheList() async {
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("sort=created_at") else {
                return Stub.json(Self.anchoredPage)
            }
            return Stub.json(Stub.page([], nextCursor: nil))
        }
        let store = TimelineStore(pageSize: 2, query: Self.anchored, calendar: Self.utc)
        #expect(!store.shouldLoadNewer(before: 0), "an unread list reached for a page above")

        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(store.shouldLoadNewer(before: 0))
        #expect(store.shouldLoadNewer(before: 2))
        #expect(!store.shouldLoadNewer(before: 3), "a row three deep counted as the top")

        // Once the server says there is nothing above, the trigger stops asking.
        await store.loadNewer(using: client, baseURL: Stub.baseURL)
        #expect(!store.shouldLoadNewer(before: 0))
    }

    @Test("reading towards now drops the ceiling and turns the sort around")
    func theNewerDirectionRewritesTheBound() {
        let query = MemoQuery(
            term: "trip", anchor: .day(year: 2026, month: 8, day: 24), tags: ["a"]
        )
        let bound = Date(timeIntervalSince1970: 1_787_616_000)
        let older = query.parameters(in: Self.utc, direction: .older)
        let newer = query.parameters(in: Self.utc, direction: .newer, after: bound)

        #expect(older.createdBefore == bound)
        #expect(older.createdAfter == nil)
        #expect(older.sort == nil, "the older direction sent a sort the server already defaults to")
        #expect(newer.createdBefore == nil)
        #expect(newer.createdAfter == bound)
        #expect(newer.sort == "created_at")
        // Everything that is not a bound is the same question asked the other way up.
        #expect(newer.q == older.q)
        #expect(newer.tag == older.tag)
        // And the direction with no bound at all asks for the oldest memos the query matches,
        // which is what an anchored list with nothing in it needs.
        #expect(query.parameters(in: Self.utc, direction: .newer).createdAfter == nil)
    }
}
