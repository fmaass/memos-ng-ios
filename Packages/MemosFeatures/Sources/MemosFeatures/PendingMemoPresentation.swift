import Foundation
import MemosOutbox

/// One thing a row lets a person do about a capture. A row offers a list of them, in the order
/// they are drawn; the empty list is the row that asks for nothing.
public enum PendingAction: Sendable, Hashable {
    /// A hold a person can clear, and the way back into the editor for a capture they stopped —
    /// "Try again".
    case retry
    /// A capture nothing can move on: its manifest could not be read, so it can never be sent and
    /// no hold can be cleared. What is left is throwing it away deliberately, files and all.
    case remove
    /// Stop a capture on its way and have its words and its files back in the editor. Offered
    /// while it is still moving, because that is exactly when a person wants it.
    case cancel
}

/// One queued capture, as a row.
public struct PendingRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var snippet: String
    public var status: String
    public var attachmentCount: Int
    /// What the row offers, in the order it is drawn, decided here rather than by the view.
    public var actions: [PendingAction]

    /// True when the job is stopped and only a person can move it — the row says so and offers the
    /// one thing that would help.
    ///
    /// Not derived from `actions`: a capture doing its job offers Cancel and is not in trouble,
    /// and a row painted orange for that would make the colour mean nothing on the rows that are.
    public var needsAttention: Bool

    public init(
        id: UUID,
        snippet: String,
        status: String,
        attachmentCount: Int,
        actions: [PendingAction],
        needsAttention: Bool
    ) {
        self.id = id
        self.snippet = snippet
        self.status = status
        self.attachmentCount = attachmentCount
        self.actions = actions
        self.needsAttention = needsAttention
    }
}

/// What the pending section says, decided outside any view.
///
/// A queue that lies is worse than no queue: every state a job can be in has a sentence here, and
/// each one is asserted rather than eyeballed on a device that happens to have wifi.
public enum PendingMemoPresentation {
    /// Newest capture first, above the server's own memos — the same order the timeline reads in.
    ///
    /// `now` and the two facts beside it are handed in rather than read here: whether a capture's
    /// bytes have stopped moving is a comparison against a clock, and a comparison a screen makes
    /// against its own clock is one nothing can assert.
    public static func rows(
        for jobs: [UploadJob],
        now: Date = Date(),
        lastProgressAt: [UUID: Date] = [:],
        uploadsPermitted: Bool = true
    ) -> [PendingRow] {
        jobs
            .sorted { $0.capturedAt > $1.capturedAt }
            .map { job in
                PendingRow(
                    id: job.id,
                    snippet: snippet(job.content),
                    status: status(
                        for: job,
                        now: now,
                        lastProgressAt: lastProgressAt,
                        uploadsPermitted: uploadsPermitted
                    ),
                    attachmentCount: job.files.count,
                    actions: action(for: job),
                    needsAttention: job.state == .held || job.cancelledAt != nil
                )
            }
    }

    /// What a row lets a person do.
    ///
    /// A capture whose manifest could not be read is the exception every other state is measured
    /// against: "Try again" would clear a hold nothing is holding, so the row would offer a button
    /// that does nothing and sit in the pending list for ever. What it offers instead is the only
    /// move left — throwing the capture away on purpose, which is a person's decision to make and
    /// nothing else's.
    ///
    /// A capture still on its way offers Cancel beside Try again, because a person who no longer
    /// wants it sent should not have to wait for it to finish first. A capture already being
    /// written into a memo offers nothing: its bytes are at the server and nothing here can take
    /// them back, so a control there would be a promise this screen cannot keep.
    public static func action(for job: UploadJob) -> [PendingAction] {
        if job.cancelledAt != nil { return [.retry, .remove] }
        switch job.state {
        case .held:
            switch job.holdReason {
            case .unreadableManifest:
                return [.remove]
            case .accountMismatch, .serverRefused, .storageFailed, .none:
                return [.retry]
            }
        case .uploading, .waiting:
            return [.cancel, .retry]
        case .creating:
            return []
        }
    }

    public static func status(
        for job: UploadJob,
        now: Date = Date(),
        lastProgressAt: [UUID: Date] = [:],
        uploadsPermitted: Bool = true
    ) -> String {
        // Said before the state, because a cancelled capture keeps whatever state it was stopped
        // in: what a person needs to read is that it is theirs again, not where it got to.
        if job.cancelledAt != nil { return Self.cancelledAndKept }
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
            // The network the phone is on explains the silence completely, so the row says that
            // and not that something unknown has gone quiet.
            if !uploadsPermitted { return Self.waitingForHomeNetwork }
            if let last = lastProgressAt[job.id], now.timeIntervalSince(last) >= Self.stallInterval
            {
                return Self.noProgressConfirmed
            }
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

    /// How long a capture's confirmed bytes may stand still before the row stops showing a
    /// percentage nothing is adding to.
    ///
    /// A product number rather than a derived one. One chunk is megabytes and can legitimately
    /// take longer than a single request is given, so a shorter interval would call a working
    /// upload stalled; longer, and the row goes on counting at a person who can see it is stuck.
    public static let stallInterval: TimeInterval = 90

    /// What a capture whose bytes stopped moving says. It states what is known — nothing has been
    /// confirmed for a while — and nothing else: no attempt has failed, and a row that said so
    /// would be inventing an outcome the queue has not had.
    static let noProgressConfirmed = "No progress confirmed for \(Int(stallInterval)) s"

    /// What a capture a person stopped says for as long as they leave it alone. The words and the
    /// files are on this device and nowhere else, which is the part they need to know before they
    /// decide between sending it again and throwing it away.
    static let cancelledAndKept = "Cancelled — kept on this device"

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
