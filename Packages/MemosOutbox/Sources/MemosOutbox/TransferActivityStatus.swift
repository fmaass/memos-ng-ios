import Foundation

/// Why the Live Activity reads paused, as a value. The extension words it; this names the class of
/// wait the queue is in, so the island and the strip read the same facts.
public enum TransferActivityPause: String, Codable, Hashable, Sendable {
    /// The phone is on a network this capture may not use — mobile data off, Low Data Mode, or a
    /// video over the mobile limit. What ends it is Wi-Fi.
    case waitingForWiFi
    /// The phone has no network at all.
    case noConnection
    /// A failed send is spacing itself out (`RetrySchedule`).
    case retrying
    /// Stopped until a person does something (`JobState.held`).
    case held
}

/// What the activity says the queue is doing.
public enum TransferActivityStatus: Codable, Hashable, Sendable {
    /// Bytes are moving, or are with the background session.
    case sending
    /// Nothing is moving, for the reason given (nil when the queue names none).
    case paused(TransferActivityPause?)
    /// The queue emptied while the activity ran: the captures it counted have left it.
    case finished
}

/// The activity's content state: the ledger's summary struct — the same four numbers the strip
/// shows — and what the queue is doing. Within one activity the summary only ever rises
/// (`TransferActivityDriver`).
public struct TransferActivityState: Codable, Hashable, Sendable {
    public var summary: TransferSummary
    public var status: TransferActivityStatus
    /// The part of `summary` that captures which already left the queue contributed, at their
    /// last numbers. A process that adopts the activity after a relaunch no longer has those
    /// captures in its ledger; it takes this part over as it stands and counts only the
    /// captures still queued on top of it.
    public var settled: TransferSummary

    public init(
        summary: TransferSummary, status: TransferActivityStatus,
        settled: TransferSummary = .empty
    ) {
        self.summary = summary
        self.status = status
        self.settled = settled
    }
}

extension TransferSummary {
    /// Nothing at all: no capture, no file, no byte.
    public static let empty = TransferSummary(
        jobs: 0, filesDone: 0, filesTotal: 0, bytesConfirmed: 0, bytesTotal: 0)
}

extension TransferActivityDriver {
    /// What the queue is doing, read off the manifests the planner wrote: sending while a file is
    /// with the session, a capture's memo is being created, or nothing is left to send but that
    /// create; otherwise paused, for the reason of the oldest capture that names one. A confirmed
    /// byte is not read here: a read can show the bytes a send confirmed AND the wait the planner
    /// put the capture in after it, and the wait is what is true now.
    nonisolated static func status(of jobs: [TransferJob]) -> TransferActivityStatus {
        var pauses: [TransferActivityPause?] = []
        for job in jobs {
            switch job.manifest.state {
            case .creating:
                return .sending
            case .uploading:
                let spacing = job.files.contains {
                    if case .retrying = $0.reason { return true }
                    return false
                }
                let sending = job.files.contains { $0.state == .uploading }
                if sending || !spacing { return .sending }
                pauses.append(.retrying)
            case .waiting:
                pauses.append(Self.pause(for: job.manifest.waitReason))
            case .held:
                pauses.append(.held)
            }
        }
        return .paused(pauses.first ?? nil)
    }

    nonisolated static func pause(for reason: WaitReason?) -> TransferActivityPause? {
        switch reason {
        case .homeNetwork, .videoOverMobileLimit: .waitingForWiFi
        case .noNetwork: .noConnection
        case .retrying: .retrying
        case nil: nil
        }
    }
}
