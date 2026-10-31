import Foundation
import MemosOutbox

/// One thing a row lets a person do about a capture. A row offers a list of them, in the order
/// they are drawn; the empty list is the row that asks for nothing.
public enum PendingAction: Sendable, Hashable {
    /// A hold a person can clear — "Try again" on a capture the queue stopped itself.
    case retry
    /// A capture nothing can move on: its manifest could not be read, so it can never be sent and
    /// no hold can be cleared. What is left is throwing it away deliberately, files and all.
    case remove
    /// Stop a capture on its way and have its words and its files back in the editor. Offered
    /// while it is still moving, because that is exactly when a person wants it.
    case cancel
    /// The way back into the editor for a capture a person stopped, or whose change stopped before
    /// it was sent. It is not a retry: nothing is sent, the queue hands the draft back and the
    /// editor opens on it.
    case reopen
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

    /// The actions drawn but not pressable, each with the sentence that says why
    /// (`PendingMemoPresentation.disabledReason`).
    public var disabledReasons: [PendingAction: String]

    /// The picked items that never reached this capture, said in one line — nil when none.
    public var missingNote: String?

    public init(
        id: UUID,
        snippet: String,
        status: String,
        attachmentCount: Int,
        actions: [PendingAction],
        needsAttention: Bool,
        disabledReasons: [PendingAction: String] = [:],
        missingNote: String? = nil
    ) {
        self.id = id
        self.snippet = snippet
        self.status = status
        self.attachmentCount = attachmentCount
        self.actions = actions
        self.needsAttention = needsAttention
        self.disabledReasons = disabledReasons
        self.missingNote = missingNote
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
        verdict: UploadVerdict = .permitted
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
                        verdict: verdict
                    ),
                    attachmentCount: job.files.count,
                    actions: action(for: job),
                    needsAttention: job.state == .held || job.cancelledAt != nil,
                    disabledReasons: disabledReasons(for: job),
                    missingNote: missingNote(for: job)
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
        // Nothing in it to send — a Post whose every picked item failed: Reopen would lead to a
        // re-post the queue refuses (`Outbox.resubmit`), so the one way out is the one offered.
        if job.hasNothingToSend { return [.remove] }
        if job.cancelledAt != nil { return [.reopen, .remove] }
        switch job.state {
        case .held:
            switch job.holdReason {
            case .unreadableManifest:
                return [.remove]
            case .memoGone:
                // The memo may come back, so Try again stays; Remove is the way out that does not
                // pretend the change was answered.
                return [.retry, .remove]
            case .editIncomplete:
                // Stopped before it was sent, so the capture is the person's again and the editor
                // is offered back — unless a change already stands unanswered, whose body stays
                // frozen until the server settles it.
                return job.editUnansweredSince == nil ? [.reopen, .retry] : [.retry]
            case .tooLarge:
                // Sending the same bytes again gets the same 413, so the fix the reason names
                // (`fixAction`, remove) leads — unless a change stands unanswered, whose capture
                // Remove must never throw away. Try again stays for the day the limit rises.
                return job.editUnansweredSince == nil ? [.remove, .retry] : [.retry]
            case .accountMismatch, .serverRefused, .storageFailed, .uploadSessionLost,
                .signInRequired, .none:
                // No Remove here: a change turned away while it was still unanswered is not a
                // deleted memo, and Remove would throw away a capture whose change may have landed.
                return [.retry]
            }
        case .uploading, .waiting:
            // While an edit stands unanswered the row offers nothing: the queue refuses the cancel,
            // and its own backoff sends the edit again under the key it was minted with, so the
            // row leaves the answer to the queue until the server gives one.
            return job.editUnansweredSince == nil ? [.cancel, .retry] : []
        case .creating:
            return []
        }
    }

    /// Why an action the row draws cannot be pressed now, or nil when it can.
    ///
    /// Cancel while files are still arriving (MEMNG-951) is drawn disabled: the editor would open
    /// on what has landed so far and every late file would be turned away by the capture it was
    /// picked for. The queue refuses it too (`Outbox.cancel`); this is the sentence, not the guard.
    public static func disabledReason(_ action: PendingAction, for job: UploadJob) -> String? {
        switch action {
        case .cancel where job.stillArriving: return Self.cancelWhileArriving
        default: return nil
        }
    }

    static func disabledReasons(for job: UploadJob) -> [PendingAction: String] {
        var reasons: [PendingAction: String] = [:]
        for action in action(for: job) {
            if let reason = disabledReason(action, for: job) { reasons[action] = reason }
        }
        return reasons
    }

    /// The line a capture carries when picked items never reached it: they are still in Photos,
    /// and the memo goes without them — said, never left to be discovered.
    public static func missingNote(for job: UploadJob) -> String? {
        missingNote(count: job.missingItems)
    }

    /// The same line for a count carried past the capture — the memo its card became draws it
    /// (`TimelineStore.missingItems(forUID:)`, MEMNG-1049), so the sentence does not leave with
    /// the card that said it first.
    public static func missingNote(count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 photo could not be added — it is still in Photos"
        case let count: "\(count) photos could not be added — they are still in Photos"
        }
    }

    public static func status(
        for job: UploadJob,
        now: Date = Date(),
        lastProgressAt: [UUID: Date] = [:],
        verdict: UploadVerdict = .permitted
    ) -> String {
        // Said before the state, because a stopped capture's state says nothing a person needs —
        // the marker parks it back in `waiting` — and what they do need to read is that it is
        // theirs again.
        if job.cancelledAt != nil { return Self.cancelledAndKept }
        // The two states `action(for:)` fences, for its reason: the row can do nothing while that
        // request stands. Held and creating keep their own — theirs is the more specific reason.
        if job.editUnansweredSince != nil, job.state == .uploading || job.state == .waiting {
            return Self.editUnanswered
        }
        switch job.state {
        case .held:
            switch job.holdReason {
            case .accountMismatch:
                return "Captured under another account"
            case .unreadableManifest:
                return "This capture could not be read — its files are kept"
            case .storageFailed:
                return job.lastError ?? "This capture could not be saved on this device"
            case .editIncomplete:
                return job.lastError ?? "A picture this memo keeps is missing from this device"
            case .memoGone:
                // The reason is the whole of what the person needs to read, so the server's own
                // words for the refusal do not replace it.
                return "This memo is no longer on the server"
            case .tooLarge:
                return "Too large for the server — remove it, or try again if the limit rises"
            case .signInRequired:
                return "Sign in again to send this memo"
            case .serverRefused, .uploadSessionLost, .none:
                return job.lastError ?? "Needs attention"
            }
        case .creating:
            return "Finishing up"
        case .uploading:
            // The network the phone is on explains the silence completely, so the row says that
            // and not that something unknown has gone quiet.
            if case .refused(let reason) = verdict { return Self.refusal(reason) }
            if let last = lastProgressAt[job.id], now.timeIntervalSince(last) >= Self.stallInterval
            {
                return Self.noProgressConfirmed
            }
            return "Uploading \(percent(job))%"
        case .waiting:
            // The reason comes before the attempt count on purpose. A capture refused by the
            // network it is on is not spacing out a retry — nothing was tried — and a retry
            // sentence on a phone that will never try until it is back on wifi is the kind of
            // sentence that makes a person force-quit the app.
            if case .refused(let reason) = verdict { return Self.refusal(reason) }
            // Then the reason the queue persisted. The network reasons are the path's, and the
            // live verdict above outranks a marker the next drain has not yet cleared; the video
            // rule is this capture's own, and a backoff says it is retrying — a file spacing
            // itself out never reads as waiting for a network it was not refused by (MEMNG-657).
            if job.waitReason == .videoOverMobileLimit, job.owesVideoOverMobileLimit {
                return Self.waitingForWiFiVideo
            }
            if job.waitReason == .videoOnWiFiOnly, job.owesVideo {
                return Self.waitingForWiFiVideosOnWiFiOnly
            }
            if job.waitReason == .retrying || job.attemptCount > 0
                || job.files.contains(where: { ($0.attemptCount ?? 0) > 0 })
            {
                return Self.retrying
            }
            return "Waiting for home wifi"
        }
    }

    /// What a capture still owing a video over the mobile-data limit says while on mobile data.
    static let waitingForWiFiVideo = "Waiting for Wi-Fi (video over 200 MB)"

    /// The same wait under "Send videos over mobile data: Never" — it names the setting, because
    /// no size would send it.
    static let waitingForWiFiVideosOnWiFiOnly = "Waiting for Wi-Fi (videos are set to Wi-Fi only)"

    /// What a capture spacing out a transient failure says: the queue sends it again by itself,
    /// in seconds, and nothing is asked of the person.
    static let retrying = "Retrying shortly — it will be sent again by itself"

    /// How long a capture's confirmed bytes may stand still before the row stops showing a
    /// percentage nothing is adding to.
    ///
    /// A product number, chosen and not derived: one chunk is megabytes and may legitimately take
    /// longer than a single request is given, and a row that goes on counting at a person who can
    /// see it is stuck is the thing this replaces.
    public static let stallInterval: TimeInterval = 90

    /// The next instant at which a row's sentence changes because time passed and nothing else
    /// happened. `nil` when no row is counting: a screen that armed a wake for a capture that is
    /// not uploading would be a timer with extra steps. The verdict is not consulted — a refused
    /// row's sentence does not depend on time, and a verdict change redraws the section anyway.
    public static func stallDeadline(
        for jobs: [UploadJob],
        lastProgressAt: [UUID: Date],
        after instant: Date
    ) -> Date? {
        jobs
            .filter { $0.state == .uploading && $0.cancelledAt == nil }
            .compactMap { lastProgressAt[$0.id]?.addingTimeInterval(stallInterval) }
            .filter { $0 > instant }
            .min()
    }

    /// What a capture whose bytes stopped moving says. It states what is known — nothing has been
    /// confirmed for a while — and nothing else: whether anything failed is not something this row
    /// is told, and a sentence that guessed would be inventing an outcome.
    static let noProgressConfirmed = "No progress confirmed for \(Int(stallInterval)) s"

    /// What a capture a person stopped says for as long as they leave it alone. The words and the
    /// files are kept HERE — the create may already have committed a memo at the server, which the
    /// queue owes the edit to — and that is what they need before choosing between sending it
    /// again and binning it.
    static let cancelledAndKept = "Cancelled — kept on this device"
    static let cancelWhileArriving = "Files are still being added. Cancel it once they are in."

    /// True on the wire and in the backoff between replays alike: what stands is the answer, not
    /// the request, and the queue sends the change again under the same key until it comes.
    static let editUnanswered =
        "Your change hasn't been answered yet — it will be sent again until it is"

    /// What a capture held for the wrong network says, which is also where the person is told
    /// what would send it now. A row that only said "waiting" would be true and useless.
    static let waitingForHomeNetwork =
        "Waiting for your home network — turn on Upload over mobile data in Settings"
        + " to send it now"

    /// No network at all: nothing is tried until one comes back, and nothing needs pressing.
    static let waitingForAnyNetwork = "No network — it will send when the phone is back online"

    /// Low Data Mode is not the mobile-data switch's business, so its sentence does not send a
    /// person to a setting that would not help.
    static let waitingForLowDataMode =
        "Low Data Mode is on for this network — turn it off in Settings to send it now"

    /// The one network sentence per reason. Each names what would send the capture NOW, because a
    /// row that only said "waiting" would be true and useless. A hotspot and the phone's own radio
    /// are the same hold behind the same switch, so they read the same.
    static func refusal(_ reason: UploadVerdict.Reason) -> String {
        switch reason {
        case .noPath:
            return waitingForAnyNetwork
        case .cellularWhileMobileDataOff, .expensiveWhileMobileDataOff:
            return waitingForHomeNetwork
        case .lowDataMode:
            return waitingForLowDataMode
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
