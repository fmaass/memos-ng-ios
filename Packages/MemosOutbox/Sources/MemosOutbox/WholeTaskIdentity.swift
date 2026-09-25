import Foundation

/// What a whole-file upload task is FOR, written into its `taskDescription`.
///
/// Six terms: `job|file|0|attempt|launch|epoch`. The first four stand where the chunk lane's stand,
/// so whatever reads a description by position — the job UUID at its head — reads this one too. The
/// offset is always 0: a whole task carries the original from its first byte, and a description at
/// any other offset is not one this lane wrote.
///
/// The last two say who sent it. `launch` is minted once per process and `epoch` is the authority
/// epoch the request presented. A refusal is evidence only against the credential that earned it,
/// and after a relaunch the process that knew which credential that was is gone: an epoch another
/// launch recorded cannot be compared with anything here, so its provenance is unknown, never
/// current.
public struct WholeTaskIdentity: Sendable, Equatable, Hashable {
    public var jobID: UUID
    public var fileID: UUID
    /// The file's attempt term. Every whole task names one: a manifest that never moved the term
    /// reads `uploadAttempt` as nil, and that is attempt 0 here.
    public var attempt: Int
    /// The process that sent the task.
    public var launch: UUID
    /// The authority epoch the request presented.
    public var epoch: Int

    public init(jobID: UUID, fileID: UUID, attempt: Int, launch: UUID, epoch: Int) {
        self.jobID = jobID
        self.fileID = fileID
        self.attempt = attempt
        self.launch = launch
        self.epoch = epoch
    }

    public var taskDescription: String {
        "\(jobID.uuidString)|\(fileID.uuidString)|0|\(attempt)|\(launch.uuidString)|\(epoch)"
    }

    /// Returns nil for anything this lane did not write — a task with an unreadable description is
    /// not adopted, it is cancelled. A chunk-lane description has fewer terms and is one of those.
    public init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let parts = taskDescription.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 6,
            let jobID = UUID(uuidString: String(parts[0])),
            let fileID = UUID(uuidString: String(parts[1])),
            parts[2] == "0",
            let attempt = Int(String(parts[3])),
            attempt >= 0,
            let launch = UUID(uuidString: String(parts[4])),
            let epoch = Int(String(parts[5]))
        else { return nil }
        self.init(jobID: jobID, fileID: fileID, attempt: attempt, launch: launch, epoch: epoch)
    }

    /// Whose credential this task's answer is evidence about, judged from the process asking.
    public func provenance(currentLaunch: UUID) -> WholeTaskProvenance {
        launch == currentLaunch ? .thisLaunch(epoch: epoch) : .unknown
    }
}

/// Which grant a whole task was sent under, as far as the process holding its answer can know.
public enum WholeTaskProvenance: Sendable, Equatable {
    /// This process sent it under this authority epoch: a refusal it earned is judged against it.
    case thisLaunch(epoch: Int)
    /// An earlier process sent it. A refusal it earned is never taken as proof against the
    /// credential the device holds now — the next request, sent under that credential, asks again.
    case unknown
}
