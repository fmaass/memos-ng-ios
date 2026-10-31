import Foundation

/// One activity the host started, by the identifier the system gave it.
public struct TransferActivityHandle: Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// An activity the system still shows from an earlier run of the app: the process that started it
/// may be gone — a background relaunch for an upload's events is a new process — but the activity
/// is not, and it is the one to go on updating.
public struct SurvivingTransferActivity: Sendable, Equatable {
    public let handle: TransferActivityHandle
    /// When it was started, from its attributes, so the ceiling still counts from then.
    public let startedAt: Date
    /// What it shows now.
    public let state: TransferActivityState

    public init(handle: TransferActivityHandle, startedAt: Date, state: TransferActivityState) {
        self.handle = handle
        self.startedAt = startedAt
        self.state = state
    }
}

/// The seam ActivityKit sits behind. The driver decides; the host carries the decision out, in the
/// order it was made. Nothing here awaits: a host whose calls are asynchronous orders them itself.
@MainActor
public protocol TransferActivityHosting: AnyObject {
    /// Starts an activity showing `state`. Nil when the system will not start one now — Live
    /// Activities unsupported or switched off, or the app not in front — which is not an error:
    /// the driver asks again on a later read.
    func start(_ state: TransferActivityState) -> TransferActivityHandle?
    func update(_ activity: TransferActivityHandle, to state: TransferActivityState)
    func end(_ activity: TransferActivityHandle, on state: TransferActivityState)
    /// The activities the system is still showing, active or stale — not ended, not dismissed.
    func surviving() -> [SurvivingTransferActivity]
}

/// Decides when the transfers Live Activity starts, what it shows and when it ends, from the reads
/// the ledger applied and the clock — and from nothing else, so it can be driven without
/// ActivityKit.
///
/// - It starts when the ledger has its first capture.
/// - Every applied read updates it. What it shows is summed over the captures it has counted,
///   each held at the highest numbers any read showed for it, so a capture leaving the queue or a
///   file starting over never takes the ring or the count back: within one activity they only rise.
/// - It ends on `finished` when the queue empties.
/// - The system ends a Live Activity eight hours after it started. An activity that would outlive
///   that ceiling — a read inside `renewalMargin` of it, or after it — ends on `paused`, naming the
///   pause it was showing, and the next one starts on the first byte the server confirms after.
///
/// Main-actor and synchronous: one read is judged whole before the next, so two reads cannot
/// interleave a start with an end. The ledger hands it only the reads it accepted, in order, so a
/// late read that the ledger refused never reaches it.
@MainActor
public final class TransferActivityDriver {
    /// How long the system lets a Live Activity run.
    public static let ceiling: TimeInterval = 8 * 60 * 60
    /// How close to the ceiling a read ends the activity rather than updating it: nothing says a
    /// later read will come before the system ends it.
    public static let renewalMargin: TimeInterval = 15 * 60

    private let host: any TransferActivityHosting
    private let clock: @Sendable () -> Date
    private var phase: Phase = .idle(awaitingBytes: false)
    /// Each capture's confirmed bytes at the last read, so a rise — a byte the server confirmed —
    /// can be told from a capture that was already this far.
    private var bytesSeen: [UUID: Int64] = [:]

    private enum Phase {
        /// No activity. `awaitingBytes`: the last one ended at the ceiling, and the next starts
        /// only on a confirmed byte, not on a capture merely being queued.
        case idle(awaitingBytes: Bool)
        case running(Running)
    }

    private struct Running {
        var handle: TransferActivityHandle
        var startedAt: Date
        var marks: [UUID: Marks]
        var shown: TransferActivityState
        /// The captures that left the queue during this activity, at their last numbers. Kept
        /// in the content state too, so a relaunched process takes it over as it stands.
        var settled: TransferSummary = .empty
    }

    /// The highest numbers any read showed for one capture.
    struct Marks: Equatable {
        var filesDone: Int
        var filesTotal: Int
        var bytesConfirmed: Int64
        var bytesTotal: Int64

        init(_ job: TransferJob) {
            filesDone = job.files.count(where: { $0.state == .done })
            filesTotal = job.files.count
            bytesConfirmed = job.files.reduce(0) { $0 + $1.bytesConfirmed }
            bytesTotal = job.files.reduce(0) { $0 + $1.byteSize }
        }

        func raised(to other: Marks) -> Marks {
            var raised = self
            raised.filesDone = Swift.max(filesDone, other.filesDone)
            raised.filesTotal = Swift.max(filesTotal, other.filesTotal)
            raised.bytesConfirmed = Swift.max(bytesConfirmed, other.bytesConfirmed)
            raised.bytesTotal = Swift.max(bytesTotal, other.bytesTotal)
            return raised
        }
    }

    public init(
        host: any TransferActivityHosting, clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.host = host
        self.clock = clock
        adoptSurvivors()
    }

    /// Takes over the activity an earlier run left showing, before any read is judged, so a
    /// relaunch updates the ring that is on the lock screen instead of asking for a second one.
    /// Of several, the newest is kept and the others end on what they show.
    private func adoptSurvivors() {
        let survivors = host.surviving().sorted { $0.startedAt > $1.startedAt }
        guard let newest = survivors.first else { return }
        for older in survivors.dropFirst() { host.end(older.handle, on: older.state) }
        phase = .running(
            Running(
                handle: newest.handle, startedAt: newest.startedAt, marks: [:],
                shown: newest.state, settled: newest.state.settled))
    }

    /// What the running activity shows; nil while none runs.
    public var shown: TransferActivityState? {
        if case .running(let running) = phase { return running.shown }
        return nil
    }

    /// Takes in one read the ledger applied: its captures, oldest first.
    public func observe(_ jobs: [TransferJob]) {
        let now = clock()
        let moved = jobs.contains { job in
            guard let before = bytesSeen[job.id] else { return false }
            return Self.bytes(of: job) > before
        }
        bytesSeen = Dictionary(jobs.map { ($0.id, Self.bytes(of: $0)) }) { first, _ in first }
        let status = Self.status(of: jobs)
        switch phase {
        case .idle(let awaitingBytes):
            guard !jobs.isEmpty else {
                phase = .idle(awaitingBytes: false)
                return
            }
            guard !awaitingBytes || moved else { return }
            begin(jobs, status: status, at: now)
        case .running(var running):
            // A capture that left the queue settles at the last numbers this activity saw for it.
            let present = Set(jobs.map(\.id))
            for (id, mark) in running.marks where !present.contains(id) {
                running.settled = Self.adding(Self.summary(of: [id: mark]), to: running.settled)
                running.marks[id] = nil
            }
            for job in jobs {
                let mark = Marks(job)
                running.marks[job.id] = running.marks[job.id]?.raised(to: mark) ?? mark
            }
            let summary = Self.adding(running.settled, to: Self.summary(of: running.marks))
            let settled = running.settled
            if jobs.isEmpty {
                let state = TransferActivityState(
                    summary: summary, status: .finished, settled: settled)
                host.end(running.handle, on: state)
                phase = .idle(awaitingBytes: false)
                return
            }
            if now.timeIntervalSince(running.startedAt) >= Self.ceiling - Self.renewalMargin {
                let pause = Self.pause(of: status) ?? Self.pause(of: running.shown.status)
                let state = TransferActivityState(
                    summary: summary, status: .paused(pause), settled: settled)
                host.end(running.handle, on: state)
                phase = .idle(awaitingBytes: true)
                if moved { begin(jobs, status: status, at: now) }
                return
            }
            let state = TransferActivityState(summary: summary, status: status, settled: settled)
            if state != running.shown {
                running.shown = state
                host.update(running.handle, to: state)
            }
            phase = .running(running)
        }
    }

    /// Starts an activity over `jobs`, counting from where they stand now. A start the system
    /// refuses leaves no activity and no condition: the next read asks again.
    private func begin(_ jobs: [TransferJob], status: TransferActivityStatus, at now: Date) {
        var marks: [UUID: Marks] = [:]
        for job in jobs { marks[job.id] = Marks(job) }
        let state = TransferActivityState(summary: Self.summary(of: marks), status: status)
        guard let handle = host.start(state) else {
            phase = .idle(awaitingBytes: false)
            return
        }
        phase = .running(
            Running(handle: handle, startedAt: now, marks: marks, shown: state))
    }

    nonisolated static func bytes(of job: TransferJob) -> Int64 {
        job.files.reduce(0) { $0 + $1.bytesConfirmed }
    }

    nonisolated static func summary(of marks: [UUID: Marks]) -> TransferSummary {
        let all = Array(marks.values)
        return TransferSummary(
            jobs: all.count,
            filesDone: all.reduce(0) { $0 + $1.filesDone },
            filesTotal: all.reduce(0) { $0 + $1.filesTotal },
            bytesConfirmed: all.reduce(0) { $0 + $1.bytesConfirmed },
            bytesTotal: all.reduce(0) { $0 + $1.bytesTotal }
        )
    }

    /// The two summed, number by number.
    nonisolated static func adding(_ part: TransferSummary, to read: TransferSummary)
        -> TransferSummary
    {
        TransferSummary(
            jobs: read.jobs + part.jobs,
            filesDone: read.filesDone + part.filesDone,
            filesTotal: read.filesTotal + part.filesTotal,
            bytesConfirmed: read.bytesConfirmed + part.bytesConfirmed,
            bytesTotal: read.bytesTotal + part.bytesTotal)
    }

    nonisolated static func pause(of status: TransferActivityStatus) -> TransferActivityPause? {
        if case .paused(let pause) = status { return pause }
        return nil
    }
}
