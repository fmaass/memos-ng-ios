import Foundation

/// The whole lane's background session, as the drain needs to see it.
///
/// A protocol for the reason `OutboxChunkScheduling` is one: the drain's rules are asserted
/// without a network. The tests hand the engine the PRODUCTION scheduler over a scripted task
/// session, so what stands in is the session, never the scheduler's own decisions.
public protocol OutboxUploadScheduling: Sendable {
    /// The process this scheduler describes its tasks with (`WholeTaskIdentity.launch`).
    var launch: UUID { get }
    func attach(_ handler: any WholeAnswerHandling) async
    func tasks() async -> [WholeTaskListing]
    /// Whether a finished task's answer is still waiting to be applied: buffered before adoption,
    /// or not yet reached by its replay. Such a file is carried by nothing a listing shows.
    func holdsUnappliedAnswers() async -> Bool
    /// Every file an answer the delegate has taken is about, with the attempt it answers, until the
    /// handler has finished applying it — buffered, replaying or live.
    func unappliedAnswers() async -> [WholeFileRef: Int]
    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        for ref: WholeFileRef,
        attempt: Int,
        under authority: SendAuthority,
        issuedUnder epoch: Int
    ) async -> WholeTask?
    func cancel(_ taskIdentifiers: [Int]) async
    func cancelUnreadable() async -> [Int]
    func mismatched(allowsMobileData: Bool) async -> [WholeTask]
    /// `onSettled` runs exactly once, with the successor's task once it exists or nil when none
    /// will — see `BackgroundUploadScheduler.replace(_:under:onSettled:successor:)`.
    func replace(
        _ task: WholeTask,
        under authority: SendAuthority,
        onSettled: @escaping @Sendable (WholeTask?) async -> Void,
        successor: @escaping @Sendable () async -> WholeSuccessor?
    ) async -> WholeReplacement
    func reexamineDeferred() async -> [WholeTask]
}

extension BackgroundUploadScheduler: OutboxUploadScheduling {}

/// What one whole-file answer does to its file, decided by the engine from the answer alone and
/// applied by the repository to the manifest as it is at the instant of the write.
public enum WholeFileChange: Sendable, Equatable {
    /// The server holds this many bytes of the file.
    case confirmed(Int64)
    /// The file goes again from its first byte, under a fresh session and its own next term.
    case retryWhole
    /// Nothing the server said about this file: the capture spaces itself out.
    case backOff(String)
    /// A refusal. Held or backed off by `OutboxRefusal`, chosen where the write is.
    case refused(OutboxRefusal)
}

extension UploadJob {
    /// This job with one file's answer applied, or nil when the answer is no longer about it.
    ///
    /// Pure, and asked of the manifest ON DISK at the instant of the write rather than of the value
    /// the answer's handler read before its hops: a sibling's answer landing in between is progress
    /// this answer must not overwrite, and whole-manifest equality would throw this one away.
    /// Only this file's fields move, plus the job-level state the change names.
    ///
    /// - Parameters:
    ///   - attempt: the term the task was sent under. A task a retry or a replacement superseded
    ///     carries an older one, and its answer changes nothing.
    ///   - stillCurrent: whether the credential the refused request presented still stands — the
    ///     question a refusal's disposition is chosen by, asked by the caller on the isolation that
    ///     writes.
    ///
    /// A row that is `.creating` takes no file answer: its memo create is in flight on the files as
    /// they stood when it began, and a file moving under it would be a manifest that create never
    /// saw.
    func applyingFileAnswer(
        fileID: UUID,
        attempt: Int,
        change: WholeFileChange,
        stillCurrent: Bool,
        at instant: Date
    ) -> UploadJob? {
        guard lane == .whole, cancelledAt == nil, state != .held, state != .creating,
            let file = file(fileID),
            (file.uploadAttempt ?? 0) == attempt,
            file.uploadUID != nil,
            !file.isComplete
        else { return nil }
        switch change {
        case .confirmed(let bytes):
            return advancing(fileID: fileID, bytesConfirmed: bytes)
        case .retryWhole:
            return retryingWhole(fileID: fileID)
        case .backOff(let message):
            return backingOff(at: instant, error: message)
        case .refused(let refusal):
            return applying(refusal.disposition(assumingCurrent: stillCurrent), at: instant)
        }
    }
}

extension OutboxPersisting {
    /// The per-file rebase for a store that does not implement one of its own: read, rebase, and
    /// a write fenced on the manifest that was read, asked again when a sibling moved the row in
    /// between. `OutboxRepository` answers it on its own isolation with nothing awaited.
    public func applyFileAnswer(
        jobID: UUID,
        fileID: UUID,
        attempt: Int,
        outcome: WholeFileChange,
        presented: WholeTaskProvenance,
        at instant: Date
    ) async throws -> UploadJob? {
        for _ in 0..<8 {
            guard let onDisk = await job(jobID),
                let current = onDisk.applyingFileAnswer(
                    fileID: fileID, attempt: attempt, change: outcome, stillCurrent: true,
                    at: instant
                ),
                let superseded = onDisk.applyingFileAnswer(
                    fileID: fileID, attempt: attempt, change: outcome, stillCurrent: false,
                    at: instant
                )
            else { return nil }
            let epoch: Int?
            switch presented {
            case .thisLaunch(let issued): epoch = issued
            case .unknown: epoch = nil
            }
            // An answer another launch earned is never proof against the credential held now.
            let chosen = epoch == nil ? superseded : current
            if let written = try await save(
                chosen, ifStillCurrent: epoch, matching: onDisk, else: superseded
            ) {
                return written
            }
        }
        return nil
    }
}
