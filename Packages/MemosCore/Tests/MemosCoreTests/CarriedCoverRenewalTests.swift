import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The carried cover's renewal (MEMNG-817): the REAL `TripMemberStore` reading one picture's own
/// record over a scripted transport — what a forgotten read may still report, what a retired
/// lease may still start, and which asks share one read.
@MainActor
@Suite("Collection scope — the carried cover's renewal")
struct CarriedCoverRenewalTests {
    private let seeder = TripSeeder()

    nonisolated static let meta = "attachment_meta_api_attachments__uid__get"
    static let tag = CollectionScopeDrainTests.scope(.tag("travel"), cover: "c9")

    /// The picture's record, its URLs signed `sig`.
    nonisolated static func record(_ uid: String, sig: String) -> (HTTPResponse, HTTPBody?) {
        let query = "?exp=4000000000&scope=1&sig=\(sig)"
        return Stub.json(
            """
            {"uid":"\(uid)","mime":"image/jpeg","size":1024,"sha256":null,"status":"ready",\
            "width":1000,"height":800,"duration":null,"blurhash":null,"captured_at":null,\
            "capture_instant":null,"capture_civil":null,"capture_source":null,"mine":true,\
            "hasPrint":false,"hasLegacyPrint":false,"hasPoster":false,"renditions":[],\
            "webReady":true,"downloadUrl":"/api/attachments/\(uid)/original",\
            "printUrl":"/api/attachments/\(uid)/print",\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb\(query)",\
            "previewUrl":"/api/attachments/\(uid)/mobile\(query)",\
            "webUrl":"/api/attachments/\(uid)/web\(query)",\
            "posterUrl":"/api/attachments/\(uid)/poster\(query)"}
            """)
    }

    /// The signature the store holds for c9, or "" before any.
    static func signed(_ store: TripMemberStore) -> String {
        store.renewedCover("c9")?.thumbnailURL?.query ?? ""
    }

    /// Index `case` = (forgotten, answer): the scope forgotten while the read was on the wire or
    /// not, and the read answered with a 401 or by a dropped connection.
    @Test(
        "a failed renewal reports to the session and its health only while it holds its slot",
        arguments: 0..<4)
    func aFailureAfterForgetReachesNothing(index: Int) async {
        let forgotten = index >= 2
        let offline = index % 2 == 1
        let entered = TripLatch()
        let release = TripLatch()
        let decided = LockedValue(0)
        let client = CollectionScopeDrainTests.bounded { _, _, operation in
            #expect(operation == Self.meta, "not the picture's own route: \(operation)")
            entered.open()
            await release.wait()
            if offline { throw URLError(.notConnectedToInternet) }
            return Stub.empty(.unauthorized)
        }
        let (_, store) = await seeder.members(onUnauthorized: { (_: CredentialRefusal) in
            decided.set(decided.get() + 1)
            return .endedSession
        })
        let handle = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: handle)
        store.reports(to: session)
        let lease = store.coverLease(for: Self.tag)

        let renewal = Task {
            await store.renewCover(uid: "c9", under: lease, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "precondition: the read is on the wire")
        if forgotten { store.forget(Self.tag) }
        release.open()
        await renewal.value

        let label = "\(forgotten ? "forgotten" : "held") \(offline ? "offline" : "401")"
        let reached = offline ? session.failures : decided.get()
        #expect(reached == (forgotten ? 0 : 1), "\(label): reached \(reached)")
        #expect(offline ? decided.get() == 0 : session.failures == 0, "\(label): the other lane")
        #expect(store.renewedCover("c9") == nil, "\(label): a failure wrote a cover")
    }

    /// Index 0: the lease a forget of the scope retired; 1: the one a change of identity did.
    @Test(
        "a retired lease starts no read and writes nothing; the scope's new lease does",
        arguments: 0..<2)
    func aRetiredLeaseStartsNothing(index: Int) async {
        let reads = LockedValue(0)
        let client = CollectionScopeDrainTests.bounded { _, _, operation in
            #expect(operation == Self.meta, "not the picture's own route: \(operation)")
            reads.set(reads.get() + 1)
            return Self.record("c9", sig: "new")
        }
        let (_, store) = await seeder.members()
        let handle = SessionHandle(client: client, generation: 0)
        let stale = store.coverLease(for: Self.tag)
        #expect(store.coverLease(for: Self.tag) == stale, "precondition: one showing, one lease")
        let month = CollectionScopeDrainTests.scope(.month("2026-09"), cover: "c8")
        let other = store.coverLease(for: month)
        if index == 0 { store.forget(Self.tag) } else { store.sessionIdentityChanged() }
        let kept = store.coverLease(for: month)
        #expect((kept == other) == (index == 0), "a forget reached another scope's lease")
        let fresh = store.coverLease(for: Self.tag)
        #expect(fresh != stale, "the scope opened again was handed the retired lease")

        await store.renewCover(uid: "c9", under: stale, using: handle, baseURL: Stub.baseURL)
        #expect(reads.get() == 0, "a retired lease read: \(reads.get())")
        #expect(store.renewedCover("c9") == nil, "a retired lease wrote a cover")

        await store.renewCover(uid: "c9", under: fresh, using: handle, baseURL: Stub.baseURL)
        #expect(reads.get() == 1, "control: the new lease did not read")
        #expect(Self.signed(store).contains("sig=new"), "control: \(Self.signed(store))")
    }

    @Test("asks under one credential share one read; an ask under the next credential does not")
    func aJoinIsKeptToOneCredential() async {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = CollectionScopeDrainTests.bounded { _, _, operation in
            #expect(operation == Self.meta, "not the picture's own route: \(operation)")
            let call = calls.get() + 1
            calls.set(call)
            if call == 1 {
                entered.open()
                await release.wait()
            }
            return Self.record("c9", sig: "call\(call)")
        }
        let (_, store) = await seeder.members()
        let first = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: first)
        store.reports(to: session)
        let lease = store.coverLease(for: Self.tag)
        let base = Stub.baseURL

        let issued = Task {
            await store.renewCover(uid: "c9", under: lease, using: first, baseURL: base)
        }
        #expect(await entered.wait(), "precondition: the read is on the wire")
        let joined = Task {
            await store.renewCover(uid: "c9", under: lease, using: first, baseURL: base)
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(calls.get() == 1, "an ask under the same credential read again: \(calls.get())")

        let next = SessionHandle(client: client, generation: 2)
        session.activeHandle = next
        await store.renewCover(uid: "c9", under: lease, using: next, baseURL: base)
        #expect(calls.get() == 2, "an ask under the next credential joined the old read")
        #expect(Self.signed(store).contains("sig=call2"), "\(Self.signed(store))")

        release.open()
        await issued.value
        await joined.value
        #expect(
            Self.signed(store).contains("sig=call2"), "the old read landed: \(Self.signed(store))")
    }
}
