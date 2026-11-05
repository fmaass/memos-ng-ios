import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

extension Stub {
    /// What memos-ng answers since v2.1.0 when it cannot get a database connection in time: a 503
    /// with a JSON `detail` and a `Retry-After`, now named in the contract on almost every route.
    static func databaseBusy() -> (HTTPResponse, HTTPBody?) {
        var answer = json(#"{"detail":"database_busy"}"#, status: .serviceUnavailable)
        answer.0.headerFields[HTTPField.Name("Retry-After")!] = "1"
        return answer
    }

    /// A 503 or 429 as a reverse proxy writes it: an HTML page under an HTML content type.
    static func proxyPage(_ status: HTTPResponse.Status) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "text/html"
        return (response, HTTPBody("<html><body>Service Unavailable</body></html>"))
    }
}

/// The v2.1.0 contract documents a 503 that every route below used to meet as an undocumented
/// status. Each case holds one switch to the error the SAME status
/// produced when it arrived as `.undocumented`: the re-vendor named the status, it did not change
/// what the app does with it.
@MainActor
@Suite("A newly documented 503 or 429 is answered as its undocumented self was")
struct ServiceUnavailableParityTests {
    private static let unavailable = APIError.server(status: 503)

    private static func busy() -> any APIProtocol {
        Stub.client { _, _, _ in Stub.databaseBusy() }
    }

    // MARK: - library, places, memo list

    @Test("a 503 to the buckets read is thrown as its undocumented 503 was")
    func buckets() async {
        let request = LibraryBucketRequest(
            size: .month, filter: .all, tag: nil, mine: false, visibility: .any,
            timeZoneIdentifier: "UTC"
        )
        await #expect(throws: Self.unavailable) {
            try await LibraryBucketStore.buckets(
                Self.busy(), request: request, baseURL: Stub.baseURL
            )
        }
    }

    @Test("a 503 to the tags read is thrown as its undocumented 503 was")
    func tags() async {
        await #expect(throws: Self.unavailable) {
            try await LibraryTagStore.tags(Self.busy(), filter: .all)
        }
    }

    @Test("a 503 to the markers read is thrown as its undocumented 503 was")
    func markers() async {
        await #expect(throws: Self.unavailable) {
            try await PlacesStore.markers(Self.busy(), baseURL: Stub.baseURL)
        }
    }

    @Test("a 503 to an attachments page is thrown as its undocumented 503 was")
    func attachmentsPage() async {
        await #expect(throws: Self.unavailable) {
            try await MediaLibraryStore.page(
                Self.busy(), filter: .all, order: .newestFirst, tag: nil, cursor: nil,
                limit: 10, baseURL: Stub.baseURL
            )
        }
    }

    @Test("a 503 to a memo page is thrown as its undocumented 503 was")
    func memosPage() async {
        await #expect(throws: Self.unavailable) {
            try await TimelineStore.page(
                Self.busy(), query: MemoQuery(), calendar: Calendar(identifier: .gregorian),
                cursor: nil, limit: 10, baseURL: Stub.baseURL
            )
        }
    }

    // MARK: - token management

    /// Not `RouteMissing`: only a 404 says the server predates the route.
    @Test("a 503 to the manage grant is the sign-in failure its undocumented 503 was")
    func manageGrant() async {
        await #expect(throws: NativeLoginError.api(Self.unavailable)) {
            try await ManageTokensStore.mintGrant(Self.busy(), code: "c", verifier: "v")
        }
    }

    @Test("a 503 to the token list is thrown as its undocumented 503 was")
    func listTokens() async {
        await #expect(throws: Self.unavailable) {
            try await ManageTokensStore.list(Self.busy())
        }
    }

    @Test("a 503 to a token create is thrown as its undocumented 503 was")
    func createToken() async {
        await #expect(throws: Self.unavailable) {
            try await ManageTokensStore.create(Self.busy(), name: "n", expiresInDays: nil)
        }
    }

    @Test("a 503 to a token revoke is thrown as its undocumented 503 was")
    func revokeToken() async {
        await #expect(throws: Self.unavailable) {
            try await ManageTokensStore.revoke(Self.busy(), id: 1)
        }
    }

    // MARK: - the session's own routes

    @Test("a 503 to the sign-in exchange is the sign-in failure its undocumented 503 was")
    func exchange() async {
        await #expect(throws: NativeLoginError.api(Self.unavailable)) {
            try await SessionStore.exchange(Self.busy(), code: "c", verifier: "v")
        }
    }

    @Test("a 503 to the device token read is thrown as its undocumented 503 was")
    func deviceToken() async {
        await #expect(throws: Self.unavailable) {
            try await SessionStore.deviceToken(Self.busy())
        }
    }

    @Test("a 503 to the device token rename is thrown as its undocumented 503 was")
    func renameDeviceToken() async {
        await #expect(throws: Self.unavailable) {
            try await SessionStore.renameDeviceToken(Self.busy(), to: "phone")
        }
    }

    /// The detail a 400 is read for, carried by a 503, is still a 503: the code is read only off
    /// the status that defines it.
    @Test("a 503 to a renewal is thrown as its undocumented 503 was, whatever its detail says")
    func renew() async {
        let client = Stub.client { _, _, _ in
            Stub.json(#"{"detail":"token_not_renewable"}"#, status: .serviceUnavailable)
        }
        await #expect(throws: Self.unavailable) {
            try await SessionStore.renew(client)
        }
    }

    @Test("a 503 to the settings read is thrown as its undocumented 503 was")
    func settings() async {
        await #expect(throws: Self.unavailable) {
            try await SessionStore.settings(Self.busy())
        }
    }

    @Test("a 503 to a settings change is thrown as its undocumented 503 was")
    func updateSettings() async {
        await #expect(throws: Self.unavailable) {
            try await SessionStore.updateSettings(Self.busy(), defaultVisibility: .private)
        }
    }

    @Test("a 503 to whoami is thrown as its undocumented 503 was")
    func whoami() async {
        await #expect(throws: Self.unavailable) {
            try await SessionStore.whoami(Self.busy())
        }
    }

    // MARK: - an answer whose body the client cannot read

    /// The generated client decodes a documented answer's body inside the call, so without
    /// `BusyAnswerMiddleware` each of these would throw instead of arriving as its status.
    @Test("a proxy's HTML 503 is thrown as the undocumented 503 was")
    func proxyPageUnavailable() async {
        let client = Stub.client { _, _, _ in Stub.proxyPage(.serviceUnavailable) }
        await #expect(throws: Self.unavailable) {
            try await ManageTokensStore.list(client)
        }
    }

    @Test("a bodyless 503 is thrown as the undocumented 503 was")
    func bodylessUnavailable() async {
        let client = Stub.client { _, _, _ in Stub.empty(.serviceUnavailable) }
        await #expect(throws: Self.unavailable) {
            try await SessionStore.whoami(client)
        }
    }

    /// JSON, but not the object the contract names: the quoted word is the whole body.
    @Test("a 503 whose JSON body is a bare string is thrown as the undocumented 503 was")
    func bareStringUnavailable() async {
        let client = Stub.client { _, _, _ in
            Stub.json(#""database_busy""#, status: .serviceUnavailable)
        }
        await #expect(throws: Self.unavailable) {
            try await LibraryTagStore.tags(client, filter: .all)
        }
    }

    /// An object, but with a detail the contract types as a string written as a list.
    @Test("a 503 whose detail is not a string is thrown as the undocumented 503 was")
    func listDetailUnavailable() async {
        let client = Stub.client { _, _, _ in
            Stub.json(#"{"detail":[{"msg":"busy"}]}"#, status: .serviceUnavailable)
        }
        await #expect(throws: Self.unavailable) {
            try await SessionStore.settings(client)
        }
    }

    // MARK: - decided by the status, not the body

    /// The first of `work` and a deadline, so a call that never returns fails the case instead of
    /// holding the run: the loser is cancelled.
    private static func firstOf(
        deadline: Duration,
        _ work: @escaping @Sendable () async -> String
    ) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return "still pending after \(deadline)"
            }
            let first = await group.next() ?? "nothing finished"
            group.cancelAll()
            return first
        }
    }

    /// Headers at once, then a body that does not arrive until the case releases it — a proxy that
    /// stalls. The status decided an undocumented 503 at once, so it must decide this one before a
    /// single byte of the body is sent, rather than whenever the body ends.
    @Test("a 503 whose body stalls is answered from its status before the body arrives")
    func stalledBodyAnswersAtOnce() async {
        let (bytes, feed) = AsyncStream<ArraySlice<UInt8>>.makeStream()
        defer { feed.finish() }
        let client = Stub.client { _, _, _ in
            var response = HTTPResponse(status: .serviceUnavailable)
            response.headerFields[.contentType] = "text/html"
            return (response, HTTPBody(bytes, length: .unknown, iterationBehavior: .single))
        }

        let answer = await Self.firstOf(deadline: .seconds(10)) {
            do {
                _ = try await SessionStore.settings(client)
                return "accepted"
            } catch {
                return "\(error)"
            }
        }

        #expect(answer == "\(Self.unavailable)")
    }

    @Test("the management client built by the factory answers an HTML 503 from its status")
    func grantClientCarriesTheMiddleware() async {
        let grant = ManagementGrant()
        grant.hold("mg_abc", until: Date(timeIntervalSince1970: 4_000_000_000))
        let client = Stub.client(grant: grant) { _, _, _ in
            Stub.proxyPage(.serviceUnavailable)
        }
        await #expect(throws: Self.unavailable) {
            try await ManageTokensStore.list(client)
        }
    }
}
