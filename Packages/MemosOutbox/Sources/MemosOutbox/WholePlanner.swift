import Foundation

/// The one thing a whole-lane capture needs next.
///
/// A type of its own rather than more cases on `OutboxAction`: the engine's switch over that one is
/// exhaustive, and the whole lane has no engine yet.
public enum WholeAction: Sendable, Equatable {
    /// Stop, and wait for a person. Never retried on a timer.
    case hold(HoldReason)
    /// Nothing to do until this moment. `.distantFuture` is a wait no clock ends: the capture is
    /// waiting for scheduling to open, which only the app coming to the foreground does.
    case wait(until: Date)
    /// Send these files, each whole, in ONE pass, in capture order. `starting` have no upload
    /// session yet. `retrying` have one that holds less than the whole file and that no task is
    /// carrying, so each is sent again from its first byte (`UploadJob.retryingWhole`). Together at
    /// most `UploadBudget.inFlightUploads` less the files already carried, and possibly none: every
    /// file that still needs sending is carried, and its task's answer is what comes next.
    case upload(starting: [UUID], retrying: [UUID])
    /// Every file is on the server: create the memo that links them.
    case createMemo
}

/// How many whole-file uploads may be in flight at once, across every capture.
///
/// A phone that hands the system every file of every capture at once has, in effect, asked the
/// server for all of them at once: a rate limit answers most of them, and each of those answers is
/// a retry. Two keeps one large file from starving the rest without making a burst of it.
public enum UploadBudget {
    public static let inFlightUploads = 2

    /// The longest `Retry-After`, in seconds, taken as a usable hint: seven days. A longer one
    /// cannot be a real backpressure answer from this server, and a deadline that far out risks
    /// the manifest's ISO 8601 round trip — an unreadable capture. It is ignored like an
    /// HTTP-date, and the computed schedule applies.
    public static let longestRetryAfter: TimeInterval = 604_800
}

extension OutboxPlanner {
    /// What to do next with a whole-lane capture, decided from the capture alone.
    ///
    /// It is asked about a capture none of whose files a task is carrying — reconciliation keeps
    /// the carried ones out — so a file with a session and missing bytes is one nothing is sending.
    ///
    /// - Parameter schedulingOpen: whether new work may start. While it is closed the app is not in
    ///   the foreground, and a background wake finishes a transfer that already happened and
    ///   schedules nothing new: the answer is a memo create or a wait, never a hold either — the
    ///   hold is written by the next foreground pass, where the row is on screen.
    ///   - carried: the files of this capture a task is carrying, or this engine is still handing
    ///     off or applying an answer to. They are never sent again, and they spend the budget.
    public static func nextWholeAction(
        for job: UploadJob,
        credentials: OutboxCredentials,
        now: Date,
        schedulingOpen: Bool,
        carried: Set<UUID> = []
    ) -> WholeAction {
        let action = nextWholeActionWhenOpen(
            for: job, credentials: credentials, now: now, carried: carried
        )
        if schedulingOpen { return action }
        switch action {
        case .createMemo, .wait:
            return action
        case .hold, .upload:
            return .wait(until: .distantFuture)
        }
    }

    private static func nextWholeActionWhenOpen(
        for job: UploadJob,
        credentials: OutboxCredentials,
        now: Date,
        carried: Set<UUID>
    ) -> WholeAction {
        // The binding before anything else, as on the chunk lane: a capture made under another
        // account never reaches a request, a memo create included.
        guard job.binding.matches(credentials) else { return .hold(.accountMismatch) }
        if job.cancelledAt != nil { return .wait(until: job.nextAttemptAt) }
        if job.state == .held { return .hold(job.holdReason ?? .serverRefused) }
        if now < job.nextAttemptAt { return .wait(until: job.nextAttemptAt) }

        let needing = job.files.filter { !$0.isComplete }
        if needing.isEmpty { return .createMemo }
        // Eligibility before the budget is counted, so a file waiting out its own deadline never
        // takes a place a sibling could have used.
        let eligible = needing.filter { file in
            !carried.contains(file.id) && (file.nextAttemptAt.map { now >= $0 } ?? true)
        }
        let spent = needing.filter { carried.contains($0.id) }.count
        let chosen = eligible.prefix(Swift.max(UploadBudget.inFlightUploads - spent, 0))
        if eligible.isEmpty,
            let deadline = needing.compactMap(\.nextAttemptAt).filter({ $0 > now }).min()
        {
            return .wait(until: deadline)
        }
        return .upload(
            starting: chosen.filter { $0.uploadUID == nil }.map(\.id),
            retrying: chosen.filter { $0.uploadUID != nil }.map(\.id)
        )
    }
}

extension UploadJob {
    /// Sends ONE file again from its first byte, under a fresh upload session and a new attempt
    /// term.
    ///
    /// Only this file moves. `bumpingAttempts` moves every file still transferring, which fits the
    /// chunk lane's one task per job and is wrong here: a sibling's task is still carrying its
    /// original under the term it was sent with, and moving that term would make its answer stale —
    /// a finished video thrown away because a picture failed. The session is forgotten rather than
    /// resumed: a fresh one starts at `bytes_received` 0, and the server lets the old one expire.
    /// A file the server already holds whole is not sent again.
    public func retryingWhole(fileID: UUID) -> UploadJob {
        updating(fileID) { file in
            guard !file.isComplete else { return }
            file.uploadAttempt = (file.uploadAttempt ?? 0) + 1
            file.uploadUID = nil
            file.bytesConfirmed = 0
        }
    }
}
