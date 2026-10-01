import Foundation

/// A server answer, reduced to what the outbox decides on.
public struct OutboxHTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data
    public var headers: [String: String]

    public init(statusCode: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    /// Header lookup is case-insensitive, because a header name is.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// The small, foreground JSON calls: starting an upload session, the offset HEAD, the memo create,
/// the health probe. Chunks do NOT go through here — they belong to the background session.
public protocol OutboxHTTPPerforming: Sendable {
    /// - Parameter authority: asked inside this executor, immediately before the request leaves —
    ///   see `SendAuthority`. A performer that finds it withdrawn sends nothing and throws.
    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
}

/// What a performer throws when the authority it was handed no longer holds.
public struct SendAuthorityWithdrawn: Error, Equatable {
    public init() {}
}

public struct URLSessionHTTPPerformer: OutboxHTTPPerforming {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        // Asked HERE, on the executor that is about to send, with nothing between the answer and
        // the send.
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return OutboxHTTPResponse(statusCode: -1, body: data)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return OutboxHTTPResponse(statusCode: http.statusCode, body: data, headers: headers)
    }
}

/// How a chunk upload ended, as the background session reports it — possibly in a process that was
/// launched only to hear about it.
public struct ChunkResult: Sendable, Equatable {
    public var identity: OutboxTaskIdentity
    /// nil when the task failed before a response (no network, cancelled, killed).
    public var statusCode: Int?
    public var body: Data
    public var errorDescription: String?
    /// The credential generation this chunk was SENT under, when it is known.
    ///
    /// A chunk's answer comes back in a later pass, sometimes in a process launched for it alone,
    /// so by the time anything classifies it the only thing that knows which credential earned it
    /// is the answer itself. `nil` for a task adopted across a relaunch, where nothing recorded it
    /// — read as "unknown", which is treated as current.
    public var epoch: Int?

    public init(
        identity: OutboxTaskIdentity,
        statusCode: Int?,
        body: Data = Data(),
        errorDescription: String? = nil,
        epoch: Int? = nil
    ) {
        self.identity = identity
        self.statusCode = statusCode
        self.body = body
        self.errorDescription = errorDescription
        self.epoch = epoch
    }
}

/// Who is told when a chunk finishes.
public protocol OutboxChunkHandling: Sendable {
    func handle(_ result: ChunkResult) async
    /// An answer an `inFlight()` read listed while it was being handled has settled: a pass may
    /// have left its row to that answer, so the row is planned again. A request, never an awaited
    /// drain.
    func listedAnswerSettled() async
}

/// The background session, as the drain needs to see it.
///
/// It is a protocol because the drain's rules — one chunk in flight, adopt what survived a
/// relaunch, cancel what did not — have to be asserted without a network, and because a real
/// background session cannot be driven from a unit test at all.
public protocol OutboxChunkScheduling: Sendable {
    /// The tasks the session is carrying right now, whatever launched this process.
    func inFlight() async -> [OutboxTaskIdentity]
    /// - Parameter epoch: the credential generation this chunk goes out under, kept so the
    ///   answer can be classified against the credential that earned it.
    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        identity: OutboxTaskIdentity,
        under authority: SendAuthority,
        issuedUnder epoch: Int
    ) async
    func cancel(_ identities: [OutboxTaskIdentity]) async
    /// Cancels every task the session holds, whatever its description says — the ones this lane
    /// cannot read included: a withdrawn credential is still in their headers.
    func cancelEveryTask() async
}

/// The background session's identity and its configuration, in one place so the properties that
/// matter can be asserted.
public enum OutboxSession {
    /// Stable across launches by definition: a background session is found again by this string,
    /// and changing it would strand every task in flight.
    public static let identifier = "live.discomarder.memosng.outbox"

    public static func backgroundConfiguration(
        appGroup: String = OutboxDefaults.appGroup
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // The container the app group shares, so a chunk file and the session that uploads it are
        // reachable from every process that may be launched to finish the job.
        configuration.sharedContainerIdentifier = appGroup
        // Which network a capture may go over is the ENGINE's decision, taken immediately before
        // each request against the path as it is at that instant and the person's own choice
        // (`UploadNetworkPolicy`). A session that refused cellular itself could not be told
        // otherwise: its configuration is fixed for the lifetime of the process, so a toggle
        // turned on this afternoon would hold every chunk until the app was force-quit — which is
        // exactly what a phone away from home did on 2026-08-25, reporting "Uploading 0 %" for a
        // deliberate hold. Constrained stays refused here as well as there: Low Data Mode is a
        // decision about the whole phone, and this is the belt to the engine's braces.
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = false
        // Not discretionary: when the app is open and the wifi is right, the capture goes now.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }
}
