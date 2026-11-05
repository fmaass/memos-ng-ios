import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// Trip Pass owner tools (memos-ng 2.9.0): the REAL store over the generated client and a
/// scripted transport answering `/api/collections/{uid}/passes` and `/api/passes/*` as the server
/// does.
@MainActor
@Suite("Trip guests", .timeLimit(.minutes(1)))
struct TripGuestStoreTests {
    nonisolated static let issueOp = "issue_pass_api_collections__uid__passes_post"
    nonisolated static let listOp = "list_passes_api_collections__uid__passes_get"
    nonisolated static let revokeOp = "revoke_pass_api_passes__uid__delete"
    nonisolated static let devicesOp = "list_devices_api_passes__uid__devices_get"
    nonisolated static let revokeDeviceOp =
        "revoke_device_api_passes__uid__devices__device_uid__delete"
    nonisolated static let contributionsOp = "list_contributions_api_passes__uid__contributions_get"
    nonisolated static let hideOp = "hide_contributions_api_passes__uid__contributions_hide_post"

    nonisolated static func pass(_ uid: String, state: String = "active", devices: Int = 0)
        -> String
    {
        #"{"uid":"\#(uid)","collectionUid":"t1","label":"Sardinia","scope":"contribute","#
            + #""state":"\#(state)","expiresAt":"2026-12-01T00:00:00Z","maxDevices":30,"#
            + #""notes":null,"version":1,"revokedAt":null,"revokedVersion":null,"#
            + #""deviceCount":\#(devices),"createdBy":"me","createdAt":"2026-10-01T00:00:00Z","#
            + #""updatedAt":"2026-10-01T00:00:00Z"}"#
    }

    nonisolated static func passes(_ rows: String...) -> (HTTPResponse, HTTPBody?) {
        Stub.json("[\(rows.joined(separator: ","))]")
    }

    nonisolated static func issued(_ uid: String, url: String) -> (HTTPResponse, HTTPBody?) {
        Stub.json(
            #"{"pass":\#(pass(uid)),"secret":"s3cret","url":"\#(url)","qrSvg":"<svg/>"}"#,
            status: .created)
    }

    nonisolated static func device(_ uid: String, revoked: Bool = false) -> String {
        #"{"uid":"\#(uid)","displayName":"Anna","platform":"app","#
            + #""firstSeen":"2026-10-02T00:00:00Z","lastSeen":"2026-10-03T00:00:00Z","#
            + #""uploadsCount":412,"bytesTotal":1000,"revoked":\#(revoked),"#
            + #""revokedAt":null,"revokedVersion":null}"#
    }

    nonisolated static func contribution(_ uid: String, at day: Int, hidden: Bool = false)
        -> String
    {
        #"{"attachmentUid":"\#(uid)","memoUid":"m-\#(uid)","contributorName":"Anna","#
            + #""deviceUid":"d1","caption":null,"hidden":\#(hidden),"#
            + #""createdAt":"2026-10-\#(String(format: "%02d", day))T00:00:00Z"}"#
    }

    static let draft = TripPassDraft(
        label: "  Sardinia  ", scope: .contributeAndView,
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000), maxDevices: 12)

    @Test("Invite Guests POSTs the draft, holds the guest URL in memory and reads the passes back")
    func issuingSendsTheDraftAndReadsBack() async throws {
        let sent = LockedValue<[String]>([])
        let fields = LockedValue<[String: Any]>([:])
        let client = Stub.client { request, body, operation in
            sent.set(sent.get() + ["\(request.method.rawValue) \(request.path ?? "")"])
            if operation == Self.issueOp {
                let read = try await Stub.body(body)
                fields.set(read)
                return Self.issued("p1", url: "https://door.example.invalid/p/abc")
            }
            return Self.passes(Self.pass("p1"))
        }
        let store = TripGuestStore(collectionUid: "t1")
        let made = try await store.issue(Self.draft, using: client.handle)
        #expect(made.url.absoluteString == "https://door.example.invalid/p/abc")
        #expect(store.issued?.url == made.url)
        #expect(
            sent.get() == ["POST /api/collections/t1/passes", "GET /api/collections/t1/passes"])
        let body = fields.get()
        #expect(body["label"] as? String == "Sardinia")
        #expect(body["scope"] as? String == "contribute_view")
        #expect(body["maxDevices"] as? Int == 12)
        #expect(body["expiresAt"] as? String != nil)
        #expect(store.passes?.map(\.uid) == ["p1"])
        store.dismissIssued()
        #expect(store.issued == nil)
    }

    @Test("a second identical Issue while the first is out joins it: one POST, one pass")
    func identicalIssuesJoin() async throws {
        let posts = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, operation in
            if operation == Self.issueOp {
                posts.set(posts.get() + 1)
                entered.open()
                await release.wait()
                return Self.issued("p1", url: "https://door.example.invalid/p/one")
            }
            return Self.passes(Self.pass("p1"))
        }
        let store = TripGuestStore(collectionUid: "t1")
        let first = Task { try await store.issue(Self.draft, using: client.handle) }
        await entered.wait()
        #expect(store.isWriting)
        let second = Task { try await store.issue(Self.draft, using: client.handle) }
        for _ in 0..<10 { await Task.yield() }
        release.open()
        let a = try await first.value
        let b = try await second.value
        #expect(posts.get() == 1)
        #expect(a == b)
        #expect(!store.isWriting)
    }

    @Test("any other write while one is out is refused as busy and sends nothing")
    func otherWritesAreRefused() async throws {
        let deletes = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, operation in
            switch operation {
            case Self.issueOp:
                entered.open()
                await release.wait()
                return Self.issued("p1", url: "https://door.example.invalid/p/one")
            case Self.revokeOp:
                deletes.set(deletes.get() + 1)
                return Stub.json(Self.pass("p0", state: "revoked"))
            default: return Self.passes(Self.pass("p1"))
            }
        }
        let store = TripGuestStore(collectionUid: "t1")
        let first = Task { try await store.issue(Self.draft, using: client.handle) }
        await entered.wait()
        await #expect(throws: TripGuestStore.Failure.busy) {
            try await store.endPass("p0", using: client.handle)
        }
        release.open()
        _ = try await first.value
        #expect(deletes.get() == 0)
    }

    @Test("a list asked before End the Pass and answering after it does not bring the pass back")
    func aStaleListDoesNotUndoAnEnd() async throws {
        let lists = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, operation in
            switch operation {
            case Self.listOp:
                lists.set(lists.get() + 1)
                if lists.get() == 1 {
                    entered.open()
                    await release.wait()
                    return Self.passes(Self.pass("p1", state: "active"))
                }
                return Self.passes(Self.pass("p1", state: "revoked"))
            case Self.revokeOp: return Stub.json(Self.pass("p1", state: "revoked"))
            default: return Self.passes()
            }
        }
        let store = TripGuestStore(collectionUid: "t1")
        let reading = Task { await store.loadPasses(using: client.handle) }
        await entered.wait()
        try await store.endPass("p1", using: client.handle)
        #expect(store.passes?.first?.state == .revoked)
        release.open()
        await reading.value
        #expect(store.passes?.first?.state == .revoked, "the stale list resurrected the pass")
        #expect(lists.get() == 2, "the read-back joined the stale list instead of asking again")
    }

    @Test("an answer that lands after the account changed lands nowhere, the guest URL included")
    func anotherAccountsAnswersLandNowhere() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, operation in
            if operation == Self.listOp {
                entered.open()
                await release.wait()
            }
            if operation == Self.issueOp {
                return Self.issued("p1", url: "https://door.example.invalid/p/one")
            }
            return Self.passes(Self.pass("p1"))
        }
        let store = TripGuestStore(collectionUid: "t1")
        let issuing = Task { try await store.issue(Self.draft, using: client.handle) }
        await entered.wait()
        #expect(store.issued != nil)
        store.sessionIdentityChanged()
        #expect(store.issued == nil)
        release.open()
        await #expect(throws: TripGuestStore.Failure.superseded) { try await issuing.value }
        #expect(store.passes == nil)
        #expect(store.issued == nil)
    }

    @Test("an account change after the Issue finished, before its callers resume, hands no URL")
    func callersRecheckTheIdentityAfterTheWrite() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, operation in
            if operation == Self.issueOp {
                entered.open()
                await release.wait()
                return Self.issued("p1", url: "https://door.example.invalid/p/one")
            }
            return Self.passes(Self.pass("p1"))
        }
        let store = TripGuestStore(collectionUid: "t1")
        let session = LastLookSession(for: client.handle)
        store.reports(to: session)
        session.onLastLook = { store.sessionIdentityChanged() }
        let first = Task { try await store.issue(Self.draft, using: client.handle) }
        await entered.wait()
        let second = Task { try await store.issue(Self.draft, using: client.handle) }
        for _ in 0..<10 { await Task.yield() }
        release.open()
        await #expect(throws: TripGuestStore.Failure.superseded) { try await first.value }
        await #expect(throws: TripGuestStore.Failure.superseded) { try await second.value }
        #expect(session.lookedLast, "the change was never queued: the window was not reached")
        #expect(store.issued == nil)
    }

    @Test("a sheet dismissed while its Issue is out does not get the guest URL back")
    func aDismissedIssueHoldsNothing() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, operation in
            if operation == Self.issueOp {
                entered.open()
                await release.wait()
                return Self.issued("p1", url: "https://door.example.invalid/p/one")
            }
            return Self.passes(Self.pass("p1"))
        }
        let store = TripGuestStore(collectionUid: "t1")
        let issuing = Task { try await store.issue(Self.draft, using: client.handle) }
        await entered.wait()
        store.dismissIssued()
        release.open()
        _ = try await issuing.value
        #expect(store.issued == nil, "the late answer resurrected the dismissed URL")
    }

    @Test("ending the pass whose code is on the sheet takes the code away")
    func endingTheIssuedPassDropsItsCode() async throws {
        let client = Stub.client { _, _, operation in
            switch operation {
            case Self.issueOp: return Self.issued("p1", url: "https://door.example.invalid/p/one")
            case Self.revokeOp: return Stub.json(Self.pass("p1", state: "revoked"))
            default: return Self.passes(Self.pass("p1", state: "revoked"))
            }
        }
        let store = TripGuestStore(collectionUid: "t1")
        try await store.issue(Self.draft, using: client.handle)
        #expect(store.issued != nil)
        try await store.endPass("p1", using: client.handle)
        #expect(store.issued == nil)
    }

    @Test(
        "the server's refusals are said as sentences",
        arguments: [
            (409, TripGuestStore.Failure.tripHasNoTag), (403, .forbidden),
            (404, .server(status: 404)),
        ])
    func refusalsAreSentences(_ status: Int, _ expected: TripGuestStore.Failure) async throws {
        let client = Stub.client { _, _, _ in
            Stub.detail("nope", status: HTTPResponse.Status(code: status))
        }
        let store = TripGuestStore(collectionUid: "t1")
        await #expect(throws: expected) { try await store.issue(Self.draft, using: client.handle) }
        await store.loadPasses(using: client.handle)
        #expect(store.notice != nil)
        #expect(store.passes == nil)
    }

    @Test("an already-ended pass says so and the list is read back")
    func anAlreadyEndedPassIsReadBack() async throws {
        let client = Stub.client { _, _, operation in
            if operation == Self.revokeOp { return Stub.detail("pass_revoked", status: .gone) }
            return Self.passes(Self.pass("p1", state: "revoked"))
        }
        let store = TripGuestStore(collectionUid: "t1")
        await #expect(throws: TripGuestStore.Failure.alreadyEnded) {
            try await store.endPass("p1", using: client.handle)
        }
        #expect(store.passes?.first?.state == .revoked)
    }

    @Test("a refused credential reaches the session's funnel")
    func aRefusalReachesTheFunnel() async throws {
        let heard = LockedValue(0)
        let client = Stub.client { _, _, _ in
            Stub.detail("Not authenticated", status: .unauthorized)
        }
        let store = TripGuestStore(collectionUid: "t1") { _ in
            heard.set(heard.get() + 1)
            return .superseded
        }
        await store.loadPasses(using: client.handle)
        #expect(heard.get() == 1)
    }

    @Test("Revoke ends one device by its own path and reads that pass's devices back")
    func revokingADeviceReadsBack() async throws {
        let sent = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            sent.set(sent.get() + ["\(request.method.rawValue) \(request.path ?? "")"])
            switch operation {
            case Self.revokeDeviceOp: return Stub.json(Self.device("d1", revoked: true))
            case Self.devicesOp: return Stub.json("[\(Self.device("d1", revoked: true))]")
            default: return Self.passes(Self.pass("p1", devices: 1))
            }
        }
        let store = TripGuestStore(collectionUid: "t1")
        try await store.revokeDevice("d1", of: "p1", using: client.handle)
        #expect(sent.get().first == "DELETE /api/passes/p1/devices/d1")
        #expect(sent.get().contains("GET /api/passes/p1/devices"))
        let read = try #require(store.devices["p1"]?.first)
        #expect(read.revoked)
        #expect(read.uploadsCount == 412)
        #expect(read.platform == .app)
    }

    @Test(
        "the inbox lists every pass's pictures, newest first, and hides by the pass each came through"
    )
    func moderationGroupsByPassAndReadsBack() async throws {
        let hidden = LockedValue<Set<String>>([])
        let posted = LockedValue<[String]>([])
        let client = Stub.client { request, body, operation in
            switch operation {
            case Self.listOp: return Self.passes(Self.pass("pa"), Self.pass("pb"))
            case Self.contributionsOp:
                let isA = request.path?.contains("/pa/") ?? false
                let now = hidden.get()
                let rows =
                    isA
                    ? [Self.contribution("a1", at: 3, hidden: now.contains("a1"))]
                    : [
                        Self.contribution("b1", at: 5, hidden: now.contains("b1")),
                        Self.contribution("b2", at: 1),
                    ]
                return Stub.json("[\(rows.joined(separator: ","))]")
            case Self.hideOp:
                posted.set(posted.get() + [request.path ?? ""])
                let uids = try await Stub.body(body)["attachmentUids"] as? [String] ?? []
                hidden.set(hidden.get().union(uids))
                let results = uids.map { #"{"attachmentUid":"\#($0)","outcome":"hidden"}"# }
                return Stub.json(#"{"results":[\#(results.joined(separator: ","))]}"#)
            default: return Stub.empty(.notFound)
            }
        }
        let store = TripGuestStore(collectionUid: "t1")
        await store.loadContributions(using: client.handle)
        #expect(store.contributions?.map(\.attachmentUid) == ["b1", "a1", "b2"])
        let outcome = try await store.moderate(.hide, ["a1", "b1"], using: client.handle)
        #expect(outcome == TripModerationOutcome(applied: 2, failed: 0))
        #expect(
            Set(posted.get())
                == ["/api/passes/pa/contributions/hide", "/api/passes/pb/contributions/hide"])
        let rows = try #require(store.contributions)
        #expect(rows.filter(\.hidden).map(\.attachmentUid).sorted() == ["a1", "b1"])
    }

    @Test("an outcome other than the one asked for is counted as failed")
    func unappliedOutcomesCountAsFailed() async throws {
        let client = Stub.client { _, _, _ in
            Stub.json(
                #"{"results":[{"attachmentUid":"a","outcome":"removed"},"#
                    + #"{"attachmentUid":"b","outcome":"error"},"#
                    + #"{"attachmentUid":"c","outcome":"notContribution"}]}"#)
        }
        let outcome = try await TripGuestStore.moderate(
            client, .remove, pass: "p", attachments: ["a", "b", "c"])
        #expect(outcome == TripModerationOutcome(applied: 1, failed: 2))
    }

    @Test("the expiry opens fourteen days after the trip, else thirty days from now")
    func defaultExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let day: TimeInterval = 86_400
        let ahead = now.addingTimeInterval(5 * day)
        #expect(
            TripPassDraft.defaultExpiry(spanEnd: ahead, now: now)
                == ahead.addingTimeInterval(14 * day))
        let longAgo = now.addingTimeInterval(-20 * day)
        #expect(
            TripPassDraft.defaultExpiry(spanEnd: longAgo, now: now)
                == now.addingTimeInterval(30 * day))
        #expect(
            TripPassDraft.defaultExpiry(spanEnd: nil, now: now) == now.addingTimeInterval(30 * day))
    }

    @Test("a draft is sendable only within the server's bounds")
    func draftBounds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let later = now.addingTimeInterval(60)
        #expect(TripPassDraft(label: "Trip", expiresAt: later).isSendable(at: now))
        #expect(!TripPassDraft(label: "   ", expiresAt: later).isSendable(at: now))
        #expect(!TripPassDraft(label: "Trip", expiresAt: now).isSendable(at: now))
        #expect(!TripPassDraft(label: "Trip", expiresAt: later, maxDevices: 0).isSendable(at: now))
        #expect(
            !TripPassDraft(label: "Trip", expiresAt: later, maxDevices: 201).isSendable(at: now))
        #expect(
            !TripPassDraft(label: String(repeating: "x", count: 256), expiresAt: later)
                .isSendable(at: now))
    }

    nonisolated static let metaOp = "attachment_meta_api_attachments__uid__get"

    /// The record a row's thumbnail read answers with: `filename` is nullable on the route.
    nonisolated static func record(_ uid: String, mime: String, filename: String?, capture: String?)
        -> (HTTPResponse, HTTPBody?)
    {
        let name = filename.map { "\"\($0)\"" } ?? "null"
        let taken = capture.map { "\"\($0)\"" } ?? "null"
        return Stub.json(
            """
            {"uid":"\(uid)","mime":"\(mime)","size":1024,"sha256":null,"status":"ready",\
            "width":1000,"height":800,"duration":null,"blurhash":null,"captured_at":null,\
            "capture_instant":\(taken),"capture_civil":null,"capture_source":null,"mine":true,\
            "hasPrint":false,"hasLegacyPrint":false,"hasPoster":false,"renditions":[],\
            "filename":\(name),"latitude":null,"longitude":null,"locationSource":null,\
            "addedBy":null,"camera":null,"webReady":true,\
            "downloadUrl":"/api/attachments/\(uid)/original",\
            "printUrl":"/api/attachments/\(uid)/print",\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb?sig=1",\
            "previewUrl":"/api/attachments/\(uid)/mobile?sig=1",\
            "webUrl":"/api/attachments/\(uid)/web?sig=1",\
            "posterUrl":"/api/attachments/\(uid)/poster?sig=1"}
            """)
    }

    @Test("a row's picture read keeps the file's own name, none when the server has none")
    func thePictureReadKeepsTheFilename() async throws {
        let client = Stub.client { request, _, operation in
            guard operation == Self.metaOp else { return Stub.empty(.notFound) }
            if request.path?.contains("/a1") ?? false {
                return Self.record(
                    "a1", mime: "video/quicktime", filename: "IMG_0412.MOV",
                    capture: "2026-07-14T18:03:00Z")
            }
            return Self.record("a2", mime: "image/jpeg", filename: nil, capture: nil)
        }
        let store = TripGuestStore(collectionUid: "t1")
        #expect(store.filename(for: "a1") == nil)
        await store.loadPicture("a1", using: client.handle, baseURL: Stub.baseURL)
        await store.loadPicture("a2", using: client.handle, baseURL: Stub.baseURL)
        #expect(store.filename(for: "a1") == "IMG_0412.MOV")
        #expect(store.picture(for: "a1")?.mime == "video/quicktime")
        #expect(
            store.picture(for: "a1")?.captureInstant
                == ISO8601DateFormatter().date(from: "2026-07-14T18:03:00Z"))
        #expect(store.picture(for: "a2") != nil)
        #expect(store.filename(for: "a2") == nil)
        // A name read under one identity is not shown under the next.
        store.sessionIdentityChanged()
        #expect(store.filename(for: "a1") == nil)
    }
}

/// A session that queues `onLastLook` on the main actor at the first look a store takes after its
/// second reported success. For an Issue that look is the write's own last check, after the POST
/// and its read-back have both reported: the queued job runs once the write has returned and
/// before its callers' continuations, which are queued only when the write completes.
@MainActor
private final class LastLookSession: SessionReporting {
    private let handle: SessionHandle
    nonisolated let sessionIncarnation = SessionEpoch()
    private var successes = 0
    private(set) var lookedLast = false
    var onLastLook: (@MainActor @Sendable () -> Void)?

    init(for handle: SessionHandle) { self.handle = handle }

    var activeHandle: SessionHandle? {
        if successes == 2, !lookedLast, let onLastLook {
            lookedLast = true
            Task { @MainActor in onLastLook() }
        }
        return handle
    }

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }

    func nothingEstablishedSince(_ handle: SessionHandle) -> Bool { true }

    func noteTransportFailure(_ failure: ServerReachability.Reason, issuedUnder generation: Int) {}

    func noteTransportSuccess(issuedUnder generation: Int) { successes += 1 }
}
