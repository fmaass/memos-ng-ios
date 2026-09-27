import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

/// The Library's tag menu (MEMNG-513): picture counts from `GET /api/attachments/tags`, following
/// the kind on screen, fenced like the grid it narrows.
///
/// The server is a script under the REAL generated client, so the request path, the `?type=` the
/// store derives from the kind and the decoding of `AttachmentTagCount` are all exercised.
@MainActor
@Suite("Library tag menu")
struct LibraryTagStoreTests {
    private static let operation = "attachment_tags_api_attachments_tags_get"

    @Test("the tags decode in the server's order, and All asks with no type")
    func decodesInServerOrder() async {
        let seen = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            seen.set(seen.get() + ["\(operation) \(request.path ?? "")"])
            return Stub.json(#"[{"name":"travel","count":3},{"name":"food","count":0}]"#)
        }
        let store = LibraryTagStore()
        await store.load(for: .all, using: client.handle)

        #expect(
            store.tags == [
                LibraryTag(name: "travel", count: 3), LibraryTag(name: "food", count: 0),
            ]
        )
        #expect(store.loadedFilter == .all)
        #expect(store.lastError == nil)
        let request = seen.get().first ?? ""
        #expect(request.hasPrefix(Self.operation), "not the attachments tags operation: \(request)")
        #expect(request.contains("/api/attachments/tags"), "control: the path was read")
        #expect(!request.contains("type="), "All sent a type: \(request)")
    }

    @Test("the counts follow the kind: Videos asks for the video tags")
    func countsFollowTheKind() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(#"[{"name":"travel","count":1}]"#)
        }
        let store = LibraryTagStore()
        await store.load(for: .videos, using: client.handle)
        await store.load(for: .images, using: client.handle)

        #expect(paths.get().count == 2)
        #expect(paths.get().first?.contains("type=video") == true, "\(paths.get())")
        #expect(paths.get().last?.contains("type=image") == true, "\(paths.get())")
        #expect(store.loadedFilter == .images)
    }

    @Test("no tags at all is an empty menu, not an error")
    func zeroTags() async {
        let client = Stub.client { _, _, _ in Stub.json("[]") }
        let store = LibraryTagStore()
        await store.load(for: .all, using: client.handle)

        #expect(store.tags.isEmpty)
        #expect(store.lastError == nil)
        #expect(store.loadedFilter == .all, "control: the empty answer was applied")
    }

    @Test("a refused credential goes to the session as one typed refusal")
    func aRefusalReachesTheSession() async {
        let handled = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let ended = LibraryTagStore(onUnauthorized: { _ in
            handled.set(handled.get() + 1)
            return .endedSession
        })
        await ended.load(for: .all, using: client.handle)
        #expect(handled.get() == 1, "the refusal did not reach the session")
        #expect(ended.lastError != nil, "an ended session said nothing")
        #expect(!ended.isLoading, "the spinner was stranded")

        // A refusal of a credential already replaced ends nothing and earns no sentence.
        let superseded = LibraryTagStore(onUnauthorized: { _ in .superseded })
        await superseded.load(for: .all, using: client.handle)
        #expect(superseded.lastError == nil, "a stale refusal wrote a sentence")
        #expect(superseded.tags.isEmpty)
    }

    @Test("an answer the client cannot decode leaves the previous list standing")
    func aBadAnswerKeepsThePreviousList() async {
        let broken = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in
            broken.get()
                ? Stub.json(#"{"not":"a list"}"#)
                : Stub.json(#"[{"name":"travel","count":3}]"#)
        }
        let store = LibraryTagStore()
        await store.load(for: .all, using: client.handle)
        #expect(store.tags.map(\.name) == ["travel"], "control: the first list loaded")

        broken.set(true)
        await store.load(for: .videos, using: client.handle)
        #expect(store.tags.map(\.name) == ["travel"], "a failed read emptied the menu")
        #expect(store.loadedFilter == .all, "a failed read claimed the kind it never read")
    }

    @Test("a list answered for a kind nobody is showing any more is dropped")
    func aStaleKindIsDropped() async {
        let entered = TagListSignal()
        let release = TagListSignal()
        let calls = LockedValue<Int>(0)
        // Held by ORDER rather than by path, so a store that stopped sending the kind fails here
        // instead of leaving the test waiting for a request it will never recognise.
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
                return Stub.json(#"[{"name":"stale","count":9}]"#)
            }
            return Stub.json(#"[{"name":"fresh","count":1}]"#)
        }
        let store = LibraryTagStore()
        let inFlight = Task { await store.load(for: .videos, using: client.handle) }
        await entered.wait()
        await store.load(for: .images, using: client.handle)
        release.signal()
        await inFlight.value

        #expect(store.tags.map(\.name) == ["fresh"], "the superseded kind's list landed")
        #expect(store.loadedFilter == .images)
        #expect(!store.isLoading)
    }

    @Test("a second read of the kind already being read is not sent")
    func oneReadPerKind() async {
        let calls = LockedValue<Int>(0)
        let entered = TagListSignal()
        let release = TagListSignal()
        // Only the first request is held: a second one, if the store sends it, answers at once,
        // so the refusal failing is a red expectation rather than a test waiting forever.
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Stub.json(#"[{"name":"travel","count":3}]"#)
        }
        let store = LibraryTagStore()
        let first = Task { await store.load(for: .all, using: client.handle) }
        await entered.wait()
        await store.load(for: .all, using: client.handle)
        release.signal()
        await first.value

        #expect(calls.get() == 1, "two overlapping reads of one kind were two requests")
        #expect(store.tags.map(\.name) == ["travel"], "control: the one read landed")
    }

    // MARK: - the chosen tag, when the kind changes under it

    @Test("the chosen tag goes back to All tags when the kind on screen does not carry it")
    func theChosenTagVanishesWithTheKind() async {
        let client = Stub.client { request, _, _ in
            request.path?.contains("type=video") == true
                ? Stub.json(#"[{"name":"food","count":2}]"#)
                : Stub.json(#"[{"name":"travel","count":3},{"name":"food","count":5}]"#)
        }
        let tags = LibraryTagStore()
        let library = MediaLibraryStore()
        library.setTag("travel")

        // Nothing read yet: silence is not absence.
        #expect(!library.dropTagIfAbsent(from: tags))
        #expect(library.tag == "travel")

        await tags.load(for: .all, using: client.handle)
        #expect(!library.dropTagIfAbsent(from: tags), "a tag the list names was dropped")
        #expect(library.tag == "travel")

        // The kind moves; the list still answers for All, which says nothing about Videos.
        library.setFilter(.videos)
        #expect(!library.dropTagIfAbsent(from: tags), "a list for another kind decided")

        await tags.load(for: .videos, using: client.handle)
        #expect(library.dropTagIfAbsent(from: tags), "a tag the kind lacks was kept")
        #expect(library.tag == nil)
        #expect(!library.dropTagIfAbsent(from: tags), "All tags has nothing to drop")
    }

    @Test("signing in as somebody else empties the menu and drops the read in flight")
    func identityChangeEmptiesTheMenu() async {
        let entered = TagListSignal()
        let release = TagListSignal()
        let client = Stub.client { _, _, _ in
            entered.signal()
            await release.wait()
            return Stub.json(#"[{"name":"theirs","count":1}]"#)
        }
        let store = LibraryTagStore()
        let inFlight = Task { await store.load(for: .all, using: client.handle) }
        await entered.wait()
        store.sessionIdentityChanged()
        release.signal()
        await inFlight.value

        #expect(store.tags.isEmpty, "the outgoing account's tags repopulated the menu")
        #expect(store.loadedFilter == nil)
    }
}

/// A one-shot hand-off between the test and its scripted transport — a signal, not a clock.
private final class TagListSignal: Sendable {
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
