import Foundation
import Observation

/// Lets the engine tell the facade something changed.
///
/// The two need each other at construction time — the engine reports changes to the facade, the
/// facade owns the engine — so one of the references is attached rather than passed in.
@MainActor
final class OutboxChangeBox {
    private var handler: (@MainActor () async -> Void)?

    func attach(_ handler: @escaping @MainActor () async -> Void) {
        self.handler = handler
    }

    func fire() async {
        await handler?()
    }
}

/// The outbox as a screen sees it: the queue, and the two things a person does to it.
///
/// Everything that decides anything lives below this — the facade holds no rules, it observes the
/// jobs on disk and forwards. That is deliberate: a `@MainActor` observable class is the one place
/// in this package a unit test cannot reach comfortably, so nothing worth testing is put here.
@MainActor
@Observable
public final class Outbox {
    /// The queue, oldest capture first. Read straight from disk after every change, because disk
    /// is the truth: a job that only exists in memory is a memo that a force-quit loses.
    public private(set) var jobs: [UploadJob] = []
    /// What went wrong, of the three things that can: the capture just written, the queue itself,
    /// and a write the drain could not make. They are held apart because they clear at different
    /// moments — a disk that has started answering again must not leave a sentence about it on
    /// screen, and must not wipe the one about the memo that never got saved either.
    public var lastError: String? { enqueueError ?? queueError ?? persistenceError }
    /// Bumped when a job LEAVES the queue, which only happens on a server-confirmed memo. It is
    /// the timeline's cue to reload: a capture that vanishes from Pending and does not reappear
    /// as a memo looks exactly like a lost one.
    public private(set) var lastCompletedAt: Date?

    private var enqueueError: String?
    private var queueError: String?
    private var persistenceError: String?

    private let repository: OutboxRepository
    private let credentials: any OutboxCredentialsProviding
    private let engine: OutboxEngine
    private let changes: OutboxChangeBox
    private var attachScheduler: (@Sendable (any OutboxChunkHandling) async -> Void)?
    private var isStarted = false

    public init(
        repository: OutboxRepository,
        credentials: any OutboxCredentialsProviding,
        http: any OutboxHTTPPerforming,
        scheduler: any OutboxChunkScheduling,
        completion: any MemoCompleting,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        let changes = OutboxChangeBox()
        self.changes = changes
        self.repository = repository
        self.credentials = credentials
        self.engine = OutboxEngine(
            repository: repository,
            credentials: credentials,
            http: http,
            scheduler: scheduler,
            completion: completion,
            clock: clock,
            onChange: { await changes.fire() }
        )
        changes.attach { [weak self] in await self?.refresh() }
    }

    /// The composed outbox: the app group's container, the one background session, and the live
    /// completion path. Falls back to the app's own container when the app group is unreachable —
    /// a missing entitlement must degrade to "queues locally", never to "loses the capture".
    public static func live(
        appGroup: String = OutboxDefaults.appGroup,
        credentials: any OutboxCredentialsProviding
    ) throws -> Outbox {
        let root =
            OutboxRepository.appGroupRoot(appGroup: appGroup)
            ?? URL.applicationSupportDirectory.appending(path: "outbox")
        let repository = try OutboxRepository(root: root)
        let scheduler = BackgroundChunkScheduler(appGroup: appGroup)
        let http = URLSessionHTTPPerformer()
        let outbox = Outbox(
            repository: repository,
            credentials: credentials,
            http: http,
            scheduler: scheduler,
            completion: MemoCompletionEndpoint(http: http)
        )
        outbox.attachScheduler = { handler in await scheduler.attach(handler) }
        return outbox
    }

    /// Adopt whatever survived the last run, then try to drain. Safe to call on every launch and
    /// every foreground — the engine refuses to drain twice at once.
    public func start() async {
        if !isStarted {
            isStarted = true
            await attachScheduler?(engine)
        }
        await refresh()
        await engine.drain()
    }

    public func refresh() async {
        let previous = jobs.map(\.id)
        do {
            let loaded = try await repository.loadJobs()
            jobs = loaded
            queueError = nil
            if OutboxProgress.didComplete(previous: previous, current: loaded.map(\.id)) {
                lastCompletedAt = Date()
            }
        } catch {
            // A queue that could not be read is NOT an empty queue. What is on screen stays on
            // screen, and the reason it could not be re-read is said out loud.
            queueError =
                "The queue on this device could not be read: \(error.localizedDescription)"
        }
        persistenceError = await engine.lastPersistenceFailure
    }

    /// Where a queued capture's first original actually is, so a row can show it without the view
    /// knowing anything about the container it lives in.
    public func mediaURL(for job: UploadJob) -> URL? {
        guard let file = job.files.first else { return nil }
        return repository.mediaURL(job: job, file: file)
    }

    public func drain() async {
        await engine.drain()
    }

    /// Writes a capture to disk and only then tries the network. The return value says whether it
    /// was PERSISTED, not whether it was sent: the compose screen closes on the former.
    @discardableResult
    public func enqueue(
        content: String,
        visibility: String?,
        capturedAt: Date = Date(),
        sources: [StagedSource]
    ) async -> Bool {
        guard let credentials = await credentials.currentCredentials() else {
            enqueueError = "Sign in before writing a memo."
            return false
        }
        do {
            _ = try await repository.enqueue(
                content: content,
                visibility: visibility,
                capturedAt: capturedAt,
                binding: credentials.binding,
                sources: sources
            )
            enqueueError = nil
        } catch {
            enqueueError =
                "This memo could not be saved on the device: \(error.localizedDescription)"
            return false
        }
        await refresh()
        Task { await engine.drain() }
        return true
    }

    /// Clears a hold and tries again — the "Try again" a stuck pending row offers.
    public func retry(_ jobID: UUID) async {
        await engine.release(jobID: jobID)
        await refresh()
        await engine.drain()
    }
}
