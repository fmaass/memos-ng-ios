import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The Collections root's tag covers (MEMNG-783): one newest picture per tag, looked up once,
/// joined while on the wire, fenced against the account that asked.
///
/// The server is a script under the REAL generated client, so the query the store builds and the
/// decoding of the one row are both exercised.
@MainActor
@Suite("Tag covers", .timeLimit(.minutes(1)))
struct TagCoverStoreTests {
    private static let operation = "list_attachments_api_attachments_get"

    private nonisolated static func one(_ uid: String) -> (HTTPResponse, HTTPBody?) {
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
        // The release waits until the second caller is IN the lookup, so a store that refused
        // the overlap — or sent it — rather than joining cannot pass.
        #expect(await Self.joined(store, "garden"), "the second load never joined the lookup")
        release.signal()
        await first.value
        let joined = await second.value
        #expect(calls.get() == 1, "two overlapping lookups were two requests")
        #expect(joined == "p1", "the joining caller returned before the answer")
        #expect(!store.isLoading("garden"))
    }

    @Test("a renewal while a lookup is out: a second appearance joins it, one request on the wire")
    func aRenewalJoinsTheLookupInFlight() async {
        let calls = LockedValue<Int>(0)
        let entered = CoverSignal()
        let release = CoverSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Self.one("p1")
        }
        let issued = SessionHandle(client: client, generation: 1)
        let renewed = SessionHandle(client: client, generation: 2)
        let session = TripTestSession(for: issued)
        let store = TagCoverStore()
        store.reports(to: session)
        let first = Task { await store.load(tag: "garden", using: issued, baseURL: Stub.baseURL) }
        await entered.wait()
        session.activeHandle = renewed
        let second = Task {
            await store.load(tag: "garden", using: renewed, baseURL: Stub.baseURL)
            return store.cover(for: "garden")?.uid
        }
        #expect(await Self.joined(store, "garden"), "the renewed appearance did not join")
        release.signal()
        await first.value
        let joined = await second.value
        #expect(calls.get() == 1, "the renewed appearance sent a second lookup of the tag")
        #expect(session.successes.isEmpty, "a success under the replaced credential was said")
        // The one answer was issued under the credential the renewal replaced: it is not kept.
        #expect(joined == nil, "an answer issued under the replaced credential was kept")
        #expect(store.covers["garden"] == nil)
    }

    @Test("a lookup in flight when the account changes lands nowhere, and the tag is asked again")
    func anIdentityChangeDropsTheLookup() async {
        let calls = LockedValue<Int>(0)
        let holding = LockedValue<Bool>(false)
        let entered = CoverSignal()
        let release = CoverSignal()
        // Only the lookup asked for while `holding` is set is held; every other answers at once.
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if holding.get() {
                holding.set(false)
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
        holding.set(true)
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

    /// Whether a load other than the issuer's is waiting on `tag`'s lookup, within a bound.
    private static func joined(_ store: TagCoverStore, _ tag: String) async -> Bool {
        for _ in 0..<2000 where store.joiners(of: tag) == 0 { await Task.yield() }
        return store.joiners(of: tag) > 0
    }

    /// A lookup the test holds on the wire, answered with `answer` once released.
    private static func held(
        _ answer: @escaping @Sendable () -> (HTTPResponse, HTTPBody?)
    ) -> (client: any APIProtocol, entered: CoverSignal, release: CoverSignal) {
        let entered = CoverSignal()
        let release = CoverSignal()
        let client = Stub.client { _, _, _ in
            entered.signal()
            await release.wait()
            return answer()
        }
        return (client, entered, release)
    }

    @Test("a lookup answered after a sign-out keeps nothing and says nothing to the session")
    func aSignOutDropsTheSuccess() async {
        let wire = Self.held { Self.one("p1") }
        let handle = SessionHandle(client: wire.client, generation: 1)
        let session = TripTestSession(for: handle)
        let store = TagCoverStore()
        store.reports(to: session)
        let inFlight = Task {
            await store.load(tag: "garden", using: handle, baseURL: Stub.baseURL)
        }
        await wire.entered.wait()
        session.activeHandle = nil
        wire.release.signal()
        await inFlight.value
        #expect(store.covers["garden"] == nil, "an answer after the sign-out was kept")
        #expect(session.successes.isEmpty, "a success after the sign-out was said")
    }

    @Test("a lookup failing after a sign-out is not remembered and not said")
    func aSignOutDropsTheFailure() async {
        let wire = Self.held { (HTTPResponse(status: .internalServerError), nil) }
        let handle = SessionHandle(client: wire.client, generation: 1)
        let session = TripTestSession(for: handle)
        let store = TagCoverStore()
        store.reports(to: session)
        let inFlight = Task {
            await store.load(tag: "garden", using: handle, baseURL: Stub.baseURL)
        }
        await wire.entered.wait()
        session.activeHandle = nil
        wire.release.signal()
        await inFlight.value
        #expect(store.covers["garden"] == nil, "a failure after the sign-out was remembered")
        #expect(session.failures == 0, "a failure after the sign-out was said")
    }

    @Test("a lookup refused after a renewal still goes to the session's rule, and is not kept")
    func aRefusalAfterARenewalReachesTheRule() async {
        let wire = Self.held { Stub.empty(.unauthorized) }
        let issued = SessionHandle(client: wire.client, generation: 1)
        let session = TripTestSession(for: issued)
        let handled = LockedValue<Int>(0)
        let store = TagCoverStore(onUnauthorized: { _ in
            handled.set(handled.get() + 1)
            return .superseded
        })
        store.reports(to: session)
        let inFlight = Task {
            await store.load(tag: "garden", using: issued, baseURL: Stub.baseURL)
        }
        await wire.entered.wait()
        session.activeHandle = SessionHandle(client: wire.client, generation: 2)
        wire.release.signal()
        await inFlight.value
        #expect(handled.get() == 1, "a refusal earned before the renewal never reached the rule")
        #expect(store.covers["garden"] == nil, "a refusal was remembered as no cover")
    }

    @Test("a lookup of the outgoing account that ends clears only its own slot, not its successor")
    func anOldLookupLeavesTheNewSlot() async {
        let calls = LockedValue<Int>(0)
        let entered = CoverSignal()
        let releaseOld = CoverSignal()
        let releaseNew = CoverSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            let call = calls.get()
            entered.signal()
            await (call == 1 ? releaseOld : releaseNew).wait()
            return Self.one(call == 1 ? "theirs" : "ours")
        }
        let store = TagCoverStore()
        let old = Task {
            await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        }
        await entered.wait()
        store.sessionIdentityChanged()
        let new = Task {
            await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        }
        await entered.wait()
        releaseOld.signal()
        await old.value
        #expect(store.isLoading("garden"), "the outgoing lookup cleared its successor's slot")
        let third = Task {
            await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await Self.joined(store, "garden"), "a third load did not join the new lookup")
        releaseNew.signal()
        await new.value
        await third.value
        #expect(calls.get() == 2, "the successor's slot was lost and the tag asked a third time")
        #expect(store.cover(for: "garden")?.uid == "ours")
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

    @Test("forgetting a subject asks it again and publishes the new cover")
    func forgetAsksTheSubjectAgain() async {
        let covers = LockedValue<[String]>(["p1", "p2"])
        let calls = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            let next = covers.get()
            covers.set(Array(next.dropFirst()))
            return Self.one(next.first ?? "none")
        }
        let favorites = TagCoverStore.Subject.pictureTag("favorites")
        let store = TagCoverStore()
        await store.load(favorites, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.cover(of: favorites)?.uid == "p1")
        await store.load(.tag("garden"), using: client.handle, baseURL: Stub.baseURL)
        store.forget(favorites)
        #expect(store.answer(for: favorites) == nil, "the forgotten cover is still drawn")
        #expect(store.answer(for: .tag("garden")) != nil, "control: another subject was forgotten")
        await store.load(favorites, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.cover(of: favorites)?.uid == "none")
        #expect(calls.get() == 3)
    }

    @Test("a lookup on the wire when its subject is forgotten lands nowhere and is not joined")
    func aForgottenLookupLandsNowhere() async {
        let calls = LockedValue<Int>(0)
        let holding = LockedValue<Bool>(true)
        let entered = CoverSignal()
        let release = CoverSignal()
        // The first lookup is held and answers the picture the commit took away.
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if holding.get() {
                holding.set(false)
                entered.signal()
                await release.wait()
                return Self.one("removed")
            }
            return Self.one("kept")
        }
        let favorites = TagCoverStore.Subject.pictureTag("favorites")
        let store = TagCoverStore()
        let inFlight = Task {
            await store.load(favorites, using: client.handle, baseURL: Stub.baseURL)
        }
        await entered.wait()
        store.forget(favorites)
        await store.load(favorites, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 2, "the load after the forget joined the lookup asked before it")
        #expect(store.cover(of: favorites)?.uid == "kept")
        release.signal()
        await inFlight.value
        #expect(store.cover(of: favorites)?.uid == "kept", "the lookup before the forget landed")
    }

    /// One row for the lookup, at `status`, its URLs signed to `expires` when one is given.
    private nonisolated static func row(
        _ uid: String, status: String = "ready", expires: Date? = nil
    ) -> (HTTPResponse, HTTPBody?) {
        var item = Stub.libraryItem(uid: uid).replacingOccurrences(
            of: "\"status\":\"ready\"", with: "\"status\":\"\(status)\"")
        if let expires {
            let exp = Int(expires.timeIntervalSince1970)
            for tier in ["thumb", "mobile", "web", "poster", "original", "print"] {
                item = item.replacingOccurrences(
                    of: "/\(uid)/\(tier)\"", with: "/\(uid)/\(tier)?exp=\(exp)&sig=s\"")
            }
        }
        return Stub.json("[\(item)]")
    }

    @Test(
        "an unfinished newest picture is the plain tile, asked again when the tags are read",
        arguments: ["uploading", "pending", "processing", "failed"])
    func anUnfinishedPictureIsNotSettled(status: String) async {
        let calls = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            return calls.get() == 1 ? Self.row("p1", status: status) : Self.row("p1")
        }
        let store = TagCoverStore()
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        #expect(store.cover(for: "garden") == nil, "a \(status) picture was taken as the cover")
        // Another appearance before the tags are read again asks nothing: no request per scroll.
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 1, "an appearance asked again before the tags were read again")
        store.forgetMissing()
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 2, "a \(status) newest picture was never asked again")
        #expect(store.cover(for: "garden")?.uid == "p1")
        #expect(store.cover(for: "garden")?.status == .ready)
    }

    @Test("a cover whose signature has lapsed, or is inside the fetch horizon, is asked again")
    func aLapsedSignatureIsAskedAgain() async {
        let now = Date()
        // Either side of `SignedMediaURL.horizon` (60 s) by a margin no test run can eat.
        let expiry: [String: Date] = [
            "lapsed": now.addingTimeInterval(-600),
            "closing": now.addingTimeInterval(SignedMediaURL.horizon - 30),
            "fresh": now.addingTimeInterval(7200),
        ]
        let calls = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let tag = expiry.keys.first { request.path?.contains("tag=\($0)") == true } ?? "?"
            let asked = calls.get().filter { $0 == tag }.count
            calls.set(calls.get() + [tag])
            // The second answer is freshly signed, as the server's would be.
            return Self.row(
                "p-\(tag)", expires: asked == 0 ? expiry[tag] : now.addingTimeInterval(7200))
        }
        let store = TagCoverStore()
        for tag in ["lapsed", "closing", "fresh"] {
            await store.load(tag: tag, using: client.handle, baseURL: Stub.baseURL)
            let signed = store.cover(for: tag)?.thumbnailURL?.query ?? ""
            #expect(signed.contains("exp="), "\(tag): the row carried no signature: \(signed)")
            await store.load(tag: tag, using: client.handle, baseURL: Stub.baseURL)
            await store.load(tag: tag, using: client.handle, baseURL: Stub.baseURL)
        }
        let sent = calls.get()
        #expect(sent.filter { $0 == "lapsed" }.count == 2, "\(sent)")
        #expect(sent.filter { $0 == "closing" }.count == 2, "\(sent)")
        #expect(sent.filter { $0 == "fresh" }.count == 1, "a live signature asked again: \(sent)")
        #expect(store.cover(for: "lapsed")?.uid == "p-lapsed")
    }

    @Test("a lapsed cover whose second lookup fails is the plain tile, not the spent picture")
    func aFailedReaskOfALapsedCoverIsNoCover() async {
        let calls = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            return calls.get() == 1
                ? Self.row("old", expires: Date().addingTimeInterval(-600))
                : Stub.empty(.internalServerError)
        }
        let store = TagCoverStore()
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 2, "a lapsed cover was not asked again")
        #expect(store.covers["garden"] == TagCoverStore.Cover.none)
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 2, "a failed lookup was asked again before the tags were")
    }

    @Test("two overlapping appearances of a lapsed cover are one request on the wire")
    func overlappingLapsedLookupsJoin() async {
        let calls = LockedValue<Int>(0)
        let release = CoverSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 { return Self.row("old", expires: Date().addingTimeInterval(-600)) }
            if calls.get() == 2 { await release.wait() }
            return Self.row("new", expires: Date().addingTimeInterval(7200))
        }
        let store = TagCoverStore()
        await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        let first = Task {
            await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
        }
        // Bounded, so a store that keeps the lapsed cover fails here instead of at the time limit.
        for _ in 0..<2000 where !store.isLoading("garden") { await Task.yield() }
        guard store.isLoading("garden") else {
            Issue.record("a lapsed cover was not asked again")
            release.signal()
            return
        }
        let second = Task {
            await store.load(tag: "garden", using: client.handle, baseURL: Stub.baseURL)
            return store.cover(for: "garden")?.uid
        }
        #expect(await Self.joined(store, "garden"), "the second load never joined the lookup")
        release.signal()
        await first.value
        let joined = await second.value
        #expect(calls.get() == 2, "a lapsed cover was asked twice at once")
        #expect(joined == "new")
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
