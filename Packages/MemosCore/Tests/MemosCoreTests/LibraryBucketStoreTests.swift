import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
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

    @Test("All with no tag sends neither, and the zone defaults to the device's")
    func allAndNoTagAreAbsent() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json("[]")
        }
        let store = LibraryBucketStore()
        #expect(store.timeZoneIdentifier == TimeZone.current.identifier)
        await store.load(
            size: .month,
            filter: .all,
            tag: nil,
            using: client.handle,
            baseURL: Stub.baseURL
        )

        let items = Self.items(paths.get().first)
        #expect(items["size"] == ["month"], "control: the query was read: \(paths.get())")
        #expect(items["tz"] == [TimeZone.current.identifier], "\(paths.get())")
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
