import Foundation
import Observation
import os

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
    /// The memo each recently finished capture became, by job id, as the engine noted it — read
    /// together with `jobs`, so a capture missing from one is found in the other (MEMNG-951).
    public private(set) var resolvedMemos: [UUID: String] = [:]
    /// When each job's CONFIRMED bytes last changed, by job id.
    ///
    /// In memory and never a manifest field: it is a fact about what this device has SEEN, and
    /// writing it down would rewrite every manifest on every sighting. An attempt that failed and
    /// a retry that moved nothing are not progress — a stalled upload that keeps being tried has
    /// confirmed no byte since, and that is the whole fact this instant is kept for.
    public private(set) var lastProgressAt: [UUID: Date] = [:]

    /// What each job's confirmed bytes were at the last sighting, so the instant above moves only
    /// when the number does.
    private var confirmedBytesSeen: [UUID: Int64] = [:]

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

    /// Whether the queue may send right now, and why not. Recomputed on the two events that can
    /// change the answer — the network moving and the toggle — never polled.
    public private(set) var uploadVerdict: UploadVerdict = .permitted

    /// The queue as the transfers strip and sheet show it, fed every read `refresh` applies under
    /// that read's ticket, so a read that began earlier and answered later is refused there.
    public let transfers: TransferLedger

    /// Run, in the order they were added, after every read of the queue `refresh` applied —
    /// synchronously, with `jobs`, `resolvedMemos` and `transfers` already holding that read, so
    /// an observer judges the read that was just taken and never a later one.
    @ObservationIgnored private var refreshObservers: [@MainActor () -> Void] = []

    public func onRefresh(_ observer: @escaping @MainActor () -> Void) {
        refreshObservers.append(observer)
    }

    private let repository: OutboxRepository
    public let shareSessions: ShareSessions?
    private let credentials: any OutboxCredentialsProviding
    private let network: any NetworkPathProviding
    private let engine: OutboxEngine
    private let changes: OutboxChangeBox
    private let attachScheduler: (@Sendable (any OutboxChunkHandling) async -> Void)?
    /// The whole lane's session, attached beside the chunk lane's in `adopt()`.
    private let uploads: (any OutboxUploadScheduling)?
    /// What the app feeds: open while it is active, closed otherwise (`appBecameActive`).
    private let schedulingGate: SchedulingGate
    /// The lane that copies picked items still in Photos into their captures (MEMNG-952); nil
    /// where nothing can read the library. The app's `BGProcessingTask` drives it through here.
    public let staging: StagingLane?
    /// The adoption in flight, or the one that finished. It replaces an `isStarted` flag, which
    /// was set BEFORE the attachment was awaited: a second caller arriving inside that await saw
    /// the flag, skipped adoption and drained beside the replay. The two are not siblings, so the
    /// engine's own `isDraining` cannot exclude them from each other, and the interleaving loses a
    /// cursor. Held for the life of the process, because adoption happens once.
    private var adoption: Task<Void, Never>?
    /// A withdrawal the disk refused to record, whose cancellation only this process can issue.
    private var unrecordedWithdrawal: OutboxWithdrawal?

    /// The edits a re-submit is writing or has written, one entry per call, held apart from `jobs`
    /// because `jobs` is a snapshot of disk that trails every write by a read (`editOwed`). An entry
    /// is put down synchronously when a re-submit begins, before anything suspends; it is dropped
    /// only by a successful read of the queue that began after the re-submit's own write had
    /// returned and that shows the job gone or its edit sent — or at once, when the re-submit ended
    /// without writing anything.
    private var owedEdits: [UUID: OwedEdit] = [:]
    /// Reads of the queue begun so far; each read's ticket is the count when it began.
    private var queueReadsBegun = 0
    /// The ticket of the newest read that succeeded, and of the newest one that failed.
    private var queueReadSucceeded = 0
    private var queueReadFailed = 0
    /// Awaited by `resubmit` between its write and its read back. Nil in the app; a test holds the
    /// re-submit there to ask the outbox inside that window.
    var resubmitWrote: (@MainActor () async -> Void)?

    /// The app's subsystem, spelled out: this package depends on nothing, `MemosLog` included.
    private static let log = Logger(subsystem: "live.discomarder.memosng", category: "outbox")

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
        attachScheduler: (@Sendable (any OutboxChunkHandling) async -> Void)? = nil,
        // Open unless something feeds it; the engine's sends of new work ask it (`SchedulingGate`).
        schedulingGate: SchedulingGate = SchedulingGate(),
        // The whole lane. Without one no capture is ever put on it (`OutboxEngine`).
        uploads: (any OutboxUploadScheduling)? = nil,
        // The share extension's sessions. A capture one of them carries is left to it.
        shareSessions: ShareSessions? = nil,
        // The library picked items are copied from. Without one no item stays in Photos.
        photos: (any PhotoLibrarySource)? = nil
    ) {
        self.shareSessions = shareSessions
        self.attachScheduler = attachScheduler
        self.uploads = uploads
        self.schedulingGate = schedulingGate
        let changes = OutboxChangeBox()
        self.changes = changes
        self.repository = repository
        self.credentials = credentials
        self.network = network
        self.uploadPreferences = preferences
        self.transfers = TransferLedger(clock: clock)
        self.staging = photos.map {
            StagingLane(repository: repository, library: $0, onChange: { await changes.fire() })
        }
        self.engine = OutboxEngine(
            repository: repository,
            credentials: credentials,
            http: http,
            scheduler: scheduler,
            completion: completion,
            network: network,
            preferences: preferences,
            clock: clock,
            onChange: { await changes.fire() },
            schedulingGate: schedulingGate,
            uploads: uploads,
            carriedElsewhere: { [registry = shareSessions?.registry] jobID in
                registry?.carries(jobID: jobID) ?? false
            }
        )
        changes.attach { [weak self] in await self?.refresh() }
        // The two events that can make a held capture sendable, wired to the only thing that can
        // act on them. A job put down for the wrong network has to move when the network changes
        // or when the person changes their mind — waiting for the next launch would make the
        // toggle a promise the app keeps tomorrow.
        network.onPathChange { [weak self] in await self?.reconsiderUploads() }
        preferences.onChange { [weak self] in await self?.reconsiderUploads() }
        preferences.onChangeNow { [weak self] in self?.refreshUploadVerdict() }
        uploadVerdict = UploadVerdict(
            policy: UploadNetworkPolicy(allowsMobileData: preferences.allowsMobileData),
            path: network.currentPath()
        )
    }

    /// The composed outbox: the app group's container, both background sessions, and the live
    /// completion path. Falls back to the app's own container when the app group is unreachable —
    /// a missing entitlement must degrade to "queues locally", never to "loses the capture".
    public static func live(
        appGroup: String = OutboxDefaults.appGroup,
        credentials: any OutboxCredentialsProviding,
        shareEventsFinished: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> Outbox {
        let root =
            OutboxRepository.appGroupRoot(appGroup: appGroup)
            ?? URL.applicationSupportDirectory.appending(path: "outbox")
        // The predicate the repository decides a refusal under, threaded from the one provider
        // this outbox drains as. Defaulting it here would leave every hold decided as if nothing
        // ever moved, which is the fence's whole subject (`OutboxPersisting`).
        let repository = try OutboxRepository(
            root: root, stillCurrent: { credentials.stillCurrent(epoch: $0) }
        )
        // Both sessions are created HERE, synchronously, while the app is still launching: the
        // system delivers a finished task's answer to whichever session in the process carries its
        // identifier, and one that finds none is not delivered at all.
        let scheduler = BackgroundChunkScheduler(appGroup: appGroup)
        return composed(
            repository: repository,
            credentials: credentials,
            http: URLSessionHTTPPerformer(),
            chunks: scheduler,
            attachChunks: { handler in await scheduler.attach(handler) },
            uploads: BackgroundUploadScheduler(appGroup: appGroup),
            network: NetworkPathMonitor(),
            preferences: UploadPreferences.live(appGroup: appGroup),
            shareSessions: ShareSessions(registry: SessionRegistry(root: root)) { identifier in
                URLSessionUploadTaskSession(
                    session: URLSession(
                        configuration: ShareSession.backgroundConfiguration(
                            identifier: identifier, appGroup: appGroup),
                        delegate: ShareSessionEvents(finished: shareEventsFinished),
                        delegateQueue: nil))
            },
            photos: Self.livePhotos
        )
    }

    #if os(iOS)
    private static var livePhotos: (any PhotoLibrarySource)? { PhotoKitLibrary() }
    #else
    private static var livePhotos: (any PhotoLibrarySource)? { nil }
    #endif

    /// What `live` composes, over whichever sessions it is handed — so a test composes the same
    /// outbox over scripted ones.
    ///
    /// The whole lane is not optional here: this is the composition that puts new captures on it.
    /// The scheduling gate starts CLOSED, because a process is launched before it is active — and
    /// may never become active, when the system launched it only to deliver an answer — and new
    /// work waits for `appBecameActive`.
    public static func composed(
        repository: OutboxRepository,
        credentials: any OutboxCredentialsProviding,
        http: any OutboxHTTPPerforming,
        chunks: any OutboxChunkScheduling,
        attachChunks: @escaping @Sendable (any OutboxChunkHandling) async -> Void,
        uploads: any OutboxUploadScheduling,
        network: any NetworkPathProviding,
        preferences: UploadPreferences,
        shareSessions: ShareSessions? = nil,
        photos: (any PhotoLibrarySource)? = nil
    ) -> Outbox {
        Outbox(
            repository: repository,
            credentials: credentials,
            http: http,
            scheduler: chunks,
            completion: MemoCompletionEndpoint(http: http),
            network: network,
            preferences: preferences,
            attachScheduler: attachChunks,
            schedulingGate: SchedulingGate(isOpen: false),
            uploads: uploads,
            shareSessions: shareSessions,
            photos: photos
        )
    }

    /// The guest outbox: a trip pass's captures, in a queue of their own.
    ///
    /// Its own directory, its own background session and its own provider, so a member engine
    /// never sees a guest job and the two credentials' epochs never meet. The whole lane is left
    /// out: the guest door has no whole-upload route, so every capture goes in chunks, each held
    /// to the door's ceiling by the planner. The completion is the door's batch, never a memo.
    public static func guestLive(
        appGroup: String = OutboxDefaults.appGroup,
        credentials: any OutboxCredentialsProviding
    ) throws -> Outbox {
        let root =
            OutboxRepository.guestAppGroupRoot(appGroup: appGroup)
            ?? URL.applicationSupportDirectory.appending(path: "guest-outbox")
        let repository = try OutboxRepository(
            root: root, stillCurrent: { credentials.stillCurrent(epoch: $0) }
        )
        // Created HERE, synchronously, for the reason `live` creates its own: a finished guest
        // chunk is delivered only to a session in the process that already carries its identifier.
        let scheduler = BackgroundChunkScheduler(
            appGroup: appGroup, identifier: OutboxSession.guestIdentifier
        )
        return guestComposed(
            repository: repository,
            credentials: credentials,
            http: URLSessionHTTPPerformer(),
            chunks: scheduler,
            attachChunks: { handler in await scheduler.attach(handler) },
            network: NetworkPathMonitor(),
            preferences: UploadPreferences.live(appGroup: appGroup)
        )
    }

    /// What `guestLive` composes, over whichever sessions it is handed. No whole lane, and the
    /// door's completion: the guest routes are the only ones this outbox can reach.
    public static func guestComposed(
        repository: OutboxRepository,
        credentials: any OutboxCredentialsProviding,
        http: any OutboxHTTPPerforming,
        chunks: any OutboxChunkScheduling,
        attachChunks: @escaping @Sendable (any OutboxChunkHandling) async -> Void,
        network: any NetworkPathProviding,
        preferences: UploadPreferences
    ) -> Outbox {
        Outbox(
            repository: repository,
            credentials: credentials,
            http: http,
            scheduler: chunks,
            completion: GuestCompletionEndpoint(http: http),
            network: network,
            preferences: preferences,
            attachScheduler: attachChunks,
            schedulingGate: SchedulingGate(isOpen: false),
            uploads: nil
        )
    }

    /// Attaches to every share session the extension registered, reconciles them, and retires the
    /// ones nothing needs — so a capture they carried is the drain's again. Asked on every wake
    /// and every return to the front: the system's wake for a finished share session is not
    /// promised, and a capture must not wait for one.
    @discardableResult
    public func reattachShareSessions() async -> [String: ShareSessionVerdict] {
        guard let shareSessions else { return [:] }
        return await shareSessions.wake(repository: repository)
    }

    /// The app is in front of someone: new work may start again, and what waited for this — a
    /// capture queued while the app was away, bytes a wake banked — is looked at now.
    ///
    /// The gate opens synchronously, before this returns, so it can never land after an
    /// `appEnteredBackground` that followed it. The drain is the returned task.
    @discardableResult
    public func appBecameActive() -> Task<Void, Never> {
        schedulingGate.open()
        return Task {
            await reattachShareSessions()
            await drain()
            // Access the person may have just allowed in Settings reaches the items left in Photos.
            await stageFromPhotos(mayPrompt: false)
        }
    }

    /// Copies every capture's items still in Photos into it (MEMNG-952), then drains what that
    /// brought. `mayPrompt` asks for Photos access when nobody has yet — only where a person is
    /// looking, never from a background task.
    @discardableResult
    public func stageFromPhotos(mayPrompt: Bool) async -> StagingPass? {
        guard let staging else { return nil }
        await adopted()
        let pass = await staging.drain(mayPrompt: mayPrompt)
        await refresh()
        if pass.staged > 0 { await drainAfterAdoption() }
        return pass
    }

    /// The app left the foreground: nothing new starts until it is back. What is already with the
    /// system goes on, and a finished capture's memo create still goes (decision 9).
    public func appEnteredBackground() {
        schedulingGate.close()
    }

    /// Runs a background wake and leaves it only once the engine is QUIESCENT, not merely once
    /// `start` returns.
    ///
    /// `start` can return at once while a drain another entry point began — a confirmation's, say —
    /// still owns a memo create: a second drain folds into the running one and returns. Leaving on
    /// `start` alone would answer the system with that create still out.
    public func wake(holding work: WakeWork, _ start: @MainActor () async -> Void) async {
        await start()
        await engine.untilQuiescent()
        work.leave()
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
        let work = Task { @MainActor [self] in
            _ = await attachScheduler?(engine)
            await uploads?.attach(engine)
            // A capture an editor of a launch that has since died was still bringing files into:
            // nothing more will arrive, so it is let go with what it holds before any drain.
            _ = try? await repository.releaseStaging(leftOverBefore: launch)
            // A withdrawal whose cancellation the last process never issued, issued now — in
            // every launch, whether or not anyone is signed in to drain with — and before any
            // drain, which waits for this adoption.
            await finishWithdrawal()
        }
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
        queueReadsBegun += 1
        let ticket = queueReadsBegun
        do {
            let loaded = try await repository.loadJobs()
            // After the jobs, never before: the engine notes a resolution before the job leaves
            // the disk, so a read that misses the job finds the memo it became.
            let resolved = await engine.resolvedMemos
            jobs = loaded
            resolvedMemos = resolved
            noteProgress(in: loaded)
            transfers.apply(loaded, generation: ticket)
            queueError = nil
            queueReadSucceeded = max(queueReadSucceeded, ticket)
            owedEdits = owedEdits.compactMapValues { owed -> OwedEdit? in
                // Only a read that began after the write returned can say the edit is not owed, or
                // say what memo and pictures the capture has resolved to since.
                guard let wrote = owed.wroteBefore, ticket > wrote else { return owed }
                let job = loaded.first { $0.id == owed.jobID }
                guard let job, job.pendingEdit != nil else { return nil }
                var rebound = owed
                rebound.bind(job)
                return rebound
            }
            if OutboxProgress.didComplete(previous: previous, current: loaded.map(\.id)) {
                lastCompletedAt = Date()
            }
            for observer in refreshObservers { observer() }
        } catch {
            // A queue that could not be read is NOT an empty queue. What is on screen stays on
            // screen, and the reason it could not be re-read is said out loud.
            queueError =
                "The queue on this device could not be read: \(error.localizedDescription)"
            queueReadFailed = max(queueReadFailed, ticket)
        }
        persistenceError = await engine.lastPersistenceFailure
    }

    /// Whether the memo `memoUID`, or the one holding the picture `attachmentUID`, is owed an edit
    /// this device has still to send — answered synchronously, from this outbox's own state, for an
    /// Add to trip that must not tag a memo an owed full-content edit would then rewrite
    /// (MEMNG-788).
    ///
    /// `jobs` alone cannot answer it: it is the queue as last read, and a re-submit's edit is on
    /// disk one read before it is in `jobs` — for ever, when that read fails. So an edit is owed
    /// from the instant its re-submit begins until a read begun after its write shows it sent, and
    /// the answer is `unknown` whenever the queue is not known as read: before the first read
    /// succeeds, after a failed one until a later one succeeds, and while a re-submit has not yet
    /// found the capture it edits. Nothing else writes an edit; the drain only sends them, so what
    /// it changes between two reads errs towards holding a picture, never towards tagging one.
    ///
    /// Nor can an owed edit whose capture has not resolved be told apart from the memo asked
    /// about: the server can show that memo and its picture before a read of the queue has brought
    /// back the uids its create resolved to. So such an edit answers `unknown` for every memo it
    /// cannot exclude, marked or read from disk, until a read shows it resolved.
    public func editOwed(memoUID: String?, attachmentUID: String) -> OutboxEditAnswer {
        guard queueReadSucceeded > queueReadFailed else { return .unknown }
        let marked: [OwedEdit.Binding?] = owedEdits.values.map(\.binding)
        let queued: [OwedEdit.Binding?] = jobs.filter { $0.pendingEdit != nil }.map {
            OwedEdit.Binding($0)
        }
        var answer = OutboxEditAnswer.clear
        for binding in marked + queued {
            switch binding?.answer(memoUID: memoUID, attachmentUID: attachmentUID) ?? .unknown {
            case .owed: return .owed
            case .unknown: answer = .unknown
            case .clear: break
            }
        }
        return answer
    }

    /// Whether a job of `jobs` owes an edit to the memo `memoUID`, or to the memo holding
    /// `attachmentUID`: a capture whose editor's later changes are still to be sent.
    public nonisolated static func owesEdit(
        in jobs: [UploadJob], memoUID: String?, attachmentUID: String
    ) -> Bool {
        jobs.contains { job in
            guard job.pendingEdit != nil else { return false }
            if let memoUID, job.resolvedMemoUID == memoUID { return true }
            return job.files.contains { $0.attachmentUID == attachmentUID }
        }
    }

    /// Recomputed wherever `jobs` is reassigned, from the jobs themselves: a job seen for the
    /// first time starts its instant now, one whose confirmed bytes are unchanged keeps the
    /// instant it had, and one that has left the queue keeps nothing.
    private func noteProgress(in loaded: [UploadJob]) {
        let now = Date()
        var seen: [UUID: Int64] = [:]
        var stamps: [UUID: Date] = [:]
        for job in loaded {
            let bytes = job.confirmedBytes
            seen[job.id] = bytes
            if confirmedBytesSeen[job.id] == bytes, let previous = lastProgressAt[job.id] {
                stamps[job.id] = previous
            } else {
                stamps[job.id] = now
            }
        }
        confirmedBytesSeen = seen
        lastProgressAt = stamps
    }

    /// Where a queued capture's first original actually is, so a row can show it without the view
    /// knowing anything about the container it lives in.
    public func mediaURL(for job: UploadJob) -> URL? {
        guard let file = job.files.first else { return nil }
        return repository.mediaURL(job: job, file: file)
    }

    /// The two events that can change the answer, answered once: what the queue may do now, and
    /// then the drain that acts on it. `NetworkPathProviding` and `UploadPreferences` each hold
    /// exactly ONE handler, so this is the registration the drain already had, not a second
    /// observer beside it.
    private func reconsiderUploads() async {
        refreshUploadVerdict()
        await drain()
    }

    /// What the queue says it is waiting for, recomputed from the choice and the path as they are
    /// now — the half of `reconsiderUploads` that needs no drain, and the one a preference change
    /// arriving through `UploadPreferences.apply` is answered with before the foreground drains.
    private func refreshUploadVerdict() {
        uploadVerdict = UploadVerdict(
            policy: UploadNetworkPolicy(allowsMobileData: uploadPreferences.allowsMobileData),
            path: network.currentPath()
        )
    }

    public func drain() async {
        await drainAfterAdoption()
    }

    /// Writes a capture to disk and only then tries the network. The return value says whether it
    /// was PERSISTED, not whether it was sent: the compose screen closes on the former.
    ///
    /// `account` is the account the caller read something account-scoped under — the visibility
    /// "Default" resolved to. The credentials are acquired after a hop, so a different account can
    /// be current by then, and its grant passes every check below: the authority fences the GRANT,
    /// not what the caller read. A capture is therefore refused, before any file is copied, when
    /// the account it would be bound to is not the one it was composed under.
    @discardableResult
    public func enqueue(
        content: String,
        visibility: String?,
        capturedAt: Date = Date(),
        sources: [StagedSource],
        composedUnder account: AccountBinding? = nil
    ) async -> Bool {
        await enqueueJob(
            content: content, visibility: visibility, capturedAt: capturedAt, sources: sources,
            composedUnder: account, stagingLaunch: nil
        ) != nil
    }

    /// `enqueue`, for a capture Post took while some of its files were still loading (MEMNG-951):
    /// the files that ARE here are copied and the capture is written now — so the editor can
    /// close — marked as still arriving from this launch, which keeps its create back until the
    /// editor lets it go (`release`). `arriving` is how many picked items are still loading; each
    /// `append` counts one off, and what is left at the release is what the card names as missing.
    /// Answers the job's id, which is what the late files are appended to, or nil exactly where
    /// `enqueue` answers false.
    public func stage(
        content: String,
        visibility: String?,
        capturedAt: Date = Date(),
        sources: [StagedSource],
        arriving: Int = 0,
        inPhotos: [StagingFile] = [],
        composedUnder account: AccountBinding? = nil
    ) async -> UUID? {
        // Items named only in Photos need a lane to copy them; without one they are not taken
        // into a capture that would wait for them for ever.
        let inPhotos = staging == nil ? [] : inPhotos
        let job = await enqueueJob(
            content: content, visibility: visibility, capturedAt: capturedAt, sources: sources,
            composedUnder: account, stagingLaunch: launch, arriving: arriving, inPhotos: inPhotos
        )
        if job != nil, !inPhotos.isEmpty {
            // Post is where a person is looking: the one Photos access prompt may be shown here.
            Task { await self.stageFromPhotos(mayPrompt: true) }
        }
        return job?.id
    }

    /// This process's launch: what a capture still taking files is marked with, so the next
    /// launch can tell a mark nobody will ever clear from one an editor here still holds.
    private var launch: UUID { uploads?.launch ?? OutboxUploadSession.processLaunch }

    /// Adds a file that landed after Post to the capture it was picked for. False when the capture
    /// no longer takes files — let go, taken back, or gone — or the copy failed; what the capture
    /// already holds is untouched either way (`OutboxRepository.append`).
    public func append(_ sources: [StagedSource], to jobID: UUID) async -> Bool {
        let appended =
            (try? await repository.append(sources, to: jobID, arrivingFrom: launch)) ?? nil
        await refresh()
        guard appended != nil else { return false }
        await drainAfterAdoption()
        return true
    }

    /// The editor is done bringing files into this capture: the last landed or failed, or its time
    /// ran out. The create may go once what is here is up.
    public func release(_ jobID: UUID) async {
        _ = try? await repository.releaseStaging(jobID, arrivingFrom: launch)
        await refresh()
        await drainAfterAdoption()
    }

    /// Removes a capture that has not become a memo — "Remove" on its card.
    ///
    /// Refused while the create may be on the wire or has been answered: the server may then hold
    /// the memo, and a card removed here would come back with the next read of the list. So the
    /// refusal is the state the capture is in, read and fenced in the same write that marks it:
    /// a pass that claimed the create first makes this write lose, and nothing is removed.
    public func withdraw(_ jobID: UUID) async -> Bool {
        guard let snapshot = await repository.job(jobID), !snapshot.createMayHaveBeenSent,
            snapshot.editUnansweredSince == nil
        else { return false }
        let taken = snapshot.cancelled(at: Date())
        let written = try? await repository.save(
            taken, ifStillCurrent: nil, matching: snapshot, else: taken
        )
        guard let landed = written ?? nil else {
            await refresh()
            return false
        }
        await engine.abandonTasks(jobID: jobID)
        // The delete is fenced on the row this call wrote, and the hop above is an instant for
        // another write to land in. Losing it leaves a cancelled capture on disk, so the answer is
        // the delete's: a card hidden over a row that is still there would come back next launch.
        let removed = await repository.delete(landed, ifStillCurrent: landed)
        await refresh()
        return removed
    }

    private func enqueueJob(
        content: String,
        visibility: String?,
        capturedAt: Date,
        sources: [StagedSource],
        composedUnder account: AccountBinding?,
        stagingLaunch: UUID?,
        arriving: Int = 0,
        inPhotos: [StagingFile] = []
    ) async -> UploadJob? {
        guard let credentials = await credentials.currentCredentials(),
            self.credentials.isCurrent(credentials)
        else {
            enqueueError = "Sign in before writing a memo."
            lastEnqueueFailure = .notSignedIn
            return nil
        }
        // The same answer a grant withdrawn during the copy gets below: the session this capture
        // was written in is not the one that would send it.
        if let account, account != credentials.binding {
            enqueueError = "Sign in before writing a memo."
            lastEnqueueFailure = .notSignedIn
            return nil
        }
        // The binding stamped on the job decides whose account this capture is ever sent into, and
        // the repository copies every file before it commits one. So the authority travels INTO
        // that actor and is asked again immediately before the commit, rather than only here.
        let authority = self.credentials
        let job: UploadJob
        do {
            job = try await repository.enqueue(
                content: content,
                visibility: visibility,
                capturedAt: capturedAt,
                binding: credentials.binding,
                sources: sources,
                stagingLaunch: stagingLaunch,
                arriving: arriving,
                staging: inPhotos,
                under: SendAuthority { authority.isCurrent(credentials) }
            )
            enqueueError = nil
            lastEnqueueFailure = nil
        } catch is SendAuthorityWithdrawn {
            enqueueError = "Sign in before writing a memo."
            lastEnqueueFailure = .notSignedIn
            return nil
        } catch {
            enqueueError =
                "This memo could not be saved on the device: \(error.localizedDescription)"
            lastEnqueueFailure = .storage
            return nil
        }
        await refresh()
        Task { await self.drainAfterAdoption() }
        return job
    }

    /// Clears a hold and tries again — the "Try again" a stuck pending row offers.
    public func retry(_ jobID: UUID) async {
        await engine.release(jobID: jobID)
        await refresh()
        await drainAfterAdoption()
    }

    /// Takes a capture out of the queue and hands it back to the editor.
    ///
    /// The manifest is NOT destroyed. It carries the idempotency key and the account this capture
    /// was made under, and a re-submit that did not present both would make a second memo out of a
    /// create that already committed. Nothing local is removed either: the pictures handed back are
    /// the job's own copies, which the sweep keeps while the job is on disk.
    ///
    /// The write is fenced on the manifest this call read, so a pass that advanced or finished the
    /// capture inside that read wins and nothing is handed back. A capture is taken back or it is
    /// finished, never both. It is REFUSED outright while an edit of it is on the wire: the body
    /// the server is answering about cannot be edited under it, so the answer is waited for and
    /// the person may take the capture back after it — nothing is written by the refusal.
    ///
    /// Refused too while files are still arriving (MEMNG-951): the editor would reopen on what has
    /// landed so far, and every late file would then be refused by the capture it was picked for —
    /// a picture gone in silence. The write below is fenced on this snapshot, and a capture never
    /// goes back to arriving, so one read as let go is still let go when the mark lands.
    ///
    /// Refused for a capture with nothing to send (MEMNG-1049): the draft would be empty, and the
    /// only re-post it could lead to is one `resubmit` refuses. The row offers Remove alone; this
    /// is the guard, the row is the sentence.
    public func cancel(_ jobID: UUID) async -> RestoredDraft? {
        guard let snapshot = await repository.job(jobID) else { return nil }
        guard snapshot.editUnansweredSince == nil, !snapshot.stillArriving,
            !snapshot.hasNothingToSend
        else { return nil }
        let taken = snapshot.cancelled(at: Date())
        let written = try? await repository.save(
            taken, ifStillCurrent: nil, matching: snapshot, else: taken
        )
        await refresh()
        guard let landed = written ?? nil else { return nil }
        // After the mark landed, never before: a task torn down on a write that lost its fence
        // would leave a live job whose transfer nobody is running.
        await engine.abandonTasks(jobID: jobID)
        return draft(of: landed)
    }

    /// An account's grant was withdrawn — a sign-out, with or without the revoke, or another
    /// account signing in over it — at this authority epoch: written down before this returns.
    ///
    /// Synchronous, because the caller is the epoch move itself and nothing may be awaited there,
    /// and on disk, because the cancellation it owes is issued later by a process the system may
    /// terminate first. `finishWithdrawal` issues it; a record left by a process that died first
    /// is issued by the next launch's adoption.
    public func recordWithdrawal(at epoch: Int) {
        let launch = uploads?.launch ?? OutboxUploadSession.processLaunch
        let withdrawal = OutboxWithdrawal(launch: launch, epoch: epoch)
        guard !repository.withdrawals.record(withdrawal) else { return }
        // The disk refused it, so no later launch will issue this cancel: this process still can,
        // and `finishWithdrawal` must have something to issue it from.
        unrecordedWithdrawal = withdrawal
        Self.log.error("A withdrawal at epoch \(epoch) could not be recorded; cancelling live only")
    }

    /// Cancels every task of both sessions the recorded withdrawal covers, and the one the disk
    /// refused, and only once that cancellation has been issued clears each — unless a later
    /// withdrawal replaced it meanwhile, which is left for its own.
    ///
    /// Both, never the newer of the two: epochs start again in every launch, so an older launch's
    /// record and this one's cannot be ordered, and each covers tasks the other does not. The
    /// older record is cleared too, or the next launch would issue it over this launch's uploads.
    public func finishWithdrawal() async {
        let recorded = repository.withdrawals.pending()
        let unrecorded = unrecordedWithdrawal
        if let recorded { await engine.abandonAllTasks(covering: recorded) }
        if let unrecorded { await engine.abandonAllTasks(covering: unrecorded) }
        if let recorded { repository.withdrawals.clear(recorded) }
        if let unrecorded, unrecordedWithdrawal == unrecorded { unrecordedWithdrawal = nil }
    }

    /// Sends a restored draft again, on the SAME manifest.
    ///
    /// The key and the account binding travel by identity rather than being stamped afresh — which
    /// is what makes a re-submit of a create that already committed resolve to the memo it made
    /// instead of a second one — and an account that no longer matches becomes the mismatch hold
    /// that already exists, never a silent re-bind. An edit is recorded rather than applied to the
    /// capture: the create is replayed as it was first sent, and the edit is owed to the memo that
    /// replay resolves to.
    public func resubmit(_ jobID: UUID, draft: RestoredDraft) async -> ResubmitOutcome {
        // The edit is owed from this instant, before anything suspends: an Add to trip asked while
        // it is being written must not read the snapshot from before it (`editOwed`).
        let call = UUID()
        owedEdits[call] = OwedEdit(jobID: jobID, job: jobs.first { $0.id == jobID })
        // Absent, unreadable and present are three answers, not two: a capture whose manifest
        // could not be read is still there, and answering `vanished` for it would hand the editor
        // a fresh enqueue — a second memo for one capture.
        let snapshot: UploadJob
        switch await repository.presence(jobID) {
        case .present(let job):
            snapshot = job
        case .absent:
            owedEdits[call] = nil
            return .vanished
        case .unreadable:
            owedEdits[call] = nil
            return .refused(.captureUnreadable)
        }
        owedEdits[call]?.bind(snapshot)
        // An edit of this capture is claimed: its body cannot be replaced under the server's feet,
        // and a new key over uploads the previous edit consumed is a memo the server refuses.
        guard snapshot.editUnansweredSince == nil else {
            owedEdits[call] = nil
            return .refused(.editUnanswered)
        }
        // A capture with nothing in it is never sent again: its create would replay an empty
        // body, and a picture picked for it would ride an edit of a memo that never comes. The
        // write below is fenced on this snapshot, so the answer stands for the row it writes.
        guard !snapshot.hasNothingToSend else {
            owedEdits[call] = nil
            return .refused(.nothingToSend)
        }
        var candidate = snapshot.released(at: Date())
        // What did not arrive was said on the card the person has just answered by re-posting;
        // whatever they added back is in this draft, so the note would now be wrong.
        candidate.notArrived = nil
        if draft != self.draft(of: snapshot) {
            let known = Set(snapshot.files.map(\.id))
            for picture in draft.pictures where !known.contains(picture.id) {
                // A picture picked while the capture was in the editor is not in the job's media
                // directory yet, and a manifest naming a file whose bytes are not there is the one
                // state a relaunch cannot recover from. So it is copied BEFORE anything is written
                // down, and a copy that fails refuses the re-submit rather than recording a
                // picture nothing holds.
                guard let staged = stage(picture, into: snapshot) else {
                    owedEdits[call] = nil
                    return .refused(.stagingFailed)
                }
                candidate.files.append(staged)
            }
            candidate.pendingEdit = PendingEdit(
                content: draft.content,
                visibility: draft.visibility,
                capturedAt: draft.capturedAt,
                fileIDs: draft.pictures.map(\.id)
            )
            // A different body is a different edit, and it is applied under its own key: reusing
            // the key of an edit the server already applied would make this one a replay of that
            // one and change nothing. Written here, so the key is on disk before the pass that
            // sends it — a re-submit of the SAME draft never reaches this and keeps its key.
            candidate.editKey = UUID().uuidString
        }
        // Making a retained original nameable again is NOT done here. It happens on the one path
        // that reaches the wire, where the create has resolved and the uid is real; doing it here
        // as well would re-stage against a binding the replay has not saved yet.
        // The cancelled transfers are superseded before the replacement can be scheduled — the same
        // bump Try again performs — so the abandoned task's late answer fails the attempt guard.
        candidate = candidate.bumpingAttempts().job
        let written = try? await repository.save(
            candidate, ifStillCurrent: nil, matching: snapshot, else: candidate
        )
        // From here a read of the queue tells the truth about this edit, written or not.
        owedEdits[call]?.wroteBefore = queueReadsBegun
        if let resubmitWrote { await resubmitWrote() }
        await refresh()
        guard (written ?? nil) != nil else { return .refused(.writeLost) }
        await drainAfterAdoption()
        return .accepted
    }

    /// Copies a newly picked picture into the job's own media directory, as a file the create
    /// deliberately does not name: the create is replayed exactly as it was first sent, and this
    /// picture reaches the memo through the edit instead.
    ///
    /// It keeps the id the editor gave it, because that id is what the pending edit's ordered
    /// picture list names it by.
    private func stage(_ picture: RestoredDraft.Picture, into job: UploadJob) -> OutboxFile? {
        let suffix = picture.url.pathExtension
        let storedName =
            suffix.isEmpty ? picture.id.uuidString : "\(picture.id.uuidString).\(suffix)"
        var file = OutboxFile(
            id: picture.id,
            relativePath: storedName,
            filename: picture.filename,
            mime: picture.mime,
            byteSize: 0,
            stagedForEdit: true
        )
        let destination = repository.mediaURL(job: job, file: file)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: picture.url, to: destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            file.byteSize = Int64(values.fileSize ?? 0)
            return file
        } catch {
            return nil
        }
    }

    /// The capture as it now stands, which is the edit when one is pending: an edit taken while
    /// the create was in flight is what the person last left, and handing back the create's body
    /// instead would lose it the moment the capture is taken back a second time. The pictures are
    /// the edit's own list, in its order — one it removed is gone, one it staged is here.
    private func draft(of job: UploadJob) -> RestoredDraft {
        let content: String
        let visibility: String?
        let capturedAt: Date
        let pictures: [OutboxFile]
        if let edit = job.pendingEdit {
            content = edit.content
            visibility = edit.visibility
            capturedAt = edit.capturedAt
            pictures = edit.fileIDs.compactMap { id in job.files.first { $0.id == id } }
        } else {
            content = job.content
            visibility = job.visibility
            capturedAt = job.capturedAt
            pictures = job.files
        }
        return RestoredDraft(
            jobID: job.id,
            content: content,
            visibility: visibility,
            capturedAt: capturedAt,
            pictures: pictures.map {
                RestoredDraft.Picture(
                    id: $0.id,
                    url: repository.mediaURL(job: job, file: $0),
                    filename: $0.filename,
                    mime: $0.mime
                )
            }
        )
    }

    /// Changes who a pending capture will be visible to: the visibility menu on its pending card
    /// and in the Transfers sheet (MEMNG-971).
    ///
    /// The rule is the repository's and it is one write (`OutboxRepository.setVisibility`); this
    /// reads the queue again and, when the change is owed to a memo the create may already have
    /// made, drains so that the edit goes. A write the disk or the lock refused changed nothing,
    /// and is answered as the refusal it is — the menu then shows what the manifest still says.
    @discardableResult
    public func setVisibility(
        _ visibility: String, of jobID: UUID
    ) async -> OutboxRepository.VisibilityWrite {
        let written: OutboxRepository.VisibilityWrite
        do {
            written = try await repository.setVisibility(visibility, of: jobID)
        } catch {
            Self.log.error(
                "A visibility change could not be written: \(error.localizedDescription)")
            written = .refused
        }
        await refresh()
        if written == .owedAsEdit { await drainAfterAdoption() }
        return written
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

/// A capture handed back to the editor: the memo as it was captured, and the originals where the
/// job already holds them.
///
/// Nothing here is a copy and nothing was removed to produce it. It is a MemosOutbox value on
/// purpose: this package cannot see the editor's own picture type, so the editor maps this into
/// whatever it composes with.
public struct RestoredDraft: Sendable, Equatable {
    public struct Picture: Sendable, Equatable {
        /// The file this picture is, so a re-submit can say which pictures the memo keeps and in
        /// what order without the editor having to name them by path.
        public var id: UUID
        public var url: URL
        public var filename: String
        public var mime: String

        public init(id: UUID, url: URL, filename: String, mime: String) {
            self.id = id
            self.url = url
            self.filename = filename
            self.mime = mime
        }
    }

    public var jobID: UUID
    public var content: String
    public var visibility: String?
    public var capturedAt: Date
    public var pictures: [Picture]

    public init(
        jobID: UUID,
        content: String,
        visibility: String?,
        capturedAt: Date,
        pictures: [Picture]
    ) {
        self.jobID = jobID
        self.content = content
        self.visibility = visibility
        self.capturedAt = capturedAt
        self.pictures = pictures
    }
}

/// How a re-submit ended. Never a Bool: "the job is gone" and "the fenced write lost" are opposite
/// instructions to the editor. Each refusal below has its own sentence on the screen.
public enum ResubmitOutcome: Sendable, Equatable {
    case accepted
    /// Nothing stands under that id, and neither the queue nor the quarantine holds a manifest
    /// for it — a fresh enqueue is the answer.
    case vanished
    /// The job stands and holds the draft; the editor keeps it.
    case refused(ResubmitRefusal)
}

/// Why a re-submit left the capture where it was.
public enum ResubmitRefusal: Sendable, Equatable {
    /// A picture picked in the editor could not be copied in.
    case stagingFailed
    /// The fenced manifest write did not land.
    case writeLost
    /// A change is claimed and unanswered; its body is immutable until the server settles it.
    case editUnanswered
    /// A retained original is no longer readable on this device.
    case pictureMissing(filename: String)
    /// The capture's manifest could not be read just now. Absent is not the same as unreadable:
    /// a re-submit answered `vanished` here would enqueue a second memo for the same capture.
    case captureUnreadable
    /// The capture holds no words and no files and was never sent (`UploadJob.hasNothingToSend`):
    /// it can only be removed.
    case nothingToSend
}

/// `Outbox.editOwed`'s answer. Three, not a Bool: a queue that could not be read is not a queue
/// owing nothing.
public enum OutboxEditAnswer: Sendable, Equatable {
    /// Nothing this device holds owes that memo an edit.
    case clear
    /// An edit to that memo is being written or waits to be sent.
    case owed
    /// The queue is not known as read just now.
    case unknown
}

/// One re-submit's edit, from the instant the call began (`Outbox.resubmit`).
private struct OwedEdit {
    /// What the edit is owed to; nil until the capture is known.
    struct Binding {
        let memoUID: String?
        let attachmentUIDs: Set<String>
        /// Whether a picture of the capture has no uid yet.
        let picturesUnresolved: Bool

        init(_ job: UploadJob) {
            memoUID = job.resolvedMemoUID
            attachmentUIDs = Set(job.files.compactMap(\.attachmentUID))
            picturesUnresolved = job.files.contains { $0.attachmentUID == nil }
        }

        /// `owed` for the memo or a picture this edit names; `unknown` when what it has not
        /// resolved could be that memo — a memo asked about while its own is unnamed, a memo-less
        /// picture while one of its own is — and `clear` only when it excludes them.
        func answer(memoUID asked: String?, attachmentUID: String) -> OutboxEditAnswer {
            if let asked, memoUID == asked { return .owed }
            if attachmentUIDs.contains(attachmentUID) { return .owed }
            let excluded = asked != nil ? memoUID != nil : !picturesUnresolved
            return excluded ? .clear : .unknown
        }
    }

    let jobID: UUID
    private(set) var binding: Binding?
    /// The count of queue reads begun when the call's write returned; nil before it has.
    var wroteBefore: Int?

    init(jobID: UUID, job: UploadJob?) {
        self.jobID = jobID
        if let job { bind(job) }
    }

    mutating func bind(_ job: UploadJob) {
        binding = Binding(job)
    }
}
