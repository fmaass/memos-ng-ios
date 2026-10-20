import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The favorite write (MEMNG-867): `PUT`/`DELETE /api/attachments/{uid}/tags/favorites` through the
/// REAL generated client over a scripted transport, so the path the store builds, the 204 it is
/// answered with and the statuses it classifies are the client's own.
@MainActor
@Suite("Favorite store — the write")
struct FavoriteStoreTests {
    nonisolated static let put = "add_picture_tag_api_attachments__uid__tags__name__put"
    nonisolated static let delete = "remove_picture_tag_api_attachments__uid__tags__name__delete"
    nonisolated static let meta = "attachment_meta_api_attachments__uid__get"

    /// One picture's own record (`AttachmentMeta`) with its own tags, signed `sig`.
    nonisolated static func record(_ uid: String, tags: [String], sig: String = "new") -> String {
        let query = "?exp=4000000000&scope=1&sig=\(sig)"
        let names = tags.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            {"uid":"\(uid)","mime":"image/jpeg","size":1024,"sha256":null,"status":"ready",\
            "width":1000,"height":800,"duration":null,"blurhash":null,"captured_at":null,\
            "capture_instant":null,"capture_civil":null,"capture_source":null,"mine":true,\
            "hasPrint":false,"hasLegacyPrint":false,"hasPoster":false,"renditions":[],\
            "filename":null,"latitude":null,"longitude":null,"locationSource":null,\
            "addedBy":null,"camera":null,"tags":[\(names)],\
            "webReady":true,"downloadUrl":"/api/attachments/\(uid)/original",\
            "printUrl":"/api/attachments/\(uid)/print",\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb\(query)",\
            "previewUrl":"/api/attachments/\(uid)/mobile\(query)",\
            "webUrl":"/api/attachments/\(uid)/web\(query)",\
            "posterUrl":"/api/attachments/\(uid)/poster\(query)"}
            """
    }

    /// What the scripted server was asked, in order: `operation path`.
    private nonisolated static func recording(
        _ log: LockedValue<[String]>,
        _ answer: @escaping @Sendable (String, Int) async throws -> (HTTPResponse, HTTPBody?)
    ) -> any APIProtocol {
        Stub.client { request, _, operation in
            log.set(log.get() + ["\(operation) \(request.path ?? "")"])
            return try await answer(operation, log.get().count)
        }
    }

    private static func operations(_ log: LockedValue<[String]>) -> [String] {
        log.get().map { String($0.split(separator: " ").first ?? "") }
    }

    private func set(
        _ store: FavoriteStore, _ target: Bool, shown: [String] = [], _ client: any APIProtocol
    ) -> Task<Void, Never> {
        store.setFavorite(
            uid: "p1", to: target, shownTags: shown, using: client.handle, baseURL: Stub.baseURL)
    }

    @Test("two overlapping marks of one picture are ONE request on the wire")
    func overlappingMarksJoin() async {
        let log = LockedValue<[String]>([])
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.recording(log) { operation, _ in
            if operation == Self.put {
                entered.open()
                _ = await release.wait()
            }
            return Stub.empty(.noContent)
        }
        let store = FavoriteStore()
        let first = set(store, true, client)
        #expect(await entered.wait(), "no request was sent")
        let second = set(store, true, client)
        release.open()
        await first.value
        await second.value

        #expect(Self.operations(log) == [Self.put], "\(log.get())")
        #expect(log.get().first?.contains("/api/attachments/p1/tags/favorites") == true)
        #expect(store.tags(for: "p1", shown: []) == ["favorites"])
        #expect(store.revision == 1)
    }

    @Test("true then false while the PUT is out: exactly one DELETE follows, and false stands")
    func anOppositeWishIsOneFollowUp() async {
        let log = LockedValue<[String]>([])
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.recording(log) { operation, _ in
            if operation == Self.put {
                entered.open()
                _ = await release.wait()
            }
            return Stub.empty(.noContent)
        }
        let store = FavoriteStore()
        let first = set(store, true, client)
        #expect(await entered.wait(), "no request was sent")
        let second = set(store, false, client)
        // The heart follows the newest wish while the request is out.
        #expect(store.tags(for: "p1", shown: []) == [])
        release.open()
        await first.value
        await second.value

        #expect(Self.operations(log) == [Self.put, Self.delete], "\(log.get())")
        #expect(store.tags(for: "p1", shown: ["favorites"]) == [], "the ledger did not end false")
        #expect(store.revision == 2)
    }

    @Test("marking a picture that already is a favorite, with nothing out, sends nothing")
    func anEqualStateIsANoOp() async {
        let log = LockedValue<[String]>([])
        let client = Self.recording(log) { _, _ in Stub.empty(.noContent) }
        let store = FavoriteStore()
        await set(store, true, shown: ["favorites", "trip"], client).value

        #expect(log.get().isEmpty, "\(log.get())")
        #expect(store.revision == 0)
        // Control: the opposite wish on the same picture is sent.
        await set(store, false, shown: ["favorites", "trip"], client).value
        #expect(Self.operations(log) == [Self.delete])
        #expect(store.tags(for: "p1", shown: ["favorites", "trip"]) == ["trip"])
    }

    @Test("an empty 204 commits the target, and every follower is told once")
    func aNoContentAnswerCommits() async {
        let client = Stub.client { _, body, operation in
            #expect(operation == Self.put)
            #expect(body == nil, "the SET sent a body")
            return Stub.empty(.noContent)
        }
        let store = FavoriteStore()
        let told = LockedValue<[FavoriteCommit]>([])
        store.observe { told.set(told.get() + [$0]) }
        await set(store, true, shown: ["trip"], client).value

        #expect(store.tags(for: "p1", shown: ["trip"]) == ["favorites", "trip"])
        #expect(
            told.get() == [FavoriteCommit(uid: "p1", tags: ["favorites", "trip"], revision: 1)])
        #expect(store.notice == nil)
    }

    @Test("a 404 is a confirmed rejection: the heart goes back and says nothing changed")
    func aRejectionReverts() async {
        let log = LockedValue<[String]>([])
        let client = Self.recording(log) { _, _ in Stub.empty(.notFound) }
        let store = FavoriteStore()
        await set(store, true, client).value

        #expect(store.tags(for: "p1", shown: []) == [])
        #expect(store.notice == FavoriteStore.nothingChangedNotice)
        #expect(store.revision == 0)
        #expect(Self.operations(log) == [Self.put], "a rejection was reconciled: \(log.get())")
    }

    @Test("a lost answer the server committed: pending, one read, heart filled, detail replaced")
    func aLostAnswerIsReconciled() async throws {
        let log = LockedValue<[String]>([])
        let entered = TripLatch()
        let release = TripLatch()
        let metaReads = LockedValue(0)
        let client = Self.recording(log) { operation, _ in
            switch operation {
            case Self.put: throw URLError(.networkConnectionLost)
            default:
                metaReads.set(metaReads.get() + 1)
                if metaReads.get() == 1 {
                    return Stub.json(Self.record("p1", tags: [], sig: "old"))
                }
                entered.open()
                _ = await release.wait()
                return Stub.json(Self.record("p1", tags: ["favorites"], sig: "new"))
            }
        }
        let store = FavoriteStore()
        await store.loadDetail(uid: "p1", using: client.handle, baseURL: Stub.baseURL)
        #expect(store.details["p1"]?.thumbnailURL?.query?.contains("sig=old") == true)

        let flight = set(store, true, client)
        #expect(await entered.wait(), "no reconciling read was sent")
        #expect(store.isPending("p1"), "the heart claimed a state while the outcome was unknown")
        #expect(store.details["p1"] == nil, "the old detail outlived the unknown outcome")
        release.open()
        await flight.value

        #expect(!store.isPending("p1"))
        #expect(store.tags(for: "p1", shown: []) == ["favorites"])
        let detail = try #require(store.details["p1"])
        #expect(detail.tags == ["favorites"])
        #expect(detail.thumbnailURL?.query?.contains("sig=new") == true, "the detail was kept")
        #expect(store.notice != FavoriteStore.nothingChangedNotice)
        #expect(store.notice == nil)
        #expect(Self.operations(log) == [Self.meta, Self.put, Self.meta], "\(log.get())")
    }

    @Test("a lost answer the server did not commit: one read decides it and nothing is resent")
    func aLostAnswerThatDidNotLandIsNotResent() async {
        let log = LockedValue<[String]>([])
        // Only the first write is lost; a resent one would be answered, so a store that loops
        // ends instead of hanging, and the log shows the extra round.
        let client = Self.recording(log) { operation, count in
            switch operation {
            case Self.put where count == 1: throw URLError(.networkConnectionLost)
            case Self.put: return Stub.empty(.noContent)
            default: return Stub.json(Self.record("p1", tags: ["trip"]))
            }
        }
        let store = FavoriteStore()
        await set(store, true, client).value

        #expect(Self.operations(log) == [Self.put, Self.meta], "\(log.get())")
        #expect(store.tags(for: "p1", shown: []) == ["trip"], "the read is the outcome")
        #expect(!store.isPending("p1"))
        #expect(store.notice == nil, "an unknown outcome said nothing changed")
        #expect(store.revision == 1, "the read was not committed")
    }

    @Test("a lost answer whose reconciling read fails too reverts and says it cannot confirm")
    func anUnconfirmedOutcomeReverts() async {
        let log = LockedValue<[String]>([])
        let client = Self.recording(log) { _, _ in throw URLError(.notConnectedToInternet) }
        let store = FavoriteStore()
        await set(store, true, client).value

        #expect(store.tags(for: "p1", shown: []) == [])
        #expect(store.notice == FavoriteStore.unconfirmedNotice)
        #expect(!store.isPending("p1"))
        #expect(Self.operations(log) == [Self.put, Self.meta], "\(log.get())")
        // The server's state is unknown, so the same tap is sent rather than taken for a no-op.
        await set(store, false, client).value
        #expect(Array(Self.operations(log).dropFirst(2).prefix(1)) == [Self.delete], "\(log.get())")
    }

    @Test(
        "an answer from a previous session neither commits nor reverts",
        arguments: [
            HTTPResponse.Status.noContent, .notFound,
        ])
    func aStaleAnswerChangesNothing(_ status: HTTPResponse.Status) async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in
            entered.open()
            _ = await release.wait()
            return Stub.empty(status)
        }
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: issued)
        let store = FavoriteStore()
        store.reports(to: session)
        let told = LockedValue(0)
        store.observe { _ in told.set(told.get() + 1) }
        let flight = store.setFavorite(
            uid: "p1", to: true, shownTags: [], using: issued, baseURL: Stub.baseURL)
        #expect(await entered.wait(), "no request was sent")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.open()
        await flight.value

        #expect(store.revision == 0, "a stale answer committed")
        #expect(told.get() == 0)
        #expect(store.notice == nil, "a stale answer reverted with a notice")
        #expect(store.tags(for: "p1", shown: []) == [])
    }

    @Test("a refused credential reaches the session once, as one typed refusal, with no notice")
    func aRefusalGoesToTheSession() async {
        let log = LockedValue<[String]>([])
        let client = Self.recording(log) { _, _ in Stub.empty(.unauthorized) }
        let handled = LockedValue<[CredentialRefusal]>([])
        let store = FavoriteStore(onUnauthorized: { refusal in
            handled.set(handled.get() + [refusal])
            return .endedSession
        })
        await set(store, true, client).value

        #expect(handled.get().count == 1, "the refusal did not reach the session once")
        #expect(store.notice == nil)
        #expect(store.tags(for: "p1", shown: []) == [])
        #expect(Self.operations(log) == [Self.put], "a refusal was reconciled: \(log.get())")
    }

    // MARK: - round 1: what an identity change and a detail read leave behind

    @Test("a commit's delivery stops at an identity change; the next account's commit stays last")
    func aCommitDeliveryEndsAtAnIdentityChange() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in Stub.empty(.noContent) }
        let store = FavoriteStore()
        let last = LockedValue<FavoriteCommit?>(nil)
        store.observe { entry in
            guard entry.revision == 1 else { return }
            entered.open()
            _ = await release.wait()
        }
        store.observe { entry in last.set(entry) }
        let first = set(store, true, client)
        #expect(await entered.wait(), "the first commit was not delivered")
        store.sessionIdentityChanged()
        await set(store, false, shown: ["favorites"], client).value
        #expect(last.get()?.revision == 2, "control: the next account's commit was delivered")
        release.open()
        await first.value

        #expect(last.get()?.revision == 2, "the ended account's commit was delivered after it")
        #expect(last.get()?.tags == [])
    }

    @Test("the read of a flight an identity change let go leaves the next flight pending")
    func anObsoleteReadLeavesTheNewFlightPending() async {
        let reads = LockedValue(0)
        let enteredFirst = TripLatch()
        let releaseFirst = TripLatch()
        let enteredSecond = TripLatch()
        let releaseSecond = TripLatch()
        let client = Stub.client { _, _, operation in
            if operation == Self.put { throw URLError(.networkConnectionLost) }
            reads.set(reads.get() + 1)
            if reads.get() == 1 {
                enteredFirst.open()
                _ = await releaseFirst.wait()
            } else {
                enteredSecond.open()
                _ = await releaseSecond.wait()
            }
            return Stub.json(Self.record("p1", tags: ["favorites"]))
        }
        let store = FavoriteStore()
        let first = set(store, true, client)
        #expect(await enteredFirst.wait(), "the first flight did not reconcile")
        store.sessionIdentityChanged()
        let second = set(store, true, client)
        #expect(await enteredSecond.wait(), "the second flight did not reconcile")
        #expect(store.isPending("p1"), "control: the second flight is reading")
        releaseFirst.open()
        await first.value

        #expect(store.isPending("p1"), "the let-go read cleared the live flight's pending")
        releaseSecond.open()
        await second.value
        #expect(!store.isPending("p1"))
        #expect(store.tags(for: "p1", shown: []) == ["favorites"])
    }

    @Test("a detail read settles an unconfirmed favorite the ledger holds, through the ledger")
    func aDetailReadResolvesAnUnconfirmedFavorite() async {
        let reads = LockedValue(0)
        let client = Stub.client { _, _, operation in
            switch operation {
            case Self.delete: return Stub.empty(.noContent)
            case Self.put: throw URLError(.networkConnectionLost)
            default:
                reads.set(reads.get() + 1)
                if reads.get() == 1 { throw URLError(.notConnectedToInternet) }
                return Stub.json(Self.record("p1", tags: ["favorites"]))
            }
        }
        let store = FavoriteStore()
        await set(store, false, shown: ["favorites"], client).value
        #expect(store.revision == 1, "control: the unmark committed")
        await set(store, true, client).value
        #expect(store.notice == FavoriteStore.unconfirmedNotice, "control: the outcome is unknown")
        await store.loadDetail(uid: "p1", using: client.handle, baseURL: Stub.baseURL)

        #expect(store.details["p1"]?.tags == ["favorites"], "control: the detail landed")
        #expect(store.tags(for: "p1", shown: []) == ["favorites"], "the ledger's stale word won")
        #expect(store.revision == 2, "the answer was not published to the copies")
    }
}
