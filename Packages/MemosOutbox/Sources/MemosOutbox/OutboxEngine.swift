import Foundation

/// The drain: what actually moves a capture from this phone to the server.
///
/// Three rules shape all of it. Nothing is sent before a cheap health probe says the server is
/// reachable, so a day on a foreign network costs one small request rather than a video. Exactly
/// one chunk is in flight per job, and its offset comes from the server's own count, never from
/// local arithmetic. And a job leaves the outbox on ONE condition — the memo was created with
/// every original linked to it; everything else is a retry, and nothing is ever dropped.
public actor OutboxEngine: OutboxChunkHandling {
    /// A ceiling on how many decisions one job may take in a single pass. It is not a retry limit
    /// (there is none): it stops a server that keeps answering "recover this" from spinning the
    /// drain, and hands the job to the ordinary backoff instead.
    static let maxStepsPerPass = 32

    private let repository: OutboxRepository
    private let credentials: any OutboxCredentialsProviding
    private let http: any OutboxHTTPPerforming
    private let scheduler: any OutboxChunkScheduling
    private let completion: any MemoCompleting
    private let clock: @Sendable () -> Date
    private let onChange: @Sendable () async -> Void
    private var isDraining = false

    public init(
        repository: OutboxRepository,
        credentials: any OutboxCredentialsProviding,
        http: any OutboxHTTPPerforming,
        scheduler: any OutboxChunkScheduling,
        completion: any MemoCompleting,
        clock: @escaping @Sendable () -> Date = Date.init,
        onChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.credentials = credentials
        self.http = http
        self.scheduler = scheduler
        self.completion = completion
        self.clock = clock
        self.onChange = onChange
    }

    // MARK: - launch

    /// Reads the persisted jobs and the session's surviving tasks together, adopts what still
    /// fits, cancels what does not, and sweeps what belongs to no job. Runs BEFORE anything new is
    /// scheduled — that ordering is what keeps a relaunch from uploading the same bytes twice.
    @discardableResult
    public func reconcile() async -> ReconciliationPlan {
        await repository.sweepOrphans()
        let jobs = await repository.loadJobs()
        let plan = OutboxReconciliation.plan(jobs: jobs, inFlight: await scheduler.inFlight())
        if !plan.cancelled.isEmpty {
            await scheduler.cancel(plan.cancelled)
        }
        return plan
    }

    // MARK: - draining

    public func drain() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        guard let credentials = await credentials.currentCredentials() else { return }
        let plan = await reconcile()
        guard !plan.drainable.isEmpty else { return }

        // A job that belongs to another account is held here, before the probe: saying so does not
        // need a network, and a pending row that stays silent about it is the same as a lost memo.
        var candidates: [UploadJob] = []
        for id in plan.drainable {
            guard let job = await repository.job(id) else { continue }
            if !job.binding.matches(credentials) {
                await hold(job, reason: .accountMismatch)
                continue
            }
            candidates.append(job)
        }
        guard !candidates.isEmpty else {
            await onChange()
            return
        }
        guard await isReachable(credentials) else {
            await onChange()
            return
        }
        for job in candidates {
            await advance(job, credentials: credentials)
        }
        await onChange()
    }

    /// Clears a hold — what "Try again" on a pending row does.
    public func release(jobID: UUID) async {
        guard let job = await repository.job(jobID) else { return }
        try? await repository.save(job.released(at: clock()))
        await onChange()
    }

    private func advance(_ job: UploadJob, credentials: OutboxCredentials) async {
        var current = job
        for _ in 0..<Self.maxStepsPerPass {
            switch OutboxPlanner.nextAction(
                for: current, credentials: credentials, now: clock()
            ) {
            case .hold(let reason):
                await hold(current, reason: reason)
                return
            case .wait:
                return
            case .startUpload(let fileID):
                guard
                    let next = await startUpload(
                        current, fileID: fileID, credentials: credentials
                    )
                else { return }
                current = next
            case .uploadChunk(let fileID, let offset, let length):
                await schedule(
                    current, fileID: fileID, offset: offset, length: length,
                    credentials: credentials
                )
                return
            case .createMemo:
                guard let next = await complete(current, credentials: credentials) else { return }
                current = next
            }
        }
        // Out of steps without settling: space it out rather than spin.
        await save(current.backingOff(at: clock(), error: "The server kept asking to start over."))
    }

    // MARK: - the four calls

    private func isReachable(_ credentials: OutboxCredentials) async -> Bool {
        let request = OutboxRequests.health(baseURL: credentials.serverBaseURL)
        guard let response = try? await http.perform(request) else { return false }
        return response.isSuccess
    }

    private func startUpload(
        _ job: UploadJob,
        fileID: UUID,
        credentials: OutboxCredentials
    ) async -> UploadJob? {
        guard let file = job.file(fileID) else { return nil }
        let request: URLRequest
        do {
            request = try OutboxRequests.startUpload(
                baseURL: credentials.serverBaseURL, token: credentials.token, file: file
            )
        } catch {
            await save(job.held(.serverRefused, error: error.localizedDescription))
            return nil
        }
        guard let response = try? await http.perform(request) else {
            await save(job.backingOff(at: clock(), error: "The server could not be reached."))
            return nil
        }
        guard response.isSuccess, let session = OutboxWire.decodeSession(response.body) else {
            await save(refusal(job, statusCode: response.statusCode, what: "upload"))
            return nil
        }
        let next = job.startingUpload(fileID: fileID, session: session)
        await save(next)
        return next
    }

    private func schedule(
        _ job: UploadJob,
        fileID: UUID,
        offset: Int64,
        length: Int,
        credentials: OutboxCredentials
    ) async {
        guard let file = job.file(fileID), let uploadUID = file.uploadUID else { return }
        let chunk: URL
        do {
            chunk = try await repository.sliceChunk(
                job: job, file: file, offset: offset, length: length
            )
        } catch {
            await save(job.backingOff(at: clock(), error: error.localizedDescription))
            return
        }
        let request = OutboxRequests.chunk(
            baseURL: credentials.serverBaseURL,
            token: credentials.token,
            uploadUID: uploadUID,
            offset: offset
        )
        let identity = OutboxTaskIdentity(jobID: job.id, fileID: fileID, offset: offset)
        await scheduler.upload(request, fromFile: chunk, identity: identity)
        await save(job.with { $0.state = .uploading })
    }

    /// The offset HEAD: the server's own count, which is the only thing a resume trusts.
    private func resync(
        _ job: UploadJob,
        fileID: UUID,
        credentials: OutboxCredentials
    ) async -> UploadJob? {
        guard let file = job.file(fileID), let uploadUID = file.uploadUID else { return nil }
        let request = OutboxRequests.offset(
            baseURL: credentials.serverBaseURL, token: credentials.token, uploadUID: uploadUID
        )
        guard let response = try? await http.perform(request) else { return nil }
        if response.statusCode == 404 {
            // The session expired or was reaped. The ORIGINAL is untouched — it starts again.
            return job.clearingLostUpload(fileID: fileID)
        }
        guard response.isSuccess,
            let raw = response.header(OutboxRequests.offsetHeader),
            let offset = Int64(raw)
        else { return nil }
        return job.advancing(fileID: fileID, bytesConfirmed: offset)
    }

    private func complete(
        _ job: UploadJob,
        credentials: OutboxCredentials
    ) async -> UploadJob? {
        var current = job.creatingMemo()
        await save(current)
        switch await completion.create(job: current, credentials: credentials) {
        case .created:
            // The one exit. Everything the capture owns goes with it.
            await repository.delete(current)
            await onChange()
            return nil
        case .unlinkable(let failure):
            let recovery = OutboxPlanner.recovery(for: current, failure: failure)
            guard !recovery.isEmpty else {
                await save(
                    current.held(
                        .serverRefused, error: "The server could not link this memo's files."
                    )
                )
                return nil
            }
            current = current.applying(recovery)
            for fileID in recovery.resync {
                if let next = await resync(current, fileID: fileID, credentials: credentials) {
                    current = next
                }
            }
            await save(current)
            return current
        case .retry(let message):
            await save(current.backingOff(at: clock(), error: message))
            return nil
        case .refused(let message):
            await save(current.held(.serverRefused, error: message))
            return nil
        }
    }

    // MARK: - chunk answers

    /// Called by the background session, possibly in a process launched for this alone.
    ///
    /// This is the one entry point that runs in a process which may know nothing else: no screen,
    /// no restored session, nothing but a finished upload. So it banks what the server said FIRST
    /// and needs a credential only for the parts that talk to the server again. A byte count
    /// thrown away because nobody was signed in yet is a chunk re-uploaded for no reason.
    public func handle(_ result: ChunkResult) async {
        await repository.removeChunk(
            at: repository.chunkURL(
                jobID: result.identity.jobID,
                fileID: result.identity.fileID,
                offset: result.identity.offset
            )
        )
        guard let job = await repository.job(result.identity.jobID) else { return }
        // An answer from a superseded attempt — a task a reconcile cancelled, or a duplicate that
        // outlived the one whose answer already landed. The job has moved on, and applying this
        // would rewind the cursor and re-send bytes the server already holds.
        guard let file = job.file(result.identity.fileID),
            file.bytesConfirmed == result.identity.offset
        else { return }

        let fileID = result.identity.fileID
        let credentials = await credentials.currentCredentials()
        var next = job
        // Set when only the server can say where the upload stands, which is the one decision
        // here that cannot be made offline.
        var askTheServer: String?

        switch result.statusCode {
        case .some(let code) where (200..<300).contains(code):
            if let session = OutboxWire.decodeSession(result.body) {
                next = job.advancing(fileID: fileID, bytesConfirmed: session.bytesReceived)
            } else {
                askTheServer = "The server's answer was unreadable."
            }
        case .some(409):
            // An offset gap: the server and this device disagree, and the server is right.
            askTheServer = "The upload lost its place."
        case .some(404):
            next = job.clearingLostUpload(fileID: fileID)
        case .some(let code) where (400..<500).contains(code) && code != 408 && code != 429:
            next = refusal(job, statusCode: code, what: "chunk")
        case .some(let code):
            next = job.backingOff(at: clock(), error: "The upload failed (\(code)).")
        case .none:
            next = job.backingOff(
                at: clock(), error: result.errorDescription ?? "The upload did not finish."
            )
        }

        if let askTheServer {
            if let credentials,
                let resynced = await resync(job, fileID: fileID, credentials: credentials)
            {
                next = resynced
            } else {
                next = job.backingOff(at: clock(), error: askTheServer)
            }
        }

        await save(next)
        await onChange()
        // Nobody is signed in yet (a cold background wake, before the session is restored). What
        // the server said is on disk; the next drain carries on from there.
        guard let credentials else { return }
        await advance(next, credentials: credentials)
        await onChange()
    }

    // MARK: - helpers

    private func refusal(_ job: UploadJob, statusCode: Int, what: String) -> UploadJob {
        switch statusCode {
        case 401:
            return job.held(.serverRefused, error: "Sign in again to send this memo.")
        case 413:
            return job.held(.serverRefused, error: "The server will not accept a file this large.")
        case 408, 429, 500...599:
            return job.backingOff(at: clock(), error: "The server could not take the \(what).")
        default:
            return job.held(
                .serverRefused, error: "The server rejected the \(what) (\(statusCode))."
            )
        }
    }

    private func hold(_ job: UploadJob, reason: HoldReason) async {
        guard job.state != .held || job.holdReason != reason else { return }
        await save(job.held(reason, error: Self.message(for: reason)))
    }

    private func save(_ job: UploadJob) async {
        try? await repository.save(job)
    }

    static func message(for reason: HoldReason) -> String {
        switch reason {
        case .accountMismatch:
            return "Captured under a different account."
        case .serverRefused:
            return "The server refused this memo."
        }
    }
}
