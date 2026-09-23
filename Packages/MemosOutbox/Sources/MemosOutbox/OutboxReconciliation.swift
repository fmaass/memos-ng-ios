import Foundation

/// What a launch found, and what to do about it.
public struct ReconciliationPlan: Sendable, Equatable {
    /// Tasks that are still exactly what their job needs next: left alone, and their job is NOT
    /// scheduled again. This is the whole point — two tasks for one job would upload the same
    /// bytes twice at two offsets.
    public var adopted: [OutboxTaskIdentity]
    /// Tasks that no longer describe anything: a job that is gone, a file that has moved on, a
    /// description this app did not write.
    public var cancelled: [OutboxTaskIdentity]
    /// Jobs with nothing in flight, in capture order — the ones a drain may act on.
    public var drainable: [UUID]

    public init(adopted: [OutboxTaskIdentity], cancelled: [OutboxTaskIdentity], drainable: [UUID]) {
        self.adopted = adopted
        self.cancelled = cancelled
        self.drainable = drainable
    }
}

/// Matching the background session's surviving tasks against what is on disk.
///
/// A background session outlives the process, so on every launch the truth is in two places: the
/// persisted jobs and the tasks the session is still carrying. Deciding this from the two of them
/// — before anything new is scheduled — is what keeps a relaunch from double-uploading.
public enum OutboxReconciliation {
    public static func plan(
        jobs: [UploadJob],
        inFlight: [OutboxTaskIdentity]
    ) -> ReconciliationPlan {
        var adopted: [OutboxTaskIdentity] = []
        var cancelled: [OutboxTaskIdentity] = []
        var claimed: Set<UUID> = []
        // Whatever the disk hands over, one id is one job here. A capture that was set aside twice
        // used to arrive twice, and this ran on the LAUNCH path: a duplicate key would have taken
        // the whole queue down with it rather than one row. The first in capture order wins, so the
        // same list always plans the same way.
        let jobsByID = Dictionary(
            jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )

        for task in inFlight {
            guard let job = jobsByID[task.jobID],
                job.state != .held,
                // A capture taken back to the editor wants nothing from its task. `cancel` writes
                // the mark before it tears the task down, so a relaunch between the two finds both.
                job.cancelledAt == nil,
                !claimed.contains(job.id),
                let file = job.file(task.fileID),
                file.uploadUID != nil,
                !file.isComplete,
                file.bytesConfirmed == task.offset,
                // The attempt the task was sent under, against the one the manifest names now. A
                // task a retry superseded sits at the same offset as its replacement, so without
                // this the obsolete one would be adopted and the replacement cancelled as a
                // duplicate.
                file.uploadAttempt == task.attempt
            else {
                cancelled.append(task)
                continue
            }
            claimed.insert(job.id)
            adopted.append(task)
        }

        var listed: Set<UUID> = []
        var drainable: [UUID] = []
        for job in jobs where !claimed.contains(job.id) {
            // The same reason as above, on the other side of the plan: an id listed twice would be
            // advanced twice in one pass, which is the double upload this whole type exists to
            // prevent.
            guard listed.insert(job.id).inserted else { continue }
            drainable.append(job.id)
        }
        return ReconciliationPlan(adopted: adopted, cancelled: cancelled, drainable: drainable)
    }
}

/// Whether anything left the queue between two snapshots.
public enum OutboxProgress {
    /// A job only ever leaves the outbox on a server-confirmed memo, so a job id that was there
    /// and is not any more means exactly one thing: that memo now exists on the server.
    public static func didComplete(previous: [UUID], current: [UUID]) -> Bool {
        guard !previous.isEmpty else { return false }
        let remaining = Set(current)
        return previous.contains { !remaining.contains($0) }
    }
}
