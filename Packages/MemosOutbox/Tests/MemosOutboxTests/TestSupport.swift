import Foundation
import MemosOutbox

/// Substitutes the network, not the drain.
///
/// The engine's dependencies are the transport, the background session and the completion path;
/// each of those is scripted here so the RULES — one chunk in flight, resume from the server's
/// count, hold rather than loop — are what the tests exercise. Nothing stands in for the engine
/// itself, which is the unit under test.
final class ScriptedHTTP: OutboxHTTPPerforming, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> OutboxHTTPResponse

    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func perform(_ request: URLRequest) async throws -> OutboxHTTPResponse {
        lock.withLock { seen.append(request) }
        return try handler(request)
    }

    var requests: [URLRequest] { lock.withLock { seen } }

    func requests(method: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method }
    }

    static func json(_ object: [String: Any], status: Int = 200) -> OutboxHTTPResponse {
        let data = try? JSONSerialization.data(withJSONObject: object)
        return OutboxHTTPResponse(
            statusCode: status,
            body: data ?? Data(),
            headers: ["Content-Type": "application/json"]
        )
    }

    static func session(uid: String, chunkSize: Int, received: Int) -> OutboxHTTPResponse {
        json(
            ["upload_uid": uid, "chunk_size": chunkSize, "bytes_received": received], status: 201
        )
    }

    /// The server as it behaves when nothing is wrong: reachable, hands out upload sessions, and
    /// answers the offset HEAD with what a test says it holds.
    static func standard(
        uid: String = "u1",
        chunkSize: Int = 5 * 1024 * 1024,
        received: Int = 0,
        headOffset: Int = 0,
        health: Int = 200
    ) -> ScriptedHTTP {
        ScriptedHTTP { request in
            let path = request.url?.path() ?? ""
            switch (request.httpMethod ?? "", path) {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: health)
            case ("POST", "/api/uploads"):
                return session(uid: uid, chunkSize: chunkSize, received: received)
            case ("HEAD", _):
                return OutboxHTTPResponse(
                    statusCode: 200, headers: ["Upload-Offset": String(headOffset)]
                )
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
    }
}

/// A background session that never touches the network: it records what it was asked to upload and
/// answers with whatever a test says is already in flight.
final class ScriptedScheduler: OutboxChunkScheduling, @unchecked Sendable {
    struct Scheduled: Sendable, Equatable {
        var identity: OutboxTaskIdentity
        var file: URL
        var offsetHeader: String?
    }

    private let lock = NSLock()
    private var scheduled: [Scheduled] = []
    private var cancelled: [OutboxTaskIdentity] = []
    private var pretendInFlight: [OutboxTaskIdentity]

    init(inFlight: [OutboxTaskIdentity] = []) {
        self.pretendInFlight = inFlight
    }

    func inFlight() async -> [OutboxTaskIdentity] { lock.withLock { pretendInFlight } }

    /// Set after the harness knows the job and file ids a relaunch would have left behind.
    func pretend(inFlight identities: [OutboxTaskIdentity]) {
        lock.withLock { pretendInFlight = identities }
    }

    func upload(_ request: URLRequest, fromFile file: URL, identity: OutboxTaskIdentity) async {
        lock.withLock {
            scheduled.append(
                Scheduled(
                    identity: identity,
                    file: file,
                    offsetHeader: request.value(forHTTPHeaderField: "Upload-Offset")
                )
            )
        }
    }

    func cancel(_ identities: [OutboxTaskIdentity]) async {
        lock.withLock {
            cancelled.append(contentsOf: identities)
            pretendInFlight.removeAll { identities.contains($0) }
        }
    }

    var uploads: [Scheduled] { lock.withLock { scheduled } }
    var cancellations: [OutboxTaskIdentity] { lock.withLock { cancelled } }
}

/// The completion path, scripted. It records the idempotency key of every attempt, which is what
/// the replay-window test asserts on.
final class ScriptedCompletion: MemoCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [MemoCompletionOutcome]
    private var attempts: [UUID] = []
    private var lastOutcome: MemoCompletionOutcome

    init(_ outcomes: [MemoCompletionOutcome], repeating last: MemoCompletionOutcome? = nil) {
        self.outcomes = outcomes
        self.lastOutcome = last ?? outcomes.last ?? .created(uid: "m1")
    }

    func create(job: UploadJob, credentials: OutboxCredentials) async -> MemoCompletionOutcome {
        lock.withLock {
            attempts.append(job.idempotencyKey)
            guard !outcomes.isEmpty else { return lastOutcome }
            return outcomes.removeFirst()
        }
    }

    var idempotencyKeys: [UUID] { lock.withLock { attempts } }
}

/// A clock a test can move, for the parts of the drain that only happen later.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }

    var now: Date { lock.withLock { instant } }

    func advance(_ interval: TimeInterval) {
        lock.withLock { instant += interval }
    }
}

/// Credentials that can disappear mid-run — a cold background wake before the session is
/// restored, or a sign-out between two chunks.
final class SwitchableCredentials: OutboxCredentialsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: OutboxCredentials?

    init(_ current: OutboxCredentials?) { self.current = current }

    func set(_ credentials: OutboxCredentials?) {
        lock.withLock { current = credentials }
    }

    func currentCredentials() async -> OutboxCredentials? { lock.withLock { current } }
}

struct StaticCredentials: OutboxCredentialsProviding {
    var credentials: OutboxCredentials?

    func currentCredentials() async -> OutboxCredentials? { credentials }
}

enum Fixture {
    static let server = URL(string: "https://memos.example.invalid")!
    static let otherServer = URL(string: "https://other.example.invalid")!

    static func credentials(
        server: URL = Fixture.server,
        owner: String = "fabian",
        token: String = "pat-token"
    ) -> OutboxCredentials {
        OutboxCredentials(serverBaseURL: server, ownerSubject: owner, token: token)
    }

    static func binding(server: URL = Fixture.server, owner: String = "fabian") -> AccountBinding {
        AccountBinding(serverBaseURL: server, ownerSubject: owner)
    }

    /// A temporary directory that the caller removes.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "outbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file whose bytes are known, so a slice can be compared against them exactly.
    static func file(in directory: URL, named name: String, bytes count: Int) throws -> URL {
        let url = directory.appending(path: name)
        try content(count).write(to: url)
        return url
    }

    /// Deterministic, non-repeating-per-byte content: a wrong offset produces different bytes.
    static func content(_ count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0..<count {
            data.append(UInt8((index &* 31 &+ 7) % 251))
        }
        return data
    }

    static func job(
        content: String = "a note",
        files: [OutboxFile] = [],
        binding: AccountBinding = Fixture.binding(),
        state: JobState = .waiting,
        nextAttemptAt: Date = .distantPast,
        capturedAt: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> UploadJob {
        UploadJob(
            content: content,
            capturedAt: capturedAt,
            files: files,
            binding: binding,
            state: state,
            nextAttemptAt: nextAttemptAt
        )
    }

    static func file(
        uploadUID: String? = nil,
        byteSize: Int64 = 1024,
        bytesConfirmed: Int64 = 0,
        chunkSize: Int = 5 * 1024 * 1024
    ) -> OutboxFile {
        OutboxFile(
            relativePath: "file.bin",
            filename: "IMG_0001.HEIC",
            mime: "image/heic",
            byteSize: byteSize,
            uploadUID: uploadUID,
            bytesConfirmed: bytesConfirmed,
            chunkSize: chunkSize
        )
    }
}

/// Counts calls from a `@Sendable` closure without tripping strict concurrency.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }

    var count: Int { lock.withLock { value } }
}
