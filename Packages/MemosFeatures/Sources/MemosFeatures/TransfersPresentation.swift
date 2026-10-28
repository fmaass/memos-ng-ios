import Foundation
import MemosOutbox

/// The `transfers.sheet` switch: whether the timeline shows the transfers strip and its sheet.
///
/// A Settings-pane toggle read the way `UploadSpike.isEnabled` is, from the app group's defaults.
/// It is ON by default — the household is meant to see its uploads — so a suite the pane never
/// registered into (a fresh install before its first launch wrote the defaults) still reads on.
public enum TransfersFlag {
    public static let toggleKey = "transfers.sheet"

    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: toggleKey) as? Bool ?? true
    }
}

/// The one move a stopped transfer row offers, named by the fix it makes.
public enum TransfersAction: String, Sendable, Hashable, CaseIterable {
    /// Clear the hold or the backoff and send now — the outbox's own retry.
    case retryNow
    /// Turn on Upload over mobile data — the upload preference the Settings pane holds.
    case useMobileData
    /// Sign in again — the sign-out that leads to the sign-in screen.
    case signIn
    /// Throw the capture away — the outbox's own discard.
    case remove
    /// Take the capture back into the editor — the outbox's own cancel.
    case reopen

    public var title: String {
        switch self {
        case .retryNow: "Retry now"
        case .useMobileData: "Use mobile data"
        case .signIn: "Sign in"
        case .remove: "Remove"
        case .reopen: "Reopen"
        }
    }
}

/// One file's row in the transfers sheet.
public struct TransfersRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var jobID: UUID
    public var filename: String
    /// 0...1, the ring's fill.
    public var fraction: Double
    /// "400 KB of 1 MB".
    public var bytes: String
    /// Why the file is not moving, in the pending rows' own words; nil while it moves or once done.
    public var reason: String?
    /// The one fix this row offers, when it offers one.
    public var action: TransfersAction?
}

/// One capture in the transfers sheet: its first line and a row per file.
public struct TransfersSection: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var rows: [TransfersRow]
}

/// What the transfers strip and sheet say, from the ledger alone.
///
/// Every sentence about WHY a file waits is read from `PendingMemoPresentation`, which already
/// words the persisted hold and wait reasons for the pending rows: two tables would drift, and a
/// row in the sheet would then disagree with the same capture's pending card.
public enum TransfersPresentation {
    /// The strip's line, or nil when the strip is not shown at `now`.
    public static func stripLine(for ledger: TransferLedger, now: Date) -> String? {
        guard ledger.isStripVisible(at: now) else { return nil }
        return stripLine(summary: ledger.summary, eta: ledger.estimate(at: now))
    }

    static func stripLine(summary: TransferSummary, eta: TransferETA) -> String {
        guard summary.jobs > 0 else { return nothingLeft }
        var parts = ["\(summary.filesDone) of \(summary.filesTotal) sent"]
        if summary.bytesLeft > 0 {
            parts.append("\(byteString(summary.bytesLeft)) left")
            if let time = etaText(eta) { parts.append(time) }
        }
        return parts.joined(separator: " · ")
    }

    static let nothingLeft = "Nothing left to upload"

    /// The ETA as the strip says it; nil when no time is said at all.
    static func etaText(_ eta: TransferETA) -> String? {
        switch eta {
        case .unknown: return nil
        case .paused: return "paused"
        case .remaining(let seconds):
            guard seconds >= 60 else { return "under a minute" }
            let minutes = Int((seconds / 60).rounded(.up))
            guard minutes >= 60 else { return "about \(minutes) min" }
            let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
            return rest == 0 ? "about \(hours) h" : "about \(hours) h \(rest) min"
        }
    }

    static func byteString(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// The sheet: a section per capture, newest first as the pending rows are, a row per file.
    public static func sections(
        for ledger: TransferLedger,
        now: Date,
        lastProgressAt: [UUID: Date],
        verdict: UploadVerdict
    ) -> [TransfersSection] {
        ledger.jobs
            .sorted { $0.manifest.capturedAt > $1.manifest.capturedAt }
            .map { job in
                TransfersSection(
                    id: job.id,
                    title: PendingMemoPresentation.snippet(job.manifest.content),
                    rows: job.files.map { file in
                        TransfersRow(
                            id: file.id,
                            jobID: job.id,
                            filename: file.filename,
                            fraction: Swift.min(Swift.max(file.fraction, 0), 1),
                            bytes: "\(byteString(file.bytesConfirmed)) of "
                                + byteString(file.byteSize),
                            reason: reason(
                                for: file, in: job, now: now, lastProgressAt: lastProgressAt,
                                verdict: verdict),
                            action: action(
                                for: file, in: job, now: now, lastProgressAt: lastProgressAt,
                                verdict: verdict)
                        )
                    }
                )
            }
    }

    /// Why `file` is not moving, in the pending rows' words; nil while it moves or once it is done.
    static func reason(
        for file: TransferFile, in job: TransferJob, now: Date, lastProgressAt: [UUID: Date],
        verdict: UploadVerdict
    ) -> String? {
        switch file.state {
        case .done:
            return nil
        case .uploading:
            // A file the network refuses, or one whose capture has confirmed nothing for the stall
            // interval, is not moving whatever its state says.
            if case .refused(let refusal) = verdict {
                return PendingMemoPresentation.refusal(refusal)
            }
            if stalled(job, now: now, lastProgressAt: lastProgressAt) {
                return PendingMemoPresentation.noProgressConfirmed
            }
            return nil
        case .waiting, .held:
            if case .retrying = file.reason { return PendingMemoPresentation.retrying }
            return PendingMemoPresentation.status(
                for: job.manifest, now: now, lastProgressAt: lastProgressAt, verdict: verdict)
        }
    }

    /// The one fix `file`'s row offers. A hold offers the fix its reason names
    /// (`HoldReason.fixAction`), but never a move the pending row would refuse the same capture —
    /// a Remove beside a change the server has not answered, a Reopen of one it is editing — and
    /// then it falls back to the retry that row does offer.
    static func action(
        for file: TransferFile, in job: TransferJob, now: Date, lastProgressAt: [UUID: Date],
        verdict: UploadVerdict
    ) -> TransfersAction? {
        guard
            reason(for: file, in: job, now: now, lastProgressAt: lastProgressAt, verdict: verdict)
                != nil
        else { return nil }
        let offered = PendingMemoPresentation.action(for: job.manifest)
        let retry: TransfersAction? = offered.contains(.retry) ? .retryNow : nil
        switch file.state {
        case .done:
            return nil
        case .held:
            switch job.manifest.holdReason?.fixAction ?? .retry {
            case .retry: return retry
            case .remove: return offered.contains(.remove) ? .remove : retry
            case .reopen: return offered.contains(.reopen) ? .reopen : retry
            case .signIn, .switchAccount: return .signIn
            }
        case .waiting, .uploading:
            if case .refused(let refusal) = verdict {
                switch refusal {
                case .cellularWhileMobileDataOff, .expensiveWhileMobileDataOff:
                    return .useMobileData
                case .noPath, .lowDataMode:
                    return nil
                }
            }
            if case .retrying = file.reason { return retry }
            if file.state == .uploading { return retry }  // stalled: the reason above said so
            let manifest = job.manifest
            if manifest.waitReason == .retrying || manifest.attemptCount > 0 { return retry }
            return nil
        }
    }

    static func stalled(_ job: TransferJob, now: Date, lastProgressAt: [UUID: Date]) -> Bool {
        guard let last = lastProgressAt[job.id] else { return false }
        return now.timeIntervalSince(last) >= PendingMemoPresentation.stallInterval
    }
}

/// Runs a row's fix through the outbox's own operations — the retry, the discard and the cancel
/// the pending rows use, the upload preference the Settings pane holds — never a path of its own.
///
/// A row's fix is claimed per capture before anything is awaited, so a second tap landing while
/// the first is still out is refused rather than sent beside it: a disabled button is not the
/// guard.
@MainActor
final class TransfersFixer {
    private var claimed: Set<UUID> = []

    /// Performs `action` for the capture `jobID`. Returns false, doing nothing, while a fix for the
    /// same capture is still running.
    @discardableResult
    func perform(
        _ action: TransfersAction,
        jobID: UUID,
        outbox: Outbox,
        uploads: UploadSettings?,
        signIn: () -> Void,
        reopen: (RestoredDraft) -> Void
    ) async -> Bool {
        guard claimed.insert(jobID).inserted else { return false }
        defer { claimed.remove(jobID) }
        switch action {
        case .retryNow:
            await outbox.retry(jobID)
        case .remove:
            await outbox.discard(jobID)
        case .useMobileData:
            if let uploads {
                await uploads.select(true).value
            } else {
                outbox.uploadPreferences.apply(true)
                await outbox.uploadPreferences.drainAfterApply()
            }
        case .signIn:
            signIn()
        case .reopen:
            if let draft = await outbox.cancel(jobID) { reopen(draft) }
        }
        return true
    }
}
