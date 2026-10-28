import Foundation
import MemosOutbox

/// MEMNG-538 device spike — KILL DATE Tue 3 Nov 2026.
///
/// The one place the share extension sends anything, and only with the debug switch on: after the
/// capture is safely in the queue (unchanged), it opens an upload session for a synthetic file and
/// hands ONE whole-file PATCH to a background session of its own, then lets the sheet close. It
/// never finalizes and never creates a memo. Whether the system then launches the app to hear how
/// that task ended is the whole question (`UploadSpike`).
public enum UploadSpikeShare {
    public enum Outcome: Sendable, Equatable {
        /// The switch is off: nothing was read, written or sent.
        case disabled
        /// No usable spike token for this account.
        case noGrant
        case failed(String)
        case started(identifier: String, uploadUID: String)
    }

    /// - Parameters:
    ///   - enabled: the switch, read by the caller. Off means this returns before touching
    ///     anything else.
    ///   - send: the foreground request that opens the upload session.
    ///   - startBackground: creates the background session and resumes its one upload task;
    ///     returns the task's identifier for the log.
    public static func run(
        jobID: UUID,
        enabled: Bool,
        licence: () -> PublishedLicence?,
        grant: () throws -> UploadSpikeGrant?,
        root: URL,
        now: Date = Date(),
        size: Int64 = UploadSpike.syntheticSize,
        log: (String) -> Void,
        send: (URLRequest) async throws -> (Data, URLResponse),
        startBackground: (_ identifier: String, _ request: URLRequest, _ file: URL) -> Int
    ) async -> Outcome {
        guard enabled else { return .disabled }
        log("ext: enqueued job \(jobID.uuidString)")
        let stored: UploadSpikeGrant?
        do {
            stored = try grant()
        } catch {
            log("ext: spike token unreadable: \(error)")
            return .noGrant
        }
        // The licence the POST is issued under. Its answer is judged against THIS, re-read after
        // the await: a sign-out or account switch in the app while the POST was out starts nothing.
        let issuing = licence()
        let binding = issuing?.binding
        guard let stored, stored.isUsable(for: binding, at: now), let binding else {
            log("ext: no usable spike token for this account - mint one in Manage tokens")
            return .noGrant
        }
        let file = UploadSpike.syntheticFileURL(in: root, jobID: jobID)
        do {
            let started = Date()
            try UploadSpike.writeSyntheticFile(to: file, size: size)
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            log("ext: synthetic file written bytes=\(size) in \(millis) ms")
            let request = try UploadSpike.startRequest(
                baseURL: binding.serverBaseURL, token: stored.token, jobID: jobID, size: size)
            let (data, response) = try await send(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 201, let session = OutboxWire.decodeSession(data) else {
                log("ext: POST /api/uploads -> \(status), no upload session")
                try? FileManager.default.removeItem(at: file)
                return .failed("POST status \(status)")
            }
            log("ext: POST /api/uploads -> \(status) upload_uid=\(session.uploadUID)")
            guard licence() == issuing else {
                log("ext: the account changed while the POST was out - nothing started")
                try? FileManager.default.removeItem(at: file)
                return .failed("account changed")
            }
            let identifier = UploadSpike.sessionIdentifier(jobID: jobID)
            let task = startBackground(
                identifier,
                UploadSpike.uploadRequest(
                    baseURL: binding.serverBaseURL, token: stored.token,
                    uploadUID: session.uploadUID),
                file
            )
            log("ext: background task \(task) resumed in session \(identifier)")
            return .started(identifier: identifier, uploadUID: session.uploadUID)
        } catch {
            log("ext: spike failed: \((error as NSError).domain)/\((error as NSError).code)")
            try? FileManager.default.removeItem(at: file)
            return .failed("\((error as NSError).domain)/\((error as NSError).code)")
        }
    }

    /// The extension's composition: the app group's switch, the published account, the app-group
    /// token file, a plain foreground session for the POST and a background session for the PATCH.
    @discardableResult
    public static func live(jobID: UUID, root: URL) async -> Outcome {
        let enabled =
            UserDefaults(suiteName: OutboxDefaults.appGroup).map(UploadSpike.isEnabled) ?? false
        guard enabled else { return .disabled }
        let foreground = URLSession(configuration: .ephemeral)
        defer { foreground.finishTasksAndInvalidate() }
        let outcome = await run(
            jobID: jobID,
            enabled: enabled,
            licence: { OutboxAccountStore.live()?.currentLicence() },
            grant: { try UploadSpikeGrantFile().load() },
            root: root,
            log: { UploadSpikeLog.append($0, root: root) },
            send: { try await foreground.data(for: $0) },
            startBackground: { identifier, request, file in
                let session = URLSession(
                    configuration: UploadSpike.backgroundConfiguration(identifier: identifier))
                let task = session.uploadTask(with: request, fromFile: file)
                task.resume()
                return task.taskIdentifier
            }
        )
        UploadSpikeLog.append("ext: finishing the share sheet (\(outcome))", root: root)
        return outcome
    }
}
