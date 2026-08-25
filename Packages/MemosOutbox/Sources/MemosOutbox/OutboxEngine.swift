import Foundation

/// The drain: what actually moves a capture from this phone to the server.
///
/// Four rules shape all of it. Nothing goes out over a network the person did not agree to spend:
/// the policy is asked immediately before every step that would produce a request, against the
/// path as it is at that instant. Nothing is sent before a cheap health probe says the server is
/// reachable, so a day on a foreign network costs one small request rather than a video. Exactly
/// one chunk is in flight per job, and its offset comes from the server's own count, never from
/// local arithmetic. And a job leaves the outbox on ONE condition — the memo was created with
/// every original linked to it; everything else is a retry, and nothing is ever dropped.
public actor OutboxEngine: OutboxChunkHandling {
    /// A ceiling on how many decisions one job may take in a single pass. It is not a retry limit
    /// (there is none): it stops a server that keeps answering "recover this" from spinning the
    /// drain, and hands the job to the ordinary backoff instead.
    static let maxStepsPerPass = 32

    private let repository: any OutboxPersisting
    private let credentials: any OutboxCredentialsProviding
    private let http: any OutboxHTTPPerforming
    private let scheduler: any OutboxChunkScheduling
    private let completion: any MemoCompleting
    private let network: any NetworkPathProviding
    private let preferences: UploadPreferences
    private let clock: @Sendable () -> Date
    private let onChange: @Sendable () async -> Void
    private var isDraining = false
    /// Something asked for a drain while one was already running. It is a flag rather than a queue
    /// because every request means the same thing — look at the queue again — so one more pass
    /// answers all of them.
    private var drainRequested = false

    /// The last write to the queue that did not happen, in the words a person gets to read, or nil
    /// while the last one went through. It is a channel of its own because the ordinary one — the
    /// job's own manifest, saying it is held and why — is exactly what could not be written.
    public private(set) var lastPersistenceFailure: String?

    public init(
        repository: any OutboxPersisting,
        credentials: any OutboxCredentialsProviding,
        http: any OutboxHTTPPerforming,
        scheduler: any OutboxChunkScheduling,
        completion: any MemoCompleting,
        network: any NetworkPathProviding,
        preferences: UploadPreferences,
        clock: @escaping @Sendable () -> Date = Date.init,
        onChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.credentials = credentials
        self.http = http
        self.scheduler = scheduler
        self.completion = completion
        self.network = network
        self.preferences = preferences
        self.clock = clock
        self.onChange = onChange
    }

    // MARK: - launch

    /// Reads the persisted jobs and the session's surviving tasks together, adopts what still
    /// fits, cancels what does not, and sweeps what belongs to no job. Runs BEFORE anything new is
    /// scheduled — that ordering is what keeps a relaunch from uploading the same bytes twice.
    @discardableResult
    public func reconcile() async throws -> ReconciliationPlan {
        try await repository.sweepOrphans()
        let jobs = try await repository.loadJobs()
        let plan = OutboxReconciliation.plan(jobs: jobs, inFlight: await scheduler.inFlight())
        if !plan.cancelled.isEmpty {
            await scheduler.cancel(plan.cancelled)
        }
        return plan
    }

    // MARK: - draining

    /// One pass at a time, and never an event dropped.
    ///
    /// A drain refuses to run twice at once, so a request that arrives while one is running is
    /// remembered rather than discarded, and the running drain takes one more pass before it
    /// stops. The two events this matters for are exactly the two that release a parked capture:
    /// the wifi coming back and the toggle going on, both of which can land in the middle of the
    /// pass that is writing down why the capture is parked. Dropped, they would leave it parked
    /// until something unrelated happened to start another drain.
    public func drain() async {
        guard !isDraining else {
            drainRequested = true
            return
        }
        isDraining = true
        defer { isDraining = false }
        repeat {
            drainRequested = false
            await drainOnce()
        } while drainRequested
    }

    private func drainOnce() async {
        guard let credentials = await credentials.currentCredentials() else { return }
        let plan: ReconciliationPlan
        do {
            plan = try await reconcile()
        } catch {
            // The queue could not be read. Nothing is drained, nothing is cancelled and nothing is
            // swept on the strength of a list nobody could produce — an empty one would look
            // exactly like an empty outbox. The facade says so on its next refresh.
            await onChange()
            return
        }
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
        // Before the probe, because the probe is itself a request: a phone on mobile data with the
        // toggle off spends nothing at all, and every candidate says what it is waiting for.
        guard permitsNetwork() else {
            for job in candidates {
                await waitForNetwork(job)
            }
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
        await save(job.released(at: clock()))
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
                guard permitsNetwork() else {
                    await waitForNetwork(current)
                    return
                }
                guard
                    let next = await startUpload(
                        current, fileID: fileID, credentials: credentials
                    )
                else { return }
                current = next
            case .uploadChunk(let fileID, let offset, let length):
                guard permitsNetwork() else {
                    await waitForNetwork(current)
                    return
                }
                await schedule(
                    current, fileID: fileID, offset: offset, length: length,
                    credentials: credentials
                )
                return
            case .createMemo:
                guard permitsNetwork() else {
                    await waitForNetwork(current)
                    return
                }
                guard let next = await complete(current, credentials: credentials) else { return }
                current = next
            }
        }
        // Out of steps without settling: space it out rather than spin.
        await save(current.backingOff(at: clock(), error: "The server kept asking to start over."))
    }

    // MARK: - the network the phone is on

    /// Whether bytes may leave this device RIGHT NOW.
    ///
    /// Read fresh at every step rather than once per pass: a drain that started on the home wifi
    /// can reach its next chunk on a train, and the only honest moment to ask is the moment before
    /// a request would go out. `advance` therefore asks again for each action it takes — including
    /// the one `handle` re-enters it with when a chunk finishes.
    private func permitsNetwork() -> Bool {
        let policy = UploadNetworkPolicy(allowsMobileData: preferences.allowsMobileData)
        return policy.permits(network.currentPath())
    }

    /// The capture waits for a network it is allowed to use, and the row says which.
    ///
    /// Written down only when the manifest does not already say it, so a phone that stays on
    /// mobile data for a week does not rewrite every manifest on every drain.
    private func waitForNetwork(_ job: UploadJob) async {
        guard job.state != .waiting || job.waitReason != .homeNetwork else { return }
        await save(job.waitingForNetwork())
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
        // The server has handed out a session. Carrying on with it while the manifest still knows
        // nothing about it is how a chunk gets sent against a uid a relaunch cannot resume.
        guard await save(next) else { return nil }
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
        // The chunk is already with the background session, and this write only records that. Its
        // failure is reported, not acted on: the answer is applied against the manifest as it
        // stands, which is exactly what `handle` re-reads.
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
        // Nothing is created against a queue that could not be written: the capture waits, whole,
        // rather than being sent while the disk has no record that it was ever tried.
        guard await save(current) else { return nil }
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
            guard await save(current) else { return nil }
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
            // Only the server can say where this upload stands, and asking is a request like any
            // other. On a network this capture may not use it is not asked: the capture parks,
            // with nothing counted against it, because nothing was tried.
            guard permitsNetwork() else {
                await save(job.waitingForNetwork())
                await onChange()
                return
            }
            if let credentials,
                let resynced = await resync(job, fileID: fileID, credentials: credentials)
            {
                next = resynced
            } else {
                next = job.backingOff(at: clock(), error: askTheServer)
            }
        }

        // The cursor moves HERE or not at all. Going on to the next chunk from a count only this
        // process holds is what makes the server's answer to it unusable: `handle` matches an
        // answer against the offset on disk, and one that no longer matches is thrown away.
        let persisted = await save(next)
        await onChange()
        guard persisted else { return }
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

    /// Writes a transition down, and says whether it actually happened.
    ///
    /// The disk is the truth, so every caller stops where it stands when this returns false: a step
    /// taken on a state only memory holds is how the drain cursor and the server's own count come
    /// apart. One more thing is attempted first — the job, held, saying why — because when it is
    /// this one manifest that cannot be written, that hold is what a person sees; when it is the
    /// whole container, that write fails too and `lastPersistenceFailure` is the only answer left.
    @discardableResult
    private func save(_ job: UploadJob) async -> Bool {
        do {
            try await repository.save(job)
            lastPersistenceFailure = nil
            return true
        } catch {
            lastPersistenceFailure = Self.storageMessage(error)
            await holdUnsaved(job, error: error)
            return false
        }
    }

    private func holdUnsaved(_ job: UploadJob, error: any Error) async {
        guard job.state != .held || job.holdReason != .storageFailed else { return }
        do {
            try await repository.save(job.held(.storageFailed, error: Self.storageMessage(error)))
        } catch {
            // Nothing more can be written. It is already reported above, and the next pass finds
            // the job exactly as the last write that did land left it.
        }
    }

    static func storageMessage(_ error: any Error) -> String {
        "This capture could not be saved on this device: \(error.localizedDescription)"
    }

    static func message(for reason: HoldReason) -> String {
        switch reason {
        case .accountMismatch:
            return "Captured under a different account."
        case .serverRefused:
            return "The server refused this memo."
        case .unreadableManifest:
            return "This capture could not be read from the queue."
        case .storageFailed:
            return "This capture could not be saved on this device."
        }
    }
}
