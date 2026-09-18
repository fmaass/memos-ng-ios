import Foundation
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// Whether a request reached the server, decided from the error and only from the error.
///
/// The ticket's premise is a dropped VPN tunnel: the routing table stays satisfied and the socket
/// still goes nowhere. So a path hint may not change a single answer here, and the vector below
/// asserts that by classifying the same error twice — once with `_NSURLErrorNWPathKey` in its
/// `userInfo` and once without.
@Suite("Whether a request reached the server")
struct ServerReachabilityTests {
    private static let streamErrorCodeKey = "_kCFStreamErrorCodeKey"
    private static let pathKey = "_NSURLErrorNWPathKey"

    /// What the generated client actually hands a store: the transport's error, wrapped.
    private func wrapped(_ underlying: any Error) -> ClientError {
        ClientError(
            operationID: "list_memos_api_memos_get",
            operationInput: "the request this envelope may never spell out",
            causeDescription: "Transport threw an error.",
            underlyingError: underlying
        )
    }

    /// Every URL-loading vector is asserted bare AND through the envelope, so the chain walk is
    /// exercised by each of them rather than by one representative.
    private func expect(
        _ error: any Error,
        _ reachability: ServerReachability,
        _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            ServerReachability.classify(error) == reachability,
            comment,
            sourceLocation: sourceLocation
        )
        #expect(
            ServerReachability.classify(wrapped(error)) == reachability,
            comment,
            sourceLocation: sourceLocation
        )
    }

    @Test("a request that timed out never reached the server")
    func timedOut() {
        expect(URLError(.timedOut), .unreachable(.timedOut), "-1001")
    }

    @Test("a connection that could not be made never reached the server")
    func cannotConnect() {
        expect(URLError(.cannotConnectToHost), .unreachable(.cannotConnect), "-1004")
    }

    @Test("a connection lost mid-flight never got its answer")
    func connectionLost() {
        expect(URLError(.networkConnectionLost), .unreachable(.connectionLost), "-1005")
    }

    @Test("both name-resolution failures are the one thing the app has to say")
    func dnsFailures() {
        expect(URLError(.cannotFindHost), .unreachable(.dnsFailure), "-1003")
        expect(URLError(.dnsLookupFailed), .unreachable(.dnsFailure), "-1006")
    }

    @Test("a -1009 without the stream code is a phone with no network")
    func offline() {
        expect(URLError(.notConnectedToInternet), .unreachable(.offline), "-1009 alone")
    }

    @Test("a -1009 carrying ENETDOWN at connect is the Local Network denial")
    func localNetworkDenied() {
        expect(
            URLError(.notConnectedToInternet, userInfo: [Self.streamErrorCodeKey: 50]),
            .unreachable(.localNetworkDenied),
            "-1009 with _kCFStreamErrorCodeKey 50"
        )
    }

    /// The whole premise of the ticket: the routing table says satisfied and the tunnel is gone.
    @Test("a satisfied path hint changes nothing about what the socket did")
    func pathHintIsNotConsulted() {
        let hinted = URLError(.timedOut, userInfo: [Self.pathKey: "satisfied"])
        let bare = URLError(.timedOut)
        #expect(ServerReachability.classify(hinted) == ServerReachability.classify(bare))
        #expect(ServerReachability.classify(hinted) == .unreachable(.timedOut))
    }

    @Test("the two statuses this server never emits itself mean the proxy answered for it")
    func gatewayStatuses() {
        expect(APIError.server(status: 502), .unreachable(.gateway(status: 502)), "502")
        expect(APIError.server(status: 504), .unreachable(.gateway(status: 504)), "504")
    }

    @Test("every other status is the server answering, and keeps its own error card")
    func answeredStatuses() {
        expect(APIError.server(status: 503), .reached, "503 is this server's own answer")
        expect(APIError.server(status: 500), .reached, "500")
        expect(APIError.forbidden, .reached, "403")
        expect(APIError.notFound, .reached, "404")
        expect(APIError.server(status: 422), .reached, "422")
    }

    @Test("a body that would not decode is still an answer")
    func decodingIsAnAnswer() {
        let error = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "not json")
        )
        expect(error, .reached, "a decode failure means something answered")
    }

    @Test("a refusal is an auth outcome, whichever of its two shapes it arrives in")
    func refusalsAreNeverUnreachable() async {
        expect(APIError.unauthorized, .refused, "the bare-token client's 401")
        let installed = await Stub.uploadRefusalFromAnInstalledClient()
        guard let installed else {
            Issue.record("the installed client's 401 did not throw")
            return
        }
        #expect(ServerReachability.classify(installed) == .refused)
    }

    /// The app's own supersede coming back at it is not a verdict about the server, and the guard
    /// that keeps it out is `transportFailure`'s own — which is where it is asserted.
    @Test("this app's own cancellation is not reported as anything")
    func cancellationIsNotReported() {
        #expect(StoreFailure.transportFailure(CancellationError()) == nil)
        #expect(StoreFailure.transportFailure(wrapped(URLError(.cancelled))) == nil)
    }

    @Test("a refusal never reaches the transport fork")
    func refusalIsNotATransportFailure() {
        #expect(StoreFailure.transportFailure(APIError.unauthorized) == nil)
    }

    @Test("the transport fork hands on exactly what the classifier decided")
    func transportForkPassesTheReasonThrough() {
        #expect(StoreFailure.transportFailure(wrapped(URLError(.timedOut))) == .timedOut)
        #expect(StoreFailure.transportFailure(APIError.server(status: 502)) == .gateway(status: 502))
        #expect(StoreFailure.transportFailure(APIError.server(status: 503)) == nil)
    }
}
