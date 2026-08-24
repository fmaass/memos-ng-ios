import Foundation
import MemosOutbox

/// One queued capture, as a row.
public struct PendingRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var snippet: String
    public var status: String
    public var attachmentCount: Int
    /// True when the job is stopped and only a person can move it — the row offers "Try again".
    public var needsAttention: Bool

    public init(
        id: UUID,
        snippet: String,
        status: String,
        attachmentCount: Int,
        needsAttention: Bool
    ) {
        self.id = id
        self.snippet = snippet
        self.status = status
        self.attachmentCount = attachmentCount
        self.needsAttention = needsAttention
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
                    needsAttention: job.state == .held
                )
            }
    }

    public static func status(for job: UploadJob) -> String {
        switch job.state {
        case .held:
            switch job.holdReason {
            case .accountMismatch:
                return "Captured under another account"
            case .serverRefused, .none:
                return job.lastError ?? "Needs attention"
            }
        case .creating:
            return "Finishing up"
        case .uploading:
            return "Uploading \(percent(job))%"
        case .waiting:
            if job.attemptCount > 0 { return "Waiting to try again" }
            return "Waiting for home wifi"
        }
    }

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
