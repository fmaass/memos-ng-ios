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

    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        // The double answers the same question the real performer does, so a test can put the
        // withdrawal between two sends and see the second one refused.
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
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

    private var hook: (@Sendable () -> Void)?

    func inFlight() async -> [OutboxTaskIdentity] { lock.withLock { pretendInFlight } }

    /// Set after the harness knows the job and file ids a relaunch would have left behind.
    func pretend(inFlight identities: [OutboxTaskIdentity]) {
        lock.withLock { pretendInFlight = identities }
    }

    /// Run the instant BEFORE the authority is asked — how a test puts an account switch inside
    /// the hop between the engine's decision to send and this executor performing it.
    var beforeUpload: (@Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        identity: OutboxTaskIdentity,
        under authority: SendAuthority
    ) async {
        beforeUpload?()
        guard authority.holds() else { return }
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

/// The network this phone is on, as a test decides it is — and the event that says it changed.
///
/// The event is half the point of the type: a capture put down for the wrong network has to move
/// when the network moves, so the tests that prove it hand `move(to:)` the wifi and then assert
/// what happened WITHOUT calling a drain themselves.
final class StubNetworkPath: NetworkPathProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var path: NetworkPath
    private var afterOneRead: NetworkPath?
    private var handler: OutboxTrigger?

    /// `thenAfterOneRead` is the train leaving the station mid-drain: the first read answers with
    /// one network and every read after it with another, which is how a test can tell a policy
    /// consulted once per pass from one consulted before each action.
    init(_ path: NetworkPath = .wifi, thenAfterOneRead next: NetworkPath? = nil) {
        self.path = path
        self.afterOneRead = next
    }

    func currentPath() -> NetworkPath {
        lock.withLock {
            let answer = path
            if let next = afterOneRead {
                path = next
                afterOneRead = nil
            }
            return answer
        }
    }

    func onPathChange(_ handler: @escaping OutboxTrigger) {
        lock.withLock { self.handler = handler }
    }

    /// Moves the phone onto another network and tells whoever asked to hear about it.
    func move(to next: NetworkPath) async {
        let handler: OutboxTrigger? = lock.withLock {
            path = next
            return self.handler
        }
        await handler?()
    }
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

    func create(
        job: UploadJob,
        credentials: OutboxCredentials,
        under authority: SendAuthority
    ) async -> MemoCompletionOutcome {
        guard authority.holds() else { return .retry("no authority") }
        return lock.withLock {
            attempts.append(job.idempotencyKey)
            guard !outcomes.isEmpty else { return lastOutcome }
            return outcomes.removeFirst()
        }
    }

    var idempotencyKeys: [UUID] { lock.withLock { attempts } }
}

/// The real queue on disk, with a set number of its writes refused.
///
/// Reading, slicing and sweeping all go straight through to the repository the app itself uses —
/// only `save` is intercepted, because "the disk would not take this write" is the one state a test
/// cannot otherwise reach, and what the drain does next is the whole point. Refusing a COUNT rather
/// than a kind is what separates the two cases that matter: one manifest that cannot be written
/// while the rest of the queue can, and a container that takes nothing at all.
actor FaultyPersistence: OutboxPersisting {
    struct Refused: Error {}

    private let inner: OutboxRepository
    /// How many writes still get refused; `Int.max` is a disk that never comes back.
    private var refusals: Int
    private(set) var refusedSaves = 0

    init(_ inner: OutboxRepository, refusals: Int) {
        self.inner = inner
        self.refusals = refusals
    }

    func loadJobs() async throws -> [UploadJob] { try await inner.loadJobs() }

    func job(_ id: UUID) async -> UploadJob? { await inner.job(id) }

    func save(_ job: UploadJob) async throws {
        guard refusals == 0 else {
            refusals -= 1
            refusedSaves += 1
            throw Refused()
        }
        try await inner.save(job)
    }

    func delete(_ job: UploadJob) async { await inner.delete(job) }

    func sweepOrphans() async throws { try await inner.sweepOrphans() }

    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int
    ) async throws -> URL {
        try await inner.sliceChunk(job: job, file: file, offset: offset, length: length)
    }

    func removeChunk(at url: URL) async { await inner.removeChunk(at: url) }

    nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64) -> URL {
        inner.chunkURL(jobID: jobID, fileID: fileID, offset: offset)
    }
}

/// A hold a test opens by hand, so that a test can be INSIDE a drain when something happens.
///
/// Without it there is no way to assert what an event arriving DURING a drain does: everything
/// else in this bundle is fast enough that a drain is over before the next line of the test runs,
/// which is exactly the moment the drain used to lose an event in.
actor TestGate {
    private var isOpen = false
    private var isParked = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    /// Called by the work being held. Returns at once once the gate is open.
    func pass() async {
        guard !isOpen else { return }
        isParked = true
        for watcher in watchers { watcher.resume() }
        watchers = []
        await withCheckedContinuation { held.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in held { continuation.resume() }
        held = []
    }

    /// Returns when something is actually waiting on the gate — never a sleep, so the test is not
    /// racing the thing it is trying to interrupt.
    func waitUntilParked() async {
        guard !isParked else { return }
        await withCheckedContinuation { watchers.append($0) }
    }
}

/// The real queue with its first write held open, so a test can act while a drain is mid-write.
actor GatedPersistence: OutboxPersisting {
    private let inner: OutboxRepository
    private let gate: TestGate
    private var held: Int

    init(_ inner: OutboxRepository, gate: TestGate, holding: Int = 1) {
        self.inner = inner
        self.gate = gate
        self.held = holding
    }

    func loadJobs() async throws -> [UploadJob] { try await inner.loadJobs() }

    func job(_ id: UUID) async -> UploadJob? { await inner.job(id) }

    func save(_ job: UploadJob) async throws {
        if held > 0 {
            held -= 1
            await gate.pass()
        }
        try await inner.save(job)
    }

    func delete(_ job: UploadJob) async { await inner.delete(job) }

    func sweepOrphans() async throws { try await inner.sweepOrphans() }

    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int
    ) async throws -> URL {
        try await inner.sliceChunk(job: job, file: file, offset: offset, length: length)
    }

    func removeChunk(at url: URL) async { await inner.removeChunk(at: url) }

    nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64) -> URL {
        inner.chunkURL(jobID: jobID, fileID: fileID, offset: offset)
    }
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
    private var epoch = 0
    private var supersedeOnAcquire = false

    init(_ current: OutboxCredentials?) { self.current = current }

    func set(_ credentials: OutboxCredentials?) {
        lock.withLock { current = credentials }
    }

    /// Somebody signs in as somebody else RIGHT NOW — driven from inside the scripted server, so
    /// a test can put the switch between two sends rather than only before the first.
    func supersede() { lock.withLock { epoch += 1 } }

    /// Somebody signs in as somebody else the instant AFTER a pass acquires its credential — the
    /// window the acquisition itself cannot close, and the one every request in that pass is then
    /// inside of.
    func supersedeAfterNextAcquisition() { lock.withLock { supersedeOnAcquire = true } }

    func currentCredentials() async -> OutboxCredentials? {
        lock.withLock {
            guard var acquired = current else { return nil }
            acquired.epoch = epoch
            if supersedeOnAcquire {
                epoch += 1
                supersedeOnAcquire = false
            }
            return acquired
        }
    }

    func isCurrent(_ credentials: OutboxCredentials) -> Bool {
        lock.withLock { epoch == credentials.epoch }
    }
}

struct StaticCredentials: OutboxCredentialsProviding {
    var credentials: OutboxCredentials?

    func currentCredentials() async -> OutboxCredentials? { credentials }

    /// Nothing moves under this one, so what it granted always still stands.
    func isCurrent(_ credentials: OutboxCredentials) -> Bool { true }
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

    /// Takes a directory's permissions away and hands back the undo, so a test can put them back
    /// however it leaves — a directory nobody may write is the honest shape of a full disk, and one
    /// left that way cannot be cleaned up.
    static func permissions(_ mode: Int, on directory: URL) throws -> @Sendable () -> Void {
        let path = directory.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
    }

    /// A preference store of its own per test. The app group's suite is the DEVICE's, and a test
    /// that wrote into it would change how the app behaves on whatever machine ran the gate. The
    /// starting value is written straight to the key, so a test of `set` still tests `set`.
    static func preferences(
        allowsMobileData: Bool = false,
        name: String = "memosng.outbox.tests.\(UUID().uuidString)"
    ) -> (store: UploadPreferences, name: String) {
        // Emptied first, so a named suite a previous run left behind cannot decide this one.
        UserDefaults.standard.removePersistentDomain(forName: name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(allowsMobileData, forKey: UploadPreferences.allowsMobileDataKey)
        return (UploadPreferences(defaults: defaults), name)
    }

    static func forgetting(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
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
