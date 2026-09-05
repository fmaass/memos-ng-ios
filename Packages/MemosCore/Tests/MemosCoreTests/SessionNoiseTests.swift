import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
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
        let session = await signedIn(
            handler: { _, _, operation in
                guard operation != whoamiOperation else { return Stub.json(Stub.user) }
                return Stub.json(Stub.memoList(["a", "b"], nextCursor: nil))
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
        #expect(library.items.isEmpty)
        #expect(!heatmap.hasLoaded, "and it is not an ANSWER either")
        #expect(!tags.hasLoaded)
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
