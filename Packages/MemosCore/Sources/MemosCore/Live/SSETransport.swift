import Foundation

/// One open event stream: what the server answered, and the bytes it is sending.
///
/// The body is an `AsyncThrowingStream` of byte CHUNKS rather than of parsed lines, because the
/// parser is the thing under test and it has to be handed the same ragged boundaries the network
/// produces. A concrete stream type rather than an `AsyncSequence` existential keeps the whole
/// thing `Sendable` with nothing to reason about.
public struct SSEConnection: Sendable {
    public let statusCode: Int
    public let body: AsyncThrowingStream<[UInt8], any Error>

    public init(statusCode: Int, body: AsyncThrowingStream<[UInt8], any Error>) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// What opens an event stream. One method, so a test can script a server that fails three times
/// and then answers, and the client's real reconnect loop is what runs against it.
public protocol SSEConnecting: Sendable {
    func connect(_ request: URLRequest) async throws -> SSEConnection
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
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }

    public func connect(_ request: URLRequest) async throws -> SSEConnection {
        let (bytes, response) = try await session.bytes(for: request)
        // A non-HTTP response has no status to read. Zero is not 200, so it takes the retry path
        // rather than being mistaken for an open stream.
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
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
        return SSEConnection(statusCode: statusCode, body: body)
    }
}
