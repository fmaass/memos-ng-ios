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

    private let repository: OutboxRepository
    private let credentials: any OutboxCredentialsProviding
    private let network: any NetworkPathProviding
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
        attachScheduler: (@Sendable (any OutboxChunkHandling) async -> Void)? = nil,
        // Open unless something feeds it; the engine's sends of new work ask it (`SchedulingGate`).
        schedulingGate: SchedulingGate = SchedulingGate()
    ) {
        self.attachScheduler = attachScheduler
        let changes = OutboxChangeBox()
        self.changes = changes
        self.repository = repository
        self.credentials = credentials
        self.network = network
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
            onChange: { await changes.fire() },
            schedulingGate: schedulingGate
        )
        changes.attach { [weak self] in await self?.refresh() }
        // The two events that can make a held capture sendable, wired to the only thing that can
        // act on them. A job put down for the wrong network has to move when the network changes
        // or when the person changes their mind — waiting for the next launch would make the
        // toggle a promise the app keeps tomorrow.
        network.onPathChange { [weak self] in await self?.reconsiderUploads() }
        preferences.onChange { [weak self] in await self?.reconsiderUploads() }
        uploadVerdict = UploadVerdict(
            policy: UploadNetworkPolicy(allowsMobileData: preferences.allowsMobileData),
            path: network.currentPath()
        )
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
        // The predicate the repository decides a refusal under, threaded from the one provider
        // this outbox drains as. Defaulting it here would leave every hold decided as if nothing
        // ever moved, which is the fence's whole subject (`OutboxPersisting`).
        let repository = try OutboxRepository(
            root: root, stillCurrent: { credentials.stillCurrent(epoch: $0) }
        )
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
            noteProgress(in: loaded)
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
        uploadVerdict = UploadVerdict(
            policy: UploadNetworkPolicy(allowsMobileData: uploadPreferences.allowsMobileData),
            path: network.currentPath()
        )
        await drain()
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
    public func cancel(_ jobID: UUID) async -> RestoredDraft? {
        guard let snapshot = await repository.job(jobID) else { return nil }
        guard snapshot.editUnansweredSince == nil else { return nil }
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

    /// Sends a restored draft again, on the SAME manifest.
    ///
    /// The key and the account binding travel by identity rather than being stamped afresh — which
    /// is what makes a re-submit of a create that already committed resolve to the memo it made
    /// instead of a second one — and an account that no longer matches becomes the mismatch hold
    /// that already exists, never a silent re-bind. An edit is recorded rather than applied to the
    /// capture: the create is replayed as it was first sent, and the edit is owed to the memo that
    /// replay resolves to.
    public func resubmit(_ jobID: UUID, draft: RestoredDraft) async -> ResubmitOutcome {
        // Absent, unreadable and present are three answers, not two: a capture whose manifest
        // could not be read is still there, and answering `vanished` for it would hand the editor
        // a fresh enqueue — a second memo for one capture.
        let snapshot: UploadJob
        switch await repository.presence(jobID) {
        case .present(let job):
            snapshot = job
        case .absent:
            return .vanished
        case .unreadable:
            return .refused(.captureUnreadable)
        }
        // An edit of this capture is claimed: its body cannot be replaced under the server's feet,
        // and a new key over uploads the previous edit consumed is a memo the server refuses.
        guard snapshot.editUnansweredSince == nil else { return .refused(.editUnanswered) }
        var candidate = snapshot.released(at: Date())
        if draft != self.draft(of: snapshot) {
            let known = Set(snapshot.files.map(\.id))
            for picture in draft.pictures where !known.contains(picture.id) {
                // A picture picked while the capture was in the editor is not in the job's media
                // directory yet, and a manifest naming a file whose bytes are not there is the one
                // state a relaunch cannot recover from. So it is copied BEFORE anything is written
                // down, and a copy that fails refuses the re-submit rather than recording a
                // picture nothing holds.
                guard let staged = stage(picture, into: snapshot) else {
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
}
