import Foundation
import MemosAPI
import MemosCore
import Testing

/// The fence between the loaded list and a page that is already in flight.
///
/// A pull-to-refresh, the reload a sign-in does and a scroll-driven next page genuinely overlap in
/// the app — nothing serialises them — so every test here drives one interleaving explicitly: the
/// next-page request is HELD open inside the scripted transport, the thing that races it happens
/// while it is held, and only then is it let go. Nothing is left to timing.
///
/// As everywhere in this bundle, the server is a script under the REAL generated client: the
/// request the store builds, its cursor and its decoding are all exercised. A stand-in for the
/// store would prove only that the test agrees with itself.
@MainActor
@Suite("Timeline pagination fence")
struct TimelinePaginationFenceTests {
    /// Keeps a request open until the test lets it go.
    ///
    /// `nonisolated static`, because it is called from inside the scripted transport, which the
    /// client runs off the main actor.
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private nonisolated static func waiting(_ uid: String, attachment: String) -> String {
        Stub.memo(uid: uid, attachments: [Stub.attachment(uid: attachment, status: "pending")])
    }

    @Test("a page that started before a refresh is dropped, cursor and all")
    func refreshDropsAPageThatStartedBeforeIt() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let paths = LockedValue<[String]>([])
        let firstPages = Counter()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if path.contains("cursor=page-2") {
                entered.set(true)
                try await Self.hold(until: release)
                // The list as it stood when the scroll asked for it: "stale" was on it, and the
                // cursor it hands back walks that same superseded lineage.
                return Stub.json(Stub.memoList(["stale"], nextCursor: "page-3"))
            }
            firstPages.increment()
            // The refreshed list is complete — there is no page after it — so the drop is the
            // only thing that happens here and can be read off the store directly.
            return firstPages.count == 1
                ? Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
                : Stub.json(Stub.memoList(["fresh-a"], nextCursor: nil))
        }
        let store = TimelineStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["a"])
        #expect(store.hasMore)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["fresh-a"], "the refresh did not replace the list")
        release.set(true)
        await inFlight.value

        #expect(store.memos.map(\.uid) == ["fresh-a"], "the superseded page was merged anyway")
        // The cursor is the damage that outlives the merge. The refreshed list ends where it ends;
        // had the dropped page's `nextCursor` been adopted, the store would believe there is more.
        #expect(!store.hasMore, "the dropped page's cursor was adopted")
        #expect(
            !paths.get().contains { $0.contains("cursor=page-3") },
            "the dropped page's cursor was asked for"
        )
        #expect(
            paths.get().contains { $0.contains("cursor=page-2") },
            "control: the page that was dropped is one this store really did ask for"
        )
    }

    /// The control the fence needs to be worth anything: with nothing racing it, the very same
    /// held-open page lands exactly as it always did.
    @Test("a page that started under the list it lands on is merged")
    func aPageOfTheCurrentListStillMerges() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            guard path.contains("cursor=page-2") else {
                return Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
            }
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(Stub.memoList(["b"], nextCursor: nil))
        }
        let store = TimelineStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        release.set(true)
        await inFlight.value

        #expect(store.memos.map(\.uid) == ["a", "b"])
        #expect(!store.hasMore)
        #expect(store.lastError == nil)
    }

    /// Gives the store's own tail its turns, and gives up rather than hanging.
    private static func settles(tries: Int = 60, until ready: () -> Bool) async -> Bool {
        for _ in 0..<tries {
            if ready() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return ready()
    }

    @Test("a refresh that arrives while one is running does not open a second lineage")
    func refreshDuringRefreshLeavesOneList() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let firstPages = Counter()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            if path.contains("cursor=page-2") {
                return Stub.json(Stub.memoList(["b"], nextCursor: nil))
            }
            firstPages.increment()
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
        }
        let store = TimelineStore(pageSize: 1)

        let first = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        // A second pull, mid-first. The store turns it away rather than reading page one BESIDE
        // the read already out — and takes it once afterwards, because that read left before the
        // pull was asked for and so cannot be the answer to it.
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(firstPages.count == 1, "the second pull read page one beside the one in flight")
        release.set(true)
        await first.value

        #expect(
            await Self.settles(until: { firstPages.count == 2 }),
            "the turned-away pull was dropped rather than taken after the read it waited on")
        #expect(firstPages.count == 2, "page one was read \(firstPages.count) times, not twice")
        #expect(store.memos.map(\.uid) == ["a"])
        // And the generation is not left ahead of the list: the page that follows the refresh that
        // DID run still belongs to it, so it still lands.
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["a", "b"], "the turned-away pull fenced a valid page")
    }

    @Test("a delete is not undone by a page that was read while the memo was still there")
    func deleteFencesThePageInFlight() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let secondPages = Counter()
        let client = Stub.client { request, _, operation in
            if operation == "delete_memo_api_memos__uid__delete" {
                return Stub.empty(.noContent)
            }
            let path = request.path ?? ""
            guard path.contains("cursor=page-2") else {
                return Stub.json(Stub.memoList(["a", "b"], nextCursor: "page-2"))
            }
            secondPages.increment()
            guard secondPages.count == 1 else {
                // Asked again after the delete, the server no longer has "b" either.
                return Stub.json(Stub.memoList(["c"], nextCursor: nil))
            }
            entered.set(true)
            try await Self.hold(until: release)
            // Cursor pages overlap when rows move, so page two repeats "b" — the memo the reader
            // deletes while this very request is open.
            return Stub.json(Stub.memoList(["b", "c"], nextCursor: "page-3"))
        }
        let store = TimelineStore(pageSize: 2)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.map(\.uid) == ["a", "b"])

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        let removed = await store.delete(uid: "b", using: client.handle)
        release.set(true)
        await inFlight.value

        #expect(removed)
        #expect(
            !store.memos.map(\.uid).contains("b"),
            "the page in flight put the deleted memo back"
        )
        // Nothing is lost by dropping it: the cursor never advanced, and the store asks again for
        // that same page itself, so what lands is the list as it is now.
        #expect(store.memos.map(\.uid) == ["a", "c"])
        #expect(secondPages.count == 2, "the dropped page was never asked for again")
    }

    /// The fence has to be narrow. The live media channel touches the loaded memos constantly —
    /// an event roughly every one and a half seconds while anything transcodes, plus the one
    /// reconciling re-read it makes when it starts — and neither changes WHICH memos there are.
    /// If those bumped the generation, a scroll during an upload would silently fetch pages that
    /// are then thrown away, and the timeline would stop paginating for as long as the upload ran.
    @Test("a live event and the reconciling re-read do not fence the page in flight")
    func liveMediaUpdatesDoNotFenceThePage() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { request, _, operation in
            if operation == "get_memo_api_memos__uid__get" {
                return Stub.json(
                    Stub.memo(
                        uid: "a",
                        content: "reconciled",
                        attachments: [Stub.attachment(uid: "a1", status: "pending")]
                    )
                )
            }
            let path = request.path ?? ""
            guard path.contains("cursor=page-2") else {
                let first = Stub.page(
                    [Self.waiting("a", attachment: "a1")], nextCursor: "page-2"
                )
                return Stub.json(first)
            }
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(Stub.memoList(["b"], nextCursor: nil))
        }
        let store = TimelineStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.memos.first?.attachments.first?.readiness == .waiting)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        // The reconciling read the channel makes when it starts, and one event off the stream.
        let reconciled = await store.refreshMemo(
            uid: "a",
            using: client.handle,
            baseURL: Stub.baseURL
        )
        await store.apply(
            MediaEvent(uid: "a1", status: .ready, progressPercent: 100, width: 1000, height: 1000)
        )
        release.set(true)
        await inFlight.value

        #expect(reconciled)
        #expect(store.memos.map(\.uid) == ["a", "b"], "an in-place update fenced a valid page")
        #expect(store.memos.first?.content == "reconciled", "the re-read did not land")
        #expect(
            store.memos.first?.attachments.first?.readiness == .ready,
            "the live event did not land"
        )
        #expect(!store.hasMore)
    }

    /// The reader who cannot ask again.
    ///
    /// The app asks for the next page when the last row APPEARS, and a row already on screen does
    /// not appear a second time: someone parked at the end of the list has already spent their
    /// trigger. So a dropped page that waits to be re-requested waits for ever. This test is that
    /// reader — after the drop it asks for nothing at all, and the list still has to fill.
    @Test("a dropped page is asked for again by the store, with no second call from the reader")
    func aDroppedPageIsAskedForAgainWithoutTheReader() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let paths = LockedValue<[String]>([])
        let firstPages = Counter()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if path.contains("cursor=page-2") {
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.json(Stub.memoList(["stale"], nextCursor: "page-3"))
            }
            if path.contains("cursor=fresh-2") {
                return Stub.json(Stub.memoList(["fresh-b"], nextCursor: nil))
            }
            firstPages.increment()
            return firstPages.count == 1
                ? Stub.json(Stub.memoList(["a"], nextCursor: "page-2"))
                : Stub.json(Stub.memoList(["fresh-a"], nextCursor: "fresh-2"))
        }
        let store = TimelineStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !entered.get() {
            await Task.yield()
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        release.set(true)
        await inFlight.value

        // Not one line below this asks for a page. Everything here is the store's own doing.
        #expect(
            paths.get().contains { $0.contains("cursor=fresh-2") },
            "the store dropped the page and never asked for the one that replaces it"
        )
        #expect(store.memos.map(\.uid) == ["fresh-a", "fresh-b"])
        #expect(!store.memos.map(\.uid).contains("stale"), "the superseded page was merged")
        #expect(!store.hasMore)
        #expect(store.lastError == nil)
    }

    /// Asking again cannot become asking for ever. Each drop buys exactly one more read, of the
    /// page that follows the list as it stands at that moment — so a list changing three times
    /// under one reader costs three reads and no more, and the last one is an ordinary merge.
    @Test("each drop asks again exactly once, however often the list changes underneath")
    func theSecondAskIsBoundedByTheChangesThatCauseIt() async {
        let enteredBeta = LockedValue<Bool>(false)
        let releaseAlpha = LockedValue<Bool>(false)
        let releaseBeta = LockedValue<Bool>(false)
        let enteredAlpha = LockedValue<Bool>(false)
        let paths = LockedValue<[String]>([])
        let firstPages = Counter()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if path.contains("cursor=c-alpha") {
                enteredAlpha.set(true)
                try await Self.hold(until: releaseAlpha)
                return Stub.json(Stub.memoList(["stale-alpha"], nextCursor: "c-alpha-next"))
            }
            if path.contains("cursor=c-beta") {
                enteredBeta.set(true)
                try await Self.hold(until: releaseBeta)
                return Stub.json(Stub.memoList(["stale-beta"], nextCursor: "c-beta-next"))
            }
            if path.contains("cursor=c-gamma") {
                return Stub.json(Stub.memoList(["gamma-2"], nextCursor: nil))
            }
            firstPages.increment()
            switch firstPages.count {
            case 1: return Stub.json(Stub.memoList(["alpha-1"], nextCursor: "c-alpha"))
            case 2: return Stub.json(Stub.memoList(["beta-1"], nextCursor: "c-beta"))
            default: return Stub.json(Stub.memoList(["gamma-1"], nextCursor: "c-gamma"))
            }
        }
        let store = TimelineStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        while !enteredAlpha.get() {
            await Task.yield()
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        releaseAlpha.set(true)
        // The store asks again on its own — and the list changes under THAT read too. This wait
        // is the only one with a deadline on it: if the second ask never comes, the point of the
        // test is that it never comes, and that has to read as a failure rather than a hang.
        let deadline = ContinuousClock.now + .seconds(5)
        while !enteredBeta.get(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(enteredBeta.get(), "the store never asked again for the page it dropped")
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        releaseBeta.set(true)
        await inFlight.value

        #expect(store.memos.map(\.uid) == ["gamma-1", "gamma-2"])
        #expect(!store.hasMore)
        for cursor in ["c-alpha", "c-beta", "c-gamma"] {
            let asked = paths.get().filter { $0.contains("cursor=\(cursor)") }.count
            #expect(asked == 1, "\(cursor) was asked for \(asked) times, not once")
        }
        #expect(
            !paths.get().contains { $0.contains("-next") },
            "a superseded page's own cursor was followed"
        )
    }
}
