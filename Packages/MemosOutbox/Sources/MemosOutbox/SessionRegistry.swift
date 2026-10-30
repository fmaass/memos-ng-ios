import Foundation
import Synchronization

/// The background sessions a shared capture's tasks are started under: one per capture, named
/// after its job, so the single-attach rule — one `URLSession` per identifier per process — holds
/// per capture rather than per process, and the app's own session is never the one shared.
public enum ShareSession {
    /// The trailing dot is load-bearing: the app's own session is
    /// `live.discomarder.memosng.uploads`, a prefix of this string, and must never be read as a
    /// capture's.
    public static let identifierPrefix = "live.discomarder.memosng.uploads.share."

    public static func identifier(jobID: UUID) -> String {
        identifierPrefix + jobID.uuidString
    }

    /// The capture a share session carries; nil for every identifier that is not one.
    public static func jobID(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
    }

    /// What both processes build for one capture's session: the extension to start its tasks, the
    /// app to hear how they ended. The app group is the shared container, because the extension's
    /// own container goes with the extension. The networks are left to each request
    /// (`OutboxRequests.wholeUpload`), so the person's mobile-data choice is the one place that
    /// decides them.
    public static func backgroundConfiguration(
        identifier: String, appGroup: String = OutboxDefaults.appGroup
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = appGroup
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return configuration
    }
}

/// One identifier that may hold a shared capture's tasks, and the capture it carries.
public struct SessionRegistryEntry: Codable, Sendable, Equatable, Hashable {
    public var identifier: String
    public var jobID: UUID

    public init(jobID: UUID) {
        self.identifier = ShareSession.identifier(jobID: jobID)
        self.jobID = jobID
    }
}

/// Why the registry could not be written.
public enum SessionRegistryFailure: Error, Sendable, Equatable {
    /// The lease was not granted: another process is writing, or the lock does not work here.
    /// Either way nothing was written, and the caller may ask again.
    case locked(OutboxLockFailure)
}

/// Every share session that may still hold tasks, persisted in the app group beside the outbox,
/// so the app can attach to each of them on any wake — including one the extension started while
/// the app was not running at all.
///
/// Every write is one read-modify-write taken under the cross-process lease (`OutboxLock`, on a
/// lock file of its own) and, inside this process, under one mutex: the read, the change and the
/// atomic replace run on one thread with nothing awaited between them, so two writers — the
/// extension registering, the app retiring, two wakes of the app — cannot lose each other's entry.
/// Reads take neither: the file is only ever replaced whole, so a reader sees one write or the
/// next, never half of one.
public struct SessionRegistry: Sendable {
    private let manifest: URL
    private let lock: OutboxLock
    /// Process-wide: two registries over the same root in one process are two descriptors, and a
    /// second descriptor is refused by `flock` exactly as a second process is. Serialising them
    /// here turns that refusal into a short wait.
    private static let writes = Mutex(())

    public init(root: URL) {
        self.init(root: root, flock: OutboxLock.systemFlock)
    }

    init(root: URL, flock: @escaping @Sendable (Int32, Int32) -> Int32) {
        self.manifest = root.appending(path: "sessions.json")
        self.lock = OutboxLock(url: root.appending(path: "sessions.lock"), flock: flock)
    }

    /// The registered identifiers, in the order they were registered. A file that cannot be
    /// decoded reads as empty: an entry only ever defers a capture to its share session, so losing
    /// one hands the capture back to the app's own lane rather than stranding it.
    public func entries() -> [SessionRegistryEntry] {
        guard let data = try? Data(contentsOf: manifest) else { return [] }
        return (try? JSONDecoder().decode([SessionRegistryEntry].self, from: data)) ?? []
    }

    /// Whether a share session carries this capture — the question the app's drain asks before it
    /// touches a job, so a capture is never sent by two sessions at once.
    public func carries(jobID: UUID) -> Bool {
        entries().contains { $0.jobID == jobID }
    }

    public func contains(identifier: String) -> Bool {
        entries().contains { $0.identifier == identifier }
    }

    public func register(_ entry: SessionRegistryEntry) throws {
        try mutate { entries in
            if !entries.contains(entry) { entries.append(entry) }
        }
    }

    public func retire(_ identifiers: Set<String>) throws {
        guard !identifiers.isEmpty else { return }
        try mutate { entries in
            entries.removeAll { identifiers.contains($0.identifier) }
        }
    }

    private func mutate(_ change: (inout [SessionRegistryEntry]) -> Void) throws {
        try Self.writes.withLock { _ in
            let lease: OutboxLease
            switch lock.acquire(.exclusive) {
            case .leased(let held): lease = held
            case .refused(let failure): throw SessionRegistryFailure.locked(failure)
            }
            defer { lease.release() }
            var current = entries()
            change(&current)
            try JSONEncoder().encode(current).write(to: manifest, options: .atomic)
        }
    }
}
