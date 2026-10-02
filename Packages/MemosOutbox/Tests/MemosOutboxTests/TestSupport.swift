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
        lock.withLock { sendHook }?(request)
        // The double answers the same question the real performer does, so a test can put the
        // withdrawal between two sends and see the second one refused.
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        lock.withLock { seen.append(request) }
        return try handler(request)
    }

    private var sendHook: (@Sendable (URLRequest) -> Void)?

    /// Run the instant BEFORE the authority is asked, as `ScriptedScheduler.beforeUpload` is —
    /// how a test puts a change inside the hop between the engine's decision to send and this
    /// executor.
    var beforeSend: (@Sendable (URLRequest) -> Void)? {
        get { lock.withLock { sendHook } }
        set { lock.withLock { sendHook = newValue } }
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
    private var everyTaskCancelled = 0
    private var pretendInFlight: [OutboxTaskIdentity]
    private var park: (@Sendable () async -> Void)?
    private var parkAfter: (@Sendable () async -> Void)?

    init(inFlight: [OutboxTaskIdentity] = []) {
        self.pretendInFlight = inFlight
    }

    private var hook: (@Sendable () -> Void)?
    private var verdicts: [Bool] = []
    /// The credential generation each chunk went out under, as the production scheduler records it.
    private var issued: [String: Int] = [:]

    func epoch(of identity: OutboxTaskIdentity) -> Int? {
        lock.withLock { issued[identity.taskDescription] }
    }

    /// Forgets a chunk's generation the way the production delegate does when a task ends: keyed by
    /// the task DESCRIPTION, which is why two transfers that share one description share one epoch.
    func consumeEpoch(of identity: OutboxTaskIdentity) {
        lock.withLock { issued.removeValue(forKey: identity.taskDescription) }
    }

    /// What the authority answered, in order, each time this executor was reached.
    var authorityVerdicts: [Bool] { lock.withLock { verdicts } }

    func inFlight() async -> [OutboxTaskIdentity] {
        let hook = lock.withLock {
            let taken = park
            park = nil
            return taken
        }
        await hook?()
        let listed = lock.withLock { pretendInFlight }
        let after = lock.withLock {
            let taken = parkAfter
            parkAfter = nil
            return taken
        }
        await after?()
        let extra = lock.withLock { alsoListed }
        return listed + (await extra?() ?? [])
    }

    private var alsoListed: (@Sendable () async -> [OutboxTaskIdentity])?
    /// A second source for `inFlight()`, read after the scripted list: how a test puts the
    /// production delegate's own listing in front of the engine.
    var alsoListing: (@Sendable () async -> [OutboxTaskIdentity])? {
        get { lock.withLock { alsoListed } }
        set { lock.withLock { alsoListed = newValue } }
    }

    /// Run INSIDE `inFlight()` once the list is taken but before it is handed back, so a test can
    /// put a hand-off between the caller's enumeration and whatever it reads next; only the first
    /// enumeration runs it.
    var afterInFlight: (@Sendable () async -> Void)? {
        get { lock.withLock { parkAfter } }
        set { lock.withLock { parkAfter = newValue } }
    }

    /// Run INSIDE `inFlight()` before it answers, so a test can put a second call into the hop the
    /// first suspends on; the call that runs it clears it, so only the first enumeration parks.
    var beforeInFlight: (@Sendable () async -> Void)? {
        get { lock.withLock { park } }
        set { lock.withLock { park = newValue } }
    }

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
        under authority: SendAuthority,
        issuedUnder epoch: Int
    ) async {
        beforeUpload?()
        lock.withLock { issued[identity.taskDescription] = epoch }
        // The double does NOT enforce the policy it is used to test — a stand-in that implements
        // the guard proves only that the stand-in has one. It records the verdict the PRODUCTION
        // `SendAuthority` gives at the instant this executor runs, and the test reads that.
        let permitted = authority.holds()
        lock.withLock { verdicts.append(permitted) }
        guard permitted else { return }
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
    /// How many times every task was cancelled at once, unreadable ones included.
    var everyTaskCancellations: Int { lock.withLock { everyTaskCancelled } }

    func cancelEveryTask() async {
        lock.withLock {
            everyTaskCancelled += 1
            cancelled.append(contentsOf: pretendInFlight)
            pretendInFlight.removeAll()
        }
    }
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

    func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async throws -> UploadJob? {
        guard refusals == 0 else {
            refusals -= 1
            refusedSaves += 1
            throw Refused()
        }
        return try await inner.save(
            job, ifStillCurrent: epoch, matching: snapshot, else: fallback
        )
    }

    func delete(_ job: UploadJob) async { await inner.delete(job) }

    func delete(_ job: UploadJob, ifStillCurrent snapshot: UploadJob) async -> Bool {
        await inner.delete(job, ifStillCurrent: snapshot)
    }

    func sweepOrphans() async throws -> SweepOutcome { try await inner.sweepOrphans() }

    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int, attempt: Int?
    ) async throws -> URL {
        try await inner.sliceChunk(
            job: job, file: file, offset: offset, length: length, attempt: attempt
        )
    }

    func removeChunk(at url: URL) async { await inner.removeChunk(at: url) }

    nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64, attempt: Int?) -> URL {
        inner.chunkURL(jobID: jobID, fileID: fileID, offset: offset, attempt: attempt)
    }

    nonisolated func mediaURL(job: UploadJob, file: OutboxFile) -> URL {
        inner.mediaURL(job: job, file: file)
    }

    nonisolated var tails: WholeTailStaging { inner.tails }
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

    func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async throws -> UploadJob? {
        if held > 0 {
            held -= 1
            await gate.pass()
        }
        return try await inner.save(
            job, ifStillCurrent: epoch, matching: snapshot, else: fallback
        )
    }

    func delete(_ job: UploadJob) async { await inner.delete(job) }

    func delete(_ job: UploadJob, ifStillCurrent snapshot: UploadJob) async -> Bool {
        await inner.delete(job, ifStillCurrent: snapshot)
    }

    func sweepOrphans() async throws -> SweepOutcome { try await inner.sweepOrphans() }

    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int, attempt: Int?
    ) async throws -> URL {
        try await inner.sliceChunk(
            job: job, file: file, offset: offset, length: length, attempt: attempt
        )
    }

    func removeChunk(at url: URL) async { await inner.removeChunk(at: url) }

    nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64, attempt: Int?) -> URL {
        inner.chunkURL(jobID: jobID, fileID: fileID, offset: offset, attempt: attempt)
    }

    nonisolated func mediaURL(job: UploadJob, file: OutboxFile) -> URL {
        inner.mediaURL(job: job, file: file)
    }

    nonisolated var tails: WholeTailStaging { inner.tails }

    /// Forwarded to the real repository's rebase ungated: the protocol's default would route an
    /// answer through the gated save above and spend a hold a test meant for a drain's write.
    func applyFileAnswer(
        jobID: UUID,
        fileID: UUID,
        attempt: Int,
        outcome: WholeFileChange,
        presented: WholeTaskProvenance,
        at instant: Date
    ) async throws -> UploadJob? {
        try await inner.applyFileAnswer(
            jobID: jobID, fileID: fileID, attempt: attempt, outcome: outcome,
            presented: presented, at: instant
        )
    }
}

/// Supersedes the grant on the way INTO the write — the hop `OutboxEngine` makes into
/// `OutboxRepository`, and the one no engine-side comparison can close.
///
/// It intercepts the REFUSAL writes, which are the ones that name an epoch: since MEMNG-289 every
/// ordinary write crosses this signature too, and superseding on those would renew the grant during
/// the setup drain of every test below — the premise each of them asserts (`the chunk really was
/// sent under the grant the engine still holds`) would be false before the answer it is about ever
/// arrived. An ordinary write asks nothing about a credential, which is exactly what
/// `ifStillCurrent: nil` says, so it is let through untouched. Because the CHOICE is made inside
/// `inner`, after the line below, the fallback is what lands.
actor SupersedingPersister: OutboxPersisting {
    private let inner: OutboxRepository
    private let provider: SwitchableCredentials
    private(set) var fencedSaves = 0

    init(_ inner: OutboxRepository, superseding provider: SwitchableCredentials) {
        self.inner = inner
        self.provider = provider
    }

    func save(_ job: UploadJob) async throws { try await inner.save(job) }

    func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async throws -> UploadJob? {
        guard epoch != nil else {
            return try await inner.save(
                job, ifStillCurrent: epoch, matching: snapshot, else: fallback
            )
        }
        fencedSaves += 1
        // The renewal commits between the engine's decision and the repository's write.
        provider.supersede()
        return try await inner.save(
            job, ifStillCurrent: epoch, matching: snapshot, else: fallback
        )
    }

    func loadJobs() async throws -> [UploadJob] { try await inner.loadJobs() }

    func job(_ id: UUID) async -> UploadJob? { await inner.job(id) }

    func delete(_ job: UploadJob) async { await inner.delete(job) }

    func delete(_ job: UploadJob, ifStillCurrent snapshot: UploadJob) async -> Bool {
        await inner.delete(job, ifStillCurrent: snapshot)
    }

    func sweepOrphans() async throws -> SweepOutcome { try await inner.sweepOrphans() }

    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int, attempt: Int?
    ) async throws -> URL {
        try await inner.sliceChunk(
            job: job, file: file, offset: offset, length: length, attempt: attempt
        )
    }

    func removeChunk(at url: URL) async { await inner.removeChunk(at: url) }

    nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64, attempt: Int?) -> URL {
        inner.chunkURL(jobID: jobID, fileID: fileID, offset: offset, attempt: attempt)
    }

    nonisolated func mediaURL(job: UploadJob, file: OutboxFile) -> URL {
        inner.mediaURL(job: job, file: file)
    }

    nonisolated var tails: WholeTailStaging { inner.tails }
}

/// Credentials that let another pass land INSIDE the acquisition hop.
///
/// `OutboxEngine.handle` reads the manifest, matches the answer against the offset on disk, and
/// only then awaits `currentCredentials()`. That await is a suspension, and a sibling drain or a
/// newer chunk answer can advance the capture — or finish it and delete the manifest — while it is
/// open. This double is that other pass, on demand and deterministically: the action runs once, at
/// the acquisition, so the handler resumes holding a snapshot that no longer describes the disk.
final class InterferingCredentials: OutboxCredentialsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: OutboxCredentials?
    private var epoch = 0
    private var fired = false
    private let onAcquire: @Sendable () async -> Void

    init(_ current: OutboxCredentials?, onAcquire: @escaping @Sendable () async -> Void) {
        self.current = current
        self.onAcquire = onAcquire
    }

    func currentCredentials() async -> OutboxCredentials? {
        // Once. A drain acquires more than once, and the point is one interleaving, not a loop.
        let shouldFire: Bool = lock.withLock {
            let first = !fired
            fired = true
            return first
        }
        if shouldFire { await onAcquire() }
        return lock.withLock {
            guard var acquired = current else { return nil }
            acquired.epoch = epoch
            return acquired
        }
    }

    func isCurrent(_ credentials: OutboxCredentials) -> Bool {
        lock.withLock { epoch == credentials.epoch }
    }

    func stillCurrent(epoch: Int) -> Bool { lock.withLock { self.epoch == epoch } }
}

/// Refuses the FIRST fenced write and moves the capture while doing it, so the storage-failure
/// recovery runs against a manifest that has changed underneath it.
///
/// The recovery is one more write, and the window that swallowed the first one is still open. This
/// double is that window, on demand: the interference lands inside the throwing call, and the
/// recovery call that follows is let through to the real repository so the test can read back what
/// it actually did.
actor FailingThenInterferingPersister: OutboxPersisting {
    struct Refused: Error {}

    private let inner: OutboxRepository
    private let interfere: @Sendable () async -> Void
    private var refusedFirst = false
    private(set) var recoveryWrites = 0

    init(_ inner: OutboxRepository, interfering: @escaping @Sendable () async -> Void) {
        self.inner = inner
        self.interfere = interfering
    }

    func save(_ job: UploadJob) async throws {
        recoveryWrites += 1
        try await inner.save(job)
    }

    func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async throws -> UploadJob? {
        guard refusedFirst else {
            refusedFirst = true
            // The other pass lands while this write is failing.
            await interfere()
            throw Refused()
        }
        recoveryWrites += 1
        return try await inner.save(
            job, ifStillCurrent: epoch, matching: snapshot, else: fallback
        )
    }

    func loadJobs() async throws -> [UploadJob] { try await inner.loadJobs() }

    func job(_ id: UUID) async -> UploadJob? { await inner.job(id) }

    func delete(_ job: UploadJob) async { await inner.delete(job) }

    func delete(_ job: UploadJob, ifStillCurrent snapshot: UploadJob) async -> Bool {
        await inner.delete(job, ifStillCurrent: snapshot)
    }

    func sweepOrphans() async throws -> SweepOutcome { try await inner.sweepOrphans() }

    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int, attempt: Int?
    ) async throws -> URL {
        try await inner.sliceChunk(
            job: job, file: file, offset: offset, length: length, attempt: attempt
        )
    }

    func removeChunk(at url: URL) async { await inner.removeChunk(at: url) }

    nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64, attempt: Int?) -> URL {
        inner.chunkURL(jobID: jobID, fileID: fileID, offset: offset, attempt: attempt)
    }

    nonisolated func mediaURL(job: UploadJob, file: OutboxFile) -> URL {
        inner.mediaURL(job: job, file: file)
    }

    nonisolated var tails: WholeTailStaging { inner.tails }
}

/// The other pass, landing INSIDE the write hop of ONE chosen write.
///
/// `FailingThenInterferingPersister` above is this shape for the recovery window; this is the
/// ordinary one, and it is what a witness for a fenced write is made of. The write is named by a
/// predicate over the CANDIDATE the engine offers — a line number would not survive the next edit,
/// and the candidate is what the site is — the interference runs once, before that write is let
/// through to the real repository, and what the fence reads inside `inner` is therefore a manifest
/// the other pass has already changed.
///
/// Nothing is parked and no continuation is held: the interference is awaited inside the save the
/// engine is suspended in, which IS the interleaving, deterministically and with no sleeping.
actor InterferingPersistence: OutboxPersisting {
    private let inner: OutboxRepository
    private let matches: @Sendable (UploadJob) -> Bool
    private let interfere: @Sendable () async -> Void
    /// Whether the chosen write was reached at all — a premise a test asserts rather than assumes.
    private(set) var didInterfere = false
    /// Writes the engine attempted AFTER the overtaken one, so "and nothing further was written for
    /// that capture" is a number rather than a hope.
    private(set) var attemptsAfter = 0

    init(
        _ inner: OutboxRepository,
        when matches: @escaping @Sendable (UploadJob) -> Bool,
        interfering: @escaping @Sendable () async -> Void
    ) {
        self.inner = inner
        self.matches = matches
        self.interfere = interfering
    }

    private func arrive(_ job: UploadJob) async {
        guard !didInterfere else {
            attemptsAfter += 1
            return
        }
        guard matches(job) else { return }
        didInterfere = true
        await interfere()
    }

    func save(_ job: UploadJob) async throws {
        await arrive(job)
        try await inner.save(job)
    }

    func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async throws -> UploadJob? {
        await arrive(job)
        return try await inner.save(
            job, ifStillCurrent: epoch, matching: snapshot, else: fallback
        )
    }

    func loadJobs() async throws -> [UploadJob] { try await inner.loadJobs() }

    func job(_ id: UUID) async -> UploadJob? { await inner.job(id) }

    func delete(_ job: UploadJob) async { await inner.delete(job) }

    func delete(_ job: UploadJob, ifStillCurrent snapshot: UploadJob) async -> Bool {
        await inner.delete(job, ifStillCurrent: snapshot)
    }

    func sweepOrphans() async throws -> SweepOutcome { try await inner.sweepOrphans() }

    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int, attempt: Int?
    ) async throws -> URL {
        try await inner.sliceChunk(
            job: job, file: file, offset: offset, length: length, attempt: attempt
        )
    }

    func removeChunk(at url: URL) async { await inner.removeChunk(at: url) }

    nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64, attempt: Int?) -> URL {
        inner.chunkURL(jobID: jobID, fileID: fileID, offset: offset, attempt: attempt)
    }

    nonisolated func mediaURL(job: UploadJob, file: OutboxFile) -> URL {
        inner.mediaURL(job: job, file: file)
    }

    nonisolated var tails: WholeTailStaging { inner.tails }
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

    func stillCurrent(epoch: Int) -> Bool {
        lock.withLock { self.epoch == epoch }
    }
}

struct StaticCredentials: OutboxCredentialsProviding {
    var credentials: OutboxCredentials?

    func currentCredentials() async -> OutboxCredentials? { credentials }

    /// Nothing moves under this one, so what it granted always still stands.
    func isCurrent(_ credentials: OutboxCredentials) -> Bool { true }

    func stillCurrent(epoch: Int) -> Bool { true }
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

/// A latch a test can wait on from one side and open from the other.
actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    /// Waits for the latch, but never forever: a mutation that keeps it shut has to turn the test
    /// RED, and an unbounded wait parks the whole bundle instead — a witness that deadlocks is no
    /// fence. A poll rather than a race between the wait and a sleep, because cancelling the losing
    /// child of a task group cannot resume a checked continuation: the group would park at the end
    /// of its own scope.
    /// - Returns: whether the latch opened before the deadline.
    func wait(within seconds: Double = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !isOpen, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return isOpen
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// The whole lane's upload session, scripted: it lists what a test says it holds, records what the
/// scheduler starts and cancels, and ends a cancelled task only when the test says so.
///
/// It substitutes the session, not the scheduler: `BackgroundUploadScheduler` is the unit under
/// test, and every decision it makes from a listing is made against this one.
final class ScriptedUploadTaskSession: UploadTaskSession, @unchecked Sendable {
    /// What a cancel does to the listing.
    enum OnCancel {
        /// The task is marked cancelling and stays listed, and no terminal callback follows —
        /// the case the replace barrier exists for.
        case staysListed
        /// The task is gone from the listing that many listings after the cancel.
        case leavesListing(after: Int)
    }

    struct Created: Sendable, Equatable {
        var taskIdentifier: Int
        var request: URLRequest
        var file: URL
        var description: String
    }

    private let lock = NSLock()
    private var listed: [WholeTaskListing]
    private var created: [Created] = []
    private var cancelled: [Int] = []
    private var listings = 0
    private var leavesAt: [Int: Int] = [:]
    private var nextIdentifier: Int
    private let onCancel: OnCancel
    private var heldListing: TestGate?
    private var creationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        listing: [WholeTaskListing] = [],
        onCancel: OnCancel = .staysListed,
        firstIdentifier: Int = 1000
    ) {
        self.listed = listing
        self.onCancel = onCancel
        self.nextIdentifier = firstIdentifier
    }

    var createdTasks: [Created] { lock.withLock { created } }
    var cancelledIdentifiers: [Int] { lock.withLock { cancelled } }
    var listingCount: Int { lock.withLock { listings } }

    /// Returns once this many tasks have been created in all — told by the creation itself.
    func untilCreated(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                guard created.count < count else { return true }
                creationWaiters.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// The task leaves the listing now, as a task the system has finished with does.
    func forget(_ taskIdentifier: Int) {
        lock.withLock { listed.removeAll { $0.taskIdentifier == taskIdentifier } }
    }

    /// The task stays listed as finished: what a listing shows between the transfer's end and its
    /// answer being applied.
    func markCompleted(_ taskIdentifier: Int) {
        lock.withLock {
            listed = listed.map { task in
                guard task.taskIdentifier == taskIdentifier else { return task }
                var finished = task
                finished.state = .completed
                return finished
            }
        }
    }

    /// The next listing is TAKEN, then held on `gate` before it is returned: a snapshot its caller
    /// is still awaiting while other work runs and the session moves on.
    func holdNextListing(on gate: TestGate) {
        lock.withLock { heldListing = gate }
    }

    func allTasks() async -> [WholeTaskListing] {
        let (snapshot, hold) = lock.withLock {
            listings += 1
            let now = listings
            listed.removeAll { task in
                leavesAt[task.taskIdentifier].map { now >= $0 } ?? false
            }
            let taken = heldListing
            heldListing = nil
            return (listed, taken)
        }
        await hold?.pass()
        return snapshot
    }

    func uploadTask(with request: URLRequest, fromFile file: URL, description: String) -> Int {
        let (id, due) = lock.withLock {
            let id = nextIdentifier
            nextIdentifier += 1
            created.append(
                Created(taskIdentifier: id, request: request, file: file, description: description)
            )
            listed.append(
                WholeTaskListing(
                    taskIdentifier: id,
                    taskDescription: description,
                    access: WholeTaskNetworkAccess(request: request),
                    state: .running
                )
            )
            let reached = created.count
            let due = creationWaiters.filter { $0.count <= reached }.map(\.continuation)
            creationWaiters.removeAll { $0.count <= reached }
            return (id, due)
        }
        for waiter in due { waiter.resume() }
        return id
    }

    func cancel(taskIdentifier: Int) async {
        lock.withLock {
            cancelled.append(taskIdentifier)
            switch onCancel {
            case .staysListed:
                for index in listed.indices where listed[index].taskIdentifier == taskIdentifier {
                    listed[index].state = .canceling
                }
            case .leavesListing(let after):
                leavesAt[taskIdentifier] = listings + after
            }
        }
    }
}

/// A sleeper the test advances: every sleep waits until `advance(to:)` passes its deadline or its
/// task is cancelled, and what is armed is on record, so "one timer at a time" is asserted rather
/// than assumed.
final class ControlledSleeper: OutboxSleeping, @unchecked Sendable {
    private struct Sleep {
        var deadline: Date
        var continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var sleeping: [Int: Sleep] = [:]
    private var cancelledEarly: Set<Int> = []
    private var nextID = 0
    private var mostAtOnce = 0
    private var armedDeadlines: [Date] = []
    private var cancels = 0
    /// When false a cancelled sleep is NOT woken: it stays armed, so a test can fire a timer the
    /// engine has already replaced — the callback that was on its way when the re-arm happened.
    private let honoursCancellation: Bool

    init(honoursCancellation: Bool = true) {
        self.honoursCancellation = honoursCancellation
    }

    /// Sleeps armed right now.
    var armed: [Date] { lock.withLock { sleeping.values.map(\.deadline).sorted() } }
    /// The most sleeps ever armed at one instant.
    var mostArmedAtOnce: Int { lock.withLock { mostAtOnce } }
    /// How many sleeps were cancelled, honoured or not.
    var cancellations: Int { lock.withLock { cancels } }
    /// Every deadline ever armed, in order.
    var history: [Date] { lock.withLock { armedDeadlines } }

    func sleep(until deadline: Date) async throws {
        let id: Int = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early = lock.withLock { () -> Bool in
                    if cancelledEarly.remove(id) != nil, honoursCancellation { return true }
                    sleeping[id] = Sleep(deadline: deadline, continuation: continuation)
                    armedDeadlines.append(deadline)
                    mostAtOnce = Swift.max(mostAtOnce, sleeping.count)
                    return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            lock.withLock { cancels += 1 }
            guard honoursCancellation else { return }
            let woken = lock.withLock { () -> Sleep? in
                guard let found = sleeping.removeValue(forKey: id) else {
                    cancelledEarly.insert(id)
                    return nil
                }
                return found
            }
            woken?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Wakes every sleep whose deadline is at or before `instant`.
    func advance(to instant: Date) {
        let due: [Sleep] = lock.withLock {
            let ids = sleeping.filter { $0.value.deadline <= instant }.map(\.key)
            return ids.compactMap { sleeping.removeValue(forKey: $0) }
        }
        for sleep in due { sleep.continuation.resume() }
    }
}
