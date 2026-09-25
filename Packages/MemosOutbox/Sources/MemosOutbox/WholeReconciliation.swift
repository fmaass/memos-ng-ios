import Foundation

/// A task as the upload session lists it: the handle a cancel is sent to, and a description that
/// may say anything, or nothing.
public struct WholeTaskListing: Sendable, Equatable {
    public var taskIdentifier: Int
    public var taskDescription: String?

    public init(taskIdentifier: Int, taskDescription: String?) {
        self.taskIdentifier = taskIdentifier
        self.taskDescription = taskDescription
    }
}

/// A listed task this lane can read.
public struct WholeTask: Sendable, Equatable, Hashable {
    public var taskIdentifier: Int
    public var identity: WholeTaskIdentity

    public init(taskIdentifier: Int, identity: WholeTaskIdentity) {
        self.taskIdentifier = taskIdentifier
        self.identity = identity
    }
}

/// One file of one capture.
public struct WholeFileRef: Sendable, Equatable, Hashable {
    public var jobID: UUID
    public var fileID: UUID

    public init(jobID: UUID, fileID: UUID) {
        self.jobID = jobID
        self.fileID = fileID
    }
}

/// What a launch found on the whole lane, and what to do about it.
public struct WholeReconciliationPlan: Sendable, Equatable {
    /// Tasks still carrying exactly what their file needs: left alone, and their file is NOT sent
    /// again. One per FILE — a capture's picture and video ride two tasks, and both are kept.
    public var adopted: [WholeTask]
    /// Tasks that describe nothing any more, and tasks whose description this lane cannot read,
    /// by the identifier a cancel is sent to. An unreadable task is named here rather than
    /// dropped: dropped, it would keep sending a file nobody is waiting for.
    public var cancelled: [Int]
    /// Files the server has an upload session for, holding less than the whole file, that no task
    /// is carrying: each goes again, whole, once scheduling is open. Capture order.
    public var retryWhole: [WholeFileRef]

    public init(adopted: [WholeTask], cancelled: [Int], retryWhole: [WholeFileRef]) {
        self.adopted = adopted
        self.cancelled = cancelled
        self.retryWhole = retryWhole
    }
}

/// Matching the upload session's surviving tasks against the whole-lane rows on disk.
///
/// The chunk lane's rule is at most one task per job, because a job there sends one slice at a
/// time. A whole-lane capture hands every file to the session in one pass, so the rule here is at
/// most one task per FILE, and a second one for the same file is the duplicate.
public enum WholeReconciliation {
    public static func plan(
        jobs: [UploadJob],
        tasks: [WholeTaskListing]
    ) -> WholeReconciliationPlan {
        // One id is one job, the first in capture order — the same reason as the chunk lane's
        // plan: a duplicate key on the launch path must cost one row, not the queue.
        let jobsByID = Dictionary(
            jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var adopted: [WholeTask] = []
        var cancelled: [Int] = []
        var carried: Set<WholeFileRef> = []

        for task in tasks {
            guard let identity = WholeTaskIdentity(taskDescription: task.taskDescription) else {
                cancelled.append(task.taskIdentifier)
                continue
            }
            let ref = WholeFileRef(jobID: identity.jobID, fileID: identity.fileID)
            guard let job = jobsByID[identity.jobID],
                job.lane == .whole,
                job.state != .held,
                // `cancel` writes the mark before it tears the tasks down, so a relaunch between
                // the two finds both.
                job.cancelledAt == nil,
                let file = job.file(identity.fileID),
                file.uploadUID != nil,
                !file.isComplete,
                // A task a retry superseded carries the older term; its successor carries the one
                // the manifest names now.
                (file.uploadAttempt ?? 0) == identity.attempt,
                !carried.contains(ref)
            else {
                cancelled.append(task.taskIdentifier)
                continue
            }
            carried.insert(ref)
            adopted.append(WholeTask(taskIdentifier: task.taskIdentifier, identity: identity))
        }

        var listed: Set<UUID> = []
        var retryWhole: [WholeFileRef] = []
        for job in jobs {
            guard listed.insert(job.id).inserted else { continue }
            // A held capture waits for a person and a cancelled one is the editor's: neither is
            // sent again by a launch.
            guard job.lane == .whole, job.state != .held, job.cancelledAt == nil else { continue }
            for file in job.files where file.uploadUID != nil && !file.isComplete {
                let ref = WholeFileRef(jobID: job.id, fileID: file.id)
                if !carried.contains(ref) { retryWhole.append(ref) }
            }
        }
        return WholeReconciliationPlan(
            adopted: adopted, cancelled: cancelled, retryWhole: retryWhole
        )
    }
}
