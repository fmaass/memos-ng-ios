import Foundation

public enum OutboxStorageError: Error, Equatable {
    case noAppGroupContainer(String)
    case unreadableSource(String)
    case mediaMissing(String)
    case shortRead(expected: Int, got: Int)
    /// The root could not be leased, so nothing was written. Not a disk failure and not a lost
    /// capture: the queue is held by another process for an instant, and the caller may try again.
    case queueBusy(OutboxLockFailure)
    /// A trip pass's capture with no file in it. The guest door takes photos and videos only, so
    /// such a capture would complete as sent with nothing received: its words would be lost.
    case guestCaptureWithoutFiles
}

extension OutboxStorageError: LocalizedError {
    /// One case, one sentence — the only one of these a person can do anything about, and now the
    /// only one that can reach a screen after the caller has already waited out its bound. Every
    /// other case keeps the description it has always had, which is why the rest answer nil rather
    /// than a sentence somebody would have to keep true.
    public var errorDescription: String? {
        switch self {
        case .queueBusy: "The memos queue on this device is busy. Try posting again in a moment."
        case .guestCaptureWithoutFiles: "A trip takes photos and videos. Share one to add it."
        default: nil
        }
    }
}

/// What a sweep did, or why it did nothing.
///
/// A deferral is not a failure. A pass that does not run costs disk until the next one and never
/// costs a capture, which is the whole trade this lock makes. It is a value rather than a silence
/// so the one state that is NOT ordinary — a lock that does not work on this device — can be seen
/// from outside, which is what the fallback decision would rest on.
public enum SweepOutcome: Sendable, Equatable {
    case swept(media: Int, chunks: Int)
    case deferred(Deferral)

    public enum Deferral: Sendable, Equatable {
        /// Somebody else holds the root: a capture being written, or a second sweep.
        case contended
        /// The lock did not work here, and the errno that said so.
        case lockUnavailable(Int32)
    }
}

/// The exclusive hold a sweep deletes under, together with the live set that was read once it was
/// held.
///
/// The two travel as one thing because the second half may not re-derive either of them: a list
/// read before the lease was taken is a list another process can still have grown, and that list
/// is what every deletion below rests on.
final class SweepLease {
    let lease: OutboxLease
    let live: Set<String>

    init(lease: OutboxLease, live: Set<String>) {
        self.lease = lease
        self.live = live
    }
}

/// One captured file on its way in, before the outbox owns a copy of it.
public struct StagedSource: Sendable, Equatable {
    /// A file the CALLER owns. It is copied, never moved: the picker's temporary export is not
    /// the outbox's to consume, and a move that half-succeeds loses the only copy.
    public var url: URL
    public var filename: String
    public var mime: String
    public var lastModified: Date?
    /// What names this file for as long as the layer above is holding it.
    ///
    /// Never nil: a source that is handed none MINTS one, because the alternative — naming a file
    /// by where it is — is the one thing that cannot be an identity. A path can be reused: replace
    /// the bytes at `…/photo.jpg` and it is a different file with the same name, and an edit key
    /// built from that name would let the server replay the edit that carried the OLD bytes and
    /// answer 200 while the replacement went nowhere. Every construction of this value is an
    /// import, and every import is its own thing.
    ///
    /// A caller that wants two constructions to BE the same thing says so by passing the identity —
    /// which is exactly what a retry does (`PickedMedia.stagedSource`), and the only way two of
    /// these are ever equal for the edit key.
    ///
    /// The outbox does not read it: a queued capture is identified by its job and by `OutboxFile.id`,
    /// which is minted where the bytes are copied and is what the manifest carries. This one lives
    /// exactly as long as the fact it stands for — one compose session's edit key.
    public var identity: UUID

    public init(
        url: URL,
        filename: String,
        mime: String,
        lastModified: Date? = nil,
        identity: UUID = UUID()
    ) {
        self.url = url
        self.filename = filename
        self.mime = mime
        self.lastModified = lastModified
        self.identity = identity
    }

    /// How this file is named in an edit key: its token, and nothing else.
    ///
    /// No fallback to anything about the file, because every candidate is a lie somewhere. The
    /// basename is shared by two directories; the full path is reused when the bytes at it are
    /// replaced; the modification date moves when the picker exports again. Only a token minted at
    /// the import says "this attachment", and only a token carried forward says "the same one".
    public var editIdentity: String { identity.uuidString }
}

/// The queue on disk, as everything above it needs to see it.
///
/// The drain talks to this rather than to `OutboxRepository` for one reason: a write to the queue
/// is allowed to FAIL, and the only way to show that the drain does the right thing when one does
/// is to make one fail. Every other dependency of the drain is already a protocol for the same
/// reason — this was the last concrete one.
public protocol OutboxPersisting: Sendable {
    func loadJobs() async throws -> [UploadJob]
    func job(_ id: UUID) async -> UploadJob?
    func save(_ job: UploadJob) async throws

    /// Writes `job` — but only if the manifest on disk is still the one `snapshot` was read from,
    /// and only if the authority `job` was decided under still stands; otherwise writes `fallback`,
    /// or nothing at all.
    ///
    /// TWO fences, and they answer different questions:
    ///
    /// - **is this still the same capture?** `snapshot` is what the caller read before it began.
    ///   Between that read and this write the caller suspended, and inside that suspension another
    ///   pass can advance the job — or finish it and delete the manifest whole. Writing then either
    ///   overwrites progress the server has already confirmed or resurrects a capture that is gone,
    ///   without the originals it named. Neither candidate is about the manifest that is on disk
    ///   now, so NEITHER is written. It is the same rule the drain already applies to a chunk answer
    ///   whose offset no longer matches, taken where nothing can land after it.
    /// - **is this still the same authority?** A hold decided under a credential the device has
    ///   since replaced is a capture stranded behind a "sign in again" its owner already did, so
    ///   `fallback` is written instead and the next pass sends under the successor.
    ///
    /// Both are asked HERE, inside the implementation, immediately before the bytes go down and with
    /// nothing awaited in between. Asked by the caller they are verdicts carried across a hop into
    /// this actor, which is the whole class this exists to close.
    ///
    /// A `nil` epoch is unknown, which writes `job` — the behaviour this lane always had.
    ///
    /// - Returns: the job actually written, AS THE DISK NOW HOLDS IT — dates are persisted to
    ///   whole seconds, so this is not always the value that was offered, and a caller that
    ///   fences its next write on what it just saved must carry this value on rather than its own.
    ///   `nil` when the manifest moved on and nothing was written at all. `nil` is not a storage
    ///   failure: there is nothing to report and nothing to retry, because a later pass already
    ///   owns this capture.
    func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async throws -> UploadJob?
    func delete(_ job: UploadJob) async

    /// The same removal, fenced on the manifest the caller last wrote — the question
    /// `save(_:ifStillCurrent:matching:else:)` asks, asked of a destruction.
    ///
    /// A capture a person took back between a request and its answer is no longer that answer's to
    /// destroy, and the originals it names are the only copies there are.
    ///
    /// - Returns: whether the manifest on disk was still `snapshot` AND is now gone. A removal that
    ///   failed answers false, exactly as a moved manifest does: the capture is still queued.
    @discardableResult
    func delete(_ job: UploadJob, ifStillCurrent snapshot: UploadJob) async -> Bool
    func sweepOrphans() async throws -> SweepOutcome
    // `attempt` carries no default here: a protocol requirement may not have one. The concrete
    // queue below defaults it to nil, which is what keeps every caller that predates the term.
    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int, attempt: Int?
    ) async throws -> URL
    func removeChunk(at url: URL) async
    func chunkURL(jobID: UUID, fileID: UUID, offset: Int64, attempt: Int?) -> URL
    /// Where this job's copy of the original lives. The drain reads those bytes to answer a
    /// question only they can answer — which of the memo's pictures this original became.
    func mediaURL(job: UploadJob, file: OutboxFile) -> URL
    /// Where a resumed whole-lane file's remaining bytes are staged (`WholeTailStaging`).
    var tails: WholeTailStaging { get }

    /// One whole-file answer, rebased onto the manifest as it stands at the write: only that
    /// file's fields move, so a sibling's completion that landed first is kept. Nil when the job is
    /// gone, cancelled, held, off the whole lane, or the file has moved past `attempt`. A refusal's
    /// disposition is chosen here from `presented` — an answer another launch earned backs off.
    func applyFileAnswer(
        jobID: UUID,
        fileID: UUID,
        attempt: Int,
        outcome: WholeFileChange,
        presented: WholeTaskProvenance,
        at instant: Date
    ) async throws -> UploadJob?
}

/// The outbox on disk.
///
/// Everything lives in the app group's container so that the app, a share extension and a
/// background-session relaunch all see the same queue. The layout is three directories:
///
///     jobs/<job>.json      the manifest — a job EXISTS exactly when this file does
///     media/<job>/<file>   the captured originals, copied byte for byte
///     chunks/<...>.part    the single slice currently with the background session
///     quarantine/<job>.json  a manifest nobody could decode, kept byte for byte
///
/// The order matters: media is copied first and the manifest is written last, atomically, so a
/// crash mid-capture leaves at worst an unreferenced media directory (swept on the next launch)
/// and never a job whose files are missing.
///
/// Which is also why the tree is leased rather than merely owned by an actor. That unreferenced
/// media directory is exactly what a capture in mid-copy looks like, this actor's isolation stops
/// at the process boundary, and the share extension is a SECOND process over this same tree: a
/// capture is written under a shared lease on `<root>/.lock` and a sweep deletes under an
/// exclusive one, so the two can never be in here at once.
public actor OutboxRepository {
    private let root: URL
    /// Whether an authority epoch handed out earlier still stands, asked at the instant of a write.
    ///
    /// A closure rather than the provider itself, so the durability layer takes no dependency on
    /// the credentials protocol and the on-disk format is untouched. The default answers "nothing
    /// moves", which is correct for every repository that no drain is behind — the share
    /// extension's, and the fixtures with no engine — and wrong for one that is, which is why the
    /// call sites that feed an engine pass the real predicate.
    private let stillCurrent: @Sendable (Int) -> Bool

    /// What keeps the app's housekeeping and the share extension's capture out of each other.
    private let lock: OutboxLock

    /// The withdrawal still owed its cancellation, at the root beside the lock file — out of the
    /// sweep's reach for the same reason (`prepare`).
    public nonisolated let withdrawals: OutboxWithdrawals

    /// Whether a member row an older build began in chunks is moved onto the whole lane where it is
    /// read (MEMNG-546, `UploadJob.retiringChunkLane`).
    ///
    /// Asked for, never assumed: only the member queue an engine drains has lost its chunk lane.
    /// The guest queue still sends in chunks, and the share extension's repository reads rows the
    /// app's own repository moves.
    private let retiresChunkLane: Bool

    public init(
        root: URL,
        stillCurrent: @escaping @Sendable (Int) -> Bool = { _ in true },
        retiresChunkLane: Bool = false
    ) throws {
        self.root = root
        self.stillCurrent = stillCurrent
        self.retiresChunkLane = retiresChunkLane
        self.lock = OutboxLock(url: root.appending(path: ".lock"))
        self.withdrawals = OutboxWithdrawals(url: root.appending(path: "withdrawal.json"))
        try prepare()
    }

    /// The same repository with `flock(2)` replaced, which is the only way to ask for the branch a
    /// filesystem that does not implement locking would take — the branch both sides degrade
    /// closed on. Internal: nothing outside this package may choose how the queue excludes the
    /// other process.
    init(
        root: URL,
        stillCurrent: @escaping @Sendable (Int) -> Bool = { _ in true },
        flock: @escaping @Sendable (Int32, Int32) -> Int32
    ) throws {
        self.root = root
        self.stillCurrent = stillCurrent
        self.retiresChunkLane = false
        self.lock = OutboxLock(url: root.appending(path: ".lock"), flock: flock)
        self.withdrawals = OutboxWithdrawals(url: root.appending(path: "withdrawal.json"))
        try prepare()
    }

    /// The four directories, and the lock file beside them rather than inside any of them: the
    /// sweep lists `media` and `chunks`, so a file at the root is out of its reach by construction.
    private nonisolated func prepare() throws {
        for directory in [jobsRoot, mediaRoot, chunksRoot, quarantineRoot] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        lock.createFile()
    }

    /// The queue's home inside the app group, or nil when the container is not reachable — which
    /// on a device means the entitlement is missing, not that the queue is empty.
    ///
    /// `FileManager.default` is reached for at each use rather than held: it is not `Sendable`, and
    /// an instance carried across an isolation boundary is exactly the kind of shared mutable
    /// object strict concurrency exists to refuse.
    public static func appGroupRoot(appGroup: String = OutboxDefaults.appGroup) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "outbox")
    }

    /// The guest outbox's directory in the same container: a sibling, never inside the member
    /// one, so neither queue's sweep can reach the other's files.
    public static func guestAppGroupRoot(appGroup: String = OutboxDefaults.appGroup) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "guest-outbox")
    }

    // Derived from `root`, which never changes, so they are reachable from the initialiser and
    // from any isolation domain.
    private nonisolated var jobsRoot: URL { root.appending(path: "jobs") }
    private nonisolated var mediaRoot: URL { root.appending(path: "media") }
    private nonisolated var chunksRoot: URL { root.appending(path: "chunks") }
    private nonisolated var quarantineRoot: URL { root.appending(path: "quarantine") }

    private nonisolated func manifestURL(_ jobID: UUID) -> URL {
        jobsRoot.appending(path: "\(jobID.uuidString).json")
    }

    private nonisolated func mediaDirectory(_ jobID: UUID) -> URL {
        mediaRoot.appending(path: jobID.uuidString)
    }

    public nonisolated func mediaURL(job: UploadJob, file: OutboxFile) -> URL {
        mediaDirectory(job.id).appending(path: file.relativePath)
    }

    // MARK: - reading and writing

    /// Every queued capture, oldest first: the queue drains in the order things were captured.
    ///
    /// Two silences are deliberately gone from here. A jobs directory that cannot be LISTED throws:
    /// an empty answer is indistinguishable from an empty outbox, and everything that deletes — the
    /// sweep above all — reads this list as the whole truth. And a manifest that cannot be DECODED
    /// is set aside rather than skipped: it comes back as a held job that says so, its bytes kept
    /// and the originals it named untouched.
    public func loadJobs() throws -> [UploadJob] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: jobsRoot, includingPropertiesForKeys: nil
        )
        var jobs: [UploadJob] = []
        var seen: Set<UUID> = []
        for url in contents where url.pathExtension == "json" {
            switch readJob(at: url) {
            case .decoded(let job):
                jobs.append(job)
                seen.insert(job.id)
            case .undecodable(let reason):
                let entry = quarantine(url, reason: reason)
                jobs.append(entry)
                seen.insert(entry.id)
            case .unreadable(let reason):
                // Left exactly where it is: a read that failed once may well succeed on the next
                // pass, and moving it would turn a passing error into a permanent quarantine.
                let entry = Self.defective(at: url, reason: reason)
                jobs.append(entry)
                seen.insert(entry.id)
            case .vanished:
                continue
            }
        }
        // One capture, one row. A manifest set aside a moment ago is already spoken for above, and
        // an id can have been set aside more than ONCE — a capture that failed to be read on two
        // launches has two files under the same id. Each id speaks once here; the older file stays
        // on disk, unread and untouched, because a second row nobody can tell apart from the first
        // is a queue that cannot be acted on at all.
        for entry in try quarantinedJobs() where !seen.contains(entry.id) {
            jobs.append(entry)
            seen.insert(entry.id)
        }
        return jobs.sorted { $0.capturedAt < $1.capturedAt }
    }

    /// What stands under an id, with "could not be read" told apart from "is not there".
    ///
    /// Absence is the one answer that authorises a fresh enqueue, so it is never inferred from a
    /// failure to look. A manifest an earlier read set aside is gone from the active path, and
    /// reading that as absence would make a second memo out of the same capture.
    ///
    /// A manifest that cannot be decoded is quarantined here too, so that a background wake — which
    /// only ever asks for the one job its chunk belongs to — still sets aside what it cannot read,
    /// and the next refresh says so, rather than answering "no such capture" for ever.
    public func presence(_ id: UUID) -> JobPresence {
        let url = manifestURL(id)
        switch readJob(at: url) {
        case .decoded(let job):
            return .present(job)
        case .undecodable(let reason):
            quarantine(url, reason: reason)
            return .unreadable
        case .unreadable:
            return .unreadable
        case .vanished:
            // The active path is empty, which on its own says nothing: the capture may have
            // finished, or some earlier read may have set its manifest aside. Only the quarantine
            // can tell those apart, and a lookup that cannot answer is not an answer.
            guard let setAside = try? files(surfacingAs: id, in: quarantineRoot) else {
                return .unreadable
            }
            return setAside.isEmpty ? .absent : .unreadable
        }
    }

    /// One job, or nil when nothing actionable stands under that id.
    public func job(_ id: UUID) -> UploadJob? { presence(id).job }

    public func save(_ job: UploadJob) throws {
        _ = try persist(job)
    }

    /// The write, and the value the DISK now holds — which is not always the value it was handed.
    ///
    /// Dates go down as ISO 8601, whole seconds (`.iso8601` on both sides), so a job carrying a
    /// fractional instant — every `backingOff(at:)` and `released(at:)` taken from a real clock —
    /// is NOT equal to what the next read decodes. That matters because the fence below is a
    /// full-value compare: a caller that saves a value and then fences its next write on the
    /// value it saved would be asking about a manifest this device never held, and a legitimate
    /// write would be dropped with nobody competing for the row. So what comes back here is the
    /// round trip, and a caller that carries on carries on with what is on disk.
    private func persist(_ job: UploadJob) throws -> UploadJob {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(job)
        try data.write(to: manifestURL(job.id), options: .atomic)
        // Every write passes here, so whichever path lands a capture in `.held` or cancels it — a
        // hold, a refusal's disposition, a storage failure, a person's cancel — takes every staged
        // tail of it along, on this isolation with no suspension since the write: nothing sends a
        // held or cancelled capture, and a release resumes from a fresh HEAD that stages its own.
        if job.state == .held || job.cancelledAt != nil {
            tails.removeAll(jobID: job.id)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The bytes ARE written by now, so a round trip that somehow could not be read back is not
        // a failed write and must not be reported as one: the candidate is handed back, which is
        // what every caller got before this returned anything else.
        return (try? decoder.decode(UploadJob.self, from: data)) ?? job
    }

    /// Both questions and the write, on one isolation with no suspension between them — see
    /// `OutboxPersisting`. `job(_:)` and `save(_:)` below are a synchronous read and a synchronous
    /// `Data.write`, so from the first question to the bytes there is no instant for a renewal, a
    /// sibling drain or a background callback to land in.
    public func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) throws -> UploadJob? {
        // The manifest IS the capture: no row means a pass that finished ahead of this one deleted
        // it, and writing either candidate now would put it back without the originals it names.
        guard let onDisk = self.job(snapshot.id) else { return nil }
        // Value equality rather than a field: `UploadJob` is `Equatable`, every mutation this queue
        // makes produces a different value, and a comparison that named some of the fields would be
        // a second copy of "what counts as progress" to keep in step with the first.
        guard onDisk == snapshot else { return nil }
        let stands = epoch.map(stillCurrent) ?? true
        let chosen = stands ? job : fallback
        // As persisted, not as offered — see `persist`. A caller that fences its NEXT write on
        // this value is asking about the row on disk, so this has to BE the row on disk.
        return try persist(chosen)
    }

    /// A write judged against the credential that ISSUED the request it records, by a fence the
    /// caller holds rather than this repository's own: the share extension presents a credential
    /// the app's predicate knows nothing about. The question and the write are on this isolation
    /// with nothing awaited between them. Nil — and nothing written — when the row moved or the
    /// issuing credential no longer stands.
    public func save(
        _ job: UploadJob,
        issuedUnder epoch: Int,
        judgedBy stands: @Sendable (Int) -> Bool,
        matching snapshot: UploadJob
    ) throws -> UploadJob? {
        guard let onDisk = self.job(snapshot.id), onDisk == snapshot, stands(epoch) else {
            return nil
        }
        return try persist(job)
    }

    /// The per-file rebase — see `OutboxPersisting.applyFileAnswer`. The read, the question about
    /// the credential and the write are on this isolation with nothing awaited between them.
    public func applyFileAnswer(
        jobID: UUID,
        fileID: UUID,
        attempt: Int,
        outcome: WholeFileChange,
        presented: WholeTaskProvenance,
        at instant: Date
    ) throws -> UploadJob? {
        guard let onDisk = job(jobID) else { return nil }
        let stands: Bool
        switch presented {
        case .thisLaunch(let epoch): stands = stillCurrent(epoch)
        case .unknown: stands = false
        }
        guard
            let next = onDisk.applyingFileAnswer(
                fileID: fileID, attempt: attempt, change: outcome, stillCurrent: stands,
                at: instant
            )
        else { return nil }
        return try persist(next)
    }

    /// A job leaves the outbox whole: the manifest goes first, so a crash between the two calls
    /// leaves an unreferenced media directory rather than a job pointing at deleted files.
    public func delete(_ job: UploadJob) {
        try? FileManager.default.removeItem(at: manifestURL(job.id))
        try? FileManager.default.removeItem(at: mediaDirectory(job.id))
        removeChunks(forJob: job.id)
    }

    /// The fenced removal — see `OutboxPersisting`. Read and write are on this isolation with
    /// nothing awaited between them, so there is no instant between the question and the removal
    /// for the capture to be taken back in.
    @discardableResult
    public func delete(_ job: UploadJob, ifStillCurrent snapshot: UploadJob) -> Bool {
        guard let onDisk = self.job(snapshot.id), onDisk == snapshot else { return false }
        // Asked of the disk, not of the call: a removal that failed leaves the capture queued, and
        // a caller told otherwise acts on a job that is still there. A manifest already missing is
        // gone all the same. The originals stay while it stands, so it never names deleted files.
        let manifest = manifestURL(job.id)
        try? FileManager.default.removeItem(at: manifest)
        guard !FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false)) else {
            return false
        }
        delete(job)
        return true
    }

    /// Throws one capture away because a PERSON said so: its manifest, whatever was set aside under
    /// its id, its originals and any chunk.
    ///
    /// This is the only path in the package that destroys a capture the server never took, and it
    /// exists because the alternative is worse. A capture whose manifest cannot be read can never
    /// be sent and can never be cleared by anything automatic — without this it sits in the pending
    /// list for the life of the install. Nothing calls it on a timer, a sweep or a launch: it is
    /// reached from a button, once, per capture.
    ///
    /// It throws rather than going quiet: a removal that half-happened brings the row back on the
    /// next read, and the person is owed the reason instead of a row that will not go away.
    public func discard(_ id: UUID) throws {
        // Both directories are scanned rather than the manifest's own name alone: a row can stand
        // for a copy set aside on an earlier launch, or for a file whose name is not a job id at
        // all, and a Remove that leaves one behind puts the row straight back on the next read.
        for url in try files(surfacingAs: id, in: jobsRoot) {
            try remove(url)
        }
        for url in try files(surfacingAs: id, in: quarantineRoot) {
            try remove(url)
        }
        try remove(mediaDirectory(id))
        removeChunks(forJob: id)
    }

    /// Every file in a directory that a pending row under this id was made from: the manifest
    /// itself, and each copy set aside under that id on an earlier launch.
    private nonisolated func files(surfacingAs id: UUID, in directory: URL) throws -> [URL] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        } catch let error as CocoaError where Self.isMissing(error) {
            return []
        }
        return contents.filter { url in
            let name = url.lastPathComponent
            return (Self.jobID(named: name) ?? Self.derivedID(from: name)) == id
        }
    }

    /// Removing what is already gone is the outcome that was asked for; anything else is not.
    private nonisolated func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where Self.isMissing(error) {
            return
        }
    }

    // MARK: - manifests that cannot be read

    private enum ManifestRead {
        case decoded(UploadJob)
        /// Read whole, but not a job: corrupt bytes, a truncated write, another format.
        case undecodable(String)
        /// There, but not readable right now — permissions, a bad block, a container that went.
        case unreadable(String)
        /// Removed between the listing and the read: a job that completed, not a defect.
        case vanished
    }

    private func readJob(at url: URL) -> ManifestRead {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where Self.isMissing(error) {
            return .vanished
        } catch {
            return .unreadable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let job: UploadJob
        do {
            job = try decoder.decode(UploadJob.self, from: data)
        } catch {
            return .undecodable(Self.explain(error))
        }
        return .decoded(retiringChunkLane(job))
    }

    /// The row as the whole lane carries it, written down the first time it is read.
    ///
    /// Every read passes here — the queue's listing and the one-row lookup a background wake and
    /// every fenced write ask — so no reader ever sees the row on the chunk lane, and a fenced
    /// write compares against the moved row whether or not it reached the disk yet. A row the
    /// editor is still bringing files into is moved for this read only: the share extension
    /// appends to it from another process, and a write here could land between its read and its
    /// write. Its next write after the last file carries the move down. The chunk slices the older
    /// build cut for the row go with the move: nothing will send them.
    private func retiringChunkLane(_ job: UploadJob) -> UploadJob {
        // A guest row is never moved, whichever repository reads it: the guest door has no
        // whole-upload route.
        guard retiresChunkLane, job.binding.credentialKind == .member,
            let moved = job.retiringChunkLane()
        else { return job }
        guard !job.stillArriving, let written = try? persist(moved) else { return moved }
        removeChunks(forJob: job.id)
        return written
    }

    /// Sets a manifest nobody can decode aside, byte for byte, and returns the entry that says so.
    ///
    /// Never deleted and never rewritten — MOVED, so whatever a later look might recover from it is
    /// still there. The capture's media directory is not touched either: the entry carries the
    /// manifest's own id, so the sweep goes on counting those originals as spoken for.
    @discardableResult
    private func quarantine(_ url: URL, reason: String) -> UploadJob {
        do {
            let destination = quarantineDestination(for: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return Self.defective(at: destination, reason: reason)
        } catch {
            // It could not be moved. It stays in the queue and is reported all the same, and the
            // next load tries again; what must never happen is that it goes unmentioned.
            return Self.defective(at: url, reason: reason)
        }
    }

    private nonisolated func quarantineDestination(for name: String) -> URL {
        let candidate = quarantineRoot.appending(path: name)
        guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) else {
            return candidate
        }
        // The id stays the first 36 characters, which is how the sweep recognises that the
        // originals under it are still spoken for.
        let base = URL(filePath: name).deletingPathExtension().lastPathComponent
        return quarantineRoot.appending(path: "\(base).\(UUID().uuidString).json")
    }

    /// What was set aside earlier, read again on every load so the entry keeps saying why.
    private func quarantinedJobs() throws -> [UploadJob] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: quarantineRoot, includingPropertiesForKeys: nil
            )
        } catch let error as CocoaError where Self.isMissing(error) {
            // An outbox that has never had to set anything aside. Nothing was lost.
            return []
        }
        return
            contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> UploadJob? in
                switch readJob(at: url) {
                case .undecodable(let reason), .unreadable(let reason):
                    return Self.defective(at: url, reason: reason)
                case .decoded:
                    return Self.defective(at: url, reason: Self.setAsideEarlier)
                case .vanished:
                    return nil
                }
            }
    }

    private static let setAsideEarlier =
        "This capture was set aside earlier because its manifest could not be read."

    /// The stand-in for a manifest that could not be read: a held job that says so out loud.
    ///
    /// It carries the manifest's own id, so the sweep counts the capture's originals as live and
    /// leaves them alone, and a binding that names the FILE instead of a server — which is both
    /// true and impossible for any credential to match, so no drain can mistake it for work.
    private nonisolated static func defective(at url: URL, reason: String) -> UploadJob {
        let name = url.lastPathComponent
        let id = jobID(named: name) ?? derivedID(from: name)
        return UploadJob(
            id: id,
            idempotencyKey: id,
            content: "",
            capturedAt: creationDate(of: url) ?? .distantPast,
            files: [],
            binding: AccountBinding(serverBaseURL: url, ownerSubject: ""),
            state: .held,
            holdReason: .unreadableManifest,
            lastError: reason
        )
    }

    private nonisolated static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    }

    private nonisolated static func jobID(named name: String) -> UUID? {
        UUID(uuidString: String(name.prefix(36)))
    }

    /// A stable stand-in id for a manifest whose name is not a job id — a foreign file, or one
    /// renamed by hand. Derived from the name so the row keeps its identity from one refresh to the
    /// next; it is not an identity anything outside this file may rely on.
    private nonisolated static func derivedID(from name: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in Array(name.utf8).enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    /// A missing timestamp costs the entry only its place in capture order — it is surfaced either
    /// way — so this failure is not worth carrying up.
    private nonisolated static func creationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    /// Enough of the failure to say WHY. A decoding error names the field and the path it fell over
    /// on, all of which `localizedDescription` throws away for a single generic sentence.
    private nonisolated static func explain(_ error: any Error) -> String {
        error is DecodingError ? String(describing: error) : error.localizedDescription
    }

    // MARK: - capturing

    /// Writes a capture into the outbox and returns the job that now owns it.
    ///
    /// Nothing here talks to a network, and the manifest is the last thing written: when this
    /// returns, the capture survives a crash, a reboot and a force-quit.
    ///
    /// All of it under a SHARED lease on the root, taken before the first byte and released after
    /// the manifest. Between those two moments the media directory exists with nothing naming it,
    /// which is indistinguishable from a crash's leftovers to a sweep in the other process — so
    /// the sweep is excluded for the duration rather than asked to guess. Shared, so two captures
    /// never refuse each other; only a sweep does.
    ///
    /// A lease that cannot be taken refuses the capture, whichever way it failed. Unavailability
    /// is LOCAL to this process — a descriptor limit is per process — so it is no evidence about
    /// whether the other one is sweeping at that instant, and a capture published on that reading
    /// is the silent loss this lock exists to stop. A refusal is visible and can be retried; the
    /// loss is neither.
    public func enqueue(
        content: String,
        visibility: String?,
        capturedAt: Date,
        binding: AccountBinding,
        sources: [StagedSource],
        id: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        stagingLaunch: UUID? = nil,
        arriving: Int = 0,
        staging: [StagingFile] = [],
        under authority: SendAuthority = .unfenced
    ) throws -> UploadJob {
        // The guest door takes files only, and a guest job with none would be completed as sent
        // with nothing received. Refused here, the one place every capture is written, before
        // anything is leased or copied.
        if binding.credentialKind == .guest, sources.isEmpty {
            throw OutboxStorageError.guestCaptureWithoutFiles
        }
        let lease: OutboxLease
        switch lock.acquire(.shared) {
        case .leased(let held):
            lease = held
        case .refused(let failure):
            // Before the directory exists, so a refused capture leaves nothing behind at all.
            throw OutboxStorageError.queueBusy(failure)
        }
        defer { lease.release() }
        let directory = mediaDirectory(id)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var files: [OutboxFile] = []
            for source in sources {
                files.append(try copy(source, into: directory))
            }
            let job = UploadJob(
                id: id,
                idempotencyKey: idempotencyKey,
                content: content,
                visibility: visibility,
                capturedAt: capturedAt,
                files: files,
                binding: binding,
                stagingLaunch: stagingLaunch,
                // Only a capture still taking files is owed any: the count is what its editor
                // promised, and what is left of it at the release is what never came.
                notArrived: stagingLaunch != nil && arriving > 0 ? arriving : nil,
                staging: staging.isEmpty ? nil : staging
            )
            // The LAST word, on this executor, immediately before the manifest is committed.
            // Copying the files above is the slow part of a capture and the caller's check was
            // before it: an account switch landing in that interval would otherwise commit a job
            // stamped with the account that is leaving, which the next drain can only hold.
            guard authority.holds() else { throw SendAuthorityWithdrawn() }
            try save(job)
            return job
        } catch {
            // Nothing half-captured is left behind for the sweep to puzzle over.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    // MARK: - files still arriving (MEMNG-951)

    /// Adds files that landed after Post to the capture whose editor is still bringing them in.
    ///
    /// Only while the capture is still marked as arriving from `launch` and nobody has taken it
    /// back: from the release on, the create may be on the wire, and a file added under its key
    /// then is a different request the server answers with the first memo — the file would be on
    /// this device and in no memo. So a refusal copies nothing and writes nothing (nil). The
    /// question and the write are one call on this actor, with no suspension between them, which
    /// is what makes the release below and this append fall one on each side of the other.
    ///
    /// Every file is copied before the manifest names it; a copy that fails throws and leaves the
    /// manifest — and every file it already held — exactly as it was.
    ///
    /// `sources` are ONE picked item's files: the item is counted off what the capture is still
    /// owed (`UploadJob.notArrived`) in the same write that names them, so an item whose append
    /// was refused or failed stays counted as missing.
    public func append(
        _ sources: [StagedSource], to id: UUID, arrivingFrom launch: UUID
    ) throws -> UploadJob? {
        guard let job = job(id), job.stagingLaunch == launch, job.cancelledAt == nil else {
            return nil
        }
        let lease: OutboxLease
        switch lock.acquire(.shared) {
        case .leased(let held):
            lease = held
        case .refused(let failure):
            throw OutboxStorageError.queueBusy(failure)
        }
        defer { lease.release() }
        let directory = mediaDirectory(id)
        var copied: [OutboxFile] = []
        do {
            for source in sources {
                copied.append(try copy(source, into: directory))
            }
        } catch {
            for file in copied {
                let stored = directory.appending(path: file.relativePath)
                try? FileManager.default.removeItem(at: stored)
            }
            throw error
        }
        var next = job
        next.files.append(contentsOf: copied)
        if let owed = next.notArrived { next.notArrived = max(0, owed - 1) }
        return try persist(next)
    }

    /// What a visibility change on a pending capture became (MEMNG-971).
    public enum VisibilityWrite: Sendable, Equatable {
        /// No create can have reached the server: the create's own value was changed, and the
        /// create reads it from the manifest when it is sent.
        case intoCreate
        /// A create may be on the wire or may already have committed, so its body is left exactly
        /// as it was sent — a replay under the same key answers with the memo it made — and the
        /// change is owed to that memo as an edit, applied by one PATCH once its uid is known.
        case owedAsEdit
        /// The capture already meant that: nothing was written.
        case unchanged
        /// Nothing was written: the capture is gone, taken back to the editor, or a change of it
        /// is on the wire and its body is frozen until the server answers.
        case refused
    }

    /// Changes who a pending capture is to be visible to — the pending card's and the Transfers
    /// sheet's visibility menu (MEMNG-971).
    ///
    /// ONE mutation: the read, the question and the write are on this isolation with nothing
    /// awaited between them, under a shared lease of the root like every other write a person makes
    /// here, so no pass of this process's engine can claim the create between the question and the
    /// write. The question is `createMayHaveBeenSent`, asked of the manifest this writes: the
    /// engine writes `.creating` BEFORE its POST leaves, so a change that finds the create claimed
    /// — or sent once with no answer — cannot be put into the create's body, because a replay under
    /// the same key answers with the memo the first body made. It is owed to that memo instead, as
    /// an edit under a key of its own, and the edit lane applies it with one PATCH once the memo's
    /// uid is known. The create that was in flight cannot finish the capture under it either: its
    /// removal is fenced on the manifest it claimed, which this changed.
    public func setVisibility(_ visibility: String, of id: UUID) throws -> VisibilityWrite {
        let lease: OutboxLease
        switch lock.acquire(.shared) {
        case .leased(let held):
            lease = held
        case .refused(let failure):
            throw OutboxStorageError.queueBusy(failure)
        }
        defer { lease.release() }
        // Taken back, the capture is the editor's; with a change on the wire, its body is frozen
        // until the server answers (`editUnansweredSince`).
        guard let job = job(id), job.cancelledAt == nil, job.editUnansweredSince == nil else {
            return .refused
        }
        guard job.intendedVisibility != visibility else { return .unchanged }
        var next = job
        let written: VisibilityWrite
        if var edit = job.pendingEdit {
            // An edit is already owed: this is a different edit of it, under a key of its own.
            edit.visibility = visibility
            next.pendingEdit = edit
            next.editKey = UUID().uuidString
            written = .owedAsEdit
        } else if job.createMayHaveBeenSent {
            next.pendingEdit = PendingEdit(
                content: job.content,
                visibility: visibility,
                capturedAt: job.capturedAt,
                fileIDs: job.files.map(\.id)
            )
            next.editKey = UUID().uuidString
            written = .owedAsEdit
        } else {
            next.visibility = visibility
            written = .intoCreate
        }
        _ = try persist(next)
        return written
    }

    /// What "Use mobile data for this one" found.
    public enum MobileVideoRelease: Sendable, Equatable {
        /// Written: this capture's videos may go over mobile data from now on.
        case released
        /// The capture was already let go over mobile data: nothing was written.
        case unchanged
        /// Nothing was written: the capture is gone or taken back to the editor.
        case refused
    }

    /// Lets ONE capture's videos go over mobile data, whatever the video policy says — "Use mobile
    /// data for this one" on its Transfers row. Neither setting changes.
    ///
    /// ONE mutation, under a shared lease of the root like every other write a person makes here:
    /// the read, the question and the write are on this isolation with nothing awaited between
    /// them. So two taps landing together are one write — the second finds the mark already
    /// there and is answered `.unchanged`, writing nothing — and a pass that read the capture
    /// before this landed cannot put a video wait back over it: every engine write is fenced on
    /// the manifest it read, which this changed. A video wait the row was showing is cleared in
    /// the same write, so the row stops saying it at once; the drain that follows writes whatever
    /// the network says now.
    public func releaseVideoOverMobile(of id: UUID) throws -> MobileVideoRelease {
        let lease: OutboxLease
        switch lock.acquire(.shared) {
        case .leased(let held):
            lease = held
        case .refused(let failure):
            throw OutboxStorageError.queueBusy(failure)
        }
        defer { lease.release() }
        guard let job = job(id), job.cancelledAt == nil else { return .refused }
        guard job.videoOverMobileAllowed != true else { return .unchanged }
        var next = job
        next.videoOverMobileAllowed = true
        if next.waitReason?.isVideoRule == true { next.waitReason = nil }
        _ = try persist(next)
        return .released
    }

    /// What letting a capture go found.
    public enum StagingRelease: Sendable, Equatable {
        /// The mark is gone; the create may be sent once its files are up.
        case released
        /// Nothing arrived and there were no words: a memo of nothing is not a memo, so the
        /// capture was removed rather than handed to a create the server would refuse.
        case emptied
        /// Nothing arrived, there were no words, and items were picked that never came: kept,
        /// stopped, so its card says so rather than the Post disappearing.
        case stoppedEmpty
        /// The capture was not arriving from that launch — already let go, or gone.
        case notArriving
    }

    /// The editor that set the mark is done with this capture: its last file landed, failed, or
    /// its time ran out. From here no append is taken (`append`).
    public func releaseStaging(_ id: UUID, arrivingFrom launch: UUID) throws -> StagingRelease {
        guard var job = job(id), job.stagingLaunch == launch else { return .notArriving }
        job.stagingLaunch = nil
        let wordless = job.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Items still in Photos are still on their way (`StagingLane`): the capture is not empty.
        if job.files.isEmpty, job.stagingFiles.isEmpty, wordless {
            // Nothing to send — but when that is because every picked item failed to arrive, a
            // capture removed here would be a Post that vanished without a word. It is kept,
            // stopped, so its card can say what did not come (`missingItems`) and be removed by
            // the person who reads it.
            guard job.missingItems > 0 else {
                delete(job)
                return .emptied
            }
            _ = try persist(job.cancelled(at: Date()))
            return .stoppedEmpty
        }
        _ = try persist(job)
        return .released
    }

    /// Lets go of every capture an editor of ANOTHER launch was still bringing files into. That
    /// process is gone and its loads with it, so nothing more will ever arrive: what it appended
    /// before it died is kept, and the capture is sent with that. Called once per launch, at
    /// adoption, before any drain.
    @discardableResult
    public func releaseStaging(leftOverBefore launch: UUID) throws -> [UUID] {
        var released: [UUID] = []
        for job in try loadJobs() {
            guard let staged = job.stagingLaunch, staged != launch else { continue }
            if try releaseStaging(job.id, arrivingFrom: staged) == .released {
                released.append(job.id)
            }
        }
        return released
    }

    // MARK: - items still in Photos (MEMNG-952)

    /// Where the `StagingLane` writes an item's bytes before they are renamed into the capture.
    /// One fixed path per item, so a copy a terminated run left half-written is found — and
    /// replaced — by the run after it rather than left beside a second one.
    public nonisolated func stagingTemporaryURL(jobID: UUID, item: StagingFile) -> URL {
        mediaDirectory(jobID).appending(path: "\(item.id.uuidString).staging")
    }

    /// What committing a copied item found.
    public enum StagingCommit: Sendable, Equatable {
        /// The item is a file of the capture now, and no longer in `staging`.
        case staged(UploadJob)
        /// The item the copy was made for is not in the capture's `staging` as it was read: an
        /// earlier commit took it, the capture was cancelled or removed, or the item changed. The
        /// copy is deleted and nothing is written.
        case notStaging
    }

    /// Turns a copied item into a file of the capture: the rename of the copy to its stored name
    /// and the manifest write that moves the item from `staging` to `files` are ONE mutation, on
    /// this actor under the cross-process lease, with nothing awaited between the question and the
    /// write.
    ///
    /// Fenced on the manifest read HERE: only while the capture is not cancelled and still holds
    /// `item` exactly as the lane read it. A second copy of an item an earlier commit already took
    /// is refused (`notStaging`) and its bytes removed, so a file is never added twice.
    public func commitStaged(
        _ item: StagingFile, of jobID: UUID, copiedTo temporary: URL, filename: String,
        mime: String, lastModified: Date?
    ) throws -> StagingCommit {
        let lease: OutboxLease
        switch lock.acquire(.shared) {
        case .leased(let held):
            lease = held
        case .refused(let failure):
            throw OutboxStorageError.queueBusy(failure)
        }
        defer { lease.release() }
        guard var job = job(jobID), job.cancelledAt == nil,
            let index = job.stagingFiles.firstIndex(of: item),
            !job.files.contains(where: { $0.id == item.id })
        else {
            try? FileManager.default.removeItem(at: temporary)
            return .notStaging
        }
        let suffix = URL(fileURLWithPath: filename).pathExtension
        let storedName = suffix.isEmpty ? item.id.uuidString : "\(item.id.uuidString).\(suffix)"
        let destination = mediaDirectory(jobID).appending(path: storedName)
        // A run that renamed and then died before its write left the file under this very name; it
        // is the same item's bytes, replaced rather than kept beside the new ones.
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        var staging = job.stagingFiles
        staging.remove(at: index)
        job.staging = staging.isEmpty ? nil : staging
        job.files.append(
            OutboxFile(
                id: item.id,
                relativePath: storedName,
                filename: filename,
                mime: mime,
                byteSize: Int64(values.fileSize ?? 0),
                lastModified: lastModified
            ))
        return .staged(try persist(job))
    }

    /// Records what a staging pass found about Photos access for the items it could not read, or
    /// could again: one write, fenced the same way as `commitStaged` — an item an earlier commit
    /// took, or a cancelled capture, is not written about. Nil when nothing changed.
    public func markStaging(
        _ items: [StagingFile], of jobID: UUID, needsPhotosAccess: Bool
    ) throws -> UploadJob? {
        guard var job = job(jobID), job.cancelledAt == nil else { return nil }
        var staging = job.stagingFiles
        var changed = false
        for item in items {
            guard let index = staging.firstIndex(of: item) else { continue }
            let mark: Bool? = needsPhotosAccess ? true : nil
            guard staging[index].needsPhotosAccess != mark else { continue }
            staging[index].needsPhotosAccess = mark
            changed = true
        }
        guard changed else { return nil }
        job.staging = staging
        return try persist(job)
    }

    private func copy(_ source: StagedSource, into directory: URL) throws -> OutboxFile {
        let fileID = UUID()
        // The stored name is derived from the id, never from the picker's filename: a name from
        // outside decides where a file lands only if you let it.
        let suffix = URL(fileURLWithPath: source.filename).pathExtension
        let storedName = suffix.isEmpty ? fileID.uuidString : "\(fileID.uuidString).\(suffix)"
        let destination = directory.appending(path: storedName)
        guard FileManager.default.fileExists(atPath: source.url.path(percentEncoded: false)) else {
            throw OutboxStorageError.unreadableSource(source.filename)
        }
        try FileManager.default.copyItem(at: source.url, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        return OutboxFile(
            id: fileID,
            relativePath: storedName,
            filename: source.filename,
            mime: source.mime,
            byteSize: Int64(values.fileSize ?? 0),
            lastModified: source.lastModified
        )
    }

    // MARK: - chunks

    /// Cuts one chunk out of an original into its own file, which is what the background session
    /// uploads from. Lazily, one at a time: a 700 MB video is never held in memory or duplicated
    /// on disk.
    public func sliceChunk(
        job: UploadJob,
        file: OutboxFile,
        offset: Int64,
        length: Int,
        attempt: Int? = nil
    ) throws -> URL {
        let source = mediaURL(job: job, file: file)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw OutboxStorageError.mediaMissing(file.filename)
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length else {
            throw OutboxStorageError.shortRead(expected: length, got: data.count)
        }
        let url = chunkURL(jobID: job.id, fileID: file.id, offset: offset, attempt: attempt)
        try data.write(to: url, options: .atomic)
        return url
    }

    public nonisolated func chunkURL(
        jobID: UUID, fileID: UUID, offset: Int64, attempt: Int? = nil
    ) -> URL {
        // The attempt is APPENDED. The orphan sweep names a chunk's owner by the first 36
        // characters of the file name, so the job UUID has to stay at the head of it — a chunk a
        // retry sliced would otherwise read as belonging to no job and be swept while live.
        let stem = "\(jobID.uuidString)-\(fileID.uuidString)-\(offset)"
        guard let attempt else { return chunksRoot.appending(path: "\(stem).part") }
        return chunksRoot.appending(path: "\(stem)-a\(attempt).part")
    }

    public nonisolated var tails: WholeTailStaging { WholeTailStaging(directory: chunksRoot) }

    public func removeChunk(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func removeChunks(forJob jobID: UUID) {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: chunksRoot, includingPropertiesForKeys: nil))
            ?? []
        for url in contents where url.lastPathComponent.hasPrefix(jobID.uuidString) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - housekeeping

    /// Drops media and chunks that belong to no job: what a crash mid-capture, or a job that was
    /// completed as the process died, leaves behind. Files belonging to a live job are never
    /// touched here — a chunk may be in flight.
    ///
    /// Every deletion below rests on the list of live jobs, so when that list cannot be produced
    /// NOTHING here runs: an empty one would take every capture's originals with it.
    ///
    /// And a list is only the truth for as long as nobody else can add to it, which no actor can
    /// promise across processes. So the whole pass runs under an EXCLUSIVE lease on the root —
    /// taken BEFORE the list is read, released after the last deletion — and defers when it cannot
    /// have one. A deferred pass costs disk until the next launch; a pass that deleted without the
    /// lease would cost somebody the photographs they watched the share sheet accept.
    public func sweepOrphans() throws -> SweepOutcome {
        let started: SweepLease?
        do {
            started = try beginSweep()
        } catch OutboxStorageError.queueBusy(.unavailable(let code)) {
            return .deferred(.lockUnavailable(code))
        }
        guard let started else { return .deferred(.contended) }
        return try finishSweep(started)
    }

    /// The first half: the exclusive lease, and then the live set read under it. Nothing is deleted
    /// here.
    ///
    /// Separated from the deletions for ONE reason — a test parks a sweep exactly where the bug
    /// lived, between the list read and the loop, and drives a real `enqueue` through a second
    /// repository over the same root while it is parked. Production never separates them:
    /// `sweepOrphans()` is the only caller of both halves.
    ///
    /// `sending`, because that test receives the lease on another isolation. It is one descriptor
    /// and one immutable set, transferred out rather than shared.
    ///
    /// - Returns: the lease and the live set, or nil when another holder has the root — the
    ///   ordinary refusal, and the only thing nil is allowed to mean. A lock that does not work at
    ///   all is not ordinary and travels as a throw, because nil cannot carry the errno the
    ///   outcome names.
    func beginSweep() throws -> sending SweepLease? {
        let lease: OutboxLease
        switch lock.acquire(.exclusive) {
        case .leased(let held):
            lease = held
        case .refused(.contended):
            return nil
        case .refused(.unavailable(let code)):
            throw OutboxStorageError.queueBusy(.unavailable(code))
        }
        do {
            return SweepLease(lease: lease, live: Set(try loadJobs().map(\.id.uuidString)))
        } catch {
            // The list is what everything below rests on, so this pass is over — and a lease that
            // outlived its pass would lock the next capture out for nothing.
            lease.release()
            throw error
        }
    }

    /// The second half: both deletion passes, inside the one lease, and the release.
    ///
    /// A listing that cannot be produced still throws, exactly as it did before there was a lease:
    /// a media root nobody can read is no licence to go on and sweep the chunks.
    func finishSweep(_ sweep: sending SweepLease) throws -> SweepOutcome {
        defer { sweep.lease.release() }
        var media = 0
        let directories = try FileManager.default.contentsOfDirectory(
            at: mediaRoot, includingPropertiesForKeys: nil
        )
        for directory in directories where !sweep.live.contains(directory.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: directory)) != nil { media += 1 }
        }
        var chunks = 0
        let parts = try FileManager.default.contentsOfDirectory(
            at: chunksRoot, includingPropertiesForKeys: nil
        )
        for chunk in parts {
            let owner = String(chunk.lastPathComponent.prefix(36))
            guard !sweep.live.contains(owner) else { continue }
            if (try? FileManager.default.removeItem(at: chunk)) != nil { chunks += 1 }
        }
        return .swept(media: media, chunks: chunks)
    }
}

extension OutboxRepository: OutboxPersisting {}

/// What a lookup by id found, with the two kinds of nothing kept apart.
///
/// `absent` is a promise — the queue and the quarantine both looked and neither holds a manifest
/// under that id — and it is the only one of the three a fresh enqueue may be built on.
public enum JobPresence: Sendable, Equatable {
    case present(UploadJob)
    case absent
    case unreadable

    public var job: UploadJob? {
        if case .present(let job) = self { return job }
        return nil
    }
}

/// A grant withdrawn at `epoch` in the process `launch` names, whose tasks may still be sending.
public struct OutboxWithdrawal: Codable, Equatable, Sendable {
    public var launch: UUID
    public var epoch: Int

    public init(launch: UUID, epoch: Int) {
        self.launch = launch
        self.epoch = epoch
    }

    /// Whether a listed whole task may still present the withdrawn grant.
    ///
    /// Kept only when it provably belongs to a later grant: minted in the withdrawing process at
    /// or past the epoch it moved to, or minted by a process started after this was recorded —
    /// `currentLaunch`, when that is not the withdrawing one. Anything else, a task nobody can
    /// read included, is covered.
    public func covers(_ identity: WholeTaskIdentity?, currentLaunch: UUID) -> Bool {
        guard let identity else { return true }
        if identity.launch == launch { return identity.epoch < epoch }
        return identity.launch != currentLaunch
    }
}

/// The one withdrawal whose cancellation has not been issued yet, kept on disk.
///
/// A background task keeps its bearer header after the process that made it is gone, and a
/// cancel is issued from a process the system may terminate first. So the withdrawal is written
/// down at the moment it happens, synchronously, and cleared only once its cancellation has been
/// issued: a record found at launch is a cancel still owed, signed in or not. One record, not a
/// list — a later withdrawal covers every task an earlier one does, so it replaces it.
public final class OutboxWithdrawals: @unchecked Sendable {
    private let url: URL
    // Recording is the main actor's and clearing the engine's caller's: the lock makes clearing's
    // read-compare-remove one step, so a withdrawal recorded between them is never removed.
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    /// One atomic write. False when it did not land, which leaves only the live cancellation.
    @discardableResult
    public func record(_ withdrawal: OutboxWithdrawal) -> Bool {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(withdrawal) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }
    }

    public func pending() -> OutboxWithdrawal? {
        lock.withLock { read() }
    }

    /// Removes the record only while it is still the one whose cancellation was issued.
    public func clear(_ issued: OutboxWithdrawal) {
        lock.withLock {
            guard read() == issued else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func read() -> OutboxWithdrawal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OutboxWithdrawal.self, from: data)
    }
}
