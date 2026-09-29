import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import MemosOutbox
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit
import os

@testable import MemosFeatures

/// The memos-ng side of a lapsed signature: one memo whose pictures are signed `old` (already
/// expired) until `resign` is called, and `new` (in date) after it.
///
/// The real generated client reads it, so the list read, the memo read and their decoding are the
/// app's own; the reads of the one memo are counted, because "exactly one re-read" is the claim.
nonisolated final class ResigningMemoServer: ClientTransport, Sendable {
    static let memoUID = "m-resign"
    static let listMemos = "list_memos_api_memos_get"
    static let getMemo = "get_memo_api_memos__uid__get"

    private struct State {
        var sig = "old"
        var attachments: [String]
        var memoReads = 0
        var holdsMemoReads = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(attachments: [String]) {
        state = OSAllocatedUnfairLock(uncheckedState: State(attachments: attachments))
    }

    var memoReads: Int { state.withLock { $0.memoReads } }

    /// Memo reads wait on the wire, their answers already decided, until `releaseMemoReads`.
    func holdMemoReads() { state.withLock { $0.holdsMemoReads = true } }
    func releaseMemoReads() { state.withLock { $0.holdsMemoReads = false } }

    /// From now on the server signs afresh, and holds only `keeping` of the memo's attachments.
    func resign(keeping: [String]? = nil) {
        state.withLock {
            $0.sig = "new"
            if let keeping { $0.attachments = keeping }
        }
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (attachments, sig) = state.withLock {
            if operationID == Self.getMemo { $0.memoReads += 1 }
            return ($0.attachments, $0.sig)
        }
        while operationID == Self.getMemo, state.withLock({ $0.holdsMemoReads }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        let memo = Self.memo(attachments: attachments, sig: sig)
        switch operationID {
        case Self.listMemos:
            let page = #"{"items":[\#(memo)],"nextCursor":null,"totalCount":null}"#
            return (response, HTTPBody(page))
        case Self.getMemo:
            return (response, HTTPBody(memo))
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    static func memo(attachments: [String], sig: String) -> String {
        let refs = attachments.map { attachment(uid: $0, sig: sig) }.joined(separator: ",")
        return """
            {"uid":"\(memoUID)","owner":"fabian","mine":true,"content":"pictures",\
            "visibility":"PRIVATE","pinned":false,"created_at":"2026-08-23T09:00:00Z",\
            "updated_at":"2026-08-23T09:00:00.443000Z","archived_at":null,"tags":[],\
            "attachments":[\(refs)]}
            """
    }

    /// `old` is signed with an `exp` long past, `new` with one far ahead.
    static func attachment(uid: String, sig: String) -> String {
        let exp = sig == "old" ? 1_000_000_000 : 4_000_000_000
        let query = "?exp=\(exp)&scope=1&sig=\(sig)"
        return """
            {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
            "width":1000,"height":1000,"duration":null,"mine":true,"hasPrint":false,\
            "hasLegacyPrint":false,"renditions":[],"position":null,\
            "sha256":null,"capture_instant":null,"capture_civil":null,"capture_source":null,\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb\(query)",\
            "previewUrl":"/api/attachments/\(uid)/mobile\(query)",\
            "webUrl":"/api/attachments/\(uid)/web\(query)",\
            "posterUrl":"/api/attachments/\(uid)/poster\(query)",\
            "downloadUrl":"/api/attachments/\(uid)/original",\
            "printUrl":"/api/attachments/\(uid)/print"}
            """
    }
}

/// The rendition route: an `old` signature is refused with a 403, a `new` one answered with a
/// picture. Every request is kept, so "the next request went out under the new signature" is read
/// off what really reached it.
actor SignatureMediaServer: MediaTransport {
    private var urls: [URL] = []
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func asked(uid: String, sig: String) -> Int {
        urls.filter {
            $0.path.contains("/\(uid)/") && $0.absoluteString.contains("sig=\(sig)")
        }.count
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        let url = request.url ?? URL(string: "https://memos.example.invalid/")!
        urls.append(url)
        let refused = url.absoluteString.contains("sig=old")
        let response = HTTPURLResponse(
            url: url,
            statusCode: refused ? 403 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": refused ? "application/json" : "image/png"]
        )!
        return (refused ? Data() : payload, response)
    }
}

/// A memo's tiles as a screen shows them: the memo read from the timeline when it holds it, from
/// the screen's own copy when it does not, and the one it was opened with before either.
struct MemoTilesHost: View {
    let timeline: TimelineStore
    let detached: DetachedMemo?
    let initial: Memo?
    let refresher: MemoURLRefresher

    private var memo: Memo? {
        timeline.memos.first { $0.uid == ResigningMemoServer.memoUID } ?? detached?.fetched
            ?? initial
    }

    var body: some View {
        VStack {
            ForEach(memo?.attachments ?? []) { attachment in
                AttachmentThumbnail(attachment: attachment, slot: MemoPresentation.gridSlot)
            }
        }
        .environment(\.signedURLRefresher, refresher)
    }
}

extension MediaImageLoaderTests {
    static let resignBase = URL(string: "https://memos.example.invalid")!

    func resigningClient(_ server: ResigningMemoServer) -> SessionHandle {
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: Self.resignBase),
            token: { "memos_pat_resign" },
            transport: server
        )
        return SessionHandle(client: client, generation: 1)
    }

    func resignWindow(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    @Test("a timeline row whose signature lapsed reads its memo once and loads the new URL")
    func aTimelineRowRecoversThroughOneMemoRead() async {
        let server = ResigningMemoServer(attachments: ["ra"])
        let media = SignatureMediaServer(payload: MediaFixture.png(.red))
        await withTransport(media) {
            let handle = resigningClient(server)
            let timeline = TimelineStore()
            await timeline.refresh(using: handle, baseURL: Self.resignBase)
            #expect(timeline.memos.count == 1, "the list never loaded")
            server.resign()
            let refresher = MemoURLRefresher(
                timeline: timeline,
                session: IssuingSession(handle: { handle }, baseURL: { Self.resignBase })
            )
            let window = resignWindow(
                MemoTilesHost(timeline: timeline, detached: nil, initial: nil, refresher: refresher)
            )

            let recovered = await eventually { await media.asked(uid: "ra", sig: "new") >= 1 }
            #expect(await media.asked(uid: "ra", sig: "old") >= 1, "the lapsed URL was never tried")
            #expect(recovered, "the row's next request never went out under the new signature")
            #expect(server.memoReads == 1, "the lapsed row did not read its memo exactly once")
            window.isHidden = true
        }
    }

    @Test("a memo viewer already open reloads its page under the re-read memo's new signature")
    func anOpenViewerFollowsTheReRead() async {
        let server = ResigningMemoServer(attachments: ["va"])
        let media = SignatureMediaServer(payload: MediaFixture.png(.red))
        await withTransport(media) {
            let handle = resigningClient(server)
            let timeline = TimelineStore()
            await timeline.refresh(using: handle, baseURL: Self.resignBase)
            guard let memo = timeline.memos.first,
                let selection = MediaViewerPresentation.viewer(for: memo, startingAt: "va")
            else {
                Issue.record("the memo never loaded, so there was no viewer to open")
                return
            }
            server.resign()
            let refresher = MemoURLRefresher(
                timeline: timeline,
                session: IssuingSession(handle: { handle }, baseURL: { Self.resignBase })
            )
            let window = resignWindow(
                MediaViewerView(
                    selection: selection,
                    source: .memo(uid: memo.uid, in: timeline, fallback: selection.pages),
                    transport: media
                )
                .environment(\.signedURLRefresher, refresher)
            )

            let recovered = await eventually { await media.asked(uid: "va", sig: "new") >= 1 }
            #expect(await media.asked(uid: "va", sig: "old") >= 1, "the lapsed still was not tried")
            #expect(recovered, "the open page never asked again under the new signature")
            window.isHidden = true
        }
    }

    @Test("a detail screen whose timeline never loaded the memo takes the re-read for itself")
    func anUnloadedDetailInstallsTheReRead() async {
        let server = ResigningMemoServer(attachments: ["da"])
        let media = SignatureMediaServer(payload: MediaFixture.png(.red))
        await withTransport(media) {
            let handle = resigningClient(server)
            // The list is never read: the memo reached this screen from elsewhere.
            let timeline = TimelineStore()
            guard
                let initial = await timeline.fetchMemo(
                    uid: ResigningMemoServer.memoUID,
                    using: handle,
                    baseURL: Self.resignBase
                )
            else {
                Issue.record("the memo the screen opens with never arrived")
                return
            }
            #expect(timeline.memos.isEmpty, "the fetch put the memo in the list after all")
            server.resign()
            // The screen itself, as the app builds it, over a session it is handed rather than one
            // signed in through a `SessionStore`.
            let window = resignWindow(
                NavigationStack {
                    MemoDetailView(
                        uid: ResigningMemoServer.memoUID,
                        initial: initial,
                        timeline: timeline,
                        issuing: IssuingSession(handle: { handle }, baseURL: { Self.resignBase })
                    )
                }
            )

            let lapsed = await eventually { await media.asked(uid: "da", sig: "old") >= 1 }
            #expect(lapsed, "precondition: the detail never asked for its lapsed picture")
            let recovered = await eventually { await media.asked(uid: "da", sig: "new") >= 1 }
            #expect(recovered, "the detail's picture never asked again under the new signature")
            #expect(server.memoReads == 2, "the detail did not read its memo again exactly once")
            window.isHidden = true
        }
    }

    @Test("two pictures of an unloaded memo lapsing together put one read of it on the wire")
    func anUnloadedDetailJoinsOneReRead() async {
        let server = ResigningMemoServer(attachments: ["ja", "jb"])
        let handle = resigningClient(server)
        let timeline = TimelineStore()
        server.resign()
        server.holdMemoReads()
        let detached = DetachedMemo(uid: ResigningMemoServer.memoUID)
        let refresher = MemoURLRefresher(
            timeline: timeline,
            session: IssuingSession(handle: { handle }, baseURL: { Self.resignBase }),
            detached: detached
        )

        refresher.signatureExpired(uid: "ja")
        refresher.signatureExpired(uid: "jb")
        let sent = await eventually { server.memoReads >= 1 }
        #expect(sent, "precondition: no read of the memo went out")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(server.memoReads == 1, "the second lapse sent a read of its own beside the first")

        server.releaseMemoReads()
        let kept = await eventually { detached.fetched != nil }
        #expect(kept, "the joined read's answer was not kept")
        #expect(server.memoReads == 1)
    }

    @Test("a viewer over two pages keeps both when one is deleted, and re-signs the one left")
    func aShrunkSourceStillReSignsTheRetainedPage() async {
        let server = ResigningMemoServer(attachments: ["fa", "fb"])
        let media = SignatureMediaServer(payload: MediaFixture.png(.red))
        await withTransport(media) {
            let handle = resigningClient(server)
            let timeline = TimelineStore()
            await timeline.refresh(using: handle, baseURL: Self.resignBase)
            guard let memo = timeline.memos.first,
                let selection = MediaViewerPresentation.viewer(for: memo, startingAt: "fb")
            else {
                Issue.record("the memo never loaded, so there was no viewer to open")
                return
            }
            // "fa" is deleted elsewhere while the viewer is open; "fb" comes back signed afresh.
            server.resign(keeping: ["fb"])
            let refresher = MemoURLRefresher(
                timeline: timeline,
                session: IssuingSession(handle: { handle }, baseURL: { Self.resignBase })
            )
            let window = resignWindow(
                MediaViewerView(
                    selection: selection,
                    source: .memo(uid: memo.uid, in: timeline, fallback: selection.pages),
                    transport: media
                )
                .environment(\.signedURLRefresher, refresher)
            )

            let recovered = await eventually { await media.asked(uid: "fb", sig: "new") >= 1 }
            #expect(recovered, "the retained page kept its refused URL")
            window.isHidden = true
        }
    }
}

@Suite("Viewer pages kept across a changed source")
struct MediaViewerPagerFreshURLTests {
    func page(_ uid: String, sig: String) -> MediaPage {
        let attachment = MemoAttachment(
            uid: uid,
            mime: "image/jpeg",
            status: .ready,
            width: 1000,
            height: 1000,
            thumbnailURL: MediaFixture.signed(uid: uid, sig: sig),
            previewURL: MediaFixture.signed(uid: uid, tier: "mobile", sig: sig),
            webURL: MediaFixture.signed(uid: uid, tier: "web", sig: sig)
        )
        return MediaViewerPresentation.pages(for: [attachment])[0]
    }

    @Test("a source that lost a page keeps the pages shown, each taking the source's fresh copy")
    func retainedPagesTakeTheSourcesURLs() {
        let shown = [page("a", sig: "aaaa"), page("b", sig: "aaaa")]
        let fresh = page("b", sig: "bbbb")

        let kept = MediaViewerPager.extended(shown, with: [fresh])

        #expect(kept.map(\.id) == ["a", "b"], "the reader's pages were pulled out from under them")
        #expect(kept[1] == fresh, "the retained page kept its old URLs")
        #expect(kept[0] == shown[0], "a page the source no longer holds was changed")
    }

    @Test("an answer for another memo or another session is not installed")
    @MainActor
    func theDetachedCopyIsFenced() {
        let detached = DetachedMemo(uid: "m1")
        let issued = SessionHandle(client: Self.unusedClient, generation: 1)
        let replaced = SessionHandle(client: Self.unusedClient, generation: 2)
        let mine = Self.memo("m1")
        let other = Self.memo("m2")

        #expect(!detached.install(mine, issuedUnder: issued, current: replaced))
        #expect(!detached.install(other, issuedUnder: issued, current: issued))
        #expect(detached.fetched == nil)
        #expect(detached.install(mine, issuedUnder: issued, current: issued))
        #expect(detached.fetched?.uid == "m1")
    }

    static func memo(_ uid: String) -> Memo {
        Memo(
            uid: uid,
            owner: "fabian",
            mine: true,
            content: "x",
            visibility: .private,
            pinned: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    static let unusedClient = APIClientFactory.make(
        configuration: ServerConfiguration(baseURL: URL(string: "https://memos.example.invalid")!),
        token: { nil },
        transport: ResigningMemoServer(attachments: [])
    )
}

/// The library's list endpoint: one row, signed `old` until `resign`, every read counted.
nonisolated final class ResigningLibraryServer: ClientTransport, Sendable {
    private let state = OSAllocatedUnfairLock(uncheckedState: (sig: "old", reads: 0))

    var reads: Int { state.withLock { $0.reads } }
    func resign() { state.withLock { $0.sig = "new" } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard operationID == "list_attachments_api_attachments_get" else {
            return (HTTPResponse(status: .notFound), nil)
        }
        let sig = state.withLock {
            $0.reads += 1
            return $0.sig
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        let query = "?exp=4102444800&scope=1&sig=\(sig)"
        let row = """
            {"uid":"la","mime":"image/jpeg","status":"ready","blurhash":null,\
            "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
            "renditions":[],"orphan":true,"memoUid":null,\
            "takenAt":"2026-09-26T10:00:00Z","filename":"la.jpg",\
            "thumbnailUrl":"/api/attachments/la/thumb\(query)",\
            "previewUrl":"/api/attachments/la/mobile\(query)",\
            "webUrl":"/api/attachments/la/web\(query)",\
            "posterUrl":"/api/attachments/la/poster\(query)",\
            "downloadUrl":"/api/attachments/la/download",\
            "printUrl":"/api/attachments/la/print"}
            """
        return (response, HTTPBody("[\(row)]"))
    }
}

@Suite("Library re-signing, routed from a lapsed tile")
struct LibraryURLRefresherTests {
    @Test("a held row that lapsed is re-signed in place; a uid the library does not hold is not")
    func aHeldRowIsReissuedAndAStrangerIsNot() async {
        let server = ResigningLibraryServer()
        let base = URL(string: "https://memos.example.invalid")!
        let handle = SessionHandle(
            client: APIClientFactory.make(
                configuration: ServerConfiguration(baseURL: base),
                token: { "memos_pat_library" },
                transport: server
            ),
            generation: 1
        )
        let library = MediaLibraryStore(pageSize: 2, reissueCooldown: {})
        await library.refresh(using: handle, baseURL: base)
        #expect(library.items.map(\.id) == ["la"], "the library never loaded its row")
        server.resign()
        let refresher = LibraryURLRefresher(
            library: library,
            session: IssuingSession(handle: { handle }, baseURL: { base })
        )

        refresher.signatureExpired(uid: "nobody")
        for _ in 0..<20 { await Task.yield() }
        #expect(server.reads == 1, "a uid the library does not hold started a walk")

        refresher.signatureExpired(uid: "la")
        var resigned = false
        for _ in 0..<80 where !resigned {
            try? await Task.sleep(for: .milliseconds(25))
            resigned =
                library.items.first?.attachment.thumbnailURL?.absoluteString
                .contains("sig=new") == true
        }
        #expect(resigned, "the lapsed row kept its refused URL")
        #expect(server.reads == 2, "the walk did not re-read exactly the one page it held")
    }
}

/// A session a test replaces between an ask and the task that acts on it.
@MainActor
final class SwitchableHandle {
    var handle: SessionHandle

    init(_ handle: SessionHandle) {
        self.handle = handle
    }
}

/// The bucket endpoint: a year list whose one cover is `yc`, a day list, and day reads that can be
/// held on the wire while the test acts. Every read is counted by its `size`.
nonisolated final class HeldBucketServer: ClientTransport, Sendable {
    private let state = OSAllocatedUnfairLock(
        uncheckedState: (reads: [String](), holdsDays: false)
    )

    func reads(of size: String) -> Int { state.withLock { $0.reads.filter { $0 == size }.count } }
    func holdDays() { state.withLock { $0.holdsDays = true } }
    func releaseDays() { state.withLock { $0.holdsDays = false } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard operationID == "attachment_buckets_api_attachments_buckets_get" else {
            return (HTTPResponse(status: .notFound), nil)
        }
        let items = request.path.flatMap { URLComponents(string: $0)?.queryItems } ?? []
        let size = items.first { $0.name == "size" }?.value ?? "?"
        state.withLock { $0.reads.append(size) }
        while size == "day", state.withLock({ $0.holdsDays }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        let key = size == "year" ? "2026" : "2026-09-14"
        let cover = size == "year" ? "yc" : "dc"
        let body = """
            [{"key":"\(key)","count":3,"coverUid":"\(cover)",\
            "coverThumbnailUrl":"/api/attachments/\(cover)/thumb?exp=1000000000&scope=1&sig=old"}]
            """
        return (response, HTTPBody(body))
    }
}

extension MediaImageLoaderTests {
    @Test("a reread issued under an ended session is refused, and the running one's answer lands")
    func aStaleReReadIsRefusedAndTheCurrentOneInstalls() async {
        let server = ResigningMemoServer(attachments: ["sa"])
        let ended = resigningClient(server)
        let running = SessionHandle(client: ended.client, generation: 2)
        let timeline = TimelineStore()
        server.resign()
        server.holdMemoReads()
        let detached = DetachedMemo(uid: ResigningMemoServer.memoUID)

        let current = Task {
            await detached.reread(
                through: timeline,
                using: running,
                baseURL: Self.resignBase,
                current: { running }
            )
        }
        let sent = await eventually { server.memoReads == 1 }
        #expect(sent, "precondition: the running session's read never went out")
        let stale = Task {
            await detached.reread(
                through: timeline,
                using: ended,
                baseURL: Self.resignBase,
                current: { running }
            )
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(server.memoReads == 1, "the ended session's reread sent a read of its own")

        server.releaseMemoReads()
        await current.value
        await stale.value
        #expect(detached.fetched != nil, "the running session's answer was not installed")
    }

    @Test("a lapse asked for just before a sign-in is read under the session running at its start")
    func aLapseAskedAcrossASignInIsReadUnderTheNewSession() async {
        let before = ResigningMemoServer(attachments: ["xa"])
        let after = ResigningMemoServer(attachments: ["xa"])
        let box = SwitchableHandle(resigningClient(before))
        let next = SessionHandle(client: resigningClient(after).client, generation: 2)
        let detached = DetachedMemo(uid: ResigningMemoServer.memoUID)
        let refresher = MemoURLRefresher(
            timeline: TimelineStore(),
            session: IssuingSession(handle: { box.handle }, baseURL: { Self.resignBase }),
            detached: detached
        )

        refresher.signatureExpired(uid: "xa")
        box.handle = next

        let kept = await eventually { detached.fetched != nil }
        #expect(kept, "the lapse was read under the ended session and its answer refused")
        #expect(before.memoReads == 0, "a read went out under the ended session")
        #expect(after.memoReads == 1)
    }

    @Test("a cover's deferred ask firing while Months is on its way leaves Months to land")
    func aDeferredCoverAskDoesNotSupersedeAPendingList() async {
        let gate = CooldownGate()
        MediaImageLoader.flights = MediaFetchTable(sleep: { _ in await gate.wait() })
        let server = HeldBucketServer()
        let handle = SessionHandle(
            client: APIClientFactory.make(
                configuration: ServerConfiguration(baseURL: Self.resignBase),
                token: { "memos_pat_buckets" },
                transport: server
            ),
            generation: 1
        )
        let store = LibraryBucketStore()
        await store.load(
            size: .year,
            filter: .all,
            tag: nil,
            using: handle,
            baseURL: Self.resignBase
        )
        #expect(store.loadedRequest?.size == .year, "precondition: Years never loaded")
        let refresher = BucketURLRefresher(
            buckets: store,
            session: IssuingSession(handle: { handle }, baseURL: { Self.resignBase })
        )
        await withTransport(ScriptedTransport(payload: Data(), status: 403)) {
            let key = MediaImageKey(uid: "yc", tier: "thumb")
            let url = MediaFixture.signed(uid: "yc", exp: 1_000_000_000)
            // The first refusal re-reads Years at once; the second is owed to the cooldown's end.
            _ = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)
            let reread = await eventually { server.reads(of: "year") == 2 && !store.isLoading }
            #expect(reread, "precondition: the first refusal did not re-read Years")
            _ = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)

            server.holdDays()
            let months = Task {
                await store.load(
                    size: .day,
                    filter: .all,
                    tag: nil,
                    using: handle,
                    baseURL: Self.resignBase
                )
            }
            let pending = await eventually { server.reads(of: "day") == 1 }
            #expect(pending, "precondition: the Months read never went out")

            gate.open()
            try? await Task.sleep(for: .milliseconds(150))
            #expect(server.reads(of: "year") == 2, "the owed ask started a Years read over Months")

            server.releaseDays()
            await months.value
            #expect(store.loadedRequest?.size == .day, "the Months list never landed")
        }
    }

    @Test("an ask owed to an identity that has since ended is never made")
    func aDeferredAskForAnEndedIdentityIsDropped() async {
        let gate = CooldownGate()
        MediaImageLoader.flights = MediaFetchTable(sleep: { _ in await gate.wait() })
        await withTransport(ScriptedTransport(payload: Data(), status: 403)) {
            let refresher = CountingRefresher()
            let key = MediaImageKey(uid: "ended", tier: "thumb")
            let url = MediaFixture.signed(uid: "ended", exp: 1_000_000_000)
            _ = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)
            _ = await MediaImageLoader.answer(for: key, url: url, refresher: refresher)
            #expect(refresher.asked == ["ended"])

            identity.rotate()
            gate.open()
            try? await Task.sleep(for: .milliseconds(150))
            #expect(refresher.asked == ["ended"], "an ask owed to the ended identity was made")
        }
    }
}
