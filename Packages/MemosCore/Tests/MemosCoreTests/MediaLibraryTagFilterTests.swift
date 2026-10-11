import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

/// The library narrowed to one tag (MEMNG-513): pictures are found by tag rather than by text, and
/// the tag rides on the same `GET /api/attachments` the grid already pages through.
///
/// The server is a script under the REAL generated client, as everywhere in this bundle, so what
/// is asserted is the query the store actually built — `?tag=` included or absent — and not a
/// value the test handed itself.
@MainActor
@Suite("Media library tag filter")
struct MediaLibraryTagFilterTests {
    private nonisolated static func item(_ uid: String) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "webReady":true,\
        "renditions":[],"tags":[],"orphan":true,"memoUid":null,\
        "takenAt":"2026-09-26T10:00:00Z","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    private nonisolated static func page(
        _ uids: [String],
        nextCursor: String? = nil
    ) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if let nextCursor, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = nextCursor
        }
        return (response, HTTPBody("[\(uids.map(item).joined(separator: ","))]"))
    }

    @Test("a page under a tag asks for that tag, and a page under All tags asks for none")
    func theTagRidesOnTheRequest() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(["a"])
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        store.setTag("travel")
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.tag == "travel")
        #expect(paths.get().count == 2)
        let untagged = paths.get().first ?? ""
        let tagged = paths.get().last ?? ""
        #expect(!untagged.contains("tag="), "All tags sent a tag filter: \(untagged)")
        #expect(tagged.contains("tag=travel"), "the chosen tag was not asked for: \(tagged)")
        // A 0-hit assertion proves nothing unless the query it looked in was really there.
        #expect(untagged.contains("limit=2"), "control: the untagged read sent a query")
    }

    @Test("choosing a tag empties the grid and forgets the cursor; choosing it again does not")
    func choosingATagResetsThePaging() async {
        let client = Stub.client { _, _, _ in Self.page(["a", "b"], nextCursor: "page-2") }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.count == 2, "control: the grid loaded")

        store.setTag("travel")
        #expect(store.items.isEmpty, "the untagged rows survived a tag being chosen")
        #expect(!store.shouldLoadMore(after: 0), "the untagged cursor survived")

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        store.setTag("travel")
        #expect(store.items.count == 2, "choosing the tag already chosen emptied the grid")

        store.setTag(nil)
        #expect(store.tag == nil)
        #expect(store.items.isEmpty, "back to All tags kept the tagged rows")
    }

    @Test("a tag with no pictures is an empty grid, not an error")
    func anEmptyTagIsNotAnError() async {
        let client = Stub.client { _, _, _ in Self.page([]) }
        let store = MediaLibraryStore(pageSize: 2)
        store.setTag("nothing-here")
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.items.isEmpty)
        #expect(store.lastError == nil, "an empty tag read as a failure")
        #expect(!store.hasMore, "control: the empty page was applied as the end of the list")
    }

    /// Two quick taps in the Tags section: the first tag's page is still in flight when the second
    /// is chosen, and the first answer must not land on the second tag's grid.
    @Test("a page that answers a tag nobody has chosen any more is dropped")
    func aSupersededTagPageIsDropped() async {
        let entered = TagSignal()
        let release = TagSignal()
        let calls = LockedValue<Int>(0)
        // Held by ORDER rather than by path, so a store that stopped sending the tag fails here
        // instead of leaving the test waiting for a request it will never recognise.
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
                return Self.page(["stale"], nextCursor: "stale-2")
            }
            return Self.page(["fresh"])
        }
        let store = MediaLibraryStore(pageSize: 1)
        store.setTag("first")
        let inFlight = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        store.setTag("second")
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        release.signal()
        await inFlight.value

        #expect(
            store.items.map(\.attachment.uid) == ["fresh"],
            "the first tag's page landed on the second's"
        )
        #expect(!store.hasMore, "the dropped page's cursor was adopted")
    }
}

/// A one-shot hand-off between the test and its scripted transport — a signal, not a clock, for
/// the reason `MediaLibraryStoreTests` gives for its own.
private final class TagSignal: Sendable {
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
