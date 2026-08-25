import Foundation
import MemosOutbox

/// The one thing a stopped row lets a person do about it.
public enum PendingAction: Sendable, Equatable {
    /// The queue is still working on this capture: there is nothing to press.
    case none
    /// A hold a person can clear — "Try again".
    case retry
    /// A capture nothing can move on: its manifest could not be read, so it can never be sent and
    /// no hold can be cleared. What is left is throwing it away deliberately, files and all.
    case remove
}

/// One queued capture, as a row.
public struct PendingRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var snippet: String
    public var status: String
    public var attachmentCount: Int
    /// What the row offers, decided here rather than by the view drawing it.
    public var action: PendingAction

    /// True when the job is stopped and only a person can move it — the row says so and offers the
    /// one thing that would help.
    public var needsAttention: Bool { action != .none }

    public init(
        id: UUID,
        snippet: String,
        status: String,
        attachmentCount: Int,
        action: PendingAction
    ) {
        self.id = id
        self.snippet = snippet
        self.status = status
        self.attachmentCount = attachmentCount
        self.action = action
    }
}

/// What the pending section says, decided outside any view.
///
/// A queue that lies is worse than no queue: every state a job can be in has a sentence here, and
/// each one is asserted rather than eyeballed on a device that happens to have wifi.
public enum PendingMemoPresentation {
    /// Newest capture first, above the server's own memos — the same order the timeline reads in.
    public static func rows(for jobs: [UploadJob]) -> [PendingRow] {
        jobs
            .sorted { $0.capturedAt > $1.capturedAt }
            .map { job in
                PendingRow(
                    id: job.id,
                    snippet: snippet(job.content),
                    status: status(for: job),
                    attachmentCount: job.files.count,
                    action: action(for: job)
                )
            }
    }

    /// What a row lets a person do, which is never more than one thing.
    ///
    /// A capture whose manifest could not be read is the exception every other state is measured
    /// against: "Try again" would clear a hold nothing is holding, so the row would offer a button
    /// that does nothing and sit in the pending list for ever. What it offers instead is the only
    /// move left — throwing the capture away on purpose, which is a person's decision to make and
    /// nothing else's.
    public static func action(for job: UploadJob) -> PendingAction {
        guard job.state == .held else { return .none }
        switch job.holdReason {
        case .unreadableManifest:
            return .remove
        case .accountMismatch, .serverRefused, .storageFailed, .none:
            return .retry
        }
    }

    public static func status(for job: UploadJob) -> String {
        switch job.state {
        case .held:
            switch job.holdReason {
            case .accountMismatch:
                return "Captured under another account"
            case .unreadableManifest:
                return "This capture could not be read — its files are kept"
            case .storageFailed:
                return job.lastError ?? "This capture could not be saved on this device"
            case .serverRefused, .none:
                return job.lastError ?? "Needs attention"
            }
        case .creating:
            return "Finishing up"
        case .uploading:
            return "Uploading \(percent(job))%"
        case .waiting:
            // The reason comes before the attempt count on purpose. A capture refused by the
            // network it is on is not spacing out a retry — nothing was tried — and "Waiting to
            // try again" on a phone that will never try until it is back on wifi is the kind of
            // sentence that makes a person force-quit the app.
            if job.waitReason == .homeNetwork { return Self.waitingForHomeNetwork }
            if job.attemptCount > 0 { return "Waiting to try again" }
            return "Waiting for home wifi"
        }
    }

    /// What a capture held for the wrong network says, which is also where the person is told
    /// what would send it now. A row that only said "waiting" would be true and useless.
    static let waitingForHomeNetwork =
        "Waiting for your home network — turn on Upload over mobile data in Settings"
        + " to send it now"

    /// A capture with no words is described by what it carries, so the row is never blank.
    public static func snippet(_ content: String, limit: Int = 120) -> String {
        let flattened =
            content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "" }
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func percent(_ job: UploadJob) -> Int {
        Int((min(max(job.fractionUploaded, 0), 1) * 100).rounded())
    }
}
