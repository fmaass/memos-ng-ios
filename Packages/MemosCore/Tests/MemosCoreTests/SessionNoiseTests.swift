import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

private let whoamiOperation = "whoami_api_auth_user_get"

/// "Can't reach the server" has ONE surface in this app.
///
/// Four stores each writing it into their own `lastError` is what an offline launch used to look
/// like: an error card over the timeline, another over the grid, another under the tag chips, all
/// of them underneath a banner already saying it once. And no ordering inside a store can fix it —
/// a cached list's request can fail BEFORE the launch check does, so the later transition to
/// `.unverified` has nothing to clear.
@MainActor
@Suite("One surface for a server that cannot be reached")
struct SessionNoiseTests {
    private func signedIn(
        handler: @escaping StubTransport.Handler
    ) async -> SessionStore {
        let credentials = InMemoryCredentials()
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            sleeper: { _ in throw CancellationError() }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    /// Answers whoami and nothing else — every other operation is the failure under test.
    private func handler(
        _ answer: @escaping @Sendable () async throws -> (HTTPResponse, HTTPBody?)
    ) -> StubTransport.Handler {
        { _, _, operation in
            guard operation != whoamiOperation else { return Stub.json(Stub.user) }
            return try await answer()
        }
    }

    @Test("a timeline that cannot reach the server says nothing and the session says it once")
    func timelineTransportFailureGoesToTheSession() async {
        let session = await signedIn(
            handler: handler { throw URLError(.notConnectedToInternet) }
        )
        let timeline = TimelineStore()
        timeline.reports(to: session)

        await timeline.refresh(using: session.activeHandle!, baseURL: Stub.baseURL)

        #expect(timeline.lastError == nil, "an error card under the banner says it twice")
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
        #expect(session.state.user != nil, "and the session stands: this is not a refusal")
    }

    @Test("a timeline the server ANSWERED still reports, and leaves the session alone")
    func timelineAPIErrorStillReports() async {
        let session = await signedIn(handler: handler { Stub.empty(.init(code: 500)) })
        let timeline = TimelineStore()
        timeline.reports(to: session)

        await timeline.refresh(using: session.activeHandle!, baseURL: Stub.baseURL)

        #expect(timeline.lastError != nil, "a 500 is about the thing somebody just did")
        #expect(session.verification == .verified, "and says nothing about the credential")
    }

    @Test("the library, the heatmap and the tags follow the same rule")
    func theOtherThreeStoresFollowTheSameRule() async {
        let session = await signedIn(
            handler: handler { throw URLError(.notConnectedToInternet) }
        )
        let library = MediaLibraryStore()
        let heatmap = HeatmapStore()
        let tags = TagStore()
        library.reports(to: session)
        heatmap.reports(to: session)
        tags.reports(to: session)

        await library.refresh(using: session.activeHandle!, baseURL: Stub.baseURL)
        await heatmap.load(using: session.activeHandle!)
        await tags.load(using: session.activeHandle!)

        #expect(library.lastError == nil)
        #expect(heatmap.lastError == nil)
        #expect(tags.lastError == nil)
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
    }

    /// R5, driven THROUGH the store rather than by calling the sink.
    ///
    /// A store's own guards are local attempt counters: they can say a later load overtook this
    /// one, and they cannot say WHOSE session asked. The failure here is issued under A — the
    /// handle is captured while A is signed in — and lands after B is verified, which is the
    /// ordering a slow request on a switched account really produces.
    @Test("a failure issued under a session that has ended is not the new one's")
    func aFailureFromAnEndedSessionIsIgnored() async throws {
        let answering = LockedValue<Bool>(false)
        let session = await signedIn(
            handler: { _, _, operation in
                guard operation != whoamiOperation else { return Stub.json(Stub.user) }
                guard answering.get() else { return Stub.json(Stub.memoList([], nextCursor: nil)) }
                throw URLError(.notConnectedToInternet)
            }
        )
        let timeline = TimelineStore()
        timeline.reports(to: session)
        let underA = try #require(session.activeHandle)

        // B signs in. A's handle is now a generation nobody is in.
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        #expect(session.verification == .verified)
        answering.set(true)
        await timeline.refresh(using: underA, baseURL: Stub.baseURL)

        #expect(
            session.verification == .verified,
            "A's failed request is not evidence about the session running now"
        )
        #expect(timeline.lastError == nil, "and it is not this list's error either")

        // The positive control: the same failure, issued under the session that IS running.
        let underB = try #require(session.activeHandle)
        await timeline.refresh(using: underB, baseURL: Stub.baseURL)
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
    }

    /// B3, per store: an answer issued under one incarnation and applied under the next changes
    /// nothing at all — not the rows, not the counts, not the chips.
    @Test("a page answered for a session that has ended is not applied")
    func aPageFromAnEndedSessionIsNotApplied() async throws {
        // Each store gets the payload ITS decoder accepts. One list for all four would fail the
        // library, tag and heatmap decoders before their guards were ever reached, and the
        // assertions below would then pass with the guards removed.
        let session = await signedIn(
            handler: { _, _, operation in
                switch operation {
                case whoamiOperation: return Stub.json(Stub.user)
                case "list_attachments_api_attachments_get":
                    return Stub.json("[\(Stub.attachment(uid: "x", status: "ready"))]")
                case "list_tags_api_tags_get":
                    return Stub.json(#"[{"name":"travel","count":3}]"#)
                case "stats_heatmap_api_stats_heatmap_get":
                    return Stub.json(#"{"2026-09-05":2}"#)
                default: return Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
                }
            }
        )
        let timeline = TimelineStore()
        let library = MediaLibraryStore()
        let heatmap = HeatmapStore()
        let tags = TagStore()
        timeline.reports(to: session)
        library.reports(to: session)
        heatmap.reports(to: session)
        tags.reports(to: session)
        let underA = try #require(session.activeHandle)

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")

        await timeline.refresh(using: underA, baseURL: Stub.baseURL)
        await library.refresh(using: underA, baseURL: Stub.baseURL)
        await heatmap.load(using: underA)
        await tags.load(using: underA)

        #expect(timeline.memos.isEmpty, "a page for a session that has ended is not a list")
        #expect(library.items.isEmpty, "and neither is a page of attachments")
        #expect(!heatmap.hasLoaded, "and it is not an ANSWER either")
        #expect(!tags.hasLoaded)
        #expect(tags.tags.isEmpty)
        #expect(heatmap.counts.isEmpty)
    }

    /// R-B3, the failure direction — and the worst of it. A 401 issued under A and answered
    /// after B is signed in reaches `onUnauthorized`, which is the app's ONE "this session is
    /// over" signal: unfenced, A's refusal wipes B. The middleware cannot catch it either, because
    /// B installed a different credential OBJECT and A's retained one was never replaced.
    @Test("a stale 401 does not end the session that replaced it")
    func aStale401DoesNotEndTheSuccessor() async throws {
        let refusing = LockedValue<Bool>(false)
        let session = await signedIn(
            handler: { _, _, operation in
                guard operation != whoamiOperation else { return Stub.json(Stub.user) }
                guard refusing.get() else { return Stub.json(Stub.memoList([], nextCursor: nil)) }
                return Stub.empty(.unauthorized)
            }
        )
        let timeline = TimelineStore(onUnauthorized: { [session] in
            await session.handle(.unauthorized)
        })
        timeline.reports(to: session)
        let underA = try #require(session.activeHandle)

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        #expect(session.state.user != nil, "the premise: B is signed in")
        refusing.set(true)
        await timeline.refresh(using: underA, baseURL: Stub.baseURL)

        #expect(session.state.user != nil, "A's refusal ended the session that replaced it")
        #expect(timeline.lastError == nil, "and wrote A's sentence over B's list")
    }

    private func original() -> MemoAttachment {
        MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: .ready,
            downloadURL: URL(string: "https://memos.example.invalid/x/original")!
        )
    }

    /// The download lane. An original is the longest-lived REQUEST this app makes, and it is the
    /// one request that carries the device token outside the generated client — so the transport
    /// asks the authority itself rather than trusting the fences the caller puts either side of it.
    ///
    /// The session is ended the way the app ends one, by signing in as somebody else, and the
    /// download is held at the send point while that happens. Both halves matter. Held, because
    /// the window this fence covers is between the authority being read on the main actor and the
    /// request leaving on another executor, and a test that never enters that window is not about
    /// the fence at all. And a sign-in rather than a sign-out, because a sign-out leaves
    /// `configuration` and `credential` nil and the store then refuses at its own signed-out guard
    /// long before the transport is reached — an earlier version of this test did exactly that and
    /// passed with the whole authority removed.
    @Test("a download held at the send point is not sent once another account owns the session")
    func aDownloadForAnEndedSessionIsNeverSent() async {
        let session = await signedIn(handler: { _, _, _ in Stub.json(Stub.user) })
        let transport = HeldDownloadTransport()
        let attachment = original()

        let download = Task { try await session.download(attachment, transport: transport) }
        for _ in 0..<200 where !transport.entered.get() { await Task.yield() }
        #expect(transport.entered.get(), "the download never reached the send point")

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        #expect(session.state.user != nil, "the premise: somebody is signed in")
        #expect(
            session.serverBaseURL != nil,
            "and the lane is reachable — the signed-out guard is not what is being tested here"
        )
        transport.release.set(true)

        await #expect(throws: OriginalMediaError.superseded) { try await download.value }
        #expect(transport.sends == 0, "a request left under an authority the device had withdrawn")
    }

    /// The OTHER guard on the same lane, kept as its own test rather than folded into the one
    /// above: with nobody signed in there is no credential to offer, so the store refuses before it
    /// builds a request at all. Named for what it is, and asserted on the specific error, so it
    /// cannot be mistaken for evidence about the authority.
    @Test("a download with nobody signed in is refused before a request is built")
    func aDownloadWithNoCredentialIsRefused() async {
        let session = await signedIn(handler: { _, _, _ in Stub.json(Stub.user) })
        let transport = RecordingDownloadTransport()
        await session.signOutWithoutRevoking()

        await #expect(throws: OriginalMediaError.notSignedIn) {
            try await session.download(original(), transport: transport)
        }

        #expect(transport.sends == 0, "a request went out for a session nobody is signed in to")
    }

    /// B3. A chunked upload is the longest-lived thing this app sends and it runs off the main
    /// actor. Handed only a client, it kept starting sessions and appending chunks for an account
    /// the device had left — the check has to travel with it and be asked before every send.
    @Test("an upload whose session ended sends no further chunk")
    func anUploadStopsWhenTheSessionEnds() async throws {
        let sends = Counter()
        let box = LockedValue<SessionStore?>(nil)
        let session = await signedIn(
            handler: { _, _, operation in
                guard operation != whoamiOperation else { return Stub.json(Stub.user) }
                sends.increment()
                if operation == "start_upload_api_uploads_post" {
                    // The session ends while the upload session is being opened, so the FIRST
                    // send is legitimate and every one after it is not. 201 is what this route
                    // answers with; a 200 here would fail to decode and the upload would stop for
                    // a reason that has nothing to do with the fence.
                    if let session = box.get() { await session.signOutWithoutRevoking() }
                    return Stub.json(
                        #"{"upload_uid":"u1","chunk_size":8,"bytes_received":0}"#,
                        status: .created
                    )
                }
                return Stub.json(#"{"upload_uid":"u1","chunk_size":8,"bytes_received":8}"#)
            }
        )
        box.set(session)
        let timeline = TimelineStore()
        timeline.reports(to: session)
        let handle = try #require(session.activeHandle)
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "one.bin")
        try Data(repeating: 7, count: 64).write(to: file)

        let saved = await timeline.edit(
            uid: "m1",
            content: "with a picture",
            attaching: [StagedSource(url: file, filename: "one.bin", mime: "image/jpeg")],
            using: handle,
            baseURL: Stub.baseURL
        )

        #expect(!saved, "an edit for a session that ended did not save")
        #expect(
            sends.count == 1,
            "it opened one upload session and then went on sending chunks for a session that ended"
        )
    }

    /// The PATCH family — `save`, `setVisibility`, `setArchived` are all one method — across a
    /// session end. It is the apply point with the most entry points behind it, and the one that
    /// had no fence: an edit issued under A and answered after a switch to B would land in B,
    /// clear B's error line and tell the sheet the save went through for a session that is gone.
    @Test("an edit answered after the session ended is applied to nobody")
    func aPatchFromAnEndedSessionIsNotApplied() async throws {
        let session = await signedIn(
            handler: { _, _, operation in
                switch operation {
                case whoamiOperation: return Stub.json(Stub.user)
                case "patch_memo_api_memos__uid__patch":
                    return Stub.json(Stub.memo(uid: "a", content: "after"))
                default: return Stub.json(Stub.memoList(["a"], nextCursor: nil))
                }
            }
        )
        let timeline = TimelineStore()
        timeline.reports(to: session)
        let underA = try #require(session.activeHandle)
        await timeline.refresh(using: underA, baseURL: Stub.baseURL)
        #expect(timeline.memos.first?.content == "hello", "the premise: A's row is on screen")

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        let saved = await timeline.setArchived(
            true, uid: "a", using: underA, baseURL: Stub.baseURL
        )

        #expect(!saved, "a save that landed nowhere did not succeed")
        #expect(timeline.memos.first?.content == "hello", "and nothing of it was applied")
        #expect(timeline.lastError == nil, "nor was an error written for it")
    }

    /// And the other half of B3: a store whose session has been withdrawn entirely terminates,
    /// rather than reading "no session" as "still current".
    @Test("a retry after the session was withdrawn applies nothing")
    func aRetryAfterWithdrawalAppliesNothing() async throws {
        let session = await signedIn(
            handler: { _, _, operation in
                guard operation != whoamiOperation else { return Stub.json(Stub.user) }
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            }
        )
        let timeline = TimelineStore()
        timeline.reports(to: session)
        let held = try #require(session.activeHandle)

        await session.signOutWithoutRevoking()
        #expect(session.activeHandle == nil, "the premise: the session holds no client at all")

        await timeline.refresh(using: held, baseURL: Stub.baseURL)

        #expect(timeline.memos.isEmpty)
    }
}

/// A download that waits at the SEND POINT, so a test can end the session while the request is on
/// its way to the wire.
///
/// It asks the authority where the real transport asks it — on the executor that sends, with
/// nothing between the answer and the send — and it counts only what got past that question, so
/// "no request was sent" stays a fact rather than an inference from an error.
final class HeldDownloadTransport: MediaDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let entered = LockedValue<Bool>(false)
    let release = LockedValue<Bool>(false)

    var sends: Int { lock.withLock { count } }

    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        entered.set(true)
        while !release.get() { await Task.yield() }
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        lock.withLock { count += 1 }
        return (
            URL(filePath: "/dev/null"),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

/// Counts what actually left for the network, so "no request was sent" is a fact rather than an
/// inference from an error.
final class RecordingDownloadTransport: MediaDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var sends: Int { lock.withLock { count } }

    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        lock.withLock { count += 1 }
        return (
            URL(filePath: "/dev/null"),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
    }
}
