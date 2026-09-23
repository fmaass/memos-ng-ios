import Foundation

/// What a background upload task is FOR, written into its `taskDescription`.
///
/// A background session outlives the process: after a relaunch the app is handed tasks and no
/// memory of why they exist. The description is the only thing that survives with them, so it
/// carries everything needed to re-correlate a task with a job, a file and the byte offset it was
/// sent at — which is also what makes it possible to tell an adoptable task from a stale one.
public struct OutboxTaskIdentity: Sendable, Equatable, Hashable {
    public var jobID: UUID
    public var fileID: UUID
    public var offset: Int64
    /// Which retry of this file the task belongs to, or nil for a task minted before the term
    /// existed. It is the LAST term because everything that reads a description or a chunk name
    /// by position — the orphan sweep among them — reads the job UUID at the head of it.
    public var attempt: Int?

    public init(jobID: UUID, fileID: UUID, offset: Int64, attempt: Int? = nil) {
        self.jobID = jobID
        self.fileID = fileID
        self.offset = offset
        self.attempt = attempt
    }

    public var taskDescription: String {
        let base = "\(jobID.uuidString)|\(fileID.uuidString)|\(offset)"
        guard let attempt else { return base }
        return "\(base)|\(attempt)"
    }

    /// Returns nil for anything this app did not write — a task with an unreadable description is
    /// not adopted, it is cancelled.
    public init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let parts = taskDescription.split(separator: "|", omittingEmptySubsequences: false)
        // Three terms is a description an older build wrote, and a background session can still
        // hand one back after an update. It parses, and it names attempt nil — the same value a
        // manifest without `uploadAttempt` decodes to, so the pair still matches and is adopted.
        guard parts.count == 3 || parts.count == 4,
            let jobID = UUID(uuidString: String(parts[0])),
            let fileID = UUID(uuidString: String(parts[1])),
            let offset = Int64(String(parts[2])),
            offset >= 0
        else { return nil }
        var attempt: Int?
        if parts.count == 4 {
            guard let parsed = Int(String(parts[3])), parsed >= 0 else { return nil }
            attempt = parsed
        }
        self.init(jobID: jobID, fileID: fileID, offset: offset, attempt: attempt)
    }

    /// The tasks a retry that saved `bumped` left BEHIND: this job's, for a file that retry moved,
    /// carrying a term OLDER than the one it saved. A task at or past it is the replacement this
    /// retry scheduled or one a LATER retry minted mid-enumeration — cancelling either tears down
    /// a live transfer. A legacy task carries no term at all, which no term can predate, so it is
    /// always a predecessor.
    public static func supersededTasks(
        inFlight: [OutboxTaskIdentity],
        bumped: [UUID: Int?],
        jobID: UUID
    ) -> [OutboxTaskIdentity] {
        inFlight.filter { identity in
            guard identity.jobID == jobID, let term = bumped[identity.fileID], let saved = term
            else { return false }
            guard let attempt = identity.attempt else { return true }
            return attempt < saved
        }
    }
}
