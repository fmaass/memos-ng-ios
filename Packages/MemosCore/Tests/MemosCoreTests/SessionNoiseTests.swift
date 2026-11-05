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

    @Test("the library and its tag menu follow the same rule")
    func theLibraryFollowsTheSameRule() async {
        let session = await signedIn(
            handler: handler { throw URLError(.notConnectedToInternet) }
        )
        let library = MediaLibraryStore()
        let tags = LibraryTagStore()
        library.reports(to: session)
        tags.reports(to: session)

        await library.refresh(using: session.activeHandle!, baseURL: Stub.baseURL)
        await tags.load(for: .all, using: session.activeHandle!)

        #expect(library.lastError == nil)
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

    /// The library page both tests below serve. It must be one the list decoder accepts, or the
    /// ended-session test's empty library is a decoding failure and not the fence.
    private nonisolated static var libraryPage: String {
        "[\(Stub.libraryItem(uid: "x"))]"
    }

    /// The control on the ended-session test: the SAME page, answered to the session that asked
    /// for it, fills the library. Without it, that test's `library.items.isEmpty` could be the
    /// decoder refusing the body with the fence removed.
    @Test("the page an ended session is refused is one a live session applies")
    func theLibraryPageDecodesUnderALiveSession() async throws {
        let session = await signedIn(handler: handler { Stub.json(Self.libraryPage) })
        let library = MediaLibraryStore()
        library.reports(to: session)
        let live = try #require(session.activeHandle)

        await library.refresh(using: live, baseURL: Stub.baseURL)

        #expect(library.lastError == nil, "the page was refused before any fence was asked")
        #expect(library.items.map(\.attachment.uid) == ["x"])
    }

    /// B3, per store: an answer issued under one incarnation and applied under the next changes
    /// nothing at all — not the rows, not the pictures.
    @Test("a page answered for a session that has ended is not applied")
    func aPageFromAnEndedSessionIsNotApplied() async throws {
        // Each store gets the payload ITS decoder accepts. One list for all three would fail the
        // library and tag decoders before their guards were ever reached, and the assertions
        // below would then pass with the guards removed.
        let session = await signedIn(
            handler: { _, _, operation in
                switch operation {
                case whoamiOperation: return Stub.json(Stub.user)
                case "list_attachments_api_attachments_get":
                    return Stub.json(Self.libraryPage)
                case "attachment_tags_api_attachments_tags_get":
                    return Stub.json(#"[{"name":"travel","count":3}]"#)
                default: return Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
                }
            }
        )
        let timeline = TimelineStore()
        let library = MediaLibraryStore()
        let tags = LibraryTagStore()
        timeline.reports(to: session)
        library.reports(to: session)
        tags.reports(to: session)
        let underA = try #require(session.activeHandle)

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")

        await timeline.refresh(using: underA, baseURL: Stub.baseURL)
        await library.refresh(using: underA, baseURL: Stub.baseURL)
        await tags.load(for: .all, using: underA)

        #expect(timeline.memos.isEmpty, "a page for a session that has ended is not a list")
        #expect(library.items.isEmpty, "and neither is a page of attachments")
        #expect(tags.tags.isEmpty, "nor a tag list")
        #expect(tags.loadedFilter == nil)
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
        let timeline = TimelineStore(onUnauthorized: { [session] refusal in
            await session.handle(refusal)
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

    /// F2. A renewal replaces the token and destroys its predecessor WITHOUT ending the session,
    /// so the incarnation the authority answers on does not move — correctly, because nothing
    /// ended. What that means for a lane holding a token it read before suspending is that the
    /// fence clears it to send the one the server has just destroyed. The token has to be resolved
    /// where the verdict is: at the send point, from the authority.
    @Test("a download held across a renewal presents the successor, not the token it set out with")
    func aHeldDownloadPresentsTheRenewedToken() async {
        let session = await signedIn(
            handler: { _, _, operation in
                switch operation {
                case whoamiOperation: return Stub.json(Stub.user)
                case "native_renew_api_auth_native_renew_post":
                    return Stub.json(Stub.exchange(token: "memos_pat_next"))
                default: return Stub.json(Stub.nativeToken(name: "Fabian's iPhone"))
                }
            }
        )
        let transport = HeldDownloadTransport()

        let download = Task { try await session.download(original(), transport: transport) }
        for _ in 0..<200 where !transport.entered.get() { await Task.yield() }
        #expect(transport.entered.get(), "the download never reached the send point")

        let outcome = await session.renewDeviceToken()
        #expect(outcome == .renewed, "the premise: the device really did rotate its token")
        transport.release.set(true)
        _ = try? await download.value

        #expect(transport.sends == 1, "the session did not end, so the download had to go out")
        #expect(
            transport.presented.get() == "Bearer memos_pat_next",
            """
            the request carried a token the server destroyed in the same statement that minted \
            the one this device is now holding
            """
        )
    }

    /// G1. The other half of the same rule, and the direction that costs more. The send is made
    /// with the RENEWED token — that much F2 fixed — so a 401 answered to it is a refusal of the
    /// credential this device is holding, and it ends the session. Judged by the epoch read BEFORE
    /// the send it looks like a refusal of a token already replaced, and the session is kept: the
    /// device carries on believing it is signed in with a credential the server has rejected.
    @Test("a 401 answered to the renewed token ends the session, and is not read as a stale one")
    func aRefusalOfTheRenewedTokenEndsTheSession() async {
        let session = await signedIn(
            handler: { _, _, operation in
                switch operation {
                case whoamiOperation: return Stub.json(Stub.user)
                case "native_renew_api_auth_native_renew_post":
                    return Stub.json(Stub.exchange(token: "memos_pat_next"))
                default: return Stub.json(Stub.nativeToken(name: "Fabian's iPhone"))
                }
            }
        )
        let transport = HeldDownloadTransport(status: 401)

        let download = Task { try await session.download(original(), transport: transport) }
        for _ in 0..<200 where !transport.entered.get() { await Task.yield() }
        #expect(transport.entered.get(), "the download never reached the send point")

        #expect(await session.renewDeviceToken() == .renewed, "the premise: the token rotated")
        transport.release.set(true)
        // Under the SUCCESSOR's generation, which is the whole point: the send presented
        // `memos_pat_next`, so the refusal names generation 1 and the funnel ends the session.
        let refused = OriginalMediaError.credentialRefused(CredentialRefusal(issuedUnder: 1))
        await #expect(throws: refused) {
            try await download.value
        }

        #expect(
            transport.presented.get() == "Bearer memos_pat_next",
            "the premise: the request that earned the 401 carried the successor"
        )
        #expect(
            session.state == .signedOut,
            "a refusal of the token this device is holding was read as one about a replaced token"
        )
    }

    /// The OTHER guard on the same lane, kept as its own test rather than folded into the one
    /// above: with nobody signed in there is no credential to offer, so the store refuses before it
    /// builds a request at all. Named for what it is, and asserted on the specific error, so it
    /// cannot be mistaken for evidence about the authority.
    @Test("a download with nobody signed in is refused before a request is built")
    func aDownloadWithNoCredentialIsRefused() async throws {
        let session = await signedIn(handler: { _, _, _ in Stub.json(Stub.user) })
        // The REAL download transport, answered below `URLSession` by a route on the host the
        // attachment names — so "no request was sent" is counted where a request would arrive.
        let route = try GuardStubProtocol.open(host: "memos.example.invalid")
        defer { GuardStubProtocol.close(route) }
        let transport = MediaSession(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil),
            protocolClasses: GuardStubProtocol.only
        )
        defer { transport.session.invalidateAndCancel() }
        await session.signOutWithoutRevoking()

        await #expect(throws: OriginalMediaError.notSignedIn) {
            try await session.download(original(), transport: transport)
        }

        #expect(route.count == 0, "a request went out for a session nobody is signed in to")
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
///
/// Its guard is a COPY of `MediaSession.download`'s, kept because the `URLProtocol` seam cannot
/// cover what this double is for: the hold sits BEFORE the guard, in the window between the
/// caller's fences and the send, and a stub below `URLSession` is only reached after the guard has
/// answered. The production guard itself is pinned by `SendGuardSeamTests`
/// (`downloadGuardIsTheRealOne`), which drives the real transport.
final class HeldDownloadTransport: MediaDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let status: Int

    init(status: Int = 200) { self.status = status }
    let entered = LockedValue<Bool>(false)
    let release = LockedValue<Bool>(false)
    /// What the request carried at the moment it was sent — the whole point of holding it here.
    let presented = LockedValue<String?>(nil)

    var sends: Int { lock.withLock { count } }

    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        entered.set(true)
        while !release.get() { await Task.yield() }
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        // The production transport puts the credential on HERE, from the authority, and so does
        // this: a double that presented what the caller wrote down before suspending could not
        // tell a fenced lane from an unfenced one.
        let sending = authority.presenting(request)
        presented.set(sending.value(forHTTPHeaderField: "Authorization"))
        lock.withLock { count += 1 }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("original".utf8).write(to: file)
        return (
            file,
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
        )
    }
}
