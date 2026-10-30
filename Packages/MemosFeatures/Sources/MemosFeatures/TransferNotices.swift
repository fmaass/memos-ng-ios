import Foundation
import MemosOutbox

/// Where a tap on a transfer notification goes: the memo a capture became, or the capture's row
/// in the transfers sheet.
///
/// It travels in the notification's `userInfo` as plain strings, because that dictionary is what
/// the system hands back — possibly to a process launched by the tap itself, long after the one
/// that posted it has gone.
nonisolated public enum TransferNoticeRoute: Sendable, Hashable {
    case memo(uid: String)
    case transfers(jobID: UUID)

    static let routeKey = "memosng.notice.route"
    static let memoKey = "memosng.notice.memo"
    static let jobKey = "memosng.notice.job"

    public var userInfo: [String: String] {
        switch self {
        case .memo(let uid): [Self.routeKey: "memo", Self.memoKey: uid]
        case .transfers(let jobID): [Self.routeKey: "transfers", Self.jobKey: jobID.uuidString]
        }
    }

    /// The route a delivered notification names; nil for one this app did not write.
    public init?(userInfo: [AnyHashable: Any]) {
        switch userInfo[AnyHashable(Self.routeKey)] as? String {
        case "memo":
            guard let uid = userInfo[AnyHashable(Self.memoKey)] as? String, !uid.isEmpty
            else { return nil }
            self = .memo(uid: uid)
        case "transfers":
            guard let raw = userInfo[AnyHashable(Self.jobKey)] as? String,
                let jobID = UUID(uuidString: raw)
            else { return nil }
            self = .transfers(jobID: jobID)
        default:
            return nil
        }
    }
}

/// What a transfer notification announces.
nonisolated public enum TransferNoticeKind: String, Sendable {
    /// The capture left the queue on a create the server confirmed: the memo exists.
    case live
    /// The capture stopped until a person does something (`JobState.held`).
    case held
}

/// One notification about one capture — never about one of its files.
nonisolated public struct TransferNotice: Sendable, Equatable {
    public let jobID: UUID
    public let kind: TransferNoticeKind
    public let title: String
    /// The one action, for a hold that offers one; empty otherwise.
    public let subtitle: String
    /// For a hold, the transfers row's reason, as the sheet words it; empty for a live memo.
    public let body: String
    public let route: TransferNoticeRoute

    /// The claim this notice was posted under, and the system request's identifier: a second
    /// post of the same claim replaces the first rather than standing beside it.
    public var identifier: String { Self.claim(jobID, kind) }

    static func claim(_ jobID: UUID, _ kind: TransferNoticeKind) -> String {
        "\(jobID.uuidString).\(kind.rawValue)"
    }
}

/// Decides, from successive reads of the queue, which notifications to post: one when a capture
/// becomes a memo, one when a capture is held. Pure apart from the claims it keeps.
///
/// Every transition is claimed — the claim inserted and written to `defaults` — synchronously,
/// inside `observe`, before anything is posted and before any hop: two reads delivering the same
/// transition, or a relaunch reading it again, find the claim and post nothing. A transition seen
/// while the app is frontmost is claimed and not posted, so it is not announced late either.
@MainActor
public final class TransferNotifier {
    static let claimsKey = "transferNotices.announced"
    static let titleLimit = 60

    private let defaults: UserDefaults
    private var claimed: Set<String>
    /// The words of each capture last seen, so a capture that has left the queue is still named.
    private var titles: [UUID: String] = [:]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        claimed = Set(defaults.stringArray(forKey: Self.claimsKey) ?? [])
    }

    /// The notices this read of the queue owes, already claimed. `jobs` is the ledger's queue,
    /// `resolved` the memo each recently finished capture became (`Outbox.resolvedMemos`).
    public func observe(
        jobs: [TransferJob],
        resolved: [UUID: String],
        frontmost: Bool,
        now: Date,
        lastProgressAt: [UUID: Date] = [:],
        verdict: UploadVerdict = .permitted
    ) -> [TransferNotice] {
        let before = claimed
        var notices: [TransferNotice] = []
        let present = Set(jobs.map(\.id))
        for job in jobs {
            titles[job.id] = PendingMemoPresentation.snippet(
                job.manifest.content, limit: Self.titleLimit)
            guard job.manifest.state == .held,
                claimed.insert(TransferNotice.claim(job.id, .held)).inserted
            else { continue }
            notices.append(
                held(job, now: now, lastProgressAt: lastProgressAt, verdict: verdict))
        }
        // A finished capture is one the engine noted as a memo AND that this read no longer
        // finds: the engine notes the memo only once the capture has left the disk.
        for (jobID, uid) in resolved.sorted(by: { $0.key.uuidString < $1.key.uuidString })
        where !present.contains(jobID) {
            guard claimed.insert(TransferNotice.claim(jobID, .live)).inserted else { continue }
            notices.append(live(jobID, memo: uid))
        }
        // A claim is kept while its capture can still be announced: queued (a hold) or noted as
        // a memo (live). Neither can come back once both have let it go.
        let known = present.union(resolved.keys)
        claimed = claimed.filter { claim in
            guard let head = claim.split(separator: ".").first,
                let id = UUID(uuidString: String(head))
            else { return false }
            return known.contains(id)
        }
        titles = titles.filter { known.contains($0.key) }
        if claimed != before { defaults.set(claimed.sorted(), forKey: Self.claimsKey) }
        return frontmost ? [] : notices
    }

    private func live(_ jobID: UUID, memo uid: String) -> TransferNotice {
        let name = titles[jobID] ?? ""
        return TransferNotice(
            jobID: jobID, kind: .live,
            title: name.isEmpty ? "Your memo is live" : "\(name) is live",
            subtitle: "", body: "", route: .memo(uid: uid))
    }

    private func held(
        _ job: TransferJob, now: Date, lastProgressAt: [UUID: Date], verdict: UploadVerdict
    ) -> TransferNotice {
        let name = titles[job.id] ?? ""
        // The row's own words and fix: every file of a held capture carries the capture's reason.
        let file = job.files.first
        let reason =
            file.flatMap {
                TransfersPresentation.reason(
                    for: $0, in: job, now: now, lastProgressAt: lastProgressAt, verdict: verdict)
            }
            ?? PendingMemoPresentation.status(
                for: job.manifest, now: now, lastProgressAt: lastProgressAt, verdict: verdict)
        let action = file.flatMap {
            TransfersPresentation.action(
                for: $0, in: job, now: now, lastProgressAt: lastProgressAt, verdict: verdict)
        }
        return TransferNotice(
            jobID: job.id, kind: .held,
            title: name.isEmpty ? "A memo didn't upload" : "\(name) didn't upload",
            subtitle: action?.title ?? "", body: reason, route: .transfers(jobID: job.id))
    }
}
