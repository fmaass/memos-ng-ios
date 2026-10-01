import Foundation
import MemosAPI
import MemosOutbox

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
    /// ABSENT, and only absent: a store that could not ANSWER is a failed connection that retries,
    /// because the credential it would not hand over may be sitting there the whole time.
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

/// One event, stamped with the identity generation the connection that carried it was fenced to.
///
/// The stamp exists because a fence inside the channel cannot be sound on its own, however tightly
/// it is written: a delivered event sits in the stream's buffer and is consumed AFTER the check,
/// so the device can become another account in between and no amount of atomicity in the producer
/// closes that window. The question can only be answered where the answer is used, and
/// `MediaIdentity` rotates on the main actor — so a consumer that asks there is asking a clock
/// that cannot move underneath it.
public struct MediaEventEnvelope: Sendable, Equatable {
    /// Deliberately not `public`, and the whole reason this is a type rather than a tuple: outside
    /// this module there is no unfenced way to reach the event at all. A rule a consumer has to
    /// remember is a rule a consumer eventually forgets, and forgetting it here is precisely the
    /// bug the stamp exists to prevent.
    let event: MediaEvent
    /// The generation the channel was fenced to when this event arrived. Readable everywhere: it
    /// is a counter, it names no account and carries nothing of the event.
    public let generation: Int

    init(event: MediaEvent, generation: Int) {
        self.event = event
        self.generation = generation
    }

    /// The event to apply, or `nil` if the device has become another account since it arrived —
    /// and, by construction, the only way an event leaves an envelope across the module boundary.
    ///
    /// An attachment uid means nothing across accounts, so an event applied past a rotation
    /// patches the new account's timeline with the previous account's photo. Reading the clock
    /// HERE, on the actor that owns it, is what makes the answer still true when it is used.
    @MainActor
    public func eventIfCurrent(for identity: MediaIdentity = .shared) -> MediaEvent? {
        generation == identity.generation ? event : nil
    }
}

/// Everything the channel reports, in the order it happens: state changes and events on one
/// stream, so a consumer cannot see an event from a connection whose `open` it has not seen yet.
public enum MediaEventStreamItem: Sendable, Equatable {
    case state(MediaEventConnectionState)
    /// Stamped, and to be read through `MediaEventEnvelope.eventIfCurrent(for:)` — see the fence.
    case event(MediaEventEnvelope)
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
///
/// Those reads are an EARLY EXIT, not the fence that decides. They turn the stream off promptly,
/// and they cannot do more than that: this client is `Sendable` and runs off the main actor, while
/// rotation is serialized ON it, and an event yielded here is consumed by the app later still. So
/// every event is delivered STAMPED, as a `MediaEventEnvelope`, and the deciding check belongs to
/// the consumer: `MediaEventEnvelope.eventIfCurrent(for:)`, which reads the live clock on the
/// actor that owns it. The envelope's raw event is `internal` BY DESIGN, so that check is not a
/// convention a consumer is asked to keep — outside this module there is no other way in.
public final class MediaEventClient: Sendable {
    /// The path the events route is mounted at (memos-ng `app/routers/assets.py:822-823`).
    public static let path = "api/events"

    /// Read fresh per connection, and THROWING on purpose: `nil` means nobody is signed in, a
    /// thrown error means storage would not answer, and only the first of those is terminal.
    private let credentials: @Sendable () async throws -> MediaEventCredentials?
    private let generation: @Sendable () async -> Int
    /// Asked by the TRANSPORT before every connect, first and reconnect alike — this loop outlives
    /// any one session (`SendAuthority`).
    private let authority: SendAuthority
    private let backoff: SSEBackoff
    private let jitter: any SSEJitter
    private let idleReconnectDelay: TimeInterval
    private let transport: any SSEConnecting
    private let sleeper: any SSESleeper

    public init(
        credentials: @escaping @Sendable () async throws -> MediaEventCredentials?,
        generation: @escaping @Sendable () async -> Int,
        backoff: SSEBackoff = SSEBackoff(),
        jitter: any SSEJitter = SystemSSEJitter(),
        idleReconnectDelay: TimeInterval = 15,
        transport: any SSEConnecting = URLSessionSSETransport(),
        sleeper: any SSESleeper = ContinuousClockSleeper(),
        authority: SendAuthority = .unfenced
    ) {
        self.credentials = credentials
        self.generation = generation
        self.authority = authority
        self.backoff = backoff
        self.jitter = jitter
        self.idleReconnectDelay = idleReconnectDelay
        self.transport = transport
        self.sleeper = sleeper
    }

    /// The channel the app composes: the device credential out of the keychain — the same two
    /// items `DeviceOutboxCredentials` reads, through the same vault — and the media identity as
    /// the fence.
    ///
    /// The read is `try`, never `try?`. `CredentialStore.string(for:)` answers `nil` for an ABSENT
    /// account and nothing else; every other answer it throws, precisely so a caller can tell
    /// "there is no credential" from "there is one and it will not come back". Collapsing those
    /// two with `try?` is the class the credential-hardening round removed from Security, and it
    /// would land here as a device signing its own live channel out. So the throw travels OUT of
    /// this closure and `connect` decides what it means. An address that will not parse is
    /// neither case — it is stored and unusable — and is read as absent, the way
    /// `DeviceOutboxCredentials` reads it too.
    @MainActor
    public static func device(
        grant: @escaping @MainActor @Sendable () -> CredentialGrant?,
        identity: MediaIdentity = .shared,
        backoff: SSEBackoff = SSEBackoff(),
        idleReconnectDelay: TimeInterval = 15,
        transport: any SSEConnecting = URLSessionSSETransport(),
        sleeper: any SSESleeper = ContinuousClockSleeper(),
        authority: SendAuthority = .unfenced
    ) -> MediaEventClient {
        MediaEventClient(
            credentials: {
                // From the SESSION, in memory, not from the keychain. The two can disagree: a
                // sign-in as B whose credential would not store leaves B established here and A's
                // token in the vault, and a channel reading the vault would then present A's
                // credential under B's session — the pairing `credentialGrant` exists to make
                // impossible, since the subject and the token come out of one object in one
                // instant. Read per connection, so a renewal is simply what the next one carries.
                guard let grant = await grant(), !grant.token.isEmpty else { return nil }
                return MediaEventCredentials(baseURL: grant.serverBaseURL, token: grant.token)
            },
            generation: { await identity.generation },
            backoff: backoff,
            idleReconnectDelay: idleReconnectDelay,
            transport: transport,
            sleeper: sleeper,
            authority: authority
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
        /// The bound on re-granting. ONE immediate reconnect per refusal of a replaced credential,
        /// and it is spent until a connection opens or the server closes one cleanly. A second in
        /// a row is not a rotation the device is chasing — it is a credential the server keeps
        /// refusing, and that IS the end of the channel.
        var regrants = 0

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
            case .superseded:
                guard regrants == 0 else {
                    MemosLog.media.info("a second refusal in a row is not a rotation to chase")
                    stop(.unauthorized, into: continuation)
                    return
                }
                regrants += 1
                // The credential moved, not the session: reconnect at once, and do not spend a
                // step of the backoff on somebody else's rotation.
                attempt = max(attempt - 1, 0)
                delay = 0
            case .ended:
                // The server closes when nothing is in flight. That is not a failure and must not
                // escalate the backoff — the next connection is a fresh first attempt.
                attempt = 0
                regrants = 0
                delay = idleReconnectDelay
            case .failed(let opened):
                if opened {
                    attempt = 0
                    regrants = 0
                }
                if let retryAfter = result.retryAfter {
                    // The server said when it can take this connection back, so the answer is
                    // that instant and not a draw below it; the failure count still advances, so
                    // the schedule after it is the one this run of failures has earned. Up to the
                    // cap: a header asking for a day would park a foreground channel for a day,
                    // and the cap is the longest this client waits on its own.
                    delay = max(min(retryAfter, backoff.cap), serverRetryHint ?? 0)
                } else {
                    delay = backoff.wait(
                        forAttempt: max(attempt, 1),
                        serverHint: serverRetryHint,
                        jitter: jitter
                    )
                }
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
        func result(
            _ outcome: ConnectionOutcome,
            retryAfter: TimeInterval? = nil
        ) -> ConnectionResult {
            ConnectionResult(
                outcome: outcome,
                lastEventID: lastEventID,
                serverRetryHint: serverRetryHint,
                retryAfter: retryAfter
            )
        }

        // A store that will not answer is not an account that ended. The documented case is a
        // background launch between a reboot and the first unlock, where an `AfterFirstUnlock`
        // item is simply out of reach for a while (`KeychainAccessGroup.Probe.unavailable`) — the
        // token is on the device the whole time. `.signedOut` is terminal, so reporting one here
        // would kill the channel over a condition that fixes itself; a failed connect backs off
        // and the channel is still there when the device unlocks.
        let stored: MediaEventCredentials?
        do {
            stored = try await credentials()
        } catch {
            let detail = String(describing: error)
            MemosLog.media.error(
                "the media channel could not read the credential: \(detail, privacy: .public)"
            )
            return result(.failed(opened: false))
        }
        guard let credentials = stored else { return result(.signedOut) }
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
            // Every attempt, including each reconnect: this loop outlives any one session and
            // the credential it presents is the one this device held when it started.
            let connection = try await transport.connect(request, under: authority)
            switch connection.statusCode {
            case 200:
                break
            case 401, 403:
                // Judged against what the connect actually PRESENTED. This loop outlives any one
                // credential: a renewal lands between the request being built and the transport
                // sending it, the transport correctly presents the successor, and if the answer is
                // about the token this device has since replaced then it says nothing about the one
                // it is holding. Ending the channel on it takes live updates away from a session
                // that is perfectly valid.
                // The same value, and the same one rule, as every other lane — minted here because
                // this connection never goes through the generated client. `.superseded` is a
                // RECONNECT signal rather than a discard, which is why the answer is read locally
                // instead of being handed to the session's funnel.
                let refusal = CredentialRefusal(issuedUnder: authority.presented()?.epoch)
                if connection.statusCode == 401,
                    !refusal.concernsCurrentCredential(ofEpoch: authority.currentEpoch())
                {
                    MemosLog.media.info("a 401 for a replaced credential does not end the channel")
                    return result(.superseded)
                }
                MemosLog.media.info("GET /api/events refused the credential")
                return result(.unauthorized)
            case 429, 503:
                // Backpressure: the server is up and asking for time, which is the one failure
                // that says how long to wait.
                MemosLog.media.info(
                    "GET /api/events -> \(connection.statusCode, privacy: .public)"
                )
                return result(.failed(opened: false), retryAfter: connection.retryAfter)
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
                // The reconnection time belongs to the stream, not to this connection's parser:
                // a connection that sends no `retry:` leaves the last one standing.
                if let hint = parser.reconnectionTime { serverRetryHint = hint }
                if Task.isCancelled { return result(.cancelled) }
                // The second gate: whatever this connection was opened for, it is not this
                // device's business any more once the account has moved. An early exit only —
                // what protects an event already delivered is the stamp it carries.
                guard await generation() == fence else { return result(.identityChanged) }
                for frame in frames {
                    do {
                        let event = try MediaEvent.decode(frame)
                        let stamped = MediaEventEnvelope(event: event, generation: fence)
                        continuation.yield(.event(stamped))
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
        /// A 429 or 503's `Retry-After`, for the next reconnect ONLY. Not folded into
        /// `serverRetryHint`: that one replaces the backoff's base and doubles with every later
        /// failure, which would turn "come back in 7 seconds" into 14, then 28.
        var retryAfter: TimeInterval?
    }

    /// How one connection ended, and — for a failure — whether it had opened first, which
    /// decides between a fresh backoff and the next step of the current one.
    private enum ConnectionOutcome: Sendable, Equatable {
        case ended
        case failed(opened: Bool)
        /// A refusal of a credential this device has already replaced. Not an answer about the one
        /// it is holding, so the channel re-grants and connects again — see the bound in `run`.
        case superseded
        case unauthorized
        case signedOut
        case identityChanged
        case cancelled
    }
}
