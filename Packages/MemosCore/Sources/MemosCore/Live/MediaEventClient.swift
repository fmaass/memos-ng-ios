import Foundation
import MemosAPI

/// Where the stream connects and what it presents.
///
/// Read fresh for every connection rather than captured once: a reconnect that outlives an account
/// switch must not carry the previous account's server or token, and the token can be revoked
/// while the stream is open. The same reason `BearerAuthMiddleware` takes a closure instead of a
/// string.
///
/// Not `Codable`, and `description` is overridden, for the reason `OutboxCredentials` gives: an
/// interpolated credential in a log is a leaked credential.
public struct MediaEventCredentials: Sendable, Equatable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

extension MediaEventCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "MediaEventCredentials(server: \(baseURL.absoluteString))"
    }

    public var debugDescription: String { description }
}

/// Why the channel stopped for good. Every case is terminal: nothing here is fixed by trying
/// again, so a client that retried would only be hammering a server that already answered.
public enum MediaEventStopReason: Sendable, Equatable {
    /// There is no credential to present. Nobody is signed in, so there is nothing to stream.
    case signedOut
    /// The server refused the credential. The session ends on a 401 everywhere else in this app;
    /// reconnecting with the same dead token is the one thing that must not happen here.
    case unauthorized
    /// The device is now signed in as someone else. See the fence in `MediaEventClient.run`.
    case identityChanged
    /// The consumer went away — the ordinary end of a channel.
    case cancelled
}

/// What the channel is doing, for a caller that wants to show it.
public enum MediaEventConnectionState: Sendable, Equatable {
    case connecting(attempt: Int)
    case open
    /// Reconnecting in this many seconds.
    case waiting(TimeInterval)
    case stopped(MediaEventStopReason)
}

/// Everything the channel reports, in the order it happens: state changes and events on one
/// stream, so a consumer cannot see an event from a connection whose `open` it has not seen yet.
public enum MediaEventStreamItem: Sendable, Equatable {
    case state(MediaEventConnectionState)
    case event(MediaEvent)
}

/// The live media channel: `GET /api/events`, parsed, decoded, and reconnected.
///
/// ## What the server does, and what that forces
///
/// The stream is a POLL that ENDS ITSELF. `media_event_stream` breaks out of its loop as soon as
/// nothing is in flight (memos-ng `app/routers/assets.py:763-764`, and every other line number
/// in this file, as of a1d493c), so a clean end-of-stream is the NORMAL outcome — including
/// immediately, when a connection opens with no work outstanding.
/// That makes a naive "reconnect as soon as it closes" loop a hot loop against production, which
/// is why a clean end waits `idleReconnectDelay` and does not touch the failure backoff, and why
/// the backoff attempt counter resets whenever a connection opened.
///
/// The cheapest way to hold an idle connection open is not to hold one: a consumer that stops
/// consuming cancels the channel, which cancels the connection. That is the same shape the SPA
/// uses, where the channel is open only while the cache holds something in flight
/// (`frontend/src/lib/sseLifecycle.ts`).
///
/// ## The fence
///
/// `generation` is read once when the channel starts and again before anything is delivered and
/// before every reconnect. A stream started under account A is dead the moment the device becomes
/// account B — an attachment uid means nothing across accounts, so an event delivered across that
/// line would patch B's timeline with A's photo. It is the same clock `MediaIdentity` gives the
/// image cache, rotated at the same two moments by `SessionStore`.
public final class MediaEventClient: Sendable {
    /// The path the events route is mounted at (memos-ng `app/routers/assets.py:822-823`).
    public static let path = "api/events"

    private let credentials: @Sendable () async -> MediaEventCredentials?
    private let generation: @Sendable () async -> Int
    private let backoff: SSEBackoff
    private let idleReconnectDelay: TimeInterval
    private let transport: any SSEConnecting
    private let sleeper: any SSESleeper

    public init(
        credentials: @escaping @Sendable () async -> MediaEventCredentials?,
        generation: @escaping @Sendable () async -> Int,
        backoff: SSEBackoff = SSEBackoff(),
        idleReconnectDelay: TimeInterval = 15,
        transport: any SSEConnecting = URLSessionSSETransport(),
        sleeper: any SSESleeper = ContinuousClockSleeper()
    ) {
        self.credentials = credentials
        self.generation = generation
        self.backoff = backoff
        self.idleReconnectDelay = idleReconnectDelay
        self.transport = transport
        self.sleeper = sleeper
    }

    /// The channel the app composes: the device credential out of the keychain — the same two
    /// items `DeviceOutboxCredentials` reads — and the media identity as the fence.
    @MainActor
    public static func device(
        credentials store: any CredentialStore = DeviceCredentials.keychain(),
        identity: MediaIdentity = .shared,
        backoff: SSEBackoff = SSEBackoff(),
        idleReconnectDelay: TimeInterval = 15,
        transport: any SSEConnecting = URLSessionSSETransport(),
        sleeper: any SSESleeper = ContinuousClockSleeper()
    ) -> MediaEventClient {
        MediaEventClient(
            credentials: {
                guard let token = (try? store.string(for: SessionStore.tokenAccount)) ?? nil,
                    !token.isEmpty,
                    let address = (try? store.string(for: SessionStore.serverAccount)) ?? nil,
                    let configuration = ServerConfiguration(serverAddress: address)
                else { return nil }
                return MediaEventCredentials(baseURL: configuration.baseURL, token: token)
            },
            generation: { await identity.generation },
            backoff: backoff,
            idleReconnectDelay: idleReconnectDelay,
            transport: transport,
            sleeper: sleeper
        )
    }

    /// Opens the channel. Consuming the stream runs it; abandoning or cancelling the consuming
    /// task closes the connection and ends the channel — that IS the shutdown.
    public func stream() -> AsyncStream<MediaEventStreamItem> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { await self.run(into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(into continuation: AsyncStream<MediaEventStreamItem>.Continuation) async {
        let fence = await generation()
        var attempt = 0
        var lastEventID: String?
        var serverRetryHint: TimeInterval?

        while !Task.isCancelled {
            guard await generation() == fence else {
                stop(.identityChanged, into: continuation)
                return
            }
            attempt += 1
            continuation.yield(.state(.connecting(attempt: attempt)))
            let result = await connect(
                fence: fence,
                lastEventID: lastEventID,
                serverRetryHint: serverRetryHint,
                into: continuation
            )
            lastEventID = result.lastEventID
            serverRetryHint = result.serverRetryHint

            let delay: TimeInterval
            switch result.outcome {
            case .signedOut:
                stop(.signedOut, into: continuation)
                return
            case .unauthorized:
                stop(.unauthorized, into: continuation)
                return
            case .identityChanged:
                stop(.identityChanged, into: continuation)
                return
            case .cancelled:
                stop(.cancelled, into: continuation)
                return
            case .ended:
                // The server closes when nothing is in flight. That is not a failure and must not
                // escalate the backoff — the next connection is a fresh first attempt.
                attempt = 0
                delay = idleReconnectDelay
            case .failed(let opened):
                if opened { attempt = 0 }
                delay = backoff.delay(forAttempt: max(attempt, 1), serverHint: serverRetryHint)
            }

            continuation.yield(.state(.waiting(delay)))
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                break
            }
        }
        stop(.cancelled, into: continuation)
    }

    private func connect(
        fence: Int,
        lastEventID: String?,
        serverRetryHint: TimeInterval?,
        into continuation: AsyncStream<MediaEventStreamItem>.Continuation
    ) async -> ConnectionResult {
        // What the connection learned, carried out of every exit: a `retry:` or an `id:` is worth
        // exactly as much on the path where the connection then died.
        var lastEventID = lastEventID
        var serverRetryHint = serverRetryHint
        func result(_ outcome: ConnectionOutcome) -> ConnectionResult {
            ConnectionResult(
                outcome: outcome,
                lastEventID: lastEventID,
                serverRetryHint: serverRetryHint
            )
        }

        guard let credentials = await credentials() else { return result(.signedOut) }
        var request = URLRequest(url: credentials.baseURL.appending(path: Self.path))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        // Sent only once the stream has actually declared an id. This server declares none today
        // (memos-ng `app/routers/assets.py:721-722`), so the header stays absent rather than
        // asserting a resumption point that does not exist.
        if let lastEventID {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }

        var opened = false
        do {
            let connection = try await transport.connect(request)
            switch connection.statusCode {
            case 200:
                break
            case 401, 403:
                MemosLog.media.info("GET /api/events refused the credential")
                return result(.unauthorized)
            default:
                MemosLog.media.info(
                    "GET /api/events -> \(connection.statusCode, privacy: .public)"
                )
                return result(.failed(opened: false))
            }
            opened = true
            continuation.yield(.state(.open))

            var parser = SSEParser(lastEventID: lastEventID)
            for try await chunk in connection.body {
                let frames = parser.consume(chunk)
                lastEventID = parser.lastEventID
                serverRetryHint = parser.reconnectionTime
                if Task.isCancelled { return result(.cancelled) }
                // The second gate: whatever this connection was opened for, it is not this
                // device's business any more once the account has moved.
                guard await generation() == fence else { return result(.identityChanged) }
                for frame in frames {
                    do {
                        let event = try MediaEvent.decode(frame)
                        continuation.yield(.event(event))
                    } catch {
                        MemosLog.media.info(
                            "media event skipped: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
            }
            return result(.ended)
        } catch is CancellationError {
            return result(.cancelled)
        } catch {
            if Task.isCancelled { return result(.cancelled) }
            MemosLog.media.info(
                "media event stream dropped: \(error.localizedDescription, privacy: .public)"
            )
            return result(.failed(opened: opened))
        }
    }

    private func stop(
        _ reason: MediaEventStopReason,
        into continuation: AsyncStream<MediaEventStreamItem>.Continuation
    ) {
        continuation.yield(.state(.stopped(reason)))
        continuation.finish()
    }

    /// What one connection ended with, and what it left behind for the next one.
    private struct ConnectionResult: Sendable {
        var outcome: ConnectionOutcome
        var lastEventID: String?
        var serverRetryHint: TimeInterval?
    }

    /// How one connection ended, and — for a failure — whether it had opened first, which
    /// decides between a fresh backoff and the next step of the current one.
    private enum ConnectionOutcome: Sendable, Equatable {
        case ended
        case failed(opened: Bool)
        case unauthorized
        case signedOut
        case identityChanged
        case cancelled
    }
}
