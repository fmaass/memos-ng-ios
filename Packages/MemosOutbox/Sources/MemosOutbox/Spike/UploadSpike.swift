import Foundation
import Synchronization

/// MEMNG-538 device spike — KILL DATE Tue 3 Nov 2026. Everything under `Spike/` goes then.
///
/// The question it answers on a real iPhone: does a background session CREATED BY THE SHARE
/// EXTENSION outlive the extension, and does the system then launch the containing app —
/// force-quit — through `handleEventsForBackgroundURLSession` to hear how it ended? That
/// decides whether a share can start its own upload instead of waiting for the app's next drain.
///
/// It is a debug switch in the Settings pane, off by default, and with it off nothing here runs:
/// the extension asks `isEnabled` first and does nothing else, the app writes nothing and shows
/// nothing. The only path that does not ask is the app's wake for a `share.` session, and no such
/// session can exist unless the switch was on when a share started one.
public enum UploadSpike {
    /// The Settings-pane key. The pane writes it into the app group's defaults, which is the one
    /// suite both processes can read.
    public static let toggleKey = "debug.uploadSpike"
    /// Every spike session's identifier starts with this. The trailing dot is load-bearing: the
    /// outbox's own session is `live.discomarder.memosng.uploads`, a prefix of this string, and
    /// must never be taken for a spike session.
    public static let identifierPrefix = "live.discomarder.memosng.uploads.share."
    /// The name the spike token is minted under, so it can be recognised and revoked in the list.
    public static let tokenName = "Upload spike"
    /// The shortest lifetime the server accepts (`expires_in_days` is 1...365).
    public static let tokenLifetimeDays = 1
    /// Large enough that the upload cannot finish before the extension is gone.
    public static let syntheticSize: Int64 = 300 * 1024 * 1024
    /// What the synthetic file is written in: one reused block, never the whole file in memory —
    /// a share extension is given a fraction of an app's memory.
    public static let writeBlock = 4 * 1024 * 1024

    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: toggleKey)
    }

    public static func sessionIdentifier(jobID: UUID) -> String {
        identifierPrefix + jobID.uuidString
    }

    /// The share's job id, when `identifier` is a spike session's; nil for every other session.
    public static func jobID(fromSessionIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
    }

    public static func isSpikeSession(_ identifier: String) -> Bool {
        jobID(fromSessionIdentifier: identifier) != nil
    }

    public static func directory(in root: URL) -> URL {
        root.appending(path: "upload-spike", directoryHint: .isDirectory)
    }

    public static func syntheticFileURL(in root: URL, jobID: UUID) -> URL {
        directory(in: root).appending(path: "\(jobID.uuidString).bin")
    }

    public static func logURL(in root: URL) -> URL {
        directory(in: root).appending(path: "upload-spike-log.txt")
    }

    /// The upload session the synthetic file is sent into — the same request the outbox opens one
    /// with.
    public static func startRequest(
        baseURL: URL, token: String, jobID: UUID, size: Int64 = syntheticSize
    ) throws -> URLRequest {
        try OutboxRequests.startUpload(
            baseURL: baseURL,
            token: token,
            file: OutboxFile(
                id: jobID,
                relativePath: "upload-spike/\(jobID.uuidString).bin",
                filename: "upload-spike-\(jobID.uuidString).bin",
                mime: "application/octet-stream",
                byteSize: size
            )
        )
    }

    /// The one PATCH that carries the whole file from offset 0 — the outbox's own whole-file
    /// request, so the headers are the ones `append_chunk` reads (`Upload-Offset`, an octet-stream
    /// body, the bearer). Wi-Fi only: 300 MB on mobile data is not a test anyone asked for.
    public static func uploadRequest(baseURL: URL, token: String, uploadUID: String) -> URLRequest {
        OutboxRequests.wholeUpload(
            baseURL: baseURL, token: token, uploadUID: uploadUID, allowsMobileData: false
        )
    }

    /// The background configuration both processes build for one spike session: the extension to
    /// start it, the app to receive its events.
    public static func backgroundConfiguration(
        identifier: String, appGroup: String = OutboxDefaults.appGroup
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // The extension's own container goes with the extension; this is the one the app can open.
        configuration.sharedContainerIdentifier = appGroup
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        return configuration
    }

    /// Writes `size` bytes to `url` one reused block at a time, replacing whatever was there.
    public static func writeSyntheticFile(
        to url: URL, size: Int64 = syntheticSize, block: Int = writeBlock
    ) throws {
        precondition(block > 0, "a block of no bytes would never finish")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let bytes = Data(repeating: 0x5A, count: block)
        var remaining = size
        while remaining > 0 {
            let count = Int(min(Int64(block), remaining))
            try handle.write(contentsOf: count == block ? bytes : bytes.prefix(count))
            remaining -= Int64(count)
        }
    }
}

/// The spike token as both processes see it: the secret, when it stops working, and the account
/// it was minted for — so a share made after an account switch never presents it.
public struct UploadSpikeGrant: Codable, Sendable, Equatable, CustomStringConvertible {
    public var token: String
    public var expiresAt: Date
    public var binding: AccountBinding

    public init(token: String, expiresAt: Date, binding: AccountBinding) {
        self.token = token
        self.expiresAt = expiresAt
        self.binding = binding
    }

    /// Never the secret: a grant that reaches a log line or a test failure message says only
    /// whose it is and until when.
    public var description: String {
        "UploadSpikeGrant(owner: \(binding.ownerSubject), expires: \(expiresAt))"
    }

    /// Whether a share may present this token now: same account, not yet expired.
    public func isUsable(for binding: AccountBinding?, at now: Date) -> Bool {
        guard let binding, binding == self.binding else { return false }
        return now < expiresAt
    }

    /// What the token screen does when the spike is on: keep the stored token while it will
    /// still outlast a test, or mint one. At most one mint a day, because a usable token is reused.
    public enum Decision: Sendable, Equatable {
        case reuse(expiresAt: Date)
        case mint
        case notSignedIn
    }

    /// An hour of margin, so a token minted yesterday evening is not reused for a test that runs
    /// past its expiry.
    public static let reuseMargin: TimeInterval = 3600

    public static func decision(
        stored: UploadSpikeGrant?, binding: AccountBinding?, now: Date
    ) -> Decision {
        guard let binding else { return .notSignedIn }
        guard let stored, stored.isUsable(for: binding, at: now.addingTimeInterval(reuseMargin))
        else { return .mint }
        return .reuse(expiresAt: stored.expiresAt)
    }
}

/// Where the spike token is kept.
public protocol UploadSpikeGrantStoring: Sendable {
    func load() throws -> UploadSpikeGrant?
    func save(_ grant: UploadSpikeGrant) throws
}

/// A file in the APP GROUP container — deliberately, and only for this token.
///
/// The device credential left that group (5c181fd2) so the share extension could not read it, and
/// it stays out. This token is the opposite case: it exists so the extension CAN present it, it
/// lives one day, it is minted only through a step-up the person performs, and it is listed under
/// its own name for revoking. It is a file rather than a keychain item because raw keychain calls
/// live in MemosCore's one audited file, which the extension does not link; the file takes the
/// protection the keychain item would have had — readable after first unlock, and this device
/// only, by excluding it from backups explicitly — plus the owner's mode bits.
public struct UploadSpikeGrantFile: UploadSpikeGrantStoring {
    let url: URL?

    public init(root: URL? = OutboxRepository.appGroupRoot()?.deletingLastPathComponent()) {
        self.url = root?.appending(path: "upload-spike").appending(path: "grant.json")
    }

    public enum Failure: Error, Equatable {
        case noContainer
    }

    public func load() throws -> UploadSpikeGrant? {
        guard let url else { throw Failure.noContainer }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        return try JSONDecoder().decode(UploadSpikeGrant.self, from: Data(contentsOf: url))
    }

    public func save(_ grant: UploadSpikeGrant) throws {
        guard let url else { throw Failure.noContainer }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // The folder is excluded before any token byte is written, so a save cut short between
        // the write and the file's own exclusion below still leaves nothing eligible for backup.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(excluded)
        try JSONEncoder().encode(grant).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = url
        try file.setResourceValues(values)
    }
}

/// The spike's log: one timestamped line per step, from either process, in the app group.
///
/// Appended with `O_APPEND`, so a line the extension writes and one the app writes in the same
/// instant land whole rather than interleaved. Nothing secret is ever handed to it.
public enum UploadSpikeLog {
    public static func line(_ message: String, at now: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now) + " " + message + "\n"
    }

    public static func append(_ message: String, root: URL, now: Date = Date()) {
        let url = UploadSpike.logURL(in: root)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let bytes = Array(line(message, at: now).utf8)
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }
}

/// Which held wakes of a spike session may answer the system, decided at the callback site.
///
/// Every handler the system hands over is called exactly once. Each wake is armed with its own
/// ticket and stays pending until it is claimed: the session finishing its events claims EVERY
/// wake still pending (they are all waiting on the same session), and a wake's fallback deadline
/// claims only its own ticket. A second wake arriving before the first is answered therefore
/// displaces nothing. The claim is taken synchronously, under a lock, on whatever queue the
/// callback arrived on — before any hop to the main actor, whose ordering nobody guarantees.
public final class UploadSpikeWakeClaim: Sendable {
    private struct State {
        var ticket = 0
        var pending: Set<Int> = []
    }

    private let state = Mutex(State())

    public init() {}

    /// A new handler is held: returns its ticket.
    public func arm() -> Int {
        state.withLock {
            $0.ticket += 1
            $0.pending.insert($0.ticket)
            return $0.ticket
        }
    }

    /// Claims `ticket` alone, or every pending wake when `ticket` is nil. Returns the tickets this
    /// call won, in arming order — empty when there was nothing left to answer.
    public func claim(ticket: Int? = nil) -> [Int] {
        state.withLock { state -> [Int] in
            if let ticket {
                return state.pending.remove(ticket).map { [$0] } ?? []
            }
            let won = state.pending.sorted()
            state.pending.removeAll()
            return won
        }
    }
}

/// The app's side of one spike session: it logs what the system delivers and, when the session
/// has finished its events, answers the wake once.
public final class UploadSpikeReceiver: NSObject, URLSessionDataDelegate, Sendable {
    public let identifier: String
    public let claim = UploadSpikeWakeClaim()
    private let root: URL
    /// Handed the ticket that won; the app fires the handler it holds under it.
    private let answer: @Sendable (Int) -> Void
    private let bodies = Mutex<[Int: Data]>([:])
    private let loggedMegabytes = Mutex<Int64>(0)

    public init(identifier: String, root: URL, answer: @escaping @Sendable (Int) -> Void) {
        self.identifier = identifier
        self.root = root
        self.answer = answer
    }

    private func log(_ message: String) {
        UploadSpikeLog.append("app: \(message)", root: root)
    }

    /// Claims the wake(s) and answers each one this call won. Returns whether it won any.
    @discardableResult
    public func answerOnce(ticket: Int? = nil, reason: String) -> Bool {
        let won = claim.claim(ticket: ticket)
        for ticket in won {
            log("completion handler called (\(reason), wake \(ticket)) for \(identifier)")
            answer(ticket)
        }
        return !won.isEmpty
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        let step: Int64 = 50 * 1024 * 1024
        let crossed = loggedMegabytes.withLock { logged -> Bool in
            guard totalBytesSent >= logged + step else { return false }
            logged = totalBytesSent
            return true
        }
        if crossed {
            log("didSendBodyData total=\(totalBytesSent)/\(totalBytesExpectedToSend)")
        }
    }

    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        bodies.withLock { $0[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        let body = bodies.withLock { $0.removeValue(forKey: task.taskIdentifier) } ?? Data()
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        let received = OutboxWire.decodeSession(body).map { String($0.bytesReceived) } ?? "?"
        let failure = error.map { " error=\(($0 as NSError).domain)/\(($0 as NSError).code)" } ?? ""
        log(
            "didCompleteWithError task=\(task.taskIdentifier) status=\(status) "
                + "sent=\(task.countOfBytesSent) server_bytes_received=\(received)\(failure)"
        )
        if let jobID = UploadSpike.jobID(fromSessionIdentifier: identifier) {
            let file = UploadSpike.syntheticFileURL(in: root, jobID: jobID)
            let removed = (try? FileManager.default.removeItem(at: file)) != nil
            log("synthetic file removed=\(removed)")
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        log("urlSessionDidFinishEvents for \(identifier)")
        answerOnce(reason: "didFinishEvents")
    }
}
