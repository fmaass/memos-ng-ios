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
    /// What went wrong, of the four things that can: the capture just written, the queue itself,
    /// a write the drain could not make, and a capture a person asked to be rid of. They are held
    /// apart because they clear at different moments — a disk that has started answering again must
    /// not leave a sentence about it on screen, and must not wipe the one about the memo that never
    /// got saved either.
    public var lastError: String? {
        enqueueError ?? queueError ?? persistenceError ?? removalError
    }
    /// Bumped when a job LEAVES the queue, which only happens on a server-confirmed memo. It is
    /// the timeline's cue to reload: a capture that vanishes from Pending and does not reappear
    /// as a memo looks exactly like a lost one.
    public private(set) var lastCompletedAt: Date?

    /// Why the last capture could not be written down, as a value rather than as a sentence.
    ///
    /// The sentence stays where it was — it is what the queue's own screen shows — but the compose
    /// sheet has to do something different about each of these, and reading a category out of a
    /// string is how a message becomes a contract nobody meant to sign.
    public private(set) var lastEnqueueFailure: OutboxEnqueueFailure?

    private var enqueueError: String?
    private var queueError: String?
    private var persistenceError: String?
    private var removalError: String?

    /// The one that the ENGINE reads. The Settings screen changes this very object rather than a
    /// second store over the same suite: a preference is only half a preference if the drain
    /// waiting on it is not the thing that hears it change.
    public let uploadPreferences: UploadPreferences

    private let repository: OutboxRepository
    private let credentials: any OutboxCredentialsProviding
    private let engine: OutboxEngine
    private let changes: OutboxChangeBox
    private let attachScheduler: (@Sendable (any OutboxChunkHandling) async -> Void)?
    /// The adoption in flight, or the one that finished. It replaces an `isStarted` flag, which
    /// was set BEFORE the attachment was awaited: a second caller arriving inside that await saw
    /// the flag, skipped adoption and drained beside the replay. The two are not siblings, so the
    /// engine's own `isDraining` cannot exclude them from each other, and the interleaving loses a
    /// cursor. Held for the life of the process, because adoption happens once.
    private var adoption: Task<Void, Never>?

    public init(
        repository: OutboxRepository,
        credentials: any OutboxCredentialsProviding,
        http: any OutboxHTTPPerforming,
        scheduler: any OutboxChunkScheduling,
        completion: any MemoCompleting,
        network: any NetworkPathProviding,
        preferences: UploadPreferences,
        clock: @escaping @Sendable () -> Date = Date.init,
        // Passed in rather than assigned afterwards, so `adopt()` cannot be reached before the
        // thing it is supposed to await exists — and so the facade is drivable without a real
        // background `URLSession`, which is what the ordering below has to be tested through.
        attachScheduler: (@Sendable (any OutboxChunkHandling) async -> Void)? = nil
    ) {
        self.attachScheduler = attachScheduler
        let changes = OutboxChangeBox()
        self.changes = changes
        self.repository = repository
        self.credentials = credentials
        self.uploadPreferences = preferences
        self.engine = OutboxEngine(
            repository: repository,
            credentials: credentials,
            http: http,
            scheduler: scheduler,
            completion: completion,
            network: network,
            preferences: preferences,
            clock: clock,
            onChange: { await changes.fire() }
        )
        changes.attach { [weak self] in await self?.refresh() }
        // The two events that can make a held capture sendable, wired to the only thing that can
        // act on them. A job put down for the wrong network has to move when the network changes
        // or when the person changes their mind — waiting for the next launch would make the
        // toggle a promise the app keeps tomorrow.
        network.onPathChange { [weak self] in await self?.drain() }
        preferences.onChange { [weak self] in await self?.drain() }
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
            completion: MemoCompletionEndpoint(http: http),
            network: NetworkPathMonitor(),
            preferences: UploadPreferences.live(appGroup: appGroup),
            attachScheduler: { handler in await scheduler.attach(handler) }
        )
        return outbox
    }

    /// Take over what the last run left behind — WITHOUT sending anything.
    ///
    /// Attaching the background session's handler and reading the queue back are not network work
    /// and need no authority: a chunk the system finished while the app was dead has already been
    /// sent, and its answer carries the server's own byte count. Discarded, that count is lost and
    /// the bytes are sent again. So a wake that has no credential to drain with still comes
    /// through here — only `start` below asks for authority.
    public func adopt() async {
        await adopted()
        await refresh()
    }

    /// The barrier. The first caller runs the attachment; everyone else JOINS it and waits for the
    /// same task, so no drain can begin while a replay is still landing.
    private func adopted() async {
        if let adoption { return await adoption.value }
        let work = Task { @MainActor [self] in _ = await attachScheduler?(engine) }
        adoption = work
        await work.value
    }

    /// Adopt whatever survived the last run, then try to drain. Safe to call on every launch and
    /// every foreground — the engine refuses to drain twice at once.
    public func start() async {
        await adopt()
        await engine.drain()
    }

    /// Every OTHER way into a drain goes through here, so adoption is a barrier rather than a
    /// courtesy the first caller happens to observe.
    private func drainAfterAdoption() async {
        await adopted()
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
        await drainAfterAdoption()
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
        guard let credentials = await credentials.currentCredentials(),
            self.credentials.isCurrent(credentials)
        else {
            enqueueError = "Sign in before writing a memo."
            lastEnqueueFailure = .notSignedIn
            return false
        }
        // The binding stamped on the job decides whose account this capture is ever sent into, and
        // the repository copies every file before it commits one. So the authority travels INTO
        // that actor and is asked again immediately before the commit, rather than only here.
        let authority = self.credentials
        do {
            _ = try await repository.enqueue(
                content: content,
                visibility: visibility,
                capturedAt: capturedAt,
                binding: credentials.binding,
                sources: sources,
                under: SendAuthority { authority.isCurrent(credentials) }
            )
            enqueueError = nil
            lastEnqueueFailure = nil
        } catch is SendAuthorityWithdrawn {
            enqueueError = "Sign in before writing a memo."
            lastEnqueueFailure = .notSignedIn
            return false
        } catch {
            enqueueError =
                "This memo could not be saved on the device: \(error.localizedDescription)"
            lastEnqueueFailure = .storage
            return false
        }
        await refresh()
        Task { await self.drainAfterAdoption() }
        return true
    }

    /// Clears a hold and tries again — the "Try again" a stuck pending row offers.
    public func retry(_ jobID: UUID) async {
        await engine.release(jobID: jobID)
        await refresh()
        await drainAfterAdoption()
    }

    /// Throws a capture away on purpose — the "Remove" offered by a row whose manifest could not be
    /// read, which is the only row nothing else can ever move. A capture leaves this device because
    /// a person decided it should, never because something swept.
    public func discard(_ jobID: UUID) async {
        do {
            try await repository.discard(jobID)
            removalError = nil
        } catch {
            removalError =
                "This capture could not be removed: \(error.localizedDescription)"
        }
        await refresh()
    }
}
