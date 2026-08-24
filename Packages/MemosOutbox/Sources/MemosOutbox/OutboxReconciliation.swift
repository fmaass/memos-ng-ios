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
        let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })

        for task in inFlight {
            guard let job = jobsByID[task.jobID],
                job.state != .held,
                !claimed.contains(job.id),
                let file = job.file(task.fileID),
                file.uploadUID != nil,
                !file.isComplete,
                file.bytesConfirmed == task.offset
            else {
                cancelled.append(task)
                continue
            }
            claimed.insert(job.id)
            adopted.append(task)
        }

        let drainable = jobs.filter { !claimed.contains($0.id) }.map(\.id)
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
