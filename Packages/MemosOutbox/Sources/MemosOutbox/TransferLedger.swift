import Foundation
import Observation

/// Where one file of a queued capture stands, as the transfers sheet shows it.
public enum TransferFileState: String, Sendable, Equatable {
    /// Its bytes are being sent, or are with the background session.
    case uploading
    /// Nothing of it is in flight: the queue is waiting on the network or on the clock.
    case waiting
    /// Stopped until a person does something (`JobState.held`).
    case held
    /// The server holds every byte of it.
    case done
}

/// Why a file is not moving, as a value. The words are the app's: this package names the reason,
/// and the one table that turns a reason into a sentence lives with the rest of the app's wording.
public enum TransferReason: Sendable, Equatable {
    /// The capture is held, for the reason the queue persisted (nil on a manifest from before
    /// reasons were kept).
    case held(HoldReason?)
    /// The capture is waiting, for the reason the queue persisted (nil when it has not been tried).
    case waiting(WaitReason?)
    /// The capture is moving, but this file is spacing out a failed send of its own until then.
    case retrying(until: Date)

    /// The class of the wait: what ends it — a person, the path, or the clock.
    public var retryClass: RetryClass? {
        switch self {
        case .held: .hold
        case .waiting(let reason): reason?.retryClass
        case .retrying: .transient
        }
    }
}

/// One file's row in the ledger: how much of it the SERVER has confirmed, and why it is not moving.
public struct TransferFile: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let filename: String
    public let byteSize: Int64
    /// Only ever the server's number (`OutboxFile.bytesConfirmed`), clamped to the file's size.
    public let bytesConfirmed: Int64
    public let state: TransferFileState
    /// Nil while the file moves or once it is done.
    public let reason: TransferReason?
    /// When the queue will try this file again on its own, when that is a date on the clock.
    public let nextAttemptAt: Date?

    public init(
        id: UUID, filename: String, byteSize: Int64, bytesConfirmed: Int64,
        state: TransferFileState, reason: TransferReason?, nextAttemptAt: Date?
    ) {
        self.id = id
        self.filename = filename
        self.byteSize = byteSize
        self.bytesConfirmed = bytesConfirmed
        self.state = state
        self.reason = reason
        self.nextAttemptAt = nextAttemptAt
    }

    /// How much of the file is confirmed, 0...1. An empty file is whole once it is done.
    public var fraction: Double {
        guard byteSize > 0 else { return state == .done ? 1 : 0 }
        return Double(bytesConfirmed) / Double(byteSize)
    }
}

/// One capture in the ledger: the manifest it was projected from, as last read, and its files.
public struct TransferJob: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The manifest this row was projected from. Kept so the app words a reason from the same
    /// facts the pending rows are worded from, never from a second copy of them.
    public let manifest: UploadJob
    public let files: [TransferFile]

    public init(id: UUID, manifest: UploadJob, files: [TransferFile]) {
        self.id = id
        self.manifest = manifest
        self.files = files
    }
}

/// The whole queue in four numbers — the strip's line.
public struct TransferSummary: Sendable, Equatable {
    public var jobs: Int
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesConfirmed: Int64
    public var bytesTotal: Int64

    public init(
        jobs: Int, filesDone: Int, filesTotal: Int, bytesConfirmed: Int64, bytesTotal: Int64
    ) {
        self.jobs = jobs
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.bytesConfirmed = bytesConfirmed
        self.bytesTotal = bytesTotal
    }

    public var bytesLeft: Int64 { Swift.max(bytesTotal - bytesConfirmed, 0) }
}

/// How long the rest will take, or why no time is given.
public enum TransferETA: Sendable, Equatable {
    /// Fewer than `TransferLedger.confirmationsForETA` confirmations in the window: no time is
    /// shown, because one confirmation is a size, not a rate.
    case unknown
    /// Nothing is moving, or the estimate is above `TransferLedger.longestETA`: a number that far
    /// out is a guess about a network that will have changed, so the strip says "paused".
    case paused
    /// Seconds left at the rate the last confirmations measured.
    case remaining(TimeInterval)
}

/// The queue as the transfers strip and sheet show it: a main-actor projection of the job
/// manifests, derived only from facts the planner already keeps — `bytesConfirmed` after each
/// confirmed `Upload-Offset` tail, the retry dates, the persisted hold and wait reasons. It sets no
/// timer and reads no clock between two manifests: what it says changes when the queue does.
///
/// Every snapshot carries the generation of the read that ISSUED it, and one older than the
/// newest applied is refused whole. A read that began before the planner moved a file on, and
/// whose answer arrives after the newer one, is a late callback; applying it would put back a
/// state the planner has left — a landed capture uploading again, a confirmed file at half.
@MainActor
@Observable
public final class TransferLedger {
    /// How long the strip stays after the last capture leaves the queue.
    public static let lingerInterval: TimeInterval = 30
    /// The trailing window rates are measured over.
    public static let rateWindow: TimeInterval = 120
    /// The fewest confirmations a rate is measured from.
    public static let confirmationsForETA = 2
    /// The longest time that is ever said; anything above reads as paused.
    public static let longestETA: TimeInterval = 12 * 60 * 60

    /// The captures in the queue, oldest first, as the newest applied read found them.
    public private(set) var jobs: [TransferJob] = []
    /// When the last capture left the queue, while the queue is empty since.
    public private(set) var emptiedAt: Date?
    /// The generation of the newest read applied.
    public private(set) var generation = 0

    /// What each file's confirmed bytes were at the last applied read, so only a rise is counted.
    private var confirmedSeen: [UUID: Int64] = [:]
    /// Each applied read that saw the server confirm more bytes: when, and how many more.
    private var confirmations: [Confirmation] = []
    private let clock: @Sendable () -> Date

    struct Confirmation: Equatable {
        var at: Date
        var bytes: Int64
    }

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    /// Takes in the queue as the read numbered `generation` found it. Returns false, changing
    /// nothing, when a read at or after that generation has already been applied.
    @discardableResult
    public func apply(_ manifests: [UploadJob], generation: Int) -> Bool {
        guard generation > self.generation else { return false }
        self.generation = generation
        let now = clock()
        let projected = manifests.compactMap { Self.project($0, now: now) }
        var seen: [UUID: Int64] = [:]
        var gained: Int64 = 0
        for file in projected.flatMap(\.files) {
            seen[file.id] = file.bytesConfirmed
            if let before = confirmedSeen[file.id], file.bytesConfirmed > before {
                gained += file.bytesConfirmed - before
            }
        }
        confirmedSeen = seen
        if gained > 0 { confirmations.append(Confirmation(at: now, bytes: gained)) }
        confirmations.removeAll { now.timeIntervalSince($0.at) > Self.rateWindow }
        if projected.isEmpty {
            if !jobs.isEmpty { emptiedAt = now }
        } else {
            emptiedAt = nil
        }
        if jobs != projected { jobs = projected }
        return true
    }

    public var summary: TransferSummary {
        let files = jobs.flatMap(\.files)
        return TransferSummary(
            jobs: jobs.count,
            filesDone: files.count(where: { $0.state == .done }),
            filesTotal: files.count,
            bytesConfirmed: files.reduce(0) { $0 + $1.bytesConfirmed },
            bytesTotal: files.reduce(0) { $0 + $1.byteSize }
        )
    }

    /// Whether the strip shows at `now`: while a capture is queued, and for
    /// `lingerInterval` after the last one left.
    public func isStripVisible(at now: Date) -> Bool {
        if !jobs.isEmpty { return true }
        guard let hidesAt = stripHidesAt else { return false }
        return now < hidesAt
    }

    /// The instant a lingering strip goes, so the view can redraw once then; nil otherwise.
    public var stripHidesAt: Date? {
        guard jobs.isEmpty, let emptiedAt else { return nil }
        return emptiedAt.addingTimeInterval(Self.lingerInterval)
    }

    /// The time the rest of the queue will take at the rate the confirmations in the trailing
    /// window measured, or why none is given.
    public func estimate(at now: Date) -> TransferETA {
        guard summary.bytesLeft > 0 else { return .remaining(0) }
        guard jobs.contains(where: { $0.manifest.state == .uploading }) else { return .paused }
        // Only what is moving, or waiting on the clock to move again, is divided by the rate: a
        // held file (too large, a refused grant) never moves, and counting it would stretch every
        // estimate by bytes the network is not carrying.
        let left = jobs.flatMap(\.files).reduce(Int64(0)) { sum, file in
            let moving: Bool
            switch (file.state, file.reason) {
            case (.uploading, _), (.waiting, .some(.retrying)): moving = true
            default: moving = false
            }
            return moving ? sum + Swift.max(file.byteSize - file.bytesConfirmed, 0) : sum
        }
        guard left > 0 else { return .paused }
        let window = confirmations.filter {
            $0.at <= now && now.timeIntervalSince($0.at) <= Self.rateWindow
        }
        guard window.count >= Self.confirmationsForETA, let first = window.first,
            let last = window.last
        else { return .unknown }
        let span = last.at.timeIntervalSince(first.at)
        guard span > 0 else { return .unknown }
        // The first confirmation's bytes were sent before the window opened; only what came after
        // it was sent across the span.
        let moved = window.dropFirst().reduce(Int64(0)) { $0 + $1.bytes }
        let rate = Double(moved) / span
        guard rate > 0 else { return .paused }
        let seconds = Double(left) / rate
        return seconds > Self.longestETA ? .paused : .remaining(seconds)
    }

    public func job(_ id: UUID) -> TransferJob? { jobs.first { $0.id == id } }

    /// One manifest as the ledger shows it; nil for a capture taken back to the editor, which is
    /// a draft and not a transfer.
    public nonisolated static func project(_ job: UploadJob, now: Date) -> TransferJob? {
        guard job.cancelledAt == nil else { return nil }
        let files = job.files.map { file -> TransferFile in
            let confirmed = Swift.min(Swift.max(file.bytesConfirmed, 0), file.byteSize)
            let (state, reason) = Self.state(of: file, in: job, now: now)
            return TransferFile(
                id: file.id,
                filename: file.filename,
                byteSize: file.byteSize,
                bytesConfirmed: confirmed,
                state: state,
                reason: reason,
                nextAttemptAt: Self.nextAttempt(of: file, in: job, state: state, now: now)
            )
        }
        return TransferJob(id: job.id, manifest: job, files: files)
    }

    nonisolated static func state(
        of file: OutboxFile, in job: UploadJob, now: Date
    ) -> (TransferFileState, TransferReason?) {
        // The capture's own stop wins over a file's completion: every byte can be on the server
        // while the memo's create is held or waiting, and a row that read done would hide the
        // reason and the one fix that capture needs. The bytes still read whole.
        switch job.state {
        case .held:
            return (.held, .held(job.holdReason))
        case .waiting:
            return (.waiting, .waiting(job.waitReason))
        case .uploading:
            if file.isComplete { return (.done, nil) }
            if let next = file.nextAttemptAt, next > now {
                return (.waiting, .retrying(until: next))
            }
            return (.uploading, nil)
        case .creating:
            return (.done, nil)
        }
    }

    /// The `RetrySchedule` date this file waits for: its own spacing, or its capture's while the
    /// capture waits. A date already past, or a hold, has none.
    nonisolated static func nextAttempt(
        of file: OutboxFile, in job: UploadJob, state: TransferFileState, now: Date
    ) -> Date? {
        guard state == .waiting else { return nil }
        let candidate = file.nextAttemptAt ?? job.nextAttemptAt
        return candidate > now ? candidate : nil
    }
}
