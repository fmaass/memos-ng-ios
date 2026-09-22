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
        if job.state == .held { return .hold(job.holdReason ?? .serverRefused) }
        if now < job.nextAttemptAt { return .wait(until: job.nextAttemptAt) }

        if let pending = job.files.first(where: { $0.uploadUID == nil }) {
            return .startUpload(fileID: pending.id)
        }
        for file in job.files where !file.isComplete {
            guard
                let length = ChunkMath.chunkLength(
                    atOffset: file.bytesConfirmed,
                    byteSize: file.byteSize,
                    chunkSize: file.chunkSize
                )
            else { continue }
            return .uploadChunk(fileID: file.id, offset: file.bytesConfirmed, length: length)
        }
        return .createMemo
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

    /// The server said how much of a file it now holds. Nothing else may move this number.
    public func advancing(fileID: UUID, bytesConfirmed: Int64) -> UploadJob {
        updating(fileID) { file in
            file.bytesConfirmed = Swift.min(Swift.max(bytesConfirmed, 0), file.byteSize)
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

    /// A failure that is worth trying again later. The job is never dropped, only spaced out.
    public func backingOff(at now: Date, error: String) -> UploadJob {
        with {
            $0.attemptCount += 1
            $0.nextAttemptAt = RetrySchedule.nextAttempt(afterFailure: $0.attemptCount, from: now)
            $0.state = .waiting
            $0.lastError = error
            // A backoff waits on the clock, so whatever it was waiting for before is no longer
            // what the row should say.
            $0.waitReason = nil
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
        }
    }

    /// A person took this capture back to the editor.
    ///
    /// Nothing it owns goes anywhere: the manifest stays, so the idempotency key and the account
    /// the capture was made under travel to the re-submit instead of being minted again, and the
    /// originals stay where the job already holds them. The next attempt is put out of reach so
    /// that no pass sends it while the editor has it.
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
    public func awaitingPatch(uid: String, editKey: String) -> UploadJob {
        with {
            $0.resolvedMemoUID = uid
            $0.editKey = editKey
            $0.patchAttempt = 0
            $0.state = .creating
            $0.waitReason = nil
            $0.nextAttemptAt = .distantFuture
        }
    }

    public func creatingMemo() -> UploadJob {
        with {
            $0.state = .creating
            $0.waitReason = nil
        }
    }

    /// The network this phone is on is not one this capture may use.
    ///
    /// Not a failure and never a backoff: nothing was tried, nothing went wrong, and the job is
    /// waiting for an EVENT — the wifi coming back, or the toggle going on — rather than for a
    /// timer. So the attempt count and the next attempt are left exactly as they were, and what
    /// the row gains is the reason.
    public func waitingForNetwork() -> UploadJob {
        with {
            $0.state = .waiting
            $0.waitReason = .homeNetwork
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
