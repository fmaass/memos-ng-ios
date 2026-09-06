import Foundation

public enum OutboxStorageError: Error, Equatable {
    case noAppGroupContainer(String)
    case unreadableSource(String)
    case mediaMissing(String)
    case shortRead(expected: Int, got: Int)
}

/// One captured file on its way in, before the outbox owns a copy of it.
public struct StagedSource: Sendable, Equatable {
    /// A file the CALLER owns. It is copied, never moved: the picker's temporary export is not
    /// the outbox's to consume, and a move that half-succeeds loses the only copy.
    public var url: URL
    public var filename: String
    public var mime: String
    public var lastModified: Date?
    /// What the layer above calls this file, when it has a name for it that outlives the copy.
    ///
    /// The outbox does not read it: a queued capture is identified by its job and its file. It is
    /// here because the ONE thing that must survive a file being imported again — the identity of
    /// the attachment, for the edit key that makes a retry a replay — has to travel with the
    /// source, and a parallel array beside it is a thing that comes apart.
    public var identity: UUID?

    public init(
        url: URL,
        filename: String,
        mime: String,
        lastModified: Date? = nil,
        identity: UUID? = nil
    ) {
        self.url = url
        self.filename = filename
        self.mime = mime
        self.lastModified = lastModified
        self.identity = identity
    }

    /// How this file is named in an edit key.
    ///
    /// The identity when it has one — a per-import token, minted where the file is copied out of
    /// the picker or the provider (`PickedMedia.imported`, `SharedFile.imported`), so a file
    /// imported AGAIN for a retry keeps the name the first attempt used.
    ///
    /// Without one, the FULL PATH, never the basename: two files can be called the same thing in
    /// two directories, and an identity they shared would let a replacement be answered as a replay
    /// of the edit it replaced — the memo keeping the old file and nobody being told. A source with
    /// no token is one nothing imported (a test's, or a caller that built it by hand), and for those
    /// the path is exactly what tells them apart.
    public var editIdentity: String {
        identity?.uuidString ?? "\(url.path)|\(filename)|\(mime)"
    }
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
    func delete(_ job: UploadJob) async
    func sweepOrphans() async throws
    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int
    ) async throws -> URL
    func removeChunk(at url: URL) async
    func chunkURL(jobID: UUID, fileID: UUID, offset: Int64) -> URL
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
public actor OutboxRepository {
    private let root: URL

    public init(root: URL) throws {
        self.root = root
        for directory in [jobsRoot, mediaRoot, chunksRoot, quarantineRoot] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
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

    /// One job, or nil when nothing actionable stands under that id.
    ///
    /// A manifest that cannot be decoded is quarantined here too, so that a background wake — which
    /// only ever asks for the one job its chunk belongs to — still sets aside what it cannot read,
    /// and the next refresh says so, rather than answering "no such capture" for ever.
    public func job(_ id: UUID) -> UploadJob? {
        let url = manifestURL(id)
        switch readJob(at: url) {
        case .decoded(let job):
            return job
        case .undecodable(let reason):
            quarantine(url, reason: reason)
            return nil
        case .unreadable, .vanished:
            return nil
        }
    }

    public func save(_ job: UploadJob) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(job).write(to: manifestURL(job.id), options: .atomic)
    }

    /// A job leaves the outbox whole: the manifest goes first, so a crash between the two calls
    /// leaves an unreferenced media directory rather than a job pointing at deleted files.
    public func delete(_ job: UploadJob) {
        try? FileManager.default.removeItem(at: manifestURL(job.id))
        try? FileManager.default.removeItem(at: mediaDirectory(job.id))
        removeChunks(forJob: job.id)
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
        do {
            return .decoded(try decoder.decode(UploadJob.self, from: data))
        } catch {
            return .undecodable(Self.explain(error))
        }
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
    public func enqueue(
        content: String,
        visibility: String?,
        capturedAt: Date,
        binding: AccountBinding,
        sources: [StagedSource],
        id: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        under authority: SendAuthority = .unfenced
    ) throws -> UploadJob {
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
                binding: binding
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
        length: Int
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
        let url = chunkURL(jobID: job.id, fileID: file.id, offset: offset)
        try data.write(to: url, options: .atomic)
        return url
    }

    public nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64) -> URL {
        chunksRoot.appending(path: "\(jobID.uuidString)-\(fileID.uuidString)-\(offset).part")
    }

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
    public func sweepOrphans() throws {
        let live = Set(try loadJobs().map(\.id.uuidString))
        let directories = try FileManager.default.contentsOfDirectory(
            at: mediaRoot, includingPropertiesForKeys: nil
        )
        for directory in directories where !live.contains(directory.lastPathComponent) {
            try? FileManager.default.removeItem(at: directory)
        }
        let chunks = try FileManager.default.contentsOfDirectory(
            at: chunksRoot, includingPropertiesForKeys: nil
        )
        for chunk in chunks {
            let owner = String(chunk.lastPathComponent.prefix(36))
            if !live.contains(owner) { try? FileManager.default.removeItem(at: chunk) }
        }
    }
}

extension OutboxRepository: OutboxPersisting {}
