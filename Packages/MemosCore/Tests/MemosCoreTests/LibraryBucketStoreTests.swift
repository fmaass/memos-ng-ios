import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The Library's date buckets (MEMNG-584): `GET /api/attachments/buckets` counted per day, month
/// or year in one zone, fenced like the tag menu it sits beside.
///
/// The server is a script under the REAL generated client, so the query the store derives from a
/// request, the decoding of `AttachmentBucket` and the resolution of its cover are all exercised.
@MainActor
@Suite("Library date buckets")
struct LibraryBucketStoreTests {
    private static let operation = "attachment_buckets_api_attachments_buckets_get"
    private static let zone = "Pacific/Auckland"

    @Test("day, month and year decode, and the query names size, tz, type and tag")
    func eachSizeDecodes() async {
        let seen = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            seen.set(seen.get() + ["\(operation) \(request.path ?? "")"])
            let size = Self.items(request.path)["size"]?.first ?? "?"
            return Stub.json(
                #"[{"key":"k-\#(size)","count":4,"coverUid":"u-\#(size)","#
                    + #""coverThumbnailUrl":"/api/attachments/u-\#(size)/thumbnail?sig=s"}]"#
            )
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        #expect(store.timeZoneIdentifier == Self.zone)

        for size in LibraryBucketSize.allCases {
            await store.load(
                size: size,
                filter: .videos,
                tag: "travel",
                using: client.handle,
                baseURL: Stub.baseURL
            )
            #expect(
                store.buckets == [
                    LibraryBucket(
                        key: "k-\(size.rawValue)",
                        count: 4,
                        coverUID: "u-\(size.rawValue)",
                        coverThumbnailURL: URL(
                            string:
                                "https://memos.example.invalid/api/attachments/u-\(size.rawValue)/thumbnail?sig=s"
                        )
                    )
                ],
                "\(size)"
            )
            #expect(store.loadedRequest?.size == size)
            #expect(store.lastError == nil)
        }

        let requests = seen.get()
        #expect(requests.count == 3)
        for (request, size) in zip(requests, LibraryBucketSize.allCases) {
            #expect(request.hasPrefix(Self.operation), "not the buckets operation: \(request)")
            let path = String(request.dropFirst(Self.operation.count + 1))
            let items = Self.items(path)
            #expect(items["size"] == [size.rawValue], "\(request)")
            #expect(items["tz"] == [Self.zone], "\(request)")
            #expect(items["type"] == ["video"], "\(request)")
            #expect(items["tag"] == ["travel"], "\(request)")
        }
    }

    /// A card never assumes a cover exists (MEMNG-586): a cover URL that does not resolve is no
    /// URL at all, rather than the server's base address standing in for a picture.
    @Test("a cover URL that does not resolve is nil, and the bucket is still listed")
    func anUnresolvableCoverIsNil() async {
        let client = Stub.client { _, _, _ in
            Stub.json(
                #"[{"key":"2026","count":3,"coverUid":"u","coverThumbnailUrl":""},"#
                    + #"{"key":"2025","count":1,"coverUid":"v","coverThumbnailUrl":"/t"}]"#
            )
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        await store.load(
            size: .year, filter: .all, tag: nil, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.buckets.map(\.key) == ["2026", "2025"])
        #expect(store.buckets.first?.coverThumbnailURL == nil)
        #expect(store.buckets.first?.count == 3)
        // The control: a cover that does resolve is resolved against the server.
        #expect(
            store.buckets.last?.coverThumbnailURL
                == URL(string: "https://memos.example.invalid/t")
        )
    }

    @Test("All with no tag sends neither, and the zone defaults to the library's calendar")
    func allAndNoTagAreAbsent() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json("[]")
        }
        let store = LibraryBucketStore()
        #expect(store.timeZoneIdentifier == libraryTimeZone)
        await store.load(
            size: .month,
            filter: .all,
            tag: nil,
            using: client.handle,
            baseURL: Stub.baseURL
        )

        let items = Self.items(paths.get().first)
        #expect(items["size"] == ["month"], "control: the query was read: \(paths.get())")
        #expect(items["tz"] == [libraryTimeZone], "\(paths.get())")
        #expect(items["type"] == nil, "All sent a type: \(paths.get())")
        #expect(items["tag"] == nil, "no tag sent a tag: \(paths.get())")
    }

    @Test("a tag that spells another parameter is still one tag and the kind still rides alone")
    func aTagSpellingAParameterStaysATag() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json("[]")
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        await store.load(
            size: .day,
            filter: .videos,
            tag: "x&type=image",
            using: client.handle,
            baseURL: Stub.baseURL
        )

        let items = Self.items(paths.get().first)
        #expect(items["tag"] == ["x&type=image"], "\(paths.get())")
        #expect(items["type"] == ["video"], "the tag's text stood in for the kind: \(paths.get())")
        #expect(items["size"] == ["day"], "\(paths.get())")
    }

    @Test("an empty answer is an empty list, not an error, and replaces the last one")
    func anEmptyAnswerIsAnEmptyList() async {
        let empty = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in
            empty.get()
                ? Stub.json("[]")
                : Stub.json(
                    #"[{"key":"2026-09","count":2,"coverUid":"u","coverThumbnailUrl":"/t"}]"#
                )
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        await store.load(
            size: .month,
            filter: .all,
            tag: nil,
            using: client.handle,
            baseURL: Stub.baseURL
        )
        #expect(store.buckets.map(\.key) == ["2026-09"], "control: the first list loaded")

        empty.set(true)
        await store.load(
            size: .year,
            filter: .all,
            tag: nil,
            using: client.handle,
            baseURL: Stub.baseURL
        )
        #expect(store.buckets.isEmpty, "an empty answer left the last list standing")
        #expect(store.lastError == nil)
        #expect(store.loadedRequest?.size == .year, "the empty answer was not applied")
    }

    @Test("a refused credential goes to the session as one typed refusal")
    func aRefusalReachesTheSession() async {
        let handled = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let ended = LibraryBucketStore(
            timeZoneIdentifier: Self.zone,
            onUnauthorized: { _ in
                handled.set(handled.get() + 1)
                return .endedSession
            }
        )
        await ended.load(
            size: .month,
            filter: .all,
            tag: nil,
            using: client.handle,
            baseURL: Stub.baseURL
        )
        #expect(handled.get() == 1, "the refusal did not reach the session exactly once")
        #expect(ended.lastError != nil, "an ended session said nothing")
        #expect(!ended.isLoading, "the spinner was stranded")

        // A refusal of a credential already replaced ends nothing and earns no sentence.
        let superseded = LibraryBucketStore(
            timeZoneIdentifier: Self.zone,
            onUnauthorized: { _ in .superseded }
        )
        await superseded.load(
            size: .month,
            filter: .all,
            tag: nil,
            using: client.handle,
            baseURL: Stub.baseURL
        )
        #expect(superseded.lastError == nil, "a stale refusal wrote a sentence")
        #expect(superseded.buckets.isEmpty)
    }

    @Test("an answer the client cannot decode leaves the previous list standing")
    func aBadAnswerKeepsThePreviousList() async {
        let broken = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in
            broken.get()
                ? Stub.json(#"{"not":"a list"}"#)
                : Stub.json(
                    #"[{"key":"2026-09","count":2,"coverUid":"u","coverThumbnailUrl":"/t"}]"#
                )
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        await store.load(
            size: .month,
            filter: .all,
            tag: nil,
            using: client.handle,
            baseURL: Stub.baseURL
        )
        #expect(store.buckets.map(\.key) == ["2026-09"], "control: the first list loaded")

        broken.set(true)
        await store.load(
            size: .day,
            filter: .all,
            tag: nil,
            using: client.handle,
            baseURL: Stub.baseURL
        )
        #expect(store.buckets.map(\.key) == ["2026-09"], "a failed read emptied the list")
        #expect(store.loadedRequest?.size == .month, "a failed read claimed its request")
        #expect(store.lastError != nil, "control: the failure was said")
    }

    @Test(
        "a list answered for a request that has moved on is dropped",
        arguments: BucketRequestChange.allCases
    )
    func aStaleRequestIsDropped(movedOn: BucketRequestChange) async {
        let first = (LibraryBucketSize.month, MediaLibraryFilter.images, "travel")
        let second =
            switch movedOn {
            case .size: (LibraryBucketSize.year, MediaLibraryFilter.images, "travel")
            case .kind: (LibraryBucketSize.month, MediaLibraryFilter.videos, "travel")
            case .tag: (LibraryBucketSize.month, MediaLibraryFilter.images, "food")
            }
        let entered = BucketSignal()
        let release = BucketSignal()
        let calls = LockedValue<Int>(0)
        // Held by ORDER rather than by path, so a store that stopped sending the request's terms
        // fails here instead of leaving the test waiting for a request it will never recognise.
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
                return Stub.json(
                    #"[{"key":"stale","count":9,"coverUid":"u","coverThumbnailUrl":"/t"}]"#
                )
            }
            return Stub.json(
                #"[{"key":"fresh","count":1,"coverUid":"u","coverThumbnailUrl":"/t"}]"#
            )
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        let inFlight = Task {
            await store.load(
                size: first.0,
                filter: first.1,
                tag: first.2,
                using: client.handle,
                baseURL: Stub.baseURL
            )
        }
        await entered.wait()
        await store.load(
            size: second.0,
            filter: second.1,
            tag: second.2,
            using: client.handle,
            baseURL: Stub.baseURL
        )
        release.signal()
        await inFlight.value

        #expect(calls.get() == 2, "the superseding request was not sent")
        #expect(store.buckets.map(\.key) == ["fresh"], "the superseded request's list landed")
        #expect(store.loadedRequest?.size == second.0)
        #expect(store.loadedRequest?.filter == second.1)
        #expect(store.loadedRequest?.tag == second.2)
        #expect(!store.isLoading)
    }

    @Test("a second read of the request already in flight is not sent, and the one answer lands")
    func oneReadPerRequest() async {
        let calls = LockedValue<Int>(0)
        let entered = BucketSignal()
        let release = BucketSignal()
        // Only the first request is held: a second one, if the store sends it, answers at once,
        // so the refusal failing is a red expectation rather than a test waiting forever.
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Stub.json(
                #"[{"key":"2026-09","count":2,"coverUid":"u","coverThumbnailUrl":"/t"}]"#
            )
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        let first = Task {
            await store.load(
                size: .month,
                filter: .images,
                tag: "travel",
                using: client.handle,
                baseURL: Stub.baseURL
            )
        }
        await entered.wait()
        await store.load(
            size: .month,
            filter: .images,
            tag: "travel",
            using: client.handle,
            baseURL: Stub.baseURL
        )
        #expect(store.isLoading, "the refused caller ended the read it was refused in favour of")
        release.signal()
        await first.value

        #expect(calls.get() == 1, "two overlapping reads of one request were two requests")
        #expect(store.buckets.map(\.key) == ["2026-09"], "control: the one read landed")
        #expect(!store.isLoading)
    }

    @Test(
        "a refresh during a pending identical read lands counts read after the refresh began",
        .timeLimit(.minutes(1))
    )
    func aRefreshOutlivesAPendingRead() async {
        let calls = LockedValue<Int>(0)
        let firstAnswered = LockedValue<Bool>(false)
        let overlapped = LockedValue<Bool>(false)
        let entered = BucketSignal()
        let release = BucketSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
                firstAnswered.set(true)
                return Self.day(count: 12)
            }
            if !firstAnswered.get() { overlapped.set(true) }
            return Self.day(count: 13)
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        let initial = Task { await Self.read(store, client, refreshing: false) }
        await entered.wait()
        let refreshing = Task { await Self.read(store, client, refreshing: true) }
        await Self.settle()
        #expect(calls.get() == 1, "the refresh sent a second read beside the pending one")
        release.signal()
        await initial.value
        await refreshing.value

        #expect(calls.get() == 2, "the refresh was answered by a read asked before it began")
        #expect(!overlapped.get(), "the refresh's read went out beside the pending one")
        #expect(store.buckets.map(\.count) == [13], "the pending read's older count landed last")
        #expect(!store.isLoading)
    }

    @Test("a refresh with nothing pending is one request on the wire", .timeLimit(.minutes(1)))
    func anIdleRefreshIsOneRead() async {
        let calls = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            return Self.day(count: 13)
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        await Self.read(store, client, refreshing: true)

        #expect(calls.get() == 1, "a refresh with nothing pending sent more than one read")
        #expect(store.buckets.map(\.count) == [13], "control: the refresh's read landed")
        #expect(!store.isLoading)
    }

    @Test(
        "two refreshes during one pending read send one read of their own",
        .timeLimit(.minutes(1))
    )
    func twoRefreshesShareOneRead() async {
        let calls = LockedValue<Int>(0)
        let entered = BucketSignal()
        let release = BucketSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
                return Self.day(count: 12)
            }
            return Self.day(count: 13)
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        let initial = Task { await Self.read(store, client, refreshing: false) }
        await entered.wait()
        let one = Task { await Self.read(store, client, refreshing: true) }
        let two = Task { await Self.read(store, client, refreshing: true) }
        await Self.settle()
        release.signal()
        await initial.value
        await one.value
        await two.value

        #expect(calls.get() == 2, "two refreshes were two reads after the pending one")
        #expect(store.buckets.map(\.count) == [13], "control: the refreshes' read landed")
        #expect(!store.isLoading)
    }

    @Test("a pending read that fails still lets the refresh read", .timeLimit(.minutes(1)))
    func aFailedPendingReadStillLetsTheRefreshRead() async {
        let calls = LockedValue<Int>(0)
        let entered = BucketSignal()
        let release = BucketSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
                return Stub.json(#"{"not":"a list"}"#)
            }
            return Self.day(count: 13)
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        let initial = Task { await Self.read(store, client, refreshing: false) }
        await entered.wait()
        let refreshing = Task { await Self.read(store, client, refreshing: true) }
        await Self.settle()
        release.signal()
        await initial.value
        await refreshing.value

        #expect(calls.get() == 2, "the refresh ended with the read it waited for")
        #expect(store.buckets.map(\.count) == [13], "the refresh's own read did not land")
        #expect(store.lastError == nil, "control: the refresh's success cleared the failure")
    }

    @Test(
        "a refresh that waited sends nothing once the account has changed",
        .timeLimit(.minutes(1))
    )
    func aRefreshAfterAnIdentityChangeSendsNothing() async {
        let calls = LockedValue<Int>(0)
        let entered = BucketSignal()
        let release = BucketSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Self.day(count: 12)
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        let initial = Task { await Self.read(store, client, refreshing: false) }
        await entered.wait()
        let refreshing = Task { await Self.read(store, client, refreshing: true) }
        await Self.settle()
        store.sessionIdentityChanged()
        release.signal()
        await initial.value
        await refreshing.value

        #expect(calls.get() == 1, "a refresh asked by the outgoing account read after it left")
        #expect(store.buckets.isEmpty, "the outgoing account's buckets came back")
        #expect(!store.isLoading)
    }

    @Test(
        "a refresh that waited sends nothing once another request was read",
        .timeLimit(.minutes(1))
    )
    func aRefreshAfterTheScreenMovedOnSendsNothing() async {
        let calls = LockedValue<Int>(0)
        let entered = BucketSignal()
        let release = BucketSignal()
        let client = Stub.client { request, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            let tag = Self.items(request.path)["tag"]?.first ?? "none"
            return Stub.json(
                #"[{"key":"\#(tag)","count":1,"coverUid":"u","coverThumbnailUrl":"/t"}]"#
            )
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        let initial = Task { await Self.read(store, client, refreshing: false) }
        await entered.wait()
        let refreshing = Task { await Self.read(store, client, refreshing: true) }
        await Self.settle()
        await Self.read(store, client, refreshing: false, tag: "food")
        release.signal()
        await initial.value
        await refreshing.value

        #expect(calls.get() == 2, "the refresh read back a request the screen had left")
        #expect(store.buckets.map(\.key) == ["food"], "the left request's buckets came back")
        #expect(store.loadedRequest?.tag == "food")
    }

    /// One day bucket counting `count` pictures.
    nonisolated private static func day(count: Int) -> (HTTPResponse, HTTPBody?) {
        Stub.json(
            #"[{"key":"2026-09-28","count":\#(count),"coverUid":"u","coverThumbnailUrl":"/t"}]"#
        )
    }

    /// All's day buckets, the read a pull-to-refresh of All makes, under `tag` ("travel" unless
    /// told otherwise), through `load` or `refresh`.
    private static func read(
        _ store: LibraryBucketStore,
        _ client: any APIProtocol,
        refreshing: Bool,
        tag: String = "travel"
    ) async {
        if refreshing {
            await store.refresh(
                size: .day,
                filter: .all,
                tag: tag,
                using: client.handle,
                baseURL: Stub.baseURL
            )
        } else {
            await store.load(
                size: .day,
                filter: .all,
                tag: tag,
                using: client.handle,
                baseURL: Stub.baseURL
            )
        }
    }

    /// Lets every task already started on the main actor run to its first suspension — a started
    /// refresh has then either sent its read or begun waiting — before the test goes on.
    private static func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("signing in as somebody else empties the list and drops the read in flight")
    func identityChangeEmptiesTheList() async {
        let entered = BucketSignal()
        let release = BucketSignal()
        let calls = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 2 {
                entered.signal()
                await release.wait()
                return Stub.json(
                    #"[{"key":"theirs","count":1,"coverUid":"u","coverThumbnailUrl":"/t"}]"#
                )
            }
            return Stub.json(#"[{"key":"mine","count":1,"coverUid":"u","coverThumbnailUrl":"/t"}]"#)
        }
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        await store.load(
            size: .month,
            filter: .all,
            tag: nil,
            using: client.handle,
            baseURL: Stub.baseURL
        )
        #expect(store.buckets.map(\.key) == ["mine"], "control: the first list loaded")

        let inFlight = Task {
            await store.load(
                size: .year,
                filter: .all,
                tag: nil,
                using: client.handle,
                baseURL: Stub.baseURL
            )
        }
        await entered.wait()
        store.sessionIdentityChanged()
        #expect(store.buckets.isEmpty, "the outgoing account's list outlived the change")
        release.signal()
        await inFlight.value

        #expect(store.buckets.isEmpty, "the outgoing account's read repopulated the list")
        #expect(store.loadedRequest == nil)
        #expect(!store.isLoading)
    }

    @Test("an answer for a session that has ended is not applied")
    func anEndedSessionsAnswerIsDropped() async {
        let entered = BucketSignal()
        let release = BucketSignal()
        let client = Stub.client { _, _, _ in
            entered.signal()
            await release.wait()
            return Stub.json(#"[{"key":"old","count":1,"coverUid":"u","coverThumbnailUrl":"/t"}]"#)
        }
        let session = SwitchableSession(for: client.handle)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)
        let inFlight = Task {
            await store.load(
                size: .month,
                filter: .all,
                tag: nil,
                using: client.handle,
                baseURL: Stub.baseURL
            )
        }
        await entered.wait()
        session.activeHandle = nil
        release.signal()
        await inFlight.value

        #expect(store.buckets.isEmpty, "a signed-out session's list was applied")
        #expect(store.loadedRequest == nil)
        #expect(!store.isLoading)
    }

    // MARK: - Which session a read belongs to (MEMNG-631)

    @Test(
        "a refresh parked by a session that has since been replaced sends no read of its own",
        .timeLimit(.minutes(1))
    )
    func anObsoleteRefreshSendsNoChainedRead() async {
        let held = BucketSignal()
        let release = BucketSignal()
        let (h1, h2, sent) = Self.incarnations { call in
            if call == 1 {
                held.signal()
                await release.wait()
            }
            return Self.years(signedBy: "call-\(call)")
        }
        let session = SwitchableSession(for: h1)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)

        let initial = Task { await Self.years(store, h1, refreshing: false) }
        await held.wait()
        let refreshing = Task { await Self.years(store, h1, refreshing: true) }
        await Self.settle()
        session.activeHandle = h2
        release.signal()
        await initial.value
        await refreshing.value

        #expect(sent.get() == ["h1"], "the replaced session's refresh chained a read of its own")
        #expect(store.buckets.isEmpty, "control: the replaced session's held answer was dropped")
        #expect(!store.isLoading)
    }

    @Test(
        "two lapsed covers across a session change end in one read for the session now current",
        .timeLimit(.minutes(1))
    )
    func lapsedCoversAcrossASessionChangeShareOneCurrentRead() async {
        let held = BucketSignal()
        let release = BucketSignal()
        let (h1, h2, sent) = Self.incarnations { call in
            if call == 2 {
                held.signal()
                await release.wait()
            }
            return Self.years(signedBy: "call-\(call)")
        }
        let session = SwitchableSession(for: h1)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)
        await Self.years(store, h1, refreshing: false)
        guard let shown = store.loadedRequest else {
            Issue.record("control: the covers A and B were never on screen")
            return
        }

        let initial = Task { await Self.years(store, h1, refreshing: false) }
        await held.wait()
        let coverA = Task {
            await store.rereadCovers(of: shown, holding: "a", using: h1, baseURL: Stub.baseURL)
        }
        await Self.settle()
        session.activeHandle = h2
        let coverB = Task {
            await store.rereadCovers(of: shown, holding: "b", using: h2, baseURL: Stub.baseURL)
        }
        await Self.settle()
        #expect(sent.get() == ["h1", "h1"], "a parked refresh sent beside the held read")
        release.signal()
        await initial.value
        await coverA.value
        await coverB.value

        // Whichever waiter resumes first, the replaced session sends nothing and the current one
        // sends exactly one read.
        #expect(sent.get() == ["h1", "h1", "h2"], "the reads after the held one were not one H2")
        #expect(
            store.buckets.first { $0.coverUID == "b" }?.coverThumbnailURL?.query == "sig=call-3",
            "cover B was not re-signed by the current session's read"
        )
        #expect(!store.isLoading)
    }

    @Test(
        "a load behind the same request from a replaced session recovers with one read",
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    func aCurrentLoadBehindObsoleteWorkRecoversOnce(heldReadFails: Bool) async {
        let held = BucketSignal()
        let release = BucketSignal()
        let (h1, h2, sent) = Self.incarnations { call in
            if call == 1 {
                held.signal()
                await release.wait()
                if heldReadFails { return Stub.json(#"{"not":"a list"}"#) }
            }
            return Self.years(signedBy: "call-\(call)")
        }
        let session = SwitchableSession(for: h1)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)

        let initial = Task { await Self.years(store, h1, refreshing: false) }
        await held.wait()
        session.activeHandle = h2
        let current = Task { await Self.years(store, h2, refreshing: false) }
        await Self.settle()
        #expect(sent.get() == ["h1"], "the current load went out beside the held one")
        release.signal()
        await initial.value
        await current.value

        #expect(sent.get() == ["h1", "h2"], "the current load was not answered by one read")
        #expect(
            store.buckets.first?.coverThumbnailURL?.query == "sig=call-2",
            "the current session's buckets never landed"
        )
        #expect(store.lastError == nil, "the replaced session's failure was said to this one")
        #expect(!store.isLoading)
    }

    @Test(
        "a load or refresh from a replaced session, with nothing in flight, sends nothing",
        arguments: [false, true]
    )
    func anObsoleteIdleCallSendsNothing(refreshing: Bool) async {
        let (h1, h2, sent) = Self.incarnations { call in
            Self.years(signedBy: "call-\(call)")
        }
        let session = SwitchableSession(for: h2)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)

        await Self.years(store, h1, refreshing: refreshing)
        #expect(sent.get().isEmpty, "a replaced session's call went on the wire")
        #expect(!store.isLoading)

        await Self.years(store, h2, refreshing: refreshing)
        #expect(sent.get() == ["h2"], "control: the current session's call was not one read")
        #expect(store.buckets.count == 2, "control: the current session's buckets landed")
    }

    @Test(
        "a replaced session's call for another request leaves the current read standing",
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    func anObsoleteCallForAnotherRequestSupersedesNothing(refreshing: Bool) async {
        let held = BucketSignal()
        let release = BucketSignal()
        let (h1, h2, sent) = Self.incarnations { call in
            if call == 1 {
                held.signal()
                await release.wait()
            }
            return Self.years(signedBy: "call-\(call)")
        }
        let session = SwitchableSession(for: h2)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)

        let current = Task { await Self.years(store, h2, refreshing: false) }
        await held.wait()
        await Self.years(store, h1, size: .month, refreshing: refreshing)
        #expect(sent.get() == ["h2"], "a replaced session's call for another request was sent")
        release.signal()
        await current.value

        #expect(store.loadedRequest?.size == .year, "the current session's read was superseded")
        #expect(store.buckets.count == 2, "the current session's answer was dropped")
        #expect(!store.isLoading)
    }

    @Test(
        "every current waiter behind a replaced session's read shares one fast recovery read",
        .timeLimit(.minutes(1))
    )
    func manyCurrentWaitersShareOneRecoveryRead() async {
        let held = BucketSignal()
        let release = BucketSignal()
        let (h1, h2, sent) = Self.incarnations { call in
            if call == 1 {
                held.signal()
                await release.wait()
            }
            return Self.years(signedBy: "call-\(call)")
        }
        let session = SwitchableSession(for: h1)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)

        let initial = Task { await Self.years(store, h1, refreshing: false) }
        await held.wait()
        session.activeHandle = h2
        let waiters = [true, false, true, false].map { refreshing in
            Task { await Self.years(store, h2, refreshing: refreshing) }
        }
        await Self.settle()
        #expect(sent.get() == ["h1"], "a current waiter went out beside the held read")
        release.signal()
        await initial.value
        for waiter in waiters { await waiter.value }

        #expect(sent.get() == ["h1", "h2"], "the current waiters were not one recovery read")
        #expect(
            store.buckets.first?.coverThumbnailURL?.query == "sig=call-2",
            "the recovery read's buckets never landed"
        )
        #expect(!store.isLoading)
    }

    @Test(
        "a waiter cancelled before it resumes leaves the recovery read to the live one",
        .timeLimit(.minutes(1)),
        arguments: [0, 1]
    )
    func aWaiterCancelledBeforeItResumesLeavesTheRecovery(cancelled: Int) async {
        let held = BucketSignal()
        let release = BucketSignal()
        let (h1, h2, sent) = Self.incarnations { call in
            if call == 1 {
                held.signal()
                await release.wait()
            }
            return Self.years(signedBy: "call-\(call)")
        }
        let session = SwitchableSession(for: h1)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)

        let initial = Task { await Self.years(store, h1, refreshing: false) }
        await held.wait()
        session.activeHandle = h2
        let waiters = [
            Task { await Self.years(store, h2, refreshing: true) },
            Task { await Self.years(store, h2, refreshing: true) },
        ]
        #expect(await Self.parked(store, 2), "control: both waiters parked behind the held read")
        waiters[cancelled].cancel()
        release.signal()
        await initial.value
        for waiter in waiters { await waiter.value }

        #expect(sent.get() == ["h1", "h2"], "the live waiter was not answered by one H2 read")
        #expect(
            store.buckets.first?.coverThumbnailURL?.query == "sig=call-2",
            "the live waiter's buckets never landed"
        )
        #expect(!store.isLoading)
    }

    @Test(
        "a recovery read whose issuer is cancelled after the claim answers nobody",
        .timeLimit(.minutes(1))
    )
    func aRecoveryCancelledAfterItsClaimIsReplacedOnce() async {
        let held = BucketSignal()
        let release = BucketSignal()
        let claimed = BucketSignal()
        let abandon = BucketSignal()
        let (h1, h2, sent) = Self.incarnations { call in
            if call == 1 {
                held.signal()
                await release.wait()
            }
            if call == 2 {
                // Whichever waiter claimed the recovery, ITS task is cancelled once the other one
                // has joined, and the transport honours that before any answer arrives.
                claimed.signal()
                await abandon.wait()
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
            return Self.years(signedBy: "call-\(call)")
        }
        let session = SwitchableSession(for: h1)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)

        let initial = Task { await Self.years(store, h1, refreshing: false) }
        await held.wait()
        session.activeHandle = h2
        let waiters = [
            Task { await Self.years(store, h2, refreshing: true) },
            Task { await Self.years(store, h2, refreshing: true) },
        ]
        #expect(await Self.parked(store, 2), "control: both waiters parked behind the held read")
        release.signal()
        await claimed.wait()
        #expect(await Self.parked(store, 1), "control: the other waiter joined the claimed read")
        abandon.signal()
        await initial.value
        for waiter in waiters { await waiter.value }

        #expect(
            sent.get() == ["h1", "h2", "h2"],
            "the abandoned recovery was not replaced by exactly one H2 read"
        )
        #expect(
            store.buckets.first?.coverThumbnailURL?.query == "sig=call-3",
            "the live waiter's buckets never landed"
        )
        #expect(store.lastError == nil, "the abandoned read's cancellation was said as a failure")
        #expect(!store.isLoading)
    }

    @Test(
        "a recovery read that fails answers every waiter on it, and nothing is sent again",
        .timeLimit(.minutes(1))
    )
    func aFailedRecoveryAnswersEveryWaiter() async {
        let held = BucketSignal()
        let release = BucketSignal()
        let (h1, h2, sent) = Self.incarnations { call in
            if call == 1 {
                held.signal()
                await release.wait()
            }
            if call == 2 { return Stub.json(#"{"not":"a list"}"#) }
            return Self.years(signedBy: "call-\(call)")
        }
        let session = SwitchableSession(for: h1)
        let store = LibraryBucketStore(timeZoneIdentifier: Self.zone)
        store.reports(to: session)

        let initial = Task { await Self.years(store, h1, refreshing: false) }
        await held.wait()
        session.activeHandle = h2
        let waiters = [
            Task { await Self.years(store, h2, refreshing: true) },
            Task { await Self.years(store, h2, refreshing: true) },
        ]
        #expect(await Self.parked(store, 2), "control: both waiters parked behind the held read")
        release.signal()
        await initial.value
        for waiter in waiters { await waiter.value }

        #expect(sent.get() == ["h1", "h2"], "a failed recovery was retried by its other waiter")
        #expect(store.lastError != nil, "control: the recovery's failure was said once")
        #expect(!store.isLoading)
    }

    /// Whether `count` callers are parked on a read's end, given a bounded number of turns to get
    /// there — the registration itself, not a guess at how many yields it takes.
    private static func parked(_ store: LibraryBucketStore, _ count: Int) async -> Bool {
        for _ in 0..<1_000 where store.parkedReaders != count { await Task.yield() }
        return store.parkedReaders == count
    }

    /// What the scripted server answers to its `call`-th request, counted from one.
    private typealias BucketAnswer =
        @Sendable (_ call: Int) async throws -> (HTTPResponse, HTTPBody?)

    /// Two incarnations of one session, H1 then H2, with DISTINCT session generations — two
    /// clients alone would both be generation zero — over one scripted server that logs which
    /// incarnation sent each request and numbers the calls from one. Like a real transport it
    /// honours cancellation: a request from a cancelled task throws before anything is sent.
    private static func incarnations(
        _ answer: @escaping BucketAnswer
    ) -> (h1: SessionHandle, h2: SessionHandle, sent: LockedValue<[String]>) {
        let sent = LockedValue<[String]>([])
        let client = { (sender: String) in
            Stub.client { _, _, _ in
                try Task.checkCancellation()
                sent.set(sent.get() + [sender])
                let call = sent.get().count
                return try await answer(call)
            }
        }
        return (
            SessionHandle(client: client("h1"), generation: 1),
            SessionHandle(client: client("h2"), generation: 2),
            sent
        )
    }

    /// Two year buckets whose covers are A and B, each signed with `signature`.
    nonisolated private static func years(
        signedBy signature: String
    ) -> (HTTPResponse, HTTPBody?) {
        Stub.json(
            #"[{"key":"2026","count":2,"coverUid":"b","#
                + #""coverThumbnailUrl":"/api/attachments/b/thumbnail?sig=\#(signature)"},"#
                + #"{"key":"2025","count":1,"coverUid":"a","#
                + #""coverThumbnailUrl":"/api/attachments/a/thumbnail?sig=\#(signature)"}]"#
        )
    }

    /// All's year buckets (or `size`'s), through `load` or `refresh`, under `handle` itself rather
    /// than a generation-zero one.
    private static func years(
        _ store: LibraryBucketStore,
        _ handle: SessionHandle,
        size: LibraryBucketSize = .year,
        refreshing: Bool
    ) async {
        if refreshing {
            await store.refresh(
                size: size,
                filter: .all,
                tag: nil,
                using: handle,
                baseURL: Stub.baseURL
            )
        } else {
            await store.load(
                size: size,
                filter: .all,
                tag: nil,
                using: handle,
                baseURL: Stub.baseURL
            )
        }
    }

    /// The query as the server would read it: decoded name/value pairs, never a substring of the
    /// path, so a value that happens to spell another parameter cannot answer for it.
    nonisolated private static func items(_ path: String?) -> [String: [String]] {
        guard let path, let parts = URLComponents(string: path) else { return [:] }
        var out: [String: [String]] = [:]
        for item in parts.queryItems ?? [] {
            out[item.name, default: []].append(item.value ?? "")
        }
        return out
    }
}

/// What a superseding request differs in: the size asked for, the kind shown, or the tag it
/// narrows to.
enum BucketRequestChange: CaseIterable, Sendable {
    case size
    case kind
    case tag
}

/// A session whose active handle the test can withdraw, which is what a sign-out does to it.
private final class SwitchableSession: SessionReporting {
    var activeHandle: SessionHandle?
    nonisolated let sessionIncarnation = SessionEpoch()

    init(for handle: SessionHandle) { activeHandle = handle }

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }

    func nothingEstablishedSince(_ handle: SessionHandle) -> Bool { true }

    func noteTransportFailure(
        _ failure: ServerReachability.Reason,
        issuedUnder generation: Int
    ) {}

    func noteTransportSuccess(issuedUnder generation: Int) {}
}

/// A one-shot hand-off between the test and its scripted transport — a signal, not a clock.
private final class BucketSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    func signal() { continuation.yield() }

    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}
