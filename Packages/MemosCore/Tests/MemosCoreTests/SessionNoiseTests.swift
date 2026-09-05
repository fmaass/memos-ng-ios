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

        await timeline.refresh(using: session.api!, baseURL: Stub.baseURL)

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

        await timeline.refresh(using: session.api!, baseURL: Stub.baseURL)

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

        await library.refresh(using: session.api!, baseURL: Stub.baseURL)
        await heatmap.load(using: session.api!)
        await tags.load(using: session.api!)

        #expect(library.lastError == nil)
        #expect(heatmap.lastError == nil)
        #expect(tags.lastError == nil)
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
    }

    /// R5. A store's own guards are local attempt counters: they can say a later load overtook
    /// this one, and they cannot say WHOSE session asked. Unfenced, a page issued under A that
    /// fails after B is verified puts B's confirmed session into `.unverified`.
    @Test("a failure issued under a session that has ended is not the new one's")
    func aFailureFromAnEndedSessionIsIgnored() async {
        let session = await signedIn(handler: handler { Stub.json(Stub.user) })
        let issuedUnderA = session.handle?.generation
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        #expect(session.verification == .verified)

        session.noteTransportFailure(.offline, issuedUnder: issuedUnderA ?? -1)

        #expect(
            session.verification == .verified,
            "A's failed request is not evidence about the session running now"
        )

        // The positive control: the same report, from the session that IS running.
        session.noteTransportFailure(.offline, issuedUnder: session.handle?.generation ?? -1)
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
    }
}
