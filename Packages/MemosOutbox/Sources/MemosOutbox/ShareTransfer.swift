import Foundation
import Synchronization

/// A bearer the share extension may present for a capture's uploads, the generation it belongs to,
/// and the account it was issued for.
///
/// The extension holds no session token: the identity it reads from the app group names an
/// account, never a credential (`OutboxAccountStore`). Until something supplies one of these the
/// extension starts nothing, and the capture uploads when the app next drains — as it always has.
public struct ShareUploadCredential: Sendable, Equatable {
    public var token: String
    public var epoch: Int
    public var binding: AccountBinding

    public init(token: String, epoch: Int, binding: AccountBinding) {
        self.token = token
        self.epoch = epoch
        self.binding = binding
    }
}

/// What the extension did after the capture was committed.
public enum ShareTransferOutcome: Sendable, Equatable {
    /// Nothing was started and nothing is registered: the app's lane sends the capture.
    case notStarted(String)
    /// The server turned an upload session down. Carries the generation the request PRESENTED;
    /// nothing was written, so the app sends the capture under its own credential.
    case refused(OutboxRefusal)
    /// Every file was handed to the capture's own background session.
    case started(identifier: String, tasks: Int)
}

/// The share extension's transfer: after the capture is committed, open an upload session on the
/// server for each file (foreground, one small POST each), hand each whole-file PATCH to the
/// capture's own background session, and return — the extension's process is gone shortly after,
/// and only tasks already handed to the system survive it.
///
/// The identifier is registered BEFORE anything is sent, so the app's drain leaves the capture to
/// this session from that moment, and an app woken for it — by the system or by a launch — finds
/// it to attach to. Every way this ends short of `started` retires it again.
public enum ShareTransfer {
    /// How long a registry lease held by the app is waited out: a write takes milliseconds.
    static let registryAttempts = 20
    /// The captures a start is under way for in this process. Claimed synchronously, before the
    /// first await, and a second start for a claimed capture is REFUSED rather than joined: the
    /// first one's outcome is the capture's, and the caller of the second has nothing to wait for.
    private static let claims = Mutex<Set<UUID>>([])

    public static func start(
        jobID: UUID,
        credential: ShareUploadCredential?,
        registry: SessionRegistry,
        repository: OutboxRepository,
        http: any OutboxHTTPPerforming,
        allowsMobileData: Bool,
        stillCurrent: @escaping @Sendable (Int) -> Bool,
        launch: UUID = UUID(),
        session makeSession: (String) -> any UploadTaskSession
    ) async -> ShareTransferOutcome {
        guard let credential else { return .notStarted("no upload credential") }
        guard claims.withLock({ $0.insert(jobID).inserted }) else {
            return .notStarted("a start for this capture is already under way")
        }
        defer { _ = claims.withLock { $0.remove(jobID) } }
        let entry = SessionRegistryEntry(jobID: jobID)
        guard await register(entry, in: registry) else {
            return .notStarted("the session registry was busy")
        }
        let outcome = await send(
            entry: entry, credential: credential, repository: repository, http: http,
            allowsMobileData: allowsMobileData, stillCurrent: stillCurrent, launch: launch,
            makeSession: makeSession
        )
        if case .started = outcome { return outcome }
        try? registry.retire([entry.identifier])
        return outcome
    }

    private static func register(_ entry: SessionRegistryEntry, in registry: SessionRegistry) async
        -> Bool
    {
        for _ in 0..<registryAttempts {
            do {
                try registry.register(entry)
                return true
            } catch {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        return false
    }

    private static func send(
        entry: SessionRegistryEntry,
        credential: ShareUploadCredential,
        repository: OutboxRepository,
        http: any OutboxHTTPPerforming,
        allowsMobileData: Bool,
        stillCurrent: @escaping @Sendable (Int) -> Bool,
        launch: UUID,
        makeSession: (String) -> any UploadTaskSession
    ) async -> ShareTransferOutcome {
        // Read AFTER the registration: a drain that reached the capture first has claimed it for
        // the app's lane, and from here on no drain will.
        guard let job = await repository.job(entry.jobID),
            job.binding == credential.binding,
            OutboxEngine.claimsWhole(job)
        else { return .notStarted("the app's lane holds this capture") }
        let authority = SendAuthority { stillCurrent(credential.epoch) }
        var candidate = job.with { $0.transport = .whole }
        for file in job.files {
            let response: OutboxHTTPResponse
            do {
                let request = try OutboxRequests.startUpload(
                    baseURL: credential.binding.serverBaseURL, token: credential.token, file: file)
                response = try await http.perform(request, under: authority)
            } catch {
                return .notStarted("an upload session could not be opened")
            }
            guard response.isSuccess, let session = OutboxWire.decodeSession(response.body) else {
                return .refused(
                    OutboxRefusal(
                        statusCode: response.statusCode, issuedUnder: credential.epoch,
                        what: "upload")
                )
            }
            candidate = candidate.startingUpload(fileID: file.id, session: session)
        }
        // Against the manifest read above AND the credential the POSTs were issued under, both
        // asked inside the repository's write: a row that moved meanwhile is not overwritten, and
        // answers that outlived their credential record nothing.
        let saved: UploadJob?
        do {
            saved = try await repository.save(
                candidate, issuedUnder: credential.epoch, judgedBy: stillCurrent, matching: job)
        } catch {
            return .notStarted("the capture could not be updated")
        }
        guard let saved else { return .notStarted("the capture or its credential moved") }
        let session = makeSession(entry.identifier)
        // The handover is a credential-scoped act: every task presents the bearer. Asked here,
        // and nothing is awaited between this answer and the last task created below, so a
        // credential that ended after the save hands no file over.
        guard stillCurrent(credential.epoch) else {
            return .notStarted("the credential ended before the files were handed over")
        }
        var started = 0
        for file in saved.files {
            guard let uploadUID = file.uploadUID else { continue }
            let identity = WholeTaskIdentity(
                jobID: saved.id, fileID: file.id, attempt: file.uploadAttempt ?? 0,
                launch: launch, epoch: credential.epoch)
            _ = session.uploadTask(
                with: OutboxRequests.wholeUpload(
                    baseURL: credential.binding.serverBaseURL, token: credential.token,
                    uploadUID: uploadUID, allowsMobileData: allowsMobileData),
                fromFile: repository.mediaURL(job: saved, file: file),
                description: identity.taskDescription
            )
            started += 1
        }
        return .started(identifier: entry.identifier, tasks: started)
    }

    /// The extension's composition: the app group's registry, a plain foreground session for the
    /// POSTs, and the capture's own background session for the PATCHes.
    public static func live(
        jobID: UUID,
        credential: ShareUploadCredential?,
        root: URL,
        repository: OutboxRepository,
        stillCurrent: @escaping @Sendable (Int) -> Bool,
        appGroup: String = OutboxDefaults.appGroup
    ) async -> ShareTransferOutcome {
        guard credential != nil else { return .notStarted("no upload credential") }
        return await start(
            jobID: jobID,
            credential: credential,
            registry: SessionRegistry(root: root),
            repository: repository,
            http: URLSessionHTTPPerformer(),
            allowsMobileData: UploadPreferences.live(appGroup: appGroup).allowsMobileData,
            stillCurrent: stillCurrent,
            session: { identifier in
                URLSessionUploadTaskSession(
                    session: URLSession(
                        configuration: ShareSession.backgroundConfiguration(
                            identifier: identifier, appGroup: appGroup)))
            }
        )
    }
}
