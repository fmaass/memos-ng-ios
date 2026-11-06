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
    /// Send these files, each whole, in ONE pass, in capture order. None of them has an upload
    /// session yet. At most the in-flight budget less the files already carried, and
    /// possibly none: every file that still needs sending is carried, and its task's answer is what
    /// comes next.
    case upload(starting: [UUID])
    /// This file has an upload session holding less than the whole file, and no task is carrying
    /// it: the server is asked how much it holds, and only the rest is sent
    /// (`UploadJob.retryingFromOffset`). One file at a time, in capture order, because each resume
    /// begins with a request of its own.
    case resume(UUID)
    /// Every file is on the server: create the memo that links them.
    case createMemo
    /// Every file is on the server and the memo already exists: this is an edit job (MEMNG-954),
    /// whose terminal request is the PATCH the engine's edit branch sends. Never a create — a
    /// create here would post the edit's files as a second memo.
    case patchMemo
}

/// How many whole-file uploads may be in flight at once, across every capture.
///
/// A phone that hands the system every file of every capture at once has, in effect, asked the
/// server for all of them at once: a rate limit answers most of them, and each of those answers is
/// a retry. Two keeps one large file from starving the rest without making a burst of it — the
/// budget an `AdaptiveUploadBudget` starts at and returns to, between its floor and its ceiling.
public enum UploadBudget {
    public static let inFlightUploads = 2

    /// The most the adaptive budget ever allows (MEMNG-958): on Wi-Fi, after a quiet minute, and
    /// never above the server's published admission. The background session is sized for it.
    public static let maxInFlightUploads = 3

    /// What the adaptive budget falls to while the server keeps answering 429.
    public static let rateLimitedInFlightUploads = 1

    /// How many sessions one `POST /api/uploads/batch` may open: the server answers more with a
    /// 422 for the whole request.
    public static let maxSessionsPerBatch = 50

    /// The longest `Retry-After`, in seconds, taken as a usable hint: seven days. A longer one
    /// cannot be a real backpressure answer from this server, and a deadline that far out risks
    /// the manifest's ISO 8601 round trip — an unreadable capture. It is ignored like an
    /// HTTP-date, and the computed schedule applies.
    public static let longestRetryAfter: TimeInterval = 604_800

    /// The shortest server-named delay taken as named, in seconds; a shorter one waits this long
    /// (MEMNG-1035). A `Retry-After: 0` deadline is `now`, and the timer arms only deadlines still
    /// ahead — a past one is a pass's, and nothing asks for that pass — so the row would wait for
    /// an outside wake. One second is not enough: a capture's deadline goes down in whole seconds,
    /// truncated, so `now + 1` can land on disk a hair after `now`. Two always lands a second ahead.
    public static let shortestRetryAfter: TimeInterval = 2

    /// How many fresh upload sessions one file is given in a row after the server says its session
    /// is gone. The next loss holds the capture: a server that loses every session it opens is not
    /// helped by being asked for another.
    public static let maxFreshSessionsPerFile = 3
}

/// The in-flight budget, adapted to what the server says (MEMNG-958).
///
/// - 1 when the last three attempts it counts were each answered 429: the server is turning bodies
///   away, and every extra one is only another refusal.
/// - 3 on Wi-Fi once a whole minute has passed with no 429 it counts.
/// - 2 otherwise — the fixed budget this replaced.
/// - Never above the admission the server publishes (`bodies_per_user`), when it published one.
///
/// The quiet minute runs from the later of the last counted 429 and the first moment this value
/// was asked anything. A fresh launch has seen no minute at all: the 429s of the previous one are
/// forgotten, not disproved, so it starts at 2 rather than 3.
///
/// Every raise opens a new GENERATION. An attempt is stamped with the generation it was sent
/// under, and a 429 earned under an older one is ignored: it answers a burst the budget has
/// already stepped back from and come up again since, and counting it would lower the budget a
/// second time for the same burst. A pure value, owned by the engine's isolation.
public struct AdaptiveUploadBudget: Sendable, Equatable {
    /// How many trailing 429s drop the budget to its floor.
    public static let rateLimitedRun = 3
    /// How long without a counted 429 the Wi-Fi budget waits before it rises.
    public static let quietInterval: TimeInterval = 60

    /// The generation an attempt sent now is stamped with.
    public private(set) var generation = 0
    /// The last `rateLimitedRun` counted answers, oldest first; true where the answer was a 429.
    private var recent: [Bool] = []
    private var lastRateLimited: Date?
    private var firstAsked: Date?
    /// What the last `ceiling` call answered, so a raise can be told from a level budget.
    private var lastCeiling: Int?

    public init() {}

    /// Counts one attempt's answer.
    ///
    /// - Parameters:
    ///   - rateLimited: whether the server answered 429.
    ///   - generation: the generation the attempt was sent under. A 429 of an older one changes
    ///     nothing; any other answer is counted whatever generation it carries, since none of
    ///     them lowers the budget.
    public mutating func record(rateLimited: Bool, issuedUnder generation: Int, at instant: Date) {
        if firstAsked == nil { firstAsked = instant }
        if rateLimited {
            guard generation >= self.generation else { return }
            lastRateLimited = instant
        }
        recent.append(rateLimited)
        if recent.count > Self.rateLimitedRun {
            recent.removeFirst(recent.count - Self.rateLimitedRun)
        }
    }

    /// How many uploads may be in flight now. Moves the generation on when this answer is higher
    /// than the last one.
    ///
    /// - Parameters:
    ///   - onWiFi: whether the phone's path is one that costs nothing.
    ///   - admission: the server's published `bodies_per_user`, or nil while it is not known.
    public mutating func ceiling(onWiFi: Bool, admission: Int?, at instant: Date) -> Int {
        if firstAsked == nil { firstAsked = instant }
        var value: Int
        if recent.count == Self.rateLimitedRun, recent.allSatisfy({ $0 }) {
            value = UploadBudget.rateLimitedInFlightUploads
        } else if onWiFi, let since = [firstAsked, lastRateLimited].compactMap({ $0 }).max(),
            instant.timeIntervalSince(since) >= Self.quietInterval
        {
            value = UploadBudget.maxInFlightUploads
        } else {
            value = UploadBudget.inFlightUploads
        }
        if let admission, admission > 0 { value = Swift.min(value, admission) }
        value = Swift.max(value, 1)
        if let lastCeiling, value > lastCeiling { generation += 1 }
        lastCeiling = value
        return value
    }
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
    ///   - budget: how many uploads may be in flight now — the engine's adaptive budget.
    public static func nextWholeAction(
        for job: UploadJob,
        credentials: OutboxCredentials,
        now: Date,
        schedulingOpen: Bool,
        carried: Set<UUID> = [],
        budget: Int = UploadBudget.inFlightUploads
    ) -> WholeAction {
        let action = nextWholeActionWhenOpen(
            for: job, credentials: credentials, now: now, carried: carried, budget: budget
        )
        if schedulingOpen { return action }
        switch action {
        case .createMemo, .patchMemo, .wait:
            return action
        case .hold, .upload, .resume:
            return .wait(until: .distantFuture)
        }
    }

    private static func nextWholeActionWhenOpen(
        for job: UploadJob,
        credentials: OutboxCredentials,
        now: Date,
        carried: Set<UUID>,
        budget: Int
    ) -> WholeAction {
        // The binding before anything else, as on the chunk lane: a capture made under another
        // account never reaches a request, a memo create included.
        guard job.binding.matches(credentials) else { return .hold(.accountMismatch) }
        if job.cancelledAt != nil { return .wait(until: job.nextAttemptAt) }
        if job.state == .held { return .hold(job.holdReason ?? .serverRefused) }
        // As on the chunk lane: refused while only staged, before any session is asked for.
        if oversizedFile(in: job, limit: credentials.uploadLimit) != nil { return .hold(.tooLarge) }
        if now < job.nextAttemptAt { return .wait(until: job.nextAttemptAt) }

        let unfinished = job.files.filter { !$0.isComplete }
        if unfinished.isEmpty {
            // Files are still arriving from the editor: the ones here upload meanwhile, and the
            // create waits for the last of them (`UploadJob.stagingLaunch`).
            if job.stillArriving { return .wait(until: .distantFuture) }
            // An edit of a memo already posted links its files with a PATCH, under its own key.
            return job.memoEdit != nil ? .patchMemo : .createMemo
        }
        // A file the server turned away inside a batch waits for a person, and only it: once
        // nothing else is left to send, the capture holds for it (MEMNG-958).
        let needing = unfinished.filter { $0.heldReason == nil }
        if needing.isEmpty, let reason = unfinished.compactMap(\.heldReason).first {
            return .hold(reason)
        }
        // Eligibility before the budget is counted, so a file waiting out its own deadline never
        // takes a place a sibling could have used.
        let eligible = needing.filter { file in
            !carried.contains(file.id) && (file.nextAttemptAt.map { now >= $0 } ?? true)
        }
        let spent = needing.filter { carried.contains($0.id) }.count
        let chosen = eligible.prefix(Swift.max(budget - spent, 0))
        if eligible.isEmpty,
            let deadline = needing.compactMap(\.nextAttemptAt).filter({ $0 > now }).min()
        {
            return .wait(until: deadline)
        }
        // A file with a session goes first on its own: its resume starts with the offset HEAD, and
        // the pass plans again once that file is carried.
        if let resumable = chosen.first(where: { $0.uploadUID != nil }) {
            return .resume(resumable.id)
        }
        return .upload(starting: chosen.map(\.id))
    }
}

extension UploadJob {
    /// ONE file turned away by the server while its siblings were taken (MEMNG-958): it waits for
    /// a person, and the capture holds for it once nothing else is left to send. Only this file
    /// and the row's sentence move — the row's state stays what its siblings make it.
    func holdingFile(_ fileID: UUID, for reason: HoldReason, error: String) -> UploadJob {
        updating(fileID) { $0.heldReason = reason }.with { $0.lastError = error }
    }

    /// Sends ONE file again from its first byte, under a fresh upload session and a new attempt
    /// term. What a replacement's successor does; a retry resumes instead (`retryingFromOffset`).
    ///
    /// Only this file moves. `bumpingAttempts` moves every file still transferring, which fits the
    /// chunk lane's one task per job and is wrong here: a sibling's task is still carrying its
    /// original under the term it was sent with, and moving that term would make its answer stale —
    /// a finished video thrown away because a picture failed.
    public func retryingWhole(fileID: UUID) -> UploadJob {
        updating(fileID) { file in
            guard !file.isComplete else { return }
            file.uploadAttempt = (file.uploadAttempt ?? 0) + 1
            file.uploadUID = nil
            file.bytesConfirmed = 0
        }
    }

    /// Resumes ONE file from the offset the server just reported for its session, under a new
    /// attempt term: the session is kept, the count is the server's own, and the task that failed
    /// before is told apart from the one that carries the rest. Only this file moves.
    ///
    /// The file's failure count survives a resume that found no byte the row did not already
    /// hold: that is the same failure again, and a count cleared by it would space every
    /// following attempt as a first one, against a server that has not moved.
    public func retryingFromOffset(fileID: UUID, bytesConfirmed offset: Int64) -> UploadJob {
        let before = file(fileID)
        return advancing(fileID: fileID, bytesConfirmed: offset).updating(fileID) { file in
            file.uploadAttempt = (file.uploadAttempt ?? 0) + 1
            if let before, file.bytesConfirmed <= before.bytesConfirmed {
                file.attemptCount = before.attemptCount
            }
        }
    }
}
