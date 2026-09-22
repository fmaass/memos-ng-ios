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

    /// The jobs whose edit this launch has already put on the wire. In memory on purpose: it is
    /// the claim that keeps two invocations inside one launch from being two requests, and a
    /// relaunch is meant to ask again.
    private var editsTransmitted: Set<UUID> = []

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
    ///
    /// It carries one thing that is not a write: a housekeeping pass that could not take its lease
    /// because the lock does not work on this device. That is the same kind of fact — the queue
    /// could not do something to itself, and no job's manifest can say so — and it is the only
    /// signal a device pass has that the exclusion is not really there.
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
        switch try await repository.sweepOrphans() {
        case .swept, .deferred(.contended):
            // A pass that deferred deleted nothing, which costs disk and never correctness:
            // everything below reads manifests and the session's surviving tasks, never the files
            // the sweep would have removed. The next launch sweeps them.
            break
        case .deferred(.lockUnavailable(let code)):
            lastPersistenceFailure =
                "The queue's housekeeping could not run on this device (lock error \(code))."
        }
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
        // The probe is itself a request, and the session that these credentials were acquired
        // under can have ended since — an account switch is two writes and this pass runs across
        // both. The pass is ABANDONED rather than the jobs held: nothing is wrong with them, and
        // the next pass acquires under whoever is signed in then.
        guard mayStillSend(credentials) else { return }
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
        // A stalled upload is retried by moving the file to a NEW attempt: the task still holding
        // the old one is then distinguishable from its replacement, which is what lets a late
        // answer from it be ignored instead of rewinding the cursor its successor is moving.
        let released = job.released(at: clock()).with { next in
            for index in next.files.indices where !next.files[index].isComplete {
                next.files[index].uploadAttempt = (next.files[index].uploadAttempt ?? 0) + 1
            }
        }
        // Fenced, and BEFORE anything is cancelled: nothing is torn down on a state nobody wrote.
        // The other order would leave a job whose only live task was cancelled and whose manifest
        // still names the attempt that task was sent under.
        guard await save(released, matching: job) != nil else {
            await onChange()
            return
        }
        let live = await scheduler.inFlight().filter { $0.jobID == jobID }
        if !live.isEmpty {
            await scheduler.cancel(live)
        }
        await onChange()
    }

    private func advance(_ job: UploadJob, credentials: OutboxCredentials) async {
        var current = job
        for _ in 0..<Self.maxStepsPerPass {
            // Asked again for every step, beside `permitsNetwork` and for the same reason: the
            // only honest moment is the moment before a request would go out, and each of the
            // three actions below produces one.
            guard mayStillSend(credentials) else { return }
            // Before the planner, and deliberately: a job that is owed an edit parks its next
            // attempt in the far future so that no pass sends its create a third time, and the
            // planner can only answer `.wait` for it. The edit is the one thing still owed, so it
            // is asked for here — from the manifest, which is the only place a relaunch can read
            // it from.
            if current.pendingEdit != nil, current.resolvedMemoUID != nil, current.state != .held {
                guard permitsNetwork() else {
                    await waitForNetwork(current)
                    return
                }
                await applyEdit(current, credentials: credentials)
                return
            }
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
        await save(
            current.backingOff(at: clock(), error: "The server kept asking to start over."),
            matching: current
        )
    }

    // MARK: - the network the phone is on

    /// Whether the grant these credentials were acquired under still stands.
    ///
    /// Asked immediately before EVERY send, and after every await that precedes one — building a
    /// request, slicing a chunk, writing a manifest. Each of those is an instant an account switch
    /// can land in, and a pass that checked only once at its start would spend the rest of itself
    /// sending one account's bytes with another account's authority. Synchronous by construction
    /// (`OutboxCredentialsProviding.isCurrent`), so there is no instant between the answer and the
    /// send it guards.
    private func mayStillSend(_ credentials: OutboxCredentials) -> Bool {
        self.credentials.isCurrent(credentials)
    }

    /// The same question, as a value that travels INTO the executor performing the effect.
    ///
    /// `mayStillSend` answers on this actor; every send then hops to another one, and the hop is a
    /// suspension. What crosses it is this, so the last word before the bytes leave is spoken
    /// where they leave from (`SendAuthority`).
    private func authority(under credentials: OutboxCredentials) -> SendAuthority {
        let provider = self.credentials
        return SendAuthority { provider.isCurrent(credentials) }
    }

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
        await save(job.waitingForNetwork(), matching: job)
    }

    // MARK: - the four calls

    private func isReachable(_ credentials: OutboxCredentials) async -> Bool {
        let request = OutboxRequests.health(baseURL: credentials.serverBaseURL)
        guard let response = try? await http.perform(request, under: authority(under: credentials))
        else { return false }
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
            // Fenced like every other write here, and the one site no test can drive: the only
            // `try` above is `OutboxWire.encode` over a struct of strings and integers, which
            // `JSONEncoder` cannot fail on. The fence costs nothing and the alternative is a site
            // that reads differently from its seventeen neighbours for no reason a reader can see.
            await save(job.held(.serverRefused, error: error.localizedDescription), matching: job)
            return nil
        }
        guard let response = try? await http.perform(request, under: authority(under: credentials))
        else {
            await save(
                job.backingOff(at: clock(), error: "The server could not be reached."),
                matching: job
            )
            return nil
        }
        guard response.isSuccess, let session = OutboxWire.decodeSession(response.body) else {
            // No verdict here. `save` below hops into `OutboxRepository`, a different actor, and a
            // renewal landing in that hop is exactly what this fence is about — so both candidate
            // outcomes travel and the CHOICE is made where the bytes are written.
            let refused = OutboxRefusal(
                statusCode: response.statusCode, issuedUnder: credentials.epoch, what: "upload"
            )
            await save(
                job.applying(refused.disposition(assumingCurrent: true), at: clock()),
                ifStillCurrent: refused.issuedUnder,
                matching: job,
                else: job.applying(refused.disposition(assumingCurrent: false), at: clock())
            )
            return nil
        }
        let next = job.startingUpload(fileID: fileID, session: session)
        // The server has handed out a session. Carrying on with it while the manifest still knows
        // nothing about it is how a chunk gets sent against a uid a relaunch cannot resume.
        //
        // What comes BACK is what carries on, never the candidate: the next write this pass makes
        // is fenced on this value, and the disk keeps dates to whole seconds.
        return await save(next, matching: job)
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
                job: job, file: file, offset: offset, length: length, attempt: file.uploadAttempt
            )
        } catch {
            await save(
                job.backingOff(at: clock(), error: error.localizedDescription), matching: job
            )
            return
        }
        let request = OutboxRequests.chunk(
            baseURL: credentials.serverBaseURL,
            token: credentials.token,
            uploadUID: uploadUID,
            offset: offset
        )
        let identity = OutboxTaskIdentity(
            jobID: job.id, fileID: fileID, offset: offset, attempt: file.uploadAttempt
        )
        // Written down BEFORE the hand-off, and the hand-off does not happen if it was not.
        //
        // The other order — send first, record afterwards — is the one overtake this queue makes
        // against itself: the answer to that chunk re-reads the manifest, and a bookkeeping write
        // that lands after it either loses the cursor the answer just moved or, fenced, is refused
        // for a change this same upload made. So the write goes first and the snapshot every
        // answer is judged against already contains it. Nothing is sent on a state nobody wrote,
        // which is the rule the upload session above is handled under too.
        guard await save(job.with { $0.state = .uploading }, matching: job) != nil else { return }
        // The slice above was an await, and a chunk handed to the background session outlives this
        // pass entirely — it is the one send that cannot be taken back. The authority goes WITH it
        // rather than being checked here, because `upload` is another actor and the hop to it is
        // one more instant for the switch to land in.
        await scheduler.upload(
            request,
            fromFile: chunk,
            identity: identity,
            under: authority(under: credentials),
            issuedUnder: credentials.epoch
        )
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
        guard let response = try? await http.perform(request, under: authority(under: credentials))
        else { return nil }
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
        // The value the disk holds from here on, and the snapshot every outcome below is judged
        // against. Matching the job as it stood BEFORE the create was recorded would reject the
        // create's own bookkeeping; matching the recovery candidate would judge each outcome
        // against a value nothing ever persisted.
        // Nothing is created against a queue that could not be written: the capture waits, whole,
        // rather than being sent while the disk has no record that it was ever tried. And it is the
        // WRITTEN value that stands for the row from here on — see `OutboxPersisting`.
        guard let creating = await save(job.creatingMemo(), matching: job) else { return nil }
        // The manifest write above was an await; the create is the send it precedes, on another
        // executor again — so the authority travels rather than being asked here.
        switch await completion.create(
            job: creating, credentials: credentials, under: authority(under: credentials)
        ) {
        case .created(let uid, let attachments):
            // The capture leaves only when nothing is still owed to it. An edit taken while this
            // create was in flight is owed an apply, so the job advances in place carrying the memo
            // the server named — anything held beside the job would be reaped by the sweep, which
            // reaps by job id. And the removal is fenced on the manifest this pass wrote: a capture
            // a person has since taken back is no longer this answer's to destroy.
            if creating.pendingEdit != nil {
                return await save(
                    creating.awaitingPatch(
                        uid: uid,
                        editKey: creating.idempotencyKey.uuidString,
                        attachments: attachments
                    ),
                    matching: creating
                )
            }
            await repository.delete(creating, ifStillCurrent: creating)
            await onChange()
            return nil
        case .unlinkable(let failure):
            let recovery = OutboxPlanner.recovery(for: creating, failure: failure)
            guard !recovery.isEmpty else {
                await save(
                    creating.held(
                        .serverRefused, error: "The server could not link this memo's files."
                    ),
                    matching: creating
                )
                return nil
            }
            var current = creating.applying(recovery)
            for fileID in recovery.resync {
                if let next = await resync(current, fileID: fileID, credentials: credentials) {
                    current = next
                }
            }
            return await save(current, matching: creating)
        case .retry(let message):
            await save(creating.backingOff(at: clock(), error: message), matching: creating)
            return nil
        case .refused(let message, let refused):
            // Not at the answer, and not here either: `save` hops into `OutboxRepository`, so the
            // choice travels WITH the write and is made under that actor's isolation.
            if let refused {
                await save(
                    creating.held(.serverRefused, error: message),
                    ifStillCurrent: refused.issuedUnder,
                    matching: creating,
                    else: creating.backingOff(at: clock(), error: refused.supersededMessage)
                )
            } else {
                await save(creating.held(.serverRefused, error: message), matching: creating)
            }
            return nil
        }
    }

    /// The edit owed to the memo the create resolved to, applied.
    ///
    /// ONE transmission per launch, claimed synchronously here before any hop. Two overlapping
    /// invocations of this — a drain, and the `advance` a finished chunk re-enters — must be one
    /// request on the wire, and the second is REFUSED rather than joined: a launch that has
    /// already asked is waiting for its answer, and asking again buys nothing the edit key does
    /// not already give. A relaunch claims afresh on purpose — that is the whole recovery — and it
    /// is safe because the key makes the second transmission a replay rather than a second edit.
    private func applyEdit(_ job: UploadJob, credentials: OutboxCredentials) async {
        guard editsTransmitted.insert(job.id).inserted else { return }
        // Nothing is sent on a state nobody wrote, and the written value is what every outcome
        // below is judged against — the same rule the create is sent under.
        guard
            let claimed = await save(
                job.with { $0.patchAttempt = ($0.patchAttempt ?? 0) + 1 }, matching: job
            )
        else { return }
        switch await completion.patch(
            job: claimed, credentials: credentials, under: authority(under: credentials)
        ) {
        case .applied:
            // Fenced on the manifest this pass wrote: an answer that outlived a cancel, or a
            // relaunch that finished the same edit first, is no longer this pass's to act on — and
            // this delete takes the person's only copy of the pictures with it.
            await repository.delete(claimed, ifStillCurrent: claimed)
            await onChange()
        case .retry(let message):
            await save(claimed.backingOff(at: clock(), error: message), matching: claimed)
        case .refused(let message, let refused):
            // Not decided here: `save` hops into `OutboxRepository`, and a renewal landing in that
            // hop is exactly what this fence is about, so both outcomes travel and the choice is
            // made where the write is.
            if let refused {
                await save(
                    claimed.held(.serverRefused, error: message),
                    ifStillCurrent: refused.issuedUnder,
                    matching: claimed,
                    else: claimed.backingOff(at: clock(), error: refused.supersededMessage)
                )
            } else {
                await save(claimed.held(.serverRefused, error: message), matching: claimed)
            }
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
        guard let job = await repository.job(result.identity.jobID) else { return }
        // An answer from a superseded attempt — a task a reconcile cancelled, or a duplicate that
        // outlived the one whose answer already landed. The job has moved on, and applying this
        // would rewind the cursor and re-send bytes the server already holds.
        //
        // The offset alone cannot tell the two apart after a retry: the replacement starts at the
        // very offset the task it replaced was sent at, so the attempt the task PRESENTED is what
        // says which of them this answer belongs to.
        guard let file = job.file(result.identity.fileID),
            file.bytesConfirmed == result.identity.offset,
            file.uploadAttempt == result.identity.attempt
        else { return }
        // Dropped only once the answer is this file's to act on, and only the chunk this task was
        // sent FROM. A predecessor answering late would otherwise take the replacement's slice out
        // from under a transfer that is still running.
        await repository.removeChunk(
            at: repository.chunkURL(
                jobID: result.identity.jobID,
                fileID: result.identity.fileID,
                offset: result.identity.offset,
                attempt: result.identity.attempt
            )
        )

        let fileID = result.identity.fileID
        let credentials = await credentials.currentCredentials()
        var next = job
        // Set when only the server can say where the upload stands, which is the one decision
        // here that cannot be made offline.
        var askTheServer: String?
        // Set when the answer was a refusal, so the write below can choose between holding it and
        // queueing it for the successor under the isolation that performs the write.
        var refused: OutboxRefusal?

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
            // The chunk carries the epoch it was SENT under (`ChunkResult.epoch`), because its
            // answer arrives in a later pass — possibly in a process launched for it alone — and
            // by then the only thing that knows which credential earned it is the answer itself.
            // A nil epoch is a task from before this record existed, or one adopted across a
            // relaunch: unknown, so it is treated as current and holds, exactly as it did before.
            //
            // No verdict here either, and for the same reason as `startUpload`: the write is a hop
            // away. The snapshot at the top of this method is still what `resync` sends under; it
            // is simply no longer what any decision is read from.
            let refusal = OutboxRefusal(
                statusCode: code, issuedUnder: result.epoch, what: "chunk"
            )
            refused = refusal
            next = job.applying(refusal.disposition(assumingCurrent: true), at: clock())
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
                await save(job.waitingForNetwork(), matching: job)
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
        let written: UploadJob?
        if let refused {
            // `job` is the manifest as it stood when this answer was matched against it, at the top
            // of this method and before every suspension since. It is the snapshot both fences are
            // asked about: a pass that advanced or finished this capture while the credential was
            // being acquired owns it now, and this answer is no longer about the row on disk.
            written = await save(
                next,
                ifStillCurrent: refused.issuedUnder,
                matching: job,
                else: job.applying(refused.disposition(assumingCurrent: false), at: clock())
            )
        } else {
            // The same snapshot the refusal fence above is asked about, and for the same reason:
            // this answer is about the row `job` describes. A pass that released, held, advanced
            // or finished the capture while the credential was being acquired owns it now.
            written = await save(next, matching: job)
        }
        await onChange()
        guard let written else { return }
        next = written
        // Nobody is signed in yet (a cold background wake, before the session is restored). What
        // the server said is on disk; the next drain carries on from there. The same is true of a
        // session that ENDED while the chunk was in flight: the answer is recorded, and the next
        // pass carries on under whoever is signed in then.
        guard let credentials, mayStillSend(credentials) else { return }
        await advance(next, credentials: credentials)
        await onChange()
    }

    // MARK: - helpers

    private func hold(_ job: UploadJob, reason: HoldReason) async {
        guard job.state != .held || job.holdReason != reason else { return }
        await save(job.held(reason, error: Self.message(for: reason)), matching: job)
    }

    /// An ORDINARY write: no server has said anything about a credential, so there is no epoch to
    /// ask about — but there is still a snapshot, and it is still the whole question.
    ///
    /// Every write this drain makes crosses the hop into `OutboxRepository`, and every one of them
    /// was decided from a value read before that hop. So each is asked the same question as a
    /// refusal is, through the same fence: is this still the capture I decided about. `nil` means
    /// it is not — the person released it, deleted it or held it, or another pass advanced or
    /// finished it — and the caller stops where it stands, writing nothing further for that job.
    /// Nothing is re-queued: whoever overtook the capture owns its next step.
    ///
    /// The fallback is the candidate itself and is unreachable, because an unknown epoch reads as
    /// current — the choice this signature exists for is the refusal's, not this one's.
    @discardableResult
    private func save(_ job: UploadJob, matching snapshot: UploadJob) async -> UploadJob? {
        await save(job, ifStillCurrent: nil, matching: snapshot, else: job)
    }

    /// The same write, with the snapshot this decision was taken from and the grant it was taken
    /// under carried into it, so BOTH fences are asked inside the repository — see
    /// `OutboxPersisting.save(_:ifStillCurrent:matching:else:)`. Every write this file makes lands
    /// through here — the ordinary ones through the convenience above, which leaves the epoch
    /// unknown — so there is one rule for every caller: nil means stop where you stand.
    ///
    /// The two nils mean the same thing to the caller — stop — but only ONE of them is a storage
    /// failure. A write the fences refused is a capture a later pass already owns, so nothing is
    /// reported and nothing is held: holding for that would be this queue inventing a problem out
    /// of another pass doing its job. That is why the refusal path leaves `lastPersistenceFailure`
    /// cleared and never reaches `holdUnsaved`.
    ///
    /// - Returns: the job that actually landed, which is not always the one that was offered.
    @discardableResult
    private func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async -> UploadJob? {
        do {
            let written = try await repository.save(
                job, ifStillCurrent: epoch, matching: snapshot, else: fallback
            )
            lastPersistenceFailure = nil
            return written
        } catch {
            lastPersistenceFailure = Self.storageMessage(error)
            // The recovery is ONE MORE WRITE, and the window that swallowed the first one is still
            // open: the throw, this continuation and the write below are all suspensions another
            // pass can advance or finish the capture inside. Carrying the same snapshot is what
            // stops a failed fenced write from putting back, as a hold, the state the fence had
            // just refused to write.
            await holdUnsaved(job, error: error, matching: snapshot)
            return nil
        }
    }

    /// - Parameter snapshot: the manifest this hold is about — the same one the write that failed
    ///   was fenced on. Where it no longer matches the disk NOTHING is written: a capture another
    ///   pass has advanced or finished is not this failure's to describe, and describing it would
    ///   resurrect exactly what the fence above refused to resurrect. There is no unconditional
    ///   form: every caller of both `save`s has a snapshot, so a recovery without one would be a
    ///   second answer to a question this file answers once.
    private func holdUnsaved(
        _ job: UploadJob,
        error: any Error,
        matching snapshot: UploadJob
    ) async {
        guard job.state != .held || job.holdReason != .storageFailed else { return }
        let held = job.held(.storageFailed, error: Self.storageMessage(error))
        do {
            // The same checked write, so there is one implementation of "is this still the capture
            // I decided about" and not a second one here. The epoch is deliberately unknown — a
            // storage failure is not the server's word about a credential — and the fallback is
            // unreachable because unknown reads as current.
            _ = try await repository.save(
                held, ifStillCurrent: nil, matching: snapshot, else: held
            )
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

extension UploadJob {
    /// What a disposition IS, as a job.
    ///
    /// The other half of `OutboxRefusal.disposition(assumingCurrent:)`, and it lives here rather
    /// than on the refusal because only the engine holds a clock — a back-off is an instant as much
    /// as it is a sentence.
    func applying(_ disposition: OutboxRefusal.Disposition, at instant: Date) -> UploadJob {
        switch disposition {
        case .hold(let message): held(.serverRefused, error: message)
        case .backOff(let message): backingOff(at: instant, error: message)
        }
    }
}
