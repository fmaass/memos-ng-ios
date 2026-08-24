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

    public init(jobID: UUID, fileID: UUID, offset: Int64) {
        self.jobID = jobID
        self.fileID = fileID
        self.offset = offset
    }

    public var taskDescription: String {
        "\(jobID.uuidString)|\(fileID.uuidString)|\(offset)"
    }

    /// Returns nil for anything this app did not write — a task with an unreadable description is
    /// not adopted, it is cancelled.
    public init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let parts = taskDescription.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let jobID = UUID(uuidString: String(parts[0])),
            let fileID = UUID(uuidString: String(parts[1])),
            let offset = Int64(String(parts[2])),
            offset >= 0
        else { return nil }
        self.init(jobID: jobID, fileID: fileID, offset: offset)
    }
}
