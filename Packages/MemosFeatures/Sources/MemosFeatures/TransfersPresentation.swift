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
    /// Let THIS capture's videos go over mobile data, changing neither setting — the outbox's own
    /// `releaseVideoOverMobile`, offered while a video rule holds the capture.
    case useMobileDataForThisOne
    /// Sign in again — the sign-out that leads to the sign-in screen.
    case signIn
    /// Sign out of the account on this phone and in as the one the capture was made under — the
    /// same route as Sign in, named for what it does to the account signed in now.
    case switchAccount
    /// Throw the capture away — the outbox's own discard.
    case remove
    /// Take the capture back into the editor — the outbox's own cancel.
    case reopen
    /// The Settings app, where Photos access is allowed (MEMNG-952).
    case openSettings

    public var title: String {
        switch self {
        case .retryNow: "Retry now"
        case .useMobileData: "Use mobile data"
        case .useMobileDataForThisOne: "Use mobile data for this one"
        case .signIn: "Sign in"
        case .switchAccount: "Sign out and switch account"
        case .remove: "Remove"
        case .reopen: "Reopen"
        case .openSettings: "Open Settings"
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
        // A held capture's files read held, not done, even with every byte on the server (the
        // ledger keeps the capture's stop visible on its rows), so the strip counts what the
        // server holds whole as sent and says how many captures are held — "0 of 2 sent" with
        // nothing left to send read as a queue that had not started (MEMNG-1042).
        var summary = ledger.summary
        summary.filesDone = ledger.jobs.flatMap(\.files).count(where: { file in
            file.state == .done || (file.byteSize > 0 && file.bytesConfirmed >= file.byteSize)
        })
        let held = ledger.jobs.count(where: { $0.manifest.state == .held })
        return stripLine(summary: summary, eta: ledger.estimate(at: now), held: held)
    }

    /// The line a strip still in the list says once the ledger no longer shows one: it is kept
    /// there while the reader is away from the top (`TransfersStripPlace`).
    static func shownLine(for ledger: TransferLedger, now: Date) -> String {
        stripLine(for: ledger, now: now) ?? nothingLeft
    }

    static func stripLine(summary: TransferSummary, eta: TransferETA, held: Int = 0) -> String {
        guard summary.jobs > 0 else { return nothingLeft }
        var parts = ["\(summary.filesDone) of \(summary.filesTotal) sent"]
        if held > 0 { parts.append("\(held) held") }
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
            if case .inPhotos(let needsAccess) = file.reason {
                return needsAccess ? allowPhotosAccess : copyingFromPhotos
            }
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
        // An item Photos access does not reach is fixed in Settings, and by nothing in this app.
        if case .inPhotos(let needsAccess) = file.reason {
            return needsAccess ? .openSettings : nil
        }
        switch file.state {
        case .done:
            return nil
        case .held:
            switch job.manifest.holdReason?.fixAction ?? .retry {
            case .retry: return retry
            case .remove: return offered.contains(.remove) ? .remove : retry
            case .reopen: return offered.contains(.reopen) ? .reopen : retry
            case .signIn: return .signIn
            case .switchAccount: return .switchAccount
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
            // A video rule holds it, and the person may let this one go on mobile data — before
            // the retry, because trying again on the same network would only wait again.
            if manifest.waitReason?.isVideoRule == true, manifest.videoOverMobileAllowed != true {
                return .useMobileDataForThisOne
            }
            if manifest.waitReason == .retrying || manifest.attemptCount > 0 { return retry }
            return nil
        }
    }

    /// An item still in Photos that the last staging pass could not read (MEMNG-952).
    static let allowPhotosAccess = "Allow Photos access to send the rest"
    /// An item still in Photos, waiting for the staging lane to copy it in.
    static let copyingFromPhotos = "Copying from Photos"

    static func stalled(_ job: TransferJob, now: Date, lastProgressAt: [UUID: Date]) -> Bool {
        guard let last = lastProgressAt[job.id] else { return false }
        return now.timeIntervalSince(last) >= PendingMemoPresentation.stallInterval
    }

    /// The instant an open sheet must be drawn again on its own: the next row whose stall
    /// threshold passes, when no ledger change would redraw it. Nil when nothing will change.
    static func sheetWake(
        for ledger: TransferLedger, lastProgressAt: [UUID: Date], after now: Date
    ) -> Date? {
        PendingMemoPresentation.stallDeadline(
            for: ledger.jobs.map(\.manifest), lastProgressAt: lastProgressAt, after: now)
    }
}

/// Whether the transfers strip's row is in the timeline (MEMNG-1042).
///
/// The strip is the list's first row, so a row added or removed while the reader is further down
/// moved everything they were reading by the strip's height, and a row above the view is one
/// nobody can see arrive anyway. So the row changes only while the list is at its top, where the
/// reader watches the strip come and go; away from the top it keeps what it was, and a change
/// waits until the reader is back up. Kept as a value so the sequence can be asserted.
struct TransfersStripPlace: Equatable {
    private(set) var shown = false
    private(set) var wanted = false
    private(set) var atTop = true

    /// The ledger's answer: whether a strip should be showing now.
    mutating func want(_ wanted: Bool) {
        self.wanted = wanted
        settle()
    }

    /// One scroll reading (`isAtTop`).
    mutating func scrolled(atTop: Bool) {
        self.atTop = atTop
        settle()
    }

    private mutating func settle() {
        if atTop { shown = wanted }
    }

    /// The row a jump to a day lands on: the strip while it is in the list, which would otherwise
    /// sit just above the view, and the jump's own notice when it is not.
    func jumpTarget<ID: Hashable>(notice: ID, strip: ID) -> ID { shown ? strip : notice }

    /// The list at rest at its top, or pulled down past it. Tighter than the paging trigger's
    /// slack: a row inserted a few points short of the top would still move what is read.
    static func isAtTop(contentOffsetY: CGFloat, topInset: CGFloat) -> Bool {
        TimelineTopWatch.isAtTop(contentOffsetY: contentOffsetY, topInset: topInset, slack: 1)
    }
}

/// The move a transfers fix leaves for after the sheet — a sign-in alert or the editor cannot
/// present over it — belongs to the presentation it was earned in (MEMNG-1042). A fix that
/// returns after the sheet has already gone (dismissed while `outbox.cancel` was out) makes its
/// move at once, rather than waiting for the NEXT sheet's dismissal to open the editor there.
struct TransfersHandOff<Move: Equatable>: Equatable {
    private(set) var presented = false
    private(set) var pending: Move?

    mutating func opened() {
        presented = true
        pending = nil
    }

    /// The move to make now, or nil when it waits for this sheet's dismissal.
    mutating func leave(_ move: Move) -> Move? {
        guard presented else { return move }
        pending = move
        return nil
    }

    /// The sheet has gone: the move it was left, once.
    mutating func dismissed() -> Move? {
        presented = false
        defer { pending = nil }
        return pending
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
        reopen: (RestoredDraft) -> Void,
        openSettings: () -> Void = {}
    ) async -> Bool {
        guard claimed.insert(jobID).inserted else { return false }
        defer { claimed.remove(jobID) }
        switch action {
        case .retryNow:
            await outbox.retry(jobID)
        case .remove:
            await outbox.discard(jobID)
        case .useMobileDataForThisOne:
            await outbox.releaseVideoOverMobile(jobID)
        case .useMobileData:
            if let uploads {
                await uploads.select(true).value
            } else {
                outbox.uploadPreferences.apply(true)
                await outbox.uploadPreferences.drainAfterApply()
            }
        case .signIn, .switchAccount:
            signIn()
        case .reopen:
            if let draft = await outbox.cancel(jobID) { reopen(draft) }
        case .openSettings:
            openSettings()
        }
        return true
    }
}
