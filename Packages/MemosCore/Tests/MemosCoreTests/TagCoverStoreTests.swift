import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

/// The Collections root's tag covers (MEMNG-783): one newest picture per tag, looked up once,
/// joined while on the wire, fenced against the account that asked.
///
/// The server is a script under the REAL generated client, so the query the store builds and the
/// decoding of the one row are both exercised.
@MainActor
@Suite("Tag covers")
struct TagCoverStoreTests {
    private static let operation = "list_attachments_api_attachments_get"

    private static func one(_ uid: String) -> (HTTPResponse, HTTPBody?) {
        Stub.json("[\(Stub.libraryItem(uid: uid))]")
    }

    @Test("a lookup asks for one picture of the tag, newest first, and its row is the cover")
    func asksForOneNewestPicture() async {
        let seen = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            seen.set(seen.get() + ["\(operation) \(request.path ?? "")"])
            return Self.one("newest")
        }
        let store = TagCoverStore()
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        #expect(store.cover(for: "garden")?.uid == "newest")
        let sent = seen.get()
        #expect(sent.count == 1, "\(sent)")
        let path = sent.first?.split(separator: " ").last.map(String.init) ?? ""
        let query = URLComponents(string: path)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        #expect(sent.first?.hasPrefix(Self.operation) == true)
        #expect(value("type") == "image")
        #expect(value("limit") == "1")
        #expect(value("tag") == "garden")
        #expect(value("order") == "taken_desc")
    }

    @Test("a tag with no picture, or a failed lookup, is the plain tile and is not asked again")
    func noPictureIsAnsweredOnce() async {
        let calls = LockedValue<Int>(0)
        let client = Stub.client { request, _, _ in
            calls.set(calls.get() + 1)
            return request.path?.contains("tag=empty") == true
                ? Stub.json("[]") : Stub.empty(.internalServerError)
        }
        let store = TagCoverStore()
        for tag in ["empty", "broken"] {
            await store.load(tag: tag, using: client.handle, baseURL: Stub.baseURL)
            await store.load(tag: tag, using: client.handle, baseURL: Stub.baseURL)
            #expect(store.covers[tag] == TagCoverStore.Cover.none, "\(tag)")
            #expect(store.cover(for: tag) == nil)
        }
        #expect(calls.get() == 2, "an answered tag was asked again")
    }

    @Test("two overlapping lookups of one tag are one request, and both see its answer")
    func overlappingLookupsJoin() async {
        let calls = LockedValue<Int>(0)
        let entered = CoverSignal()
        let release = CoverSignal()
        // Only the first request is held: a second one, if the store sends it, answers at once.
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Self.one("p1")
        }
        let store = TagCoverStore()
        let first = Task {
            await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        }
        await entered.wait()
        #expect(store.isLoading("garden"))
        let second = Task {
            await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
            return store.cover(for: "garden")?.uid
        }
        await Task.yield()
        release.signal()
        await first.value
        let joined = await second.value
        #expect(calls.get() == 1, "two overlapping lookups were two requests")
        #expect(joined == "p1", "the joining caller returned before the answer")
        #expect(!store.isLoading("garden"))
    }

    @Test("a lookup in flight when the account changes lands nowhere, and the tag is asked again")
    func anIdentityChangeDropsTheLookup() async {
        let calls = LockedValue<Int>(0)
        let entered = CoverSignal()
        let release = CoverSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
                return Self.one("theirs")
            }
            return Self.one("ours")
        }
        let store = TagCoverStore()
        await store.load(tag: "seen", using: client.handle, baseURL: Stub.baseURL)
        #expect(store.cover(for: "seen") != nil, "precondition: a cover was held")
        calls.set(0)
        let inFlight = Task {
            await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        }
        await entered.wait()
        store.sessionIdentityChanged()
        #expect(store.covers.isEmpty, "the outgoing account's covers stayed")
        release.signal()
        await inFlight.value
        #expect(store.cover(for: "garden") == nil, "the outgoing account's lookup landed")
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        #expect(store.cover(for: "garden")?.uid == "ours")
        #expect(calls.get() == 2)
    }

    @Test("a failure in flight when the account changes is not remembered as no cover")
    func anIdentityChangeDropsTheFailure() async {
        let entered = CoverSignal()
        let release = CoverSignal()
        let client = Stub.client { _, _, _ in
            entered.signal()
            await release.wait()
            return Stub.empty(.internalServerError)
        }
        let store = TagCoverStore()
        let inFlight = Task {
            await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        }
        await entered.wait()
        store.sessionIdentityChanged()
        release.signal()
        await inFlight.value
        #expect(store.covers["garden"] == nil, "a stale failure was filed for the new account")
    }

    @Test("a refused credential goes to the session as one typed refusal and is not an answer")
    func aRefusalReachesTheSession() async {
        let handled = LockedValue<Int>(0)
        let calls = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            return Stub.empty(.unauthorized)
        }
        let store = TagCoverStore(onUnauthorized: { _ in
            handled.set(handled.get() + 1)
            return .superseded
        })
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        #expect(handled.get() == 1, "the refusal did not reach the session")
        #expect(store.covers["garden"] == nil, "a refusal was remembered as no cover")
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 2, "a refused lookup was never asked again")
    }

    @Test("forgetting the missing covers asks those tags again and keeps the pictures")
    func forgetMissingAsksAgain() async {
        let calls = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let tag = request.path?.contains("tag=garden") == true ? "garden" : "empty"
            calls.set(calls.get() + [tag])
            return tag == "garden" ? Self.one("p1") : Stub.json("[]")
        }
        let store = TagCoverStore()
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        await store.load(tag: "empty", using: client.handle, baseURL: Stub.baseURL)
        store.forgetMissing()
        #expect(store.covers["empty"] == nil)
        #expect(store.cover(for: "garden")?.uid == "p1", "a picture was forgotten")
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        await store.load(tag: "empty", using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == ["garden", "empty", "empty"])
    }
}

/// A one-shot hand-off between the test and its scripted transport — a signal, not a clock.
private final class CoverSignal: Sendable {
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
