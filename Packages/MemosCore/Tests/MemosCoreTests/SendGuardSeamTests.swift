import Foundation
import MemosOutbox
import Testing

@testable import MemosCore

/// A scripted server for the REAL send paths, installed below `URLSession` rather than in place of
/// the transport — so what a test drives is the production `fetch`, `download` and `connect`, send
/// guard and all, with no network: a session built with this as its only protocol class has no
/// HTTP stack to fall through to.
///
/// `URLProtocol` is class-registered, so the class itself is shared by every test in the process.
/// Parallel safety is by ROUTING, not by serialising suites:
/// - the class is never registered globally (`URLProtocol.registerClass`); it is named only in the
///   `protocolClasses` of a session a test builds for itself, so no other session ever reaches it;
/// - each test opens a route under a HOST of its own and closes it in `defer`; what a request is
///   answered with, and where it is counted, is looked up by the host it names;
/// - opening a host that is already open is refused, so two tests can never share a counter
///   silently — and a request for a host with no route fails with `URLError(.unsupportedURL)`.
final class GuardStubProtocol: URLProtocol {
    /// One test's server: what it answers, and every request that reached it.
    final class Route: @unchecked Sendable {
        let host: String
        let status: Int
        let body: Data
        private let onRequest: @Sendable (Int) -> Void
        private let lock = NSLock()
        private var seen: [URLRequest] = []

        fileprivate init(
            host: String,
            status: Int,
            body: Data,
            onRequest: @escaping @Sendable (Int) -> Void
        ) {
            self.host = host
            self.status = status
            self.body = body
            self.onRequest = onRequest
        }

        /// Every request that reached the wire's stand-in, in order.
        var requests: [URLRequest] { lock.withLock { seen } }
        var count: Int { lock.withLock { seen.count } }

        func url(_ path: String) -> URL {
            URL(string: "https://\(host)\(path)")!
        }

        fileprivate func record(_ request: URLRequest) {
            let number = lock.withLock {
                seen.append(request)
                return seen.count
            }
            onRequest(number)
        }
    }

    struct HostAlreadyOpen: Error {
        let host: String
    }

    private final class Table: @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: Route] = [:]

        func insert(_ route: Route) throws {
            try lock.withLock {
                guard routes[route.host] == nil else { throw HostAlreadyOpen(host: route.host) }
                routes[route.host] = route
            }
        }

        func remove(_ route: Route) {
            lock.withLock {
                if routes[route.host] === route { routes[route.host] = nil }
            }
        }

        func route(for host: String) -> Route? { lock.withLock { routes[host] } }
    }

    private static let table = Table()

    /// Opens a route. The default host is unique to this call; a fixed one is for a test whose
    /// URL is built by the code under test and so cannot be chosen.
    /// - Parameter onRequest: run with the request's ordinal (1-based) after it is recorded and
    ///   before it is answered — the instant a request has left and its answer has not arrived.
    static func open(
        host: String = "\(UUID().uuidString.lowercased()).guard-stub.invalid",
        status: Int = 200,
        body: Data = Data("ok".utf8),
        onRequest: @escaping @Sendable (Int) -> Void = { _ in }
    ) throws -> Route {
        let route = Route(host: host, status: status, body: body, onRequest: onRequest)
        try table.insert(route)
        return route
    }

    static func close(_ route: Route) { table.remove(route) }

    /// A configuration's protocol list with this stub as the ONLY entry.
    static var only: [AnyClass] { [GuardStubProtocol.self] }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let route = Self.table.route(for: host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        route.record(request)
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: route.status,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !route.body.isEmpty { client?.urlProtocol(self, didLoad: route.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The three send guards that carry the session's send authority inside a REAL `URLSession`:
/// `MediaSession.fetch`, `MediaSession.download` and `URLSessionSSETransport.connect`. Every
/// authority-fence test elsewhere drives a double; these drive the production code through
/// `GuardStubProtocol`, and each one fails if its guard is removed.
///
/// Each test asks twice on ONE route: withdrawn, then held. The held half is the control — it is
/// what proves the route would have counted the withdrawn request had it been sent.
@Suite("The real send guards, driven below URLSession", .timeLimit(.minutes(1)))
struct SendGuardSeamTests {
    /// A cache nothing can be answered from, so every held request has to reach the stub.
    private static func emptyCache() -> URLCache {
        URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
    }

    @Test("a media fetch sends nothing under a withdrawn authority, and once under a held one")
    func fetchGuardIsTheRealOne() async throws {
        let route = try GuardStubProtocol.open()
        defer { GuardStubProtocol.close(route) }
        let cache = Self.emptyCache()
        let media = MediaSession(cache: cache, protocolClasses: GuardStubProtocol.only)
        defer { media.session.invalidateAndCancel() }
        #expect(media.session.configuration.urlCache === cache, "the production configuration")
        let request = URLRequest(url: route.url("/file/a1/thumb"))

        await #expect(throws: SendAuthorityWithdrawn.self) {
            _ = try await media.fetch(request, under: SendAuthority { false })
        }
        #expect(route.count == 0, "a request left under an authority that was withdrawn")

        let (data, response) = try await media.fetch(request, under: SendAuthority { true })
        #expect(route.count == 1, "the held fetch is the control: it has to reach the stub")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == Data("ok".utf8))
    }

    @Test("a media download sends nothing under a withdrawn authority, and once under a held one")
    func downloadGuardIsTheRealOne() async throws {
        let route = try GuardStubProtocol.open()
        defer { GuardStubProtocol.close(route) }
        let media = MediaSession(cache: Self.emptyCache(), protocolClasses: GuardStubProtocol.only)
        defer { media.session.invalidateAndCancel() }
        let request = URLRequest(url: route.url("/file/a1/original"))

        await #expect(throws: SendAuthorityWithdrawn.self) {
            _ = try await media.download(request, under: SendAuthority { false })
        }
        #expect(route.count == 0, "a request left under an authority that was withdrawn")

        let (_, response) = try await media.download(request, under: SendAuthority { true })
        #expect(route.count == 1, "the held download is the control: it has to reach the stub")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("the SSE connect sends nothing under a withdrawn authority, and once under a held one")
    func connectGuardIsTheRealOne() async throws {
        let route = try GuardStubProtocol.open(body: Data())
        defer { GuardStubProtocol.close(route) }
        let configuration = URLSessionSSETransport.makeConfiguration()
        configuration.protocolClasses = GuardStubProtocol.only
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionSSETransport(session: session)
        let request = URLRequest(url: route.url("/api/events"))

        await #expect(throws: SendAuthorityWithdrawn.self) {
            _ = try await transport.connect(request, under: SendAuthority { false })
        }
        #expect(route.count == 0, "a connect left under an authority that was withdrawn")

        let connection = try await transport.connect(request, under: SendAuthority { true })
        #expect(route.count == 1, "the held connect is the control: it has to reach the stub")
        #expect(connection.statusCode == 200)
    }

    // MARK: - the seam itself

    /// The seam may only ADD a way in: what production builds is what it built before — the same
    /// configuration values, and Foundation's own protocol classes, not a list a test chose.
    @Test("the production sessions keep their own configuration and Foundation's protocol classes")
    func productionConstructionIsUnchanged() {
        func names(_ classes: [AnyClass]?) -> [String] {
            (classes ?? []).map { String(describing: $0) }
        }
        let cache = Self.emptyCache()
        let media = MediaSession(cache: cache)
        defer { media.session.invalidateAndCancel() }
        let reference = MediaCache.makeSessionConfiguration(cache: cache)
        let built = media.session.configuration
        #expect(built.urlCache === cache)
        #expect(built.requestCachePolicy == reference.requestCachePolicy)
        #expect(built.timeoutIntervalForRequest == reference.timeoutIntervalForRequest)
        #expect(built.httpMaximumConnectionsPerHost == reference.httpMaximumConnectionsPerHost)
        #expect(!names(reference.protocolClasses).isEmpty, "the control: Foundation lists some")
        #expect(names(built.protocolClasses) == names(reference.protocolClasses))

        let live = URLSessionSSETransport.makeSession()
        defer { live.invalidateAndCancel() }
        let channel = live.configuration
        #expect(channel.urlCache == nil)
        #expect(channel.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(channel.timeoutIntervalForRequest == 90)
        #expect(channel.httpShouldSetCookies == false)
        #expect(channel.httpCookieAcceptPolicy == .never)
        #expect(
            names(channel.protocolClasses)
                == names(URLSessionConfiguration.default.protocolClasses)
        )
    }

    /// Routing is by the request's HOST, never by text anywhere in its URL: a route's name written
    /// into another request's path or query must not be answered or counted by that route.
    @Test("a route answers its own host only, not its name written into another URL")
    func aRouteAnswersItsOwnHostOnly() async throws {
        let route = try GuardStubProtocol.open()
        defer { GuardStubProtocol.close(route) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = GuardStubProtocol.only
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let elsewhere = "unrouted-\(UUID().uuidString.lowercased()).guard-stub.invalid"
        let stray = try #require(
            URL(string: "https://\(elsewhere)/\(route.host)?route=\(route.host)")
        )

        let refusal = await #expect(throws: URLError.self) {
            _ = try await session.data(from: stray)
        }
        // The stub's own refusal, not any URLError: a DNS or connection failure is one too, and
        // would mean the request fell through to the network.
        #expect(refusal?.code == .unsupportedURL, "the stub did not refuse the unrouted host")
        #expect(route.count == 0, "a request for another host was counted on this route")
    }

    /// Two tests can never share one route's counter: a host that is open is refused, not
    /// replaced — so a collision is a failure where it happens rather than a count off by one in
    /// whichever test ran second.
    @Test("one open host is one route: opening it again is refused")
    func anOpenHostIsNotOpenedTwice() throws {
        let first = try GuardStubProtocol.open()
        defer { GuardStubProtocol.close(first) }
        do {
            let second = try GuardStubProtocol.open(host: first.host)
            GuardStubProtocol.close(second)
            Issue.record("a second route opened on a host that was already open")
        } catch let refusal as GuardStubProtocol.HostAlreadyOpen {
            #expect(refusal.host == first.host)
        }
    }
}
