import CryptoKit
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
public actor OutboxEngine: OutboxChunkHandling, WholeAnswerHandling {
    /// A ceiling on how many decisions one job may take in a single pass. It is not a retry limit
    /// (there is none): it stops a server that keeps answering "recover this" from spinning the
    /// drain, and hands the job to the ordinary backoff instead.
    static let maxStepsPerPass = 32
    /// How many times one whole-lane advance plans again after the listing hop saw `owned` move,
    /// before it hands the row to another drain instead.
    static let maxPlanRestarts = 4

    /// The jobs holding this launch's one PATCH claim. In memory on purpose: it is the claim that
    /// keeps two invocations inside one launch from being two requests, and a relaunch is meant to
    /// ask again. It is claimed in `applyEdit` before the fenced write and given back by every
    /// outcome that leaves this job alive — a failed claim, a retry, a refusal, and an applied edit
    /// whose terminal delete lost its fence or could not remove the manifest. Only an applied edit
    /// that DELETED the job keeps it, because nothing can ask about a job that is gone.
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
    /// Moves on every hand-off and every answer, so `reconcile` can tell a pair of snapshots that
    /// nothing moved under from one that something did.
    private var handOffGeneration = 0
    /// Answers and hand-offs still running: either can have written a row that names a task no
    /// list can show yet, or be about to hand over one for a row already on disk.
    private var handOffsInProgress = 0
    /// The jobs a `release` is running for, claimed synchronously before its first hop. A second
    /// release for one already releasing is REFUSED, not joined: the first call owns this job's
    /// next term, whether it has minted it yet or not, and a second bump would mint one for a
    /// transfer nobody scheduled.
    private var releasing: Set<UUID> = []
    /// The jobs whose memo create is being sent, claimed synchronously before the first hop by
    /// whichever of a drain pass or an answer continuation reaches it first. A second claimant is
    /// REFUSED, not joined: the first owns the create and its outcome. Released on every outcome,
    /// a successful delete included — after a delete the repository is the fence, because a save
    /// against a row that is gone writes nothing and so sends nothing, and a claim kept past it
    /// would refuse the replay a relaunch is entitled to send under the same key.
    private var creating: Set<UUID> = []
    /// Answer continuations still running (`handle`).
    private var continuationsInFlight = 0
    /// Callers of `untilQuiescent()`, resumed whenever something that keeps the engine busy ends.
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    /// Whether the app may start new work. Consulted here only as an early skip; the fence is the
    /// sender, which asks it through the authority a work send carries (`SendPurpose.work`).
    private let schedulingGate: SchedulingGate
    /// The whole lane's session, when this engine is composed with one. Without it no capture is
    /// ever put on the whole lane, which keeps every composition that predates it unchanged.
    private let uploads: (any OutboxUploadScheduling)?
    /// Whole tasks handed to `replace`, by identifier, with the file each was carrying. Their own
    /// answers are superseded by the successor's term, whenever they arrive — a cancelled task
    /// still answers, without a status.
    private var replacing: [Int: WholeFileRef] = [:]
    /// Files something in this engine is working on right now, counted: an answer being applied,
    /// a hand-off that has not yet given the file its task, or a replacement from the call to
    /// `replace` until the scheduler reports it settled — deferral and successor included. Such
    /// a file is never a candidate to send again — its task can be finished and gone from the list
    /// while the success it produced is still on its way to disk, and a retry then would move the
    /// file's term past that success and throw it away. Claimed synchronously, before any hop.
    private var owned: [WholeFileRef: Int] = [:]
    /// Moves on every claim and every release in `owned`. A pass that read the task listing across
    /// a hop compares it: unchanged, the listing and `owned` describe one instant; moved, a claim
    /// or a settlement landed inside the hop — a successor created and released, say — and the
    /// listing may be missing the very task that now carries the file.
    private var ownershipGeneration = 0
    /// Whole tasks whose terminal answer has reached `handle` in this launch. A listed task counts
    /// as carrying its file — whatever its term, `.canceling` included — until it is here, is
    /// listed as completed, or is gone from a fresh listing. Keyed by task, naming its row, and
    /// pruned once a listing no longer names the task or its row is gone, released or abandoned,
    /// so it does not grow with the life of the process.
    private(set) var ended: [Int: UUID] = [:]
    /// Drains `requestDrain` has started that have not begun yet, so quiescence waits for them.
    private var drainsKicked = 0

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
        onChange: @escaping @Sendable () async -> Void = {},
        schedulingGate: SchedulingGate = SchedulingGate(),
        uploads: (any OutboxUploadScheduling)? = nil
    ) {
        self.schedulingGate = schedulingGate
        self.uploads = uploads
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
        let plan = try await reconcileChunks()
        try await reconcileWhole()
        return plan
    }

    /// The whole lane's half of `reconcile`: a task this lane cannot read, and a task no row needs
    /// any more, are cancelled. Cancelling sends nothing, so it is not new work and a wake does it
    /// too. A file whose record has no task is left to the planner, which sends it again only while
    /// scheduling is open.
    private func reconcileWhole() async throws {
        guard let uploads, handOffsInProgress == 0 else { return }
        let generation = handOffGeneration
        let owners = ownershipGeneration
        let answeredBefore = Set(ended.keys)
        let unreadable = Set(await uploads.cancelUnreadable())
        let tasks = await uploads.tasks()
        let jobs = try await repository.loadJobs()
        pruneEnded(answeredBefore, listing: tasks, rows: Set(jobs.map(\.id)))
        // The same rule as the chunk lane's: a pair something moved under is not acted on — and a
        // replacement settling in between is such a move, its successor possibly in neither read.
        guard generation == handOffGeneration, owners == ownershipGeneration,
            handOffsInProgress == 0
        else { return }
        let stale = WholeReconciliation.plan(jobs: jobs, tasks: tasks).cancelled.filter {
            !unreadable.contains($0) && replacing[$0] == nil
        }
        if !stale.isEmpty {
            await uploads.cancel(stale)
        }
    }

    private func reconcileChunks() async throws -> ReconciliationPlan {
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
        // An answer or a hand-off can land in either wait below: between the rows and the list it
        // gets a live successor cancelled, between the list and the rows it gets a job whose
        // successor is live drained a second time. So a pair counts only if nothing moved under it.
        var adopted: [OutboxTaskIdentity] = []
        for _ in 0..<40 {
            let generation = handOffGeneration
            guard handOffsInProgress == 0 else {
                // Long enough in total for a chunk to be sliced and handed over.
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }
            let inFlight = await scheduler.inFlight()
            let jobs = try await repository.loadJobs()
            let plan = OutboxReconciliation.plan(jobs: jobs, inFlight: inFlight)
            guard generation == handOffGeneration, handOffsInProgress == 0 else {
                adopted = plan.adopted
                continue
            }
            if !plan.cancelled.isEmpty {
                await scheduler.cancel(plan.cancelled)
            }
            return plan
        }
        // Never settled: nothing is torn down or re-sent on a pair that kept moving; the next pass
        // reconciles.
        return ReconciliationPlan(adopted: adopted, cancelled: [], drainable: [])
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
        repeat {
            drainRequested = false
            await drainOnce()
        } while drainRequested
        isDraining = false
        settle()
    }

    /// Returns once nothing in this engine is still working: no drain pass running, no drain
    /// requested, no answer continuation in flight and no memo create claimed.
    ///
    /// It waits for the OWNING work, whoever started it. A second `drain()` returns at once when a
    /// pass is already running, so a caller that only awaited its own drain could be told the
    /// engine is done while another entry point's create is still out.
    ///
    /// - Parameter parked: told each time the caller suspends, after it is registered — how a test
    ///   learns the wait has begun without sleeping.
    public func untilQuiescent(parked: @escaping @Sendable () -> Void = {}) async {
        while !isQuiescent {
            await withCheckedContinuation {
                quiescenceWaiters.append($0)
                parked()
            }
        }
    }

    private var isQuiescent: Bool {
        !isDraining && !drainRequested && continuationsInFlight == 0 && creating.isEmpty
            && drainsKicked == 0
    }

    /// Asks for another pass without waiting for it: folded into the running drain when there is
    /// one, started on its own otherwise. Never awaited from inside other work — a pass run inline
    /// would meet that work's own in-progress marks and give up on the row it was asked for.
    private func requestDrain() {
        guard !isDraining else {
            drainRequested = true
            return
        }
        drainsKicked += 1
        Task { await self.kickedDrain() }
    }

    private func kickedDrain() async {
        drainsKicked -= 1
        await drain()
    }

    /// Wakes every waiter so each asks again; the loop in `untilQuiescent` is the judge.
    private func settle() {
        guard isQuiescent, !quiescenceWaiters.isEmpty else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters = []
        for waiter in waiters { waiter.resume() }
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
        await replaceMismatched(credentials)
        for job in candidates {
            await advance(job, credentials: credentials)
        }
        await onChange()
    }

    /// Clears a hold — what "Try again" on a pending row does.
    public func release(jobID: UUID) async {
        // A retry is new work, and new work waits for the app to be active. Nothing is written:
        // the hold stands as it is and the next foreground's Try again finds it.
        guard schedulingGate.isOpen else { return }
        // Claimed before any hop, per job: `inFlight()` suspends below and a second Try again
        // landing in that hop must not mint a second term.
        guard releasing.insert(jobID).inserted else { return }
        defer { releasing.remove(jobID) }
        guard let job = await repository.job(jobID) else { return }
        // A capture the editor holds is not retried from here: its way back into the queue is the
        // re-submit that clears the mark. Nothing is written, so the manifest the editor was handed
        // stays exactly as it was taken back.
        guard job.cancelledAt == nil else { return }
        // A PATCH this launch has claimed is not retried by hand — that claim IS the outstanding
        // request, and a second one would be a second request on the wire. An edit merely
        // unanswered is a different thing: the hold is cleared and the next drain replays the same
        // key over the same body, which is the only way out of a hold a stale refusal left.
        guard !editsTransmitted.contains(jobID) else { return }
        // A stalled upload is retried by moving the file to a NEW attempt: the task still holding
        // the old one is then distinguishable from its replacement, which is what lets a late
        // answer from it be ignored instead of rewinding the cursor its successor is moving.
        let released = job.released(at: clock()).bumpingAttempts().job
        // Fenced, and BEFORE anything is cancelled: nothing is torn down on a state nobody wrote.
        // The other order would leave a job whose only live task was cancelled and whose manifest
        // still names the attempt that task was sent under.
        guard let saved = await save(released, matching: job) else {
            await onChange()
            return
        }
        // Released: its ended tasks are behind the new terms and are forgotten.
        pruneEnded(of: jobID)
        // Only the tasks this retry left behind. A task already carrying the attempt the write
        // above minted IS the replacement — cancelling it would tear down the transfer this call
        // exists to start. A legacy task carries no attempt at all and is never the replacement.
        let bumped = saved.attemptTerms
        let live = OutboxTaskIdentity.supersededTasks(
            inFlight: await scheduler.inFlight(), bumped: bumped, jobID: jobID)
        if !live.isEmpty {
            await scheduler.cancel(live)
        }
        if let uploads {
            let superseded = await uploads.tasks().compactMap { listing -> Int? in
                guard let task = WholeTaskIdentity(taskDescription: listing.taskDescription),
                    task.jobID == jobID,
                    (saved.file(task.fileID)?.uploadAttempt ?? 0) != task.attempt
                else { return nil }
                return listing.taskIdentifier
            }
            if !superseded.isEmpty {
                await uploads.cancel(superseded)
            }
        }
        await onChange()
    }

    private func advance(_ job: UploadJob, credentials: OutboxCredentials) async {
        // The planner's first question, asked here too because the edit branch below builds a
        // request from these credentials before the planner is reached. Asked on entry rather
        // than by each caller: a chunk answer re-enters with whoever is signed in NOW, and a job
        // captured under another account must reach no request down any path into this loop.
        guard job.binding.matches(credentials) else {
            await hold(job, reason: .accountMismatch)
            return
        }
        var current = job
        for _ in 0..<Self.maxStepsPerPass {
            // A capture taken back to the editor is answered by nothing: not the edit below, not
            // the planner, not a step this pass already earned.
            guard current.cancelledAt == nil else { return }
            // Asked again for every step, beside `permitsNetwork` and for the same reason: the
            // only honest moment is the moment before a request would go out, and each of the
            // three actions below produces one.
            guard mayStillSend(credentials) else { return }
            // Before the planner, and deliberately: this branch takes every pass in which the
            // planner could answer `.createMemo` again, which is what keeps a create whose memo is
            // already named from being sent a third time. It is asked for from the manifest, the
            // only place a relaunch can read it from. Its own backoff is honoured here — a refused
            // edit waits like anything else — and a file still missing bytes goes through the
            // planner first, because an edit names the memo's complete picture list and a staged
            // picture has no uid until it is uploaded.
            if current.pendingEdit != nil, current.resolvedMemoUID != nil, current.state != .held {
                // Before the completeness gate, and it is what opens it: an original the create's
                // answer never named has no uid the PATCH could name it by, so it is uploaded
                // again and the server folds identical bytes back onto the attachment it holds.
                guard let recovered = await stageUnnamedOriginals(current) else { return }
                current = recovered
                // The backoff is asked HERE and not around the recovery above: making an original
                // nameable again writes to this device and asks nothing of the server, and a
                // capture that waits for its backoff before it re-stages waits for the upload too.
                if clock() >= current.nextAttemptAt, current.files.allSatisfy(\.isComplete) {
                    // An edit is new work: it waits for the foreground, and nothing is claimed or
                    // written for it here. The sender asks the same gate again (`applyEdit`).
                    guard schedulingGate.isOpen else { return }
                    guard permitsNetwork() else {
                        await waitForNetwork(current)
                        return
                    }
                    // Built here, before anything is claimed: the build is the one part of this
                    // that can fail without a server, and an edit that never went out must leave
                    // the capture exactly as a person could still take it back.
                    let request: URLRequest
                    do {
                        request = try OutboxRequests.patchMemo(
                            baseURL: credentials.serverBaseURL,
                            token: credentials.token,
                            job: current
                        )
                    } catch {
                        await hold(current, reason: .editIncomplete)
                        return
                    }
                    await applyEdit(current, request: request, credentials: credentials)
                    return
                }
                // A file still needs its bytes, or the backoff has not run out. The planner below
                // uploads or waits, whichever it is, and a later pass re-enters here.
            }
            if uploads != nil, current.lane == .whole || Self.claimsWhole(current) {
                await advanceWhole(current, credentials: credentials)
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
                // An early skip, and only that: the sender asks the gate again where the request
                // leaves (`authority(under:for:)`).
                guard schedulingGate.isOpen else { return }
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
                guard schedulingGate.isOpen else { return }
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
                // The one step a closed gate lets through, and one claimant at a time.
                guard creating.insert(current.id).inserted else { return }
                let next = await complete(current, credentials: credentials)
                creating.remove(current.id)
                settle()
                guard let next else { return }
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
    ///
    /// A send that starts new work also carries the scheduling gate, asked in the same instant.
    /// The memo create and the health probe do not: finishing a transfer that has already happened
    /// is the one thing a background wake is for, and the probe precedes it.
    private func authority(
        under credentials: OutboxCredentials, for purpose: SendPurpose
    ) -> SendAuthority {
        let provider = self.credentials
        let stillCurrent: @Sendable () -> Bool = { provider.isCurrent(credentials) }
        guard purpose == .work else { return SendAuthority(stillCurrent) }
        let gate = schedulingGate
        return SendAuthority(stillCurrent, scheduling: { gate.isOpen })
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
    /// - Returns: false when the fence refused the write: the row moved and says something else.
    @discardableResult
    private func waitForNetwork(_ job: UploadJob) async -> Bool {
        guard job.state != .waiting || job.waitReason != .homeNetwork else { return true }
        return await save(job.waitingForNetwork(), matching: job) != nil
    }

    // MARK: - the four calls

    private func isReachable(_ credentials: OutboxCredentials) async -> Bool {
        let request = OutboxRequests.health(baseURL: credentials.serverBaseURL)
        let probing = authority(under: credentials, for: .probe)
        guard let response = try? await http.perform(request, under: probing) else { return false }
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
        let sending = authority(under: credentials, for: .work)
        let response: OutboxHTTPResponse
        do {
            response = try await http.perform(request, under: sending)
        } catch {
            // Withheld by the gate: nothing went out and nothing is wrong, so nothing is written.
            if error is SendAuthorityWithdrawn, sending.withdrawal() == .scheduling { return nil }
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
        handOffGeneration += 1
        handOffsInProgress += 1
        defer {
            handOffsInProgress -= 1
            handOffGeneration += 1
        }
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
            under: authority(under: credentials, for: .work),
            issuedUnder: credentials.epoch
        )
    }

    /// The offset HEAD: the server's own count, which is the only thing a resume trusts.
    private func resync(
        _ job: UploadJob,
        fileID: UUID,
        credentials: OutboxCredentials
    ) async -> Resync {
        guard let file = job.file(fileID), let uploadUID = file.uploadUID else {
            return .unanswered
        }
        let request = OutboxRequests.offset(
            baseURL: credentials.serverBaseURL, token: credentials.token, uploadUID: uploadUID
        )
        let sending = authority(under: credentials, for: .work)
        let response: OutboxHTTPResponse
        do {
            response = try await http.perform(request, under: sending)
        } catch {
            if error is SendAuthorityWithdrawn, sending.withdrawal() == .scheduling {
                return .withheld
            }
            return .unanswered
        }
        if response.statusCode == 404 {
            // The session expired or was reaped. The ORIGINAL is untouched — it starts again.
            return .resynced(job.clearingLostUpload(fileID: fileID))
        }
        guard response.isSuccess,
            let raw = response.header(OutboxRequests.offsetHeader),
            let offset = Int64(raw)
        else { return .unanswered }
        return .resynced(job.advancing(fileID: fileID, bytesConfirmed: offset))
    }

    /// The originals this create sent, named by the attachments the answer came back with.
    ///
    /// Asked exactly here, in the pass that writes the create's outcome down: the answer and the
    /// bytes it describes are both in hand, and the job has not yet been saved — so no later
    /// response can rename a picture that this one already named.
    private func named(_ job: UploadJob, as answer: [ResolvedAttachment]) -> UploadJob {
        let originals = job.files.filter { $0.stagedForEdit != true }
        var digests: [UUID: String] = [:]
        for file in originals {
            if let digest = Self.digest(of: repository.mediaURL(job: job, file: file)) {
                digests[file.id] = digest
            }
        }
        let bound = OutboxAttachmentIdentity.bind(
            files: originals, digests: digests, answer: answer)
        var named = job
        for index in named.files.indices {
            named.files[index].attachmentUID = bound[named.files[index].id]
        }
        return named
    }

    /// A file's SHA-256, hex and lowercase, read a megabyte at a time so a video does not arrive in
    /// memory whole. A copy this device cannot open, or cannot finish reading, has NO digest —
    /// a hash of the bytes that did arrive is a different file's identity — and identity then
    /// falls back to the order the answer came in, which is the honest state of that knowledge.
    private static func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
        let sending = authority(under: credentials, for: .memoCreate)
        switch await completion.create(
            job: creating, credentials: credentials, under: sending
        ) {
        case .created(let uid, let attachments):
            // The capture leaves only when nothing is still owed to it. An edit taken while this
            // create was in flight is owed an apply, so the job advances in place carrying the memo
            // the server named — anything held beside the job would be reaped by the sweep, which
            // reaps by job id. And the removal is fenced on the manifest this pass wrote: a capture
            // a person has since taken back is no longer this answer's to destroy.
            if creating.pendingEdit != nil {
                return await save(
                    named(creating, as: attachments).awaitingPatch(
                        uid: uid,
                        editKey: creating.editKey ?? creating.idempotencyKey.uuidString
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
                switch await resync(current, fileID: fileID, credentials: credentials) {
                case .resynced(let next):
                    current = next
                case .unanswered:
                    break
                case .withheld:
                    // The gate closed before the server could say where this upload stands. The
                    // recovery is not written: written without that answer it reads as complete,
                    // and the planner would send the same create again. The row stays as the
                    // create's own write left it, and the foreground recovers it; a scheduling
                    // withdrawal writes nothing, no backoff included.
                    return nil
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
    /// ONE transmission at a time, claimed synchronously here before any hop. Two overlapping
    /// invocations of this — a drain, and the `advance` a finished chunk re-enters — must be one
    /// request on the wire, and the second is REFUSED rather than joined: this job is waiting for
    /// an answer, and asking again buys nothing the edit key does not already give. The claim is
    /// given back the moment an outcome leaves this job alive, so the backoff that outcome wrote
    /// can be served by a later pass; it is kept only where the applied edit's fenced delete
    /// succeeded, and there is then no job left to ask about.
    /// A relaunch claims afresh on purpose — that is the whole recovery — and it is safe because
    /// the key makes the second transmission a replay rather than a second edit.
    private func applyEdit(
        _ job: UploadJob, request: URLRequest, credentials: OutboxCredentials
    ) async {
        guard editsTransmitted.insert(job.id).inserted else { return }
        // Nothing is sent on a state nobody wrote, and the written value is what every outcome
        // below is judged against — the same rule the create is sent under. The same write records
        // that the edit is in flight, which is what makes the body the server is answering about
        // immutable until it answers.
        guard
            let claimed = await save(
                job.with {
                    $0.patchAttempt = ($0.patchAttempt ?? 0) + 1
                    // Only when it is not already set: a replay is the same edit, and moving the
                    // instant would say the uncertainty began when this transmission did.
                    $0.editUnansweredSince = $0.editUnansweredSince ?? clock()
                },
                matching: job
            )
        else {
            editsTransmitted.remove(job.id)
            return
        }
        switch await completion.patch(
            job: claimed, request: request, credentials: credentials,
            under: authority(under: credentials, for: .work)
        ) {
        case .applied:
            // Fenced on the manifest this pass wrote: an answer that outlived a cancel, or a
            // relaunch that finished the same edit first, is no longer this pass's to act on — and
            // this delete takes the person's only copy of the pictures with it.
            guard await repository.delete(claimed, ifStillCurrent: claimed) else {
                // The manifest moved under the PATCH, or this device could not remove it, so this
                // pass has not destroyed it: the claim goes back and the job stands whole —
                // `pendingEdit` and `editKey` intact — so the next drain replays the SAME key and
                // the delete is tried again.
                editsTransmitted.remove(job.id)
                await onChange()
                return
            }
            await onChange()
        case .withheld:
            // Never sent: the gate closed before the request left. Only the claim goes back; the
            // manifest stays as the claim wrote it, `editUnansweredSince` included, so the
            // foreground replays the same key, and no backoff delays it.
            editsTransmitted.remove(job.id)
        case .retry(let message):
            // Still owed, and the transmission's fate unknown: the request may have reached the
            // server, so `editUnansweredSince` STAYS SET — the body and key it may be holding are immutable
            // until an answer settles it, and the server answers the replay under that key before
            // it checks the upload uids. Only the claim goes back, for the backoff below.
            await save(claimed.backingOff(at: clock(), error: message), matching: claimed)
            editsTransmitted.remove(job.id)
        case .refused(let message, let refused):
            // A 404 is answered before the key is looked up, so it says nothing about this edit —
            // only that the memo it is owed to is gone. Its own reason, because the row's actions
            // are read from the reason and Remove belongs on this hold and no other.
            let reason: HoldReason = refused.statusCode == 404 ? .memoGone : .serverRefused
            // The only refusal that settles the key: the server decided it from the body this
            // edit is frozen on, so the first transmission would have been answered the same way
            // and cannot have committed. Everything else leaves the capture uncertain, and the
            // way back out is a replay under the same key.
            let settles = refused.deterministicOnTheFrozenBody
            // Not decided here: `save` hops into `OutboxRepository`, and a renewal landing in that
            // hop is exactly what this fence is about, so both outcomes travel and the choice is
            // made where the write is. The superseded one keeps the marker whatever the status —
            // a refusal a replaced credential earned answers nothing about the key either.
            await save(
                claimed.held(reason, error: message)
                    .with { $0.editUnansweredSince = settles ? nil : $0.editUnansweredSince },
                ifStillCurrent: refused.issuedUnder,
                matching: claimed,
                else: claimed.backingOff(at: clock(), error: refused.supersededMessage)
            )
            editsTransmitted.remove(job.id)
        }
    }

    /// Drops whatever this job still has in flight, and writes nothing.
    ///
    /// The manifest is the caller's to write — a cancel writes its mark first and then asks for
    /// this — so that nothing is ever torn down on a state nobody wrote.
    public func abandonTasks(jobID: UUID) async {
        let live = await scheduler.inFlight().filter { $0.jobID == jobID }
        if !live.isEmpty {
            await scheduler.cancel(live)
        }
        guard let uploads else { return }
        let whole = await uploads.tasks().compactMap { listing -> Int? in
            WholeTaskIdentity(taskDescription: listing.taskDescription)?.jobID == jobID
                ? listing.taskIdentifier : nil
        }
        if !whole.isEmpty {
            await uploads.cancel(whole)
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
        continuationsInFlight += 1
        defer {
            continuationsInFlight -= 1
            settle()
        }
        handOffGeneration += 1
        guard let job = await repository.job(result.identity.jobID) else { return }
        // A capture a person has taken back to the editor: the bytes this answer reports are no
        // longer the queue's business, and banking them would move a manifest the editor holds.
        // Before the chunk is dropped and before anything is written, so the job is left exactly
        // as the cancel wrote it.
        guard job.cancelledAt == nil else { return }
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
            // Asking is new work, and it waits for the foreground: nothing is written, and the
            // row — a record with no task — is drainable at the next open-gate pass.
            guard schedulingGate.isOpen else {
                await onChange()
                return
            }
            // Only the server can say where this upload stands, and asking is a request like any
            // other. On a network this capture may not use it is not asked: the capture parks,
            // with nothing counted against it, because nothing was tried.
            guard permitsNetwork() else {
                await save(job.waitingForNetwork(), matching: job)
                await onChange()
                return
            }
            var asked = Resync.unanswered
            if let credentials {
                asked = await resync(job, fileID: fileID, credentials: credentials)
            }
            switch asked {
            case .resynced(let resynced):
                next = resynced
            case .withheld:
                await onChange()
                return
            case .unanswered:
                next = job.backingOff(at: clock(), error: askTheServer)
            }
        }

        // The cursor moves HERE or not at all. Going on to the next chunk from a count only this
        // process holds is what makes the server's answer to it unusable: `handle` matches an
        // answer against the offset on disk, and one that no longer matches is thrown away.
        // From its write on, this answer's row can name a successor no list shows yet. Not before:
        // a "Try again" can drain inside the credential wait above, and must not wait on it.
        handOffsInProgress += 1
        defer {
            handOffsInProgress -= 1
            handOffGeneration += 1
        }
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

    // MARK: - the whole lane

    /// Whether a row nothing has started yet goes on the whole lane when this engine carries one.
    ///
    /// Claimed at the first hand-off rather than at enqueue, so a row an older build or the share
    /// extension wrote needs no change of its own. A row any file of which already has a session
    /// began on the chunk lane and finishes there, and a row owed an edit is left to that path.
    static func claimsWhole(_ job: UploadJob) -> Bool {
        job.transport == nil && !job.files.isEmpty
            && job.files.allSatisfy { $0.uploadUID == nil }
            && job.resolvedMemoUID == nil && job.pendingEdit == nil && job.state != .creating
    }

    /// One whole-lane capture's next step. Every file it sends goes in ONE hand-off, so a
    /// background wake only has answers to collect and a memo to create.
    private func advanceWhole(_ job: UploadJob, credentials: OutboxCredentials) async {
        guard let uploads else { return }
        for _ in 0...Self.maxPlanRestarts {
            guard await passWhole(job.id, credentials: credentials, on: uploads) else { return }
        }
        // Every plan met a queue that moved under it: another drain, asked for and not awaited —
        // the caller may be an answer still holding its in-progress marks.
        requestDrain()
    }

    /// One plan for one whole-lane row, carried out. True when it must be planned again: a claim
    /// or a release in `owned` landed while the row and the listing were being read, so the two
    /// no longer describe one instant.
    private func passWhole(
        _ jobID: UUID, credentials: OutboxCredentials, on uploads: any OutboxUploadScheduling
    ) async -> Bool {
        // Taken before the row and the listing are read, and compared once both are in hand.
        let observed = ownershipGeneration
        // Planned from the row as it stands now, not the caller's copy: a replacement or an answer
        // may have moved a file's term since, and a plan from the older copy opens a session on
        // the server that its fenced write then refuses.
        guard var current = await repository.job(jobID) else { return false }
        for _ in 0..<Self.maxStepsPerPass {
            guard current.cancelledAt == nil, mayStillSend(credentials) else { return false }
            // The gate decides the ACTION here: while the app is not active the planner answers a
            // memo create or a wait, never an upload (decision 9).
            switch OutboxPlanner.nextWholeAction(
                for: current, credentials: credentials, now: clock(),
                schedulingOpen: schedulingGate.isOpen
            ) {
            case .hold(let reason):
                // A refused write ends this pass having done nothing, on a row another writer
                // moved — perhaps one that skipped a file this pass owned. Ask again, here and at
                // every refused write below.
                if await !hold(current, reason: reason) { requestDrain() }
                return false
            case .wait:
                return false
            case .upload(let starting, let retrying):
                guard permitsNetwork() else {
                    if await !waitForNetwork(current) { requestDrain() }
                    return false
                }
                // A file a live task is carrying is not sent again: the planner cannot see tasks.
                // Nor is one this engine is still applying an answer to or handing off: whoever
                // owns it advances the row once its own work has landed.
                let carried = await carriedFiles(of: current, on: uploads)
                // A claim or release inside those hops makes the row, the listing and `owned` three
                // different instants: plan again from the read.
                guard ownershipGeneration == observed else { return true }
                let start = starting.filter { !carried.contains($0) && !isOwned(jobID, $0) }
                let retry = retrying.filter { !carried.contains($0) && !isOwned(jobID, $0) }
                guard !start.isEmpty || !retry.isEmpty else { return false }
                // Claimed here, with no hop since the check: a settlement landing after it cannot
                // free a file this pass is about to send. `handOffWhole` releases each one.
                for fileID in start + retry { own(WholeFileRef(jobID: jobID, fileID: fileID)) }
                await handOffWhole(
                    current, starting: start, retrying: retry, credentials: credentials,
                    on: uploads
                )
                return false
            case .createMemo:
                guard permitsNetwork() else {
                    if await !waitForNetwork(current) { requestDrain() }
                    return false
                }
                guard creating.insert(current.id).inserted else { return false }
                let next = await complete(current, credentials: credentials)
                creating.remove(current.id)
                settle()
                guard let next else { return false }
                current = next
            }
        }
        let backedOff = await save(
            current.backingOff(at: clock(), error: "The server kept asking to start over."),
            matching: current
        )
        if backedOff == nil { requestDrain() }
        return false
    }

    /// The files of this job some listed task is still carrying — at any term, in any state short
    /// of completed, `.canceling` included — unless its terminal answer has already arrived. A
    /// cancelled predecessor keeps its file until it has ended: a new task beside it would be two
    /// uploads of one file. A file being replaced is owned for the whole replacement besides.
    private func carriedFiles(
        of job: UploadJob, on uploads: any OutboxUploadScheduling
    ) async -> Set<UUID> {
        let answeredBefore = Set(ended.keys)
        let listing = await uploads.tasks()
        pruneEnded(answeredBefore, listing: listing)
        var carried = Set<UUID>()
        for task in listing where task.state != .completed && ended[task.taskIdentifier] == nil {
            guard let identity = WholeTaskIdentity(taskDescription: task.taskDescription),
                identity.jobID == job.id
            else { continue }
            carried.insert(identity.fileID)
        }
        return carried
    }

    /// Forgets the ended tasks a listing no longer names — only those whose answer had arrived
    /// before the listing was asked for, since a listing taken earlier says nothing of a task
    /// created after it — and, given the rows, every ended task whose row is gone.
    private func pruneEnded(
        _ answeredBefore: Set<Int>, listing: [WholeTaskListing], rows: Set<UUID>? = nil
    ) {
        let listed = Set(listing.map(\.taskIdentifier))
        for id in answeredBefore {
            guard let jobID = ended[id] else { continue }
            if !listed.contains(id) || rows.map({ !$0.contains(jobID) }) == true {
                ended[id] = nil
            }
        }
    }

    /// Forgets every ended task of one row: it was released or abandoned.
    private func pruneEnded(of jobID: UUID) {
        ended = ended.filter { $0.value != jobID }
    }

    private func isOwned(_ jobID: UUID, _ fileID: UUID) -> Bool {
        owned[WholeFileRef(jobID: jobID, fileID: fileID)] != nil
    }

    private func own(_ ref: WholeFileRef) {
        owned[ref, default: 0] += 1
        ownershipGeneration += 1
    }

    private func disown(_ ref: WholeFileRef) {
        guard let count = owned[ref] else { return }
        owned[ref] = count > 1 ? count - 1 : nil
        ownershipGeneration += 1
    }

    /// Opens a session for every file that needs one, writes them ONCE with the row `.uploading`
    /// on the whole lane, then hands every file to the session. Retrying files move to their own
    /// next term first (`retryingWhole`); a sibling's term never moves.
    private func handOffWhole(
        _ job: UploadJob,
        starting: [UUID],
        retrying: [UUID],
        credentials: OutboxCredentials,
        on uploads: any OutboxUploadScheduling
    ) async {
        handOffGeneration += 1
        handOffsInProgress += 1
        defer {
            handOffsInProgress -= 1
            handOffGeneration += 1
        }
        let sending = Set(starting + retrying)
        // The caller claimed every file before this was entered. Each stays owned until the session
        // has its task, so an answer landing for a sibling mid-loop cannot send it again; one that
        // never gets that far is released on the way out.
        var unsent = Set(sending.map { WholeFileRef(jobID: job.id, fileID: $0) })
        defer {
            for ref in unsent { disown(ref) }
        }
        var candidate = retrying.reduce(job) { $0.retryingWhole(fileID: $1) }
            .with { $0.transport = .whole }
        for file in candidate.files where sending.contains(file.id) {
            guard let session = await openSession(file, of: job, credentials: credentials) else {
                return
            }
            candidate = candidate.startingUpload(fileID: file.id, session: session)
        }
        // Nothing is handed to the session on a state nobody wrote: the answer to each task is
        // matched against this write.
        let uploading = candidate.with { $0.state = .uploading }
        guard let saved = await save(uploading, matching: job) else {
            // The row moved under this hand-off — perhaps by a pass that skipped these very files
            // because this hand-off owned them. Nobody else will send them: ask again.
            requestDrain()
            return
        }
        // One authority for every file, asked again by the scheduler for each one: the gate
        // closing between two files stops the second, and nothing is written for it.
        let work = authority(under: credentials, for: .work)
        for file in saved.files where sending.contains(file.id) && !file.isComplete {
            guard let uploadUID = file.uploadUID else { continue }
            _ = await uploads.upload(
                OutboxRequests.wholeUpload(
                    baseURL: credentials.serverBaseURL,
                    token: credentials.token,
                    uploadUID: uploadUID,
                    allowsMobileData: preferences.allowsMobileData
                ),
                fromFile: repository.mediaURL(job: saved, file: file),
                for: WholeFileRef(jobID: saved.id, fileID: file.id),
                attempt: file.uploadAttempt ?? 0,
                under: work,
                issuedUnder: credentials.epoch
            )
            let ref = WholeFileRef(jobID: saved.id, fileID: file.id)
            if unsent.remove(ref) != nil { disown(ref) }
        }
    }

    /// The upload session for one file, or nil where the POST did not produce one — having written
    /// whatever that outcome calls for, fenced on `job`, or nothing for a closed gate. Where the
    /// fence refuses that write the row carries neither the outcome nor a task for this file, and
    /// a sibling's continuation may have skipped the file while this call owned it: another drain
    /// is asked for.
    private func openSession(
        _ file: OutboxFile, of job: UploadJob, credentials: OutboxCredentials
    ) async -> OutboxWire.UploadSession? {
        let request: URLRequest
        do {
            request = try OutboxRequests.startUpload(
                baseURL: credentials.serverBaseURL, token: credentials.token, file: file
            )
        } catch {
            // Unreachable for the reason `startUpload`'s is, and written through `hold` so the
            // refusal pins count one hold site per decision rather than one per lane.
            if await !hold(job, reason: .serverRefused) { requestDrain() }
            return nil
        }
        let sending = authority(under: credentials, for: .work)
        let response: OutboxHTTPResponse
        do {
            response = try await http.perform(request, under: sending)
        } catch {
            if error is SendAuthorityWithdrawn, sending.withdrawal() == .scheduling { return nil }
            let backedOff = await save(
                job.backingOff(at: clock(), error: "The server could not be reached."),
                matching: job
            )
            if backedOff == nil { requestDrain() }
            return nil
        }
        guard response.isSuccess, let session = OutboxWire.decodeSession(response.body) else {
            // Sent under the credential held now, so its refusal holds under a known epoch.
            let refused = OutboxRefusal(
                statusCode: response.statusCode, issuedUnder: credentials.epoch, what: "upload"
            )
            let disposed = await save(
                job.applying(refused.disposition(assumingCurrent: true), at: clock()),
                ifStillCurrent: refused.issuedUnder,
                matching: job,
                else: job.applying(refused.disposition(assumingCurrent: false), at: clock())
            )
            if disposed == nil { requestDrain() }
            return nil
        }
        return session
    }

    /// Tasks whose request allows other networks than the person's choice now are replaced: the
    /// successor is built only once the old task has ended (`BackgroundUploadScheduler.replace`).
    /// Sending a successor is new work, so this runs only while scheduling is open.
    private func replaceMismatched(_ credentials: OutboxCredentials) async {
        guard let uploads, schedulingGate.isOpen else { return }
        _ = await uploads.reexamineDeferred()
        let allowsMobileData = preferences.allowsMobileData
        for task in await uploads.mismatched(allowsMobileData: allowsMobileData) {
            guard replacing[task.taskIdentifier] == nil else { continue }
            let ref = WholeFileRef(jobID: task.identity.jobID, fileID: task.identity.fileID)
            // The mismatch list is older than this instant. Admitted only on a fresh listing read
            // with `owned` unchanged across it, in which the task is still live and nothing in
            // this engine owns its file: an owner is already deciding that file, and a task gone
            // or ended has a continuation of its own.
            let observed = ownershipGeneration
            let live = await uploads.tasks().contains {
                $0.taskIdentifier == task.taskIdentifier && $0.state != .completed
            }
            guard ownershipGeneration == observed else {
                requestDrain()
                continue
            }
            guard live, ended[task.taskIdentifier] == nil, owned[ref] == nil else { continue }
            replacing[task.taskIdentifier] = ref
            // Owned before `replace` is entered and until the scheduler says the replacement is
            // over: through a deferral, and past the successor's write until its task exists.
            own(ref)
            _ = await uploads.replace(
                task, under: authority(under: credentials, for: .work),
                onSettled: { sent in await self.replacementSettled(ref, sent: sent) }
            ) {
                await self.successor(
                    replacing: task.identity, credentials: credentials,
                    allowsMobileData: allowsMobileData
                )
            }
        }
    }

    /// A replacement is over. One that sent no successor — its write fenced out, its authority
    /// withdrawn, nothing left to send — may leave a sendable row that every other pass skipped
    /// while this one owned it, so it asks for another pass.
    private func replacementSettled(_ ref: WholeFileRef, sent: WholeTask?) {
        disown(ref)
        if sent == nil { requestDrain() }
    }

    /// The replacement for one file, built after its old task has ended: the file's own next
    /// term and a fresh session, written, and the request that sends it under the choice now.
    private func successor(
        replacing old: WholeTaskIdentity,
        credentials: OutboxCredentials,
        allowsMobileData: Bool
    ) async -> WholeSuccessor? {
        guard mayStillSend(credentials),
            let job = await repository.job(old.jobID),
            job.lane == .whole, job.cancelledAt == nil, job.state != .held,
            let file = job.file(old.fileID),
            (file.uploadAttempt ?? 0) == old.attempt,
            !file.isComplete
        else { return nil }
        let retried = job.retryingWhole(fileID: old.fileID)
        guard let fresh = retried.file(old.fileID),
            let session = await openSession(fresh, of: job, credentials: credentials),
            let saved = await save(
                retried.startingUpload(fileID: old.fileID, session: session), matching: job
            ),
            let sent = saved.file(old.fileID),
            let uploadUID = sent.uploadUID
        else { return nil }
        return WholeSuccessor(
            request: OutboxRequests.wholeUpload(
                baseURL: credentials.serverBaseURL,
                token: credentials.token,
                uploadUID: uploadUID,
                allowsMobileData: allowsMobileData
            ),
            file: repository.mediaURL(job: saved, file: sent),
            ref: WholeFileRef(jobID: saved.id, fileID: sent.id),
            attempt: sent.uploadAttempt ?? 0,
            epoch: credentials.epoch
        )
    }

    /// Called by the upload session, possibly in a process launched for this alone.
    ///
    /// The answer is applied to its ONE file by the repository, rebased onto the manifest as it
    /// stands at the write (`applyFileAnswer`), so two files answering together both land. What
    /// follows is the ordinary step, which while the app is not active can only be the memo
    /// create of a row whose every file is now on the server.
    public func handle(_ answer: WholeAnswer) async {
        continuationsInFlight += 1
        defer {
            continuationsInFlight -= 1
            settle()
        }
        handOffGeneration += 1
        // Whatever it says, an answer is its task's end: it carries its file no longer.
        ended[answer.taskIdentifier] = answer.identity.jobID
        // A task handed to `replace` is superseded by its successor's term, whatever it says —
        // including the status-less answer its own cancellation produces.
        guard replacing[answer.taskIdentifier] == nil else { return }
        let identity = answer.identity
        // Owned from here until the answer has landed, so a sibling's continuation cannot send
        // this file again while its success is still on the way to disk.
        let ref = WholeFileRef(jobID: identity.jobID, fileID: identity.fileID)
        own(ref)
        var owning = true
        defer { if owning { disown(ref) } }
        guard let job = await repository.job(identity.jobID), job.cancelledAt == nil else {
            // Gone or taken back: none of the row's tasks has a file left to hold back.
            pruneEnded(of: identity.jobID)
            return
        }
        guard job.lane == .whole, let file = job.file(identity.fileID) else { return }
        guard (file.uploadAttempt ?? 0) == identity.attempt else {
            // A superseded task has ended — a Try again's predecessor, say. The file it was holding
            // back can go now, and nothing else will ask for it.
            requestDrain()
            return
        }
        let change: WholeFileChange
        switch WholeOutcome.classify(
            statusCode: answer.statusCode,
            bytesReceived: OutboxWire.decodeSession(answer.body)?.bytesReceived,
            byteSize: file.byteSize
        ) {
        case .completed(let bytes):
            change = .confirmed(bytes)
        case .retryWhole:
            change = .retryWhole
        case .backOff:
            change = .backOff(
                answer.statusCode.map { "The upload failed (\($0))." }
                    ?? answer.errorDescription ?? "The upload did not finish."
            )
        case .refused(let statusCode):
            change = .refused(
                OutboxRefusal(statusCode: statusCode, issuedUnder: identity.epoch, what: "upload")
            )
        case .unreadable:
            guard let asked = await askWhereItStands(job, fileID: identity.fileID) else { return }
            change = asked
        }
        let provenance = identity.provenance(
            currentLaunch: uploads?.launch ?? OutboxUploadSession.processLaunch
        )
        // Marked in progress for the write only, and released before the continuation below: a
        // drain that continuation asks for must not meet this answer's own mark.
        handOffsInProgress += 1
        let written: UploadJob?
        // The rebase refused — the file's term moved under this answer, say by a Try again whose
        // own drain skipped the file while this answer owned it — or a storage failure's hold
        // refused: the row stands as another writer left it, so it is asked about again once this
        // answer's mark is released. Not a row gone, and not one whose memo create has begun: that
        // create owns its next step.
        var refused = false
        do {
            written = try await repository.applyFileAnswer(
                jobID: identity.jobID,
                fileID: identity.fileID,
                attempt: identity.attempt,
                outcome: change,
                presented: provenance,
                at: clock()
            )
            lastPersistenceFailure = nil
            if written == nil, let now = await repository.job(identity.jobID) {
                refused = now.state != .creating
            }
        } catch {
            lastPersistenceFailure = Self.storageMessage(error)
            refused = await !holdUnsaved(job, error: error, matching: job)
            written = nil
        }
        handOffsInProgress -= 1
        handOffGeneration += 1
        disown(ref)
        owning = false
        if refused { requestDrain() }
        await onChange()
        guard let written,
            let credentials = await credentials.currentCredentials(),
            mayStillSend(credentials)
        else { return }
        await advance(written, credentials: credentials)
        await onChange()
    }

    /// A success whose body said nothing readable: one HEAD, while the app is active. Nil when
    /// nothing is to be written — the gate is closed or the network is not one to use; the row is
    /// then a record with no task, and the next open-gate pass sends the file again whole.
    private func askWhereItStands(_ job: UploadJob, fileID: UUID) async -> WholeFileChange? {
        guard schedulingGate.isOpen, permitsNetwork(),
            let credentials = await credentials.currentCredentials(),
            let byteSize = job.file(fileID)?.byteSize
        else { return nil }
        switch await resync(job, fileID: fileID, credentials: credentials) {
        case .resynced(let resynced):
            guard let file = resynced.file(fileID), file.uploadUID != nil else {
                return .retryWhole
            }
            switch WholeOutcome.classify(
                statusCode: 200, bytesReceived: file.bytesConfirmed, byteSize: byteSize
            ) {
            case .completed(let bytes): return .confirmed(bytes)
            default: return .retryWhole
            }
        case .withheld:
            return nil
        case .unanswered:
            return .backOff("The server's answer was unreadable.")
        }
    }

    // MARK: - helpers

    /// What a send is for, which decides whether it carries the scheduling gate.
    enum SendPurpose: Equatable {
        /// Starting or continuing an upload, asking where one stands, or sending an edit.
        case work
        /// Finishing a transfer that has already happened.
        case memoCreate
        /// The health GET before a pass.
        case probe
    }

    /// What asking the server where an upload stands came to.
    enum Resync {
        case resynced(UploadJob)
        /// No usable answer, or no request could be made: the caller backs off.
        case unanswered
        /// Not asked: the gate closed before the request left. The caller writes nothing.
        case withheld
    }

    /// Makes every retained original this edit keeps nameable again, before the edit is claimed.
    ///
    /// The create's answer binds the uploads it named onto attachments; an original it folded away
    /// — identical bytes, or a count the server disagreed with — is left with no attachment uid,
    /// and the PATCH's picture list travels whole or not at all. So it is sent again, under a new
    /// upload, and the server folds it back onto the attachment it already holds.
    ///
    /// - Returns: the job to carry on with, or nil where this pass wrote a hold and is done.
    private func stageUnnamedOriginals(_ job: UploadJob) async -> UploadJob? {
        guard let edit = job.pendingEdit else { return job }
        let kept = Set(edit.fileIDs)
        let unnamed = job.files.filter {
            kept.contains($0.id) && $0.stagedForEdit != true && $0.attachmentUID == nil
        }
        guard !unnamed.isEmpty else { return job }
        // Checked before anything is written: re-staging a copy this device cannot read promises
        // an upload that can never be made, and the capture would then retry for ever. The person
        // takes it back and removes that picture instead.
        guard unnamed.allSatisfy({ isReadable($0, of: job) }) else {
            await hold(job, reason: .editIncomplete)
            return nil
        }
        let restaging = Set(unnamed.map(\.id))
        let staged = job.with { candidate in
            for index in candidate.files.indices
            where restaging.contains(candidate.files[index].id) {
                candidate.files[index].stagedForEdit = true
                candidate.files[index].uploadUID = nil
                candidate.files[index].bytesConfirmed = 0
            }
        }
        // A re-staged file is transferring again, so it moves to a NEW term — the same bump Try
        // again performs. Without it the finished predecessor's late duplicate answer carries the
        // same file, offset and term, and would be credited to the replacement, which would then
        // read complete with its bytes never sent.
        let bumped = staged.bumpingAttempts().job
        guard let saved = await save(bumped, matching: job) else { return nil }
        // After the write, and only over tasks the bump left behind: a task already carrying the
        // new term IS the replacement.
        let live = OutboxTaskIdentity.supersededTasks(
            inFlight: await scheduler.inFlight(), bumped: saved.attemptTerms, jobID: job.id)
        if !live.isEmpty {
            await scheduler.cancel(live)
        }
        return saved
    }

    /// Whether the job's copy of this original can still be read: a send, or a promise unkeepable.
    private func isReadable(_ file: OutboxFile, of job: UploadJob) -> Bool {
        guard
            let handle = try? FileHandle(
                forReadingFrom: repository.mediaURL(job: job, file: file))
        else { return false }
        try? handle.close()
        return true
    }

    /// - Returns: false when the fence refused the write: the row moved and says something else.
    @discardableResult
    private func hold(_ job: UploadJob, reason: HoldReason) async -> Bool {
        guard job.state != .held || job.holdReason != reason else { return true }
        return await save(job.held(reason, error: Self.message(for: reason)), matching: job) != nil
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
    /// - Returns: false when the hold was not written — refused by the fence, or failed too.
    @discardableResult
    private func holdUnsaved(
        _ job: UploadJob,
        error: any Error,
        matching snapshot: UploadJob
    ) async -> Bool {
        guard job.state != .held || job.holdReason != .storageFailed else { return true }
        // The marker comes from the SNAPSHOT, never from the candidate: the candidate is the write
        // that did not happen, and one of them clears the marker. Taking it from there would put a
        // settled capture on disk over an edit the server never answered.
        let held = job.held(.storageFailed, error: Self.storageMessage(error))
            .with { $0.editUnansweredSince = snapshot.editUnansweredSince }
        do {
            // The same checked write, so there is one implementation of "is this still the capture
            // I decided about" and not a second one here. The epoch is deliberately unknown — a
            // storage failure is not the server's word about a credential — and the fallback is
            // unreachable because unknown reads as current.
            return try await repository.save(
                held, ifStillCurrent: nil, matching: snapshot, else: held
            ) != nil
        } catch {
            // Nothing more can be written. It is already reported above, and the next pass finds
            // the job exactly as the last write that did land left it.
            return false
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
        case .editIncomplete:
            return "A picture this memo keeps is missing from this device."
        case .memoGone:
            return "This memo is no longer on the server."
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
