import Foundation
import MemosOutbox

/// One open event stream: what the server answered, and the bytes it is sending.
///
/// The body is an `AsyncThrowingStream` of byte CHUNKS rather than of parsed lines, because the
/// parser is the thing under test and it has to be handed the same ragged boundaries the network
/// produces. A concrete stream type rather than an `AsyncSequence` existential keeps the whole
/// thing `Sendable` with nothing to reason about.
public struct SSEConnection: Sendable {
    public let statusCode: Int
    /// The response's `Retry-After` in seconds, or `nil` when it sent none or sent a date. A date
    /// would have to be read against a clock this device does not share with the server, and a
    /// skewed clock turns "come back at noon" into "never" or "now"; the normal schedule is the
    /// better answer to a header that cannot be read honestly.
    public let retryAfter: TimeInterval?
    public let body: AsyncThrowingStream<[UInt8], any Error>

    public init(
        statusCode: Int,
        retryAfter: TimeInterval? = nil,
        body: AsyncThrowingStream<[UInt8], any Error>
    ) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.body = body
    }

    /// `Retry-After` as delay-seconds (RFC 9110 §10.2.3: one or more digits), and nothing else.
    static func retryAfterSeconds(_ value: String?) -> TimeInterval? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty,
            trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
            let seconds = Int(trimmed)
        else { return nil }
        return TimeInterval(seconds)
    }
}

/// What opens an event stream. One method, so a test can script a server that fails three times
/// and then answers, and the client's real reconnect loop is what runs against it.
public protocol SSEConnecting: Sendable {
    /// - Parameter authority: asked INSIDE this transport, immediately before the connect. The
    ///   client's loop reconnects on its own for as long as the app is running, so every
    ///   attempt — not only the first — is a send that has to prove it still belongs to a
    ///   session this device holds (`SendAuthority`).
    func connect(_ request: URLRequest, under authority: SendAuthority) async throws
        -> SSEConnection
}

/// The real transport: `URLSession.bytes(for:)`, chunked at line boundaries.
public struct URLSessionSSETransport: SSEConnecting {
    private let session: URLSession

    public init(session: URLSession = URLSessionSSETransport.makeSession()) {
        self.session = session
    }

    /// A session of this channel's own.
    ///
    /// It holds no cache (an event stream that could be answered from a cache would be answered
    /// with yesterday's progress) and sets no cookies: the bearer token is this client's whole
    /// credential, and a cookie jar shared with a web view is a second, weaker one nobody asked
    /// for. The request timeout is the gap between bytes, not the life of the stream — the server
    /// polls every 1.5 s while work is in flight (memos-ng `app/routers/assets.py:729`, as of
    /// a1d493c), so a silence far longer than that is a connection that has stopped answering.
    public static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    /// What `makeSession()` builds its session from. Separate so a test can hand the real
    /// transport this channel's own configuration with its protocol classes replaced by a
    /// scripted `URLProtocol`, and drive `connect` — send guard included — with no network.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    public func connect(_ request: URLRequest, under authority: SendAuthority) async throws
        -> SSEConnection
    {
        // On the executor that opens the stream, with nothing between the answer and the connect
        // — and the credential goes on HERE, for the reason `SendAuthority.presenting` gives: this
        // loop reconnects for as long as the screen is up, and a renewal can land in the hop
        // between the request being built and this line.
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        let (bytes, response) = try await session.bytes(for: authority.presenting(request))
        // A non-HTTP response has no status to read. Zero is not 200, so it takes the retry path
        // rather than being mistaken for an open stream.
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        let retryAfter = SSEConnection.retryAfterSeconds(
            http?.value(forHTTPHeaderField: "Retry-After")
        )
        let body = AsyncThrowingStream<[UInt8], any Error> { continuation in
            // `URLSession.AsyncBytes` is `Sendable` (iPhoneOS.sdk Foundation swiftinterface), and
            // this pump is the only reader of it; it is cancelled with the stream, which is what
            // makes cancelling the consumer close the connection.
            let pump = Task {
                var chunk: [UInt8] = []
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        // Flushed per line, so a complete event reaches the parser as soon as the
                        // server has written it — and bounded, so a server that never sends a
                        // newline cannot grow this without limit.
                        if byte == 0x0A || chunk.count >= 4096 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
        return SSEConnection(statusCode: statusCode, retryAfter: retryAfter, body: body)
    }
}
