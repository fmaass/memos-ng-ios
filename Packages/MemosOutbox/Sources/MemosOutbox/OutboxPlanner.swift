import Foundation

/// The one thing a job needs next.
public enum OutboxAction: Sendable, Equatable {
    /// Stop, and wait for a person. Never retried on a timer.
    case hold(HoldReason)
    /// Nothing to do until this moment — a retry that is still spacing itself out.
    case wait(until: Date)
    /// This file has no upload session on the server yet.
    case startUpload(fileID: UUID)
    /// Send these bytes of this file, from the offset the server confirmed.
    case uploadChunk(fileID: UUID, offset: Int64, length: Int)
    /// Every byte is on the server: create the memo that links them.
    case createMemo
}

/// What a `uploads_unlinkable` refusal means for each file, worked out without a network.
public struct UnlinkableRecovery: Sendable, Equatable {
    /// Files whose upload session the server no longer has: upload them again from the original,
    /// which the outbox still holds. The original is NEVER deleted for this.
    public var restart: [UUID]
    /// Files the server has only part of: ask it for its offset and carry on from there.
    public var resync: [UUID]

    public init(restart: [UUID], resync: [UUID]) {
        self.restart = restart
        self.resync = resync
    }

    public var isEmpty: Bool { restart.isEmpty && resync.isEmpty }
}

/// What to do next with a job, decided from the job alone.
///
/// Pure on purpose: this is the part that must be right when the app has been relaunched into a
/// background wake with no memory of anything, so it is asserted against vectors rather than
/// inferred from a running upload.
public enum OutboxPlanner {
    public static func nextAction(
        for job: UploadJob,
        credentials: OutboxCredentials,
        now: Date
    ) -> OutboxAction {
        // The binding is checked before anything else, including before the hold state: a job
        // captured under another account must never reach a request, whatever else is true of it.
        guard job.binding.matches(credentials) else { return .hold(.accountMismatch) }
        // A capture a person has taken back to the editor is not the queue's to send, whatever
        // else is true of it. The mark is the fence; the date it parks is what this wait is
        // reported as, and no screen displays it.
        if job.cancelledAt != nil { return .wait(until: job.nextAttemptAt) }
        if job.state == .held { return .hold(job.holdReason ?? .serverRefused) }
        // Before the backoff: a file the server has said it will not take is refused while it is
        // still only staged, so it never costs a `POST /api/uploads` that can only end in a 413.
        if oversizedFile(in: job, limit: credentials.uploadLimit) != nil { return .hold(.tooLarge) }
        // The guest door takes no empty file (its create requires a size of at least one byte),
        // so that create could only be refused, and refused the same way every time it was sent.
        // Held before it costs a request, like the file over the limit above.
        if credentials.kind == .guest, emptyGuestFile(in: job) != nil {
            return .hold(.serverRefused)
        }
        if now < job.nextAttemptAt { return .wait(until: job.nextAttemptAt) }

        // A file the guest door already held is done without a session: it is never started
        // again, and nothing of it is sent.
        if let pending = job.files.first(where: {
            $0.uploadUID == nil && $0.alreadyReceived != true
        }) {
            return .startUpload(fileID: pending.id)
        }
        for file in job.files where !file.isComplete {
            if credentials.kind == .guest {
                // Every guest body, fresh or the tail of a resumed upload, is held to the door's
                // PATCH ceiling whatever slice the manifest carries.
                guard
                    let body = GuestPatchPlan.body(
                        atOffset: file.bytesConfirmed,
                        byteSize: file.byteSize,
                        limit: Int64(file.chunkSize)
                    )
                else { continue }
                return .uploadChunk(
                    fileID: file.id, offset: body.lowerBound,
                    length: Int(body.upperBound - body.lowerBound)
                )
            }
            guard
                let length = ChunkMath.chunkLength(
                    atOffset: file.bytesConfirmed,
                    byteSize: file.byteSize,
                    chunkSize: file.chunkSize
                )
            else { continue }
            return .uploadChunk(fileID: file.id, offset: file.bytesConfirmed, length: length)
        }
        // Files are still arriving from the editor: the create waits for the last of them, and the
        // release that clears the mark drains again (`UploadJob.stagingLaunch`).
        if job.stillArriving { return .wait(until: .distantFuture) }
        return .createMemo
    }

    /// The first file of `job` that has no upload session yet and is larger than `limit`.
    ///
    /// Only a file with no session: one that has a session was already accepted at its size. A
    /// file exactly at the limit is accepted, as the server accepts it. No limit, or one that is
    /// not a size at all, refuses nothing — the queue then fails open to the server's 413.
    public static func oversizedFile(in job: UploadJob, limit: Int64?) -> OutboxFile? {
        job.files.first { $0.uploadUID == nil && isOverLimit($0, limit: limit) }
    }

    /// The first file of a guest `job` the door would refuse for being empty: no session yet, not
    /// already received, and no bytes.
    public static func emptyGuestFile(in job: UploadJob) -> OutboxFile? {
        job.files.first { $0.uploadUID == nil && $0.alreadyReceived != true && $0.byteSize < 1 }
    }

    /// Whether `file` is larger than `limit`, whatever session it holds: the one size rule, which
    /// the planners apply to a staged file and the engine to every new session it asks for.
    static func isOverLimit(_ file: OutboxFile, limit: Int64?) -> Bool {
        guard let limit, limit > 0 else { return false }
        return file.byteSize > limit
    }

    /// Both sizes, the file's first: "1.6 GB > 1 GB". The one wording the held row and the compose
    /// tile share, in the platform's file-size format.
    public static func sizeComparison(_ size: Int64, over limit: Int64) -> String {
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "\(format(size)) > \(format(limit))"
    }

    /// What a capture held for a file over the limit says, with both sizes in it; nil when the
    /// hold is anything else, which keeps its usual sentence.
    public static func holdMessage(
        for reason: HoldReason, of job: UploadJob, credentials: OutboxCredentials
    ) -> String? {
        if reason == .serverRefused, credentials.kind == .guest,
            let file = emptyGuestFile(in: job)
        {
            return "\(file.filename) is empty, and the trip does not accept an empty file."
        }
        guard reason == .tooLarge, let limit = credentials.uploadLimit,
            let file = oversizedFile(in: job, limit: limit)
        else { return nil }
        return tooLargeMessage(file, over: limit)
    }

    /// The held row's sentence for `file` over `limit`, wherever the refusal was decided.
    static func tooLargeMessage(_ file: OutboxFile, over limit: Int64) -> String {
        let sizes = sizeComparison(file.byteSize, over: limit)
        return "\(sizes): the server will not accept a file this large."
    }

    /// Which files a structured refusal implicates, matched by upload uid.
    ///
    /// A uid the server names that this job does not carry is ignored rather than guessed at.
    public static func recovery(
        for job: UploadJob,
        failure: UploadsUnlinkableFailure
    ) -> UnlinkableRecovery {
        let missing = Set(failure.missingUploadUIDs)
        let incomplete = Set(failure.incompleteUploadUIDs)
        var restart: [UUID] = []
        var resync: [UUID] = []
        for file in job.files {
            guard let uid = file.uploadUID else { continue }
            if missing.contains(uid) {
                restart.append(file.id)
            } else if incomplete.contains(uid) {
                resync.append(file.id)
            }
        }
        return UnlinkableRecovery(restart: restart, resync: resync)
    }
}

// MARK: - transitions

/// Every change a job goes through, as a pure function from one job to the next.
///
/// They return a new job rather than mutating one in place so that a transition can be asserted on
/// its own, and so that nothing half-applies when a save fails.
extension UploadJob {
    /// The server accepted an upload session for a file. Its answer decides the chunk size AND the
    /// starting offset — a session it already had bytes for resumes rather than restarts.
    public func startingUpload(
        fileID: UUID,
        session: OutboxWire.UploadSession
    ) -> UploadJob {
        updating(fileID) { file in
            file.uploadUID = session.uploadUID
            file.chunkSize = session.chunkSize > 0 ? session.chunkSize : file.chunkSize
            file.bytesConfirmed = Swift.min(Swift.max(session.bytesReceived, 0), file.byteSize)
        }
        .with {
            $0.state = .uploading
            $0.waitReason = nil
        }
    }

    /// The guest door already holds this file's exact bytes. It needs no session and is named in
    /// no completion; the job carries on with its other files.
    public func receivedAlready(fileID: UUID) -> UploadJob {
        updating(fileID) { file in
            file.alreadyReceived = true
            file.uploadUID = nil
            file.bytesConfirmed = file.byteSize
            file.attemptCount = nil
            file.nextAttemptAt = nil
        }
        .with {
            $0.state = .uploading
            $0.waitReason = nil
        }
    }

    /// The server said how much of a file it now holds. Nothing else may move this number.
    public func advancing(fileID: UUID, bytesConfirmed: Int64) -> UploadJob {
        updating(fileID) { file in
            file.bytesConfirmed = Swift.min(Swift.max(bytesConfirmed, 0), file.byteSize)
            // Only this file's own spacing: a sibling's stays where its own failure put it.
            file.attemptCount = nil
            file.nextAttemptAt = nil
            // A confirmed file owes nothing to the sessions it lost on the way.
            if file.bytesConfirmed >= file.byteSize {
                file.freshSessions = nil
                file.conflictResync = nil
            }
        }
        .with {
            $0.state = .uploading
            $0.attemptCount = 0
            $0.nextAttemptAt = .distantPast
            $0.lastError = nil
            $0.waitReason = nil
        }
    }

    /// The server lost this file's upload session (404 on a uid it once issued). The session is
    /// forgotten and the file starts again from the original, which is still here.
    public func clearingLostUpload(fileID: UUID) -> UploadJob {
        updating(fileID) { file in
            file.uploadUID = nil
            file.bytesConfirmed = 0
        }
    }

    /// A transient failure (`RetryClass.transient`): worth trying again in seconds. The job is
    /// never dropped, only spaced out — by the server's `Retry-After` when it named one.
    public func backingOff(
        at now: Date, error: String, retryAfter: TimeInterval? = nil
    ) -> UploadJob {
        with {
            $0.attemptCount += 1
            // A marked job keeps the date the mark parked: an answer that outlived a cancel must
            // not schedule the capture the editor now holds.
            if $0.cancelledAt == nil {
                $0.nextAttemptAt = RetrySchedule.nextAttempt(
                    afterFailure: $0.attemptCount, from: now, retryAfter: retryAfter
                )
            }
            $0.state = .waiting
            $0.lastError = error
            // A backoff waits on the clock, so whatever it was waiting for before is no longer
            // what the row should say: it says it is retrying.
            $0.waitReason = .retrying
        }
    }

    /// A failure repeating cannot fix. The capture stays; a person decides what happens to it.
    public func held(_ reason: HoldReason, error: String? = nil) -> UploadJob {
        with {
            $0.state = .held
            $0.holdReason = reason
            $0.lastError = error ?? $0.lastError
            $0.waitReason = nil
        }
    }

    /// Let a held job try again — what the "Try again" the pending row offers actually does.
    public func released(at now: Date) -> UploadJob {
        with {
            $0.state = .waiting
            $0.holdReason = nil
            $0.waitReason = nil
            $0.attemptCount = 0
            $0.nextAttemptAt = now
            $0.lastError = nil
            $0.cancelledAt = nil
            // "Try again" means now, for every file, whatever each one was last told to wait for.
            for index in $0.files.indices {
                $0.files[index].attemptCount = nil
                $0.files[index].nextAttemptAt = nil
                // A person asking again gives the lost sessions a fresh allowance too.
                $0.files[index].freshSessions = nil
                $0.files[index].conflictResync = nil
            }
        }
    }

    /// Moves every file still transferring to a NEW attempt term, so the task holding the old one
    /// is distinguishable from its replacement and its late answer can be ignored rather than
    /// rewinding the cursor its successor is moving. The hand retry and the re-submit of a taken
    /// back capture both mint terms here and ONLY here, so the two agree on what a term means.
    /// - Returns: the job with the new terms, and the term each file now stands at.
    public func bumpingAttempts() -> (job: UploadJob, attempts: [UUID: Int?]) {
        let next = with { candidate in
            for index in candidate.files.indices where !candidate.files[index].isComplete {
                candidate.files[index].uploadAttempt =
                    (candidate.files[index].uploadAttempt ?? 0) + 1
            }
        }
        return (next, next.attemptTerms)
    }

    /// The term each file stands at, as the manifest has it — the shape a cancel predicate reads.
    public var attemptTerms: [UUID: Int?] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.uploadAttempt) })
    }

    /// A person took this capture back to the editor.
    ///
    /// Nothing it owns goes anywhere: the manifest stays, so the idempotency key and the account
    /// the capture was made under travel to the re-submit instead of being minted again, and the
    /// originals stay where the job already holds them. The mark itself is what keeps every pass
    /// off the capture — each wake point refuses a marked job — and the date parked here only
    /// keeps an unmarked pass from finding work; no screen shows it.
    public func cancelled(at now: Date) -> UploadJob {
        with {
            $0.cancelledAt = now
            $0.state = .waiting
            $0.waitReason = nil
            $0.nextAttemptAt = .distantFuture
        }
    }

    /// The server named the memo, and an edit is still owed to it. The capture stays whole until
    /// that edit is acknowledged, carrying the memo it was resolved to rather than a note of it
    /// kept somewhere the sweep would reap.
    public func awaitingPatch(
        uid: String,
        editKey: String
    ) -> UploadJob {
        with {
            $0.resolvedMemoUID = uid
            $0.editKey = editKey
            $0.patchAttempt = 0
            $0.state = .creating
            $0.waitReason = nil
            // Due now: what keeps the create from being sent again is that the edit branch takes
            // every pass in which the planner could answer `.createMemo` again, and a job still
            // missing a file's bytes is answered `.startUpload` or `.uploadChunk` — whichever
            // that file's cursor calls for — rather than a create.
            $0.nextAttemptAt = .distantPast
        }
    }

    public func creatingMemo() -> UploadJob {
        with {
            $0.state = .creating
            $0.waitReason = nil
        }
    }

    /// The network this phone is on is not one this capture may use, or there is none
    /// (`RetryClass.connectivity`).
    ///
    /// Not a failure and never a backoff: nothing was tried, nothing went wrong, and the job is
    /// waiting for an EVENT — the wifi coming back, or the toggle going on — rather than for a
    /// timer. So the attempt count and the next attempt are left exactly as they were, and what
    /// the row gains is the reason.
    public func waitingForNetwork(_ reason: WaitReason = .homeNetwork) -> UploadJob {
        with {
            $0.state = .waiting
            $0.waitReason = reason
        }
    }

    /// Applies the part of a structured refusal that needs no network: the files the server has no
    /// record of go back to having no upload session, so the drain uploads them again.
    public func applying(_ recovery: UnlinkableRecovery) -> UploadJob {
        var job = self
        for fileID in recovery.restart {
            job = job.clearingLostUpload(fileID: fileID)
        }
        return job.with {
            $0.state = .uploading
            $0.waitReason = nil
        }
    }

    func updating(_ fileID: UUID, _ change: (inout OutboxFile) -> Void) -> UploadJob {
        var job = self
        guard let index = job.files.firstIndex(where: { $0.id == fileID }) else { return job }
        change(&job.files[index])
        return job
    }

    func with(_ change: (inout UploadJob) -> Void) -> UploadJob {
        var job = self
        change(&job)
        return job
    }
}
