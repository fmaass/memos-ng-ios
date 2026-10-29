import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

/// A file larger than the server's `max_bytes` is refused while it is only staged (MEMNG-956).
///
/// The limit reaches the queue the way the app wires it: the session reads
/// `GET /api/uploads/limits` through the real generated client over `StubTransport`, the outbox's
/// credentials come from `session.credentialGrant()`, and a real `Outbox` drains a capture whose
/// requests are recorded at its HTTP seam. What is asserted is the wire: whether a
/// `POST /api/uploads` left.
@MainActor
@Suite("Upload limits: a staged file over max_bytes never starts an upload")
struct UploadLimitTests {
    nonisolated private static let limit: Int64 = 1_000_000
    /// Far enough over that the two sizes format apart: "1.6 MB > 1 MB".
    private static let oversized = 1_600_000

    /// Signs in, and answers the limits with `limit` unless `limitsStatus` says otherwise.
    private static func session(
        limitsAsked: LimitsCounter, limitsStatus: HTTPResponse.Status = .ok
    ) -> SessionStore {
        let handler: StubTransport.Handler = { _, _, operation in
            if operation == "upload_limits_api_uploads_limits_get" {
                limitsAsked.count += 1
                guard limitsStatus == .ok else { return Stub.empty(limitsStatus) }
                return Stub.json(
                    #"{"max_bytes":\#(limit),"wifi_recommended_above_bytes":500,"#
                        + #""bodies_per_user":2}"#)
            }
            return Stub.json(Stub.user)
        }
        return SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
    }

    private static func provider(for session: SessionStore) -> DeviceOutboxCredentials {
        DeviceOutboxCredentials(epoch: { session.epoch.current }) {
            await MainActor.run { session.credentialGrant() }
        }
    }

    /// Enqueues one file of `size` bytes on a real outbox over `session`, drains it, and answers
    /// what left at the HTTP seam and the capture as it stands afterwards.
    private static func send(size: Int, under session: SessionStore) async throws -> (
        [URLRequest], UploadJob?
    ) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "clip.mov")
        try Data(repeating: 7, count: size).write(to: file)
        let credentials = provider(for: session)
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { credentials.stillCurrent(epoch: $0) })
        let http = RecordingHTTP()
        let outbox = Outbox(
            repository: repository, credentials: credentials, http: http,
            scheduler: IdleChunks(), completion: MemoCompletionEndpoint(http: http),
            network: WifiOnly(),
            preferences: UploadPreferences(
                defaults: UserDefaults(suiteName: "upload-limit-\(UUID())") ?? .standard))
        let accepted = await outbox.enqueue(
            content: "too big?", visibility: nil,
            sources: [StagedSource(url: file, filename: "clip.mov", mime: "video/quicktime")])
        #expect(accepted, "positive control: the capture was written to the queue")
        await outbox.drain()
        // The drain the enqueue started may still own the engine, so this waits for the
        // decision itself: an upload started, or the capture held.
        for _ in 0..<5000 {
            await outbox.refresh()
            if uploadsStarted(http.requests) > 0 || outbox.jobs.first?.state == .held { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return (http.requests, outbox.jobs.first)
    }

    private static func uploadsStarted(_ requests: [URLRequest]) -> Int {
        requests.filter { $0.httpMethod == "POST" && $0.url?.path() == "/api/uploads" }.count
    }

    @Test("a file over max_bytes is held as too large with both sizes, and no POST leaves")
    func overTheLimitSendsNothing() async throws {
        let asked = LimitsCounter()
        let session = Self.session(limitsAsked: asked)
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await session.loadUploadLimits()
        #expect(session.uploadLimits?.maxBytes == Self.limit, "precondition: the limits arrived")

        let (requests, job) = try await Self.send(size: Self.oversized, under: session)

        #expect(Self.uploadsStarted(requests) == 0, "an oversized file started an upload")
        let held = try #require(job)
        #expect(held.state == .held)
        #expect(held.holdReason == .tooLarge)
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let reason = held.lastError ?? ""
        #expect(reason.contains(format(Int64(Self.oversized))), "no file size: \(reason)")
        #expect(reason.contains(format(Self.limit)), "the limit is not named: \(reason)")
    }

    @Test("a file exactly at max_bytes starts its upload")
    func atTheLimitStillSends() async throws {
        let session = Self.session(limitsAsked: LimitsCounter())
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await session.loadUploadLimits()
        #expect(session.uploadLimits?.maxBytes == Self.limit, "precondition: the limits arrived")

        let (requests, job) = try await Self.send(size: Int(Self.limit), under: session)

        #expect(Self.uploadsStarted(requests) == 1, "a file at the limit was not sent")
        #expect(job?.holdReason != .tooLarge)
    }

    @Test("with the limits unanswered nothing is refused: the oversized file still starts")
    func unknownLimitsFailOpen() async throws {
        let session = Self.session(limitsAsked: LimitsCounter(), limitsStatus: .internalServerError)
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await session.loadUploadLimits()
        #expect(session.uploadLimits == nil, "precondition: the limits did not arrive")
        #expect(session.state.user != nil, "a failed limits read ended the session")

        let (requests, job) = try await Self.send(size: Self.oversized, under: session)

        #expect(Self.uploadsStarted(requests) == 1, "unknown limits refused a file")
        #expect(job?.holdReason != .tooLarge)
    }

    @Test("the limits are read once per session, and a failed read may be asked again")
    func readOncePerSession() async {
        let asked = LimitsCounter()
        let session = Self.session(limitsAsked: asked)
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await session.loadUploadLimits()
        await session.loadUploadLimits()
        #expect(asked.count == 1, "the second call in one session asked again")

        let failing = LimitsCounter()
        let refused = Self.session(limitsAsked: failing, limitsStatus: .internalServerError)
        await refused.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await refused.loadUploadLimits()
        await refused.loadUploadLimits()
        #expect(failing.count == 2, "a failed read was never asked again")
    }

    @Test("a sign-out forgets the limits, so the next account is not refused by them")
    func signOutForgetsTheLimits() async {
        let session = Self.session(limitsAsked: LimitsCounter())
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await session.loadUploadLimits()
        #expect(session.uploadLimits != nil, "precondition: the limits arrived")

        await session.signOutWithoutRevoking()

        #expect(session.uploadLimits == nil)
        #expect(session.credentialGrant()?.uploadLimit == nil)
    }
}

/// How many times the limits were asked for, written from the transport's executor.
private final class LimitsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Records every request the outbox sends. The health probe is answered, so the server counts as
/// reachable; everything else gets a server error, which backs a capture off without holding it.
private final class RecordingHTTP: OutboxHTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { sent } }

    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        lock.withLock { sent.append(request) }
        if request.url?.path().hasSuffix("/health") == true {
            return OutboxHTTPResponse(statusCode: 200, body: Data("{}".utf8))
        }
        return OutboxHTTPResponse(statusCode: 503)
    }
}

/// No background transfers.
private struct IdleChunks: OutboxChunkScheduling {
    func inFlight() async -> [OutboxTaskIdentity] { [] }
    func upload(
        _ request: URLRequest, fromFile file: URL, identity: OutboxTaskIdentity,
        under authority: SendAuthority, issuedUnder epoch: Int
    ) async {}
    func cancel(_ identities: [OutboxTaskIdentity]) async {}
    func cancelEveryTask() async {}
}

/// A Wi-Fi path, never changing.
private struct WifiOnly: NetworkPathProviding {
    func currentPath() -> NetworkPath {
        NetworkPath(usesCellular: false, isExpensive: false, isConstrained: false)
    }
    func onPathChange(_ handler: @escaping OutboxTrigger) {}
}
