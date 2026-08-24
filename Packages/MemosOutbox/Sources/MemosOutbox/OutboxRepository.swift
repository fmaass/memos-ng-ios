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

    public init(url: URL, filename: String, mime: String, lastModified: Date? = nil) {
        self.url = url
        self.filename = filename
        self.mime = mime
        self.lastModified = lastModified
    }
}

/// The outbox on disk.
///
/// Everything lives in the app group's container so that the app, a share extension and a
/// background-session relaunch all see the same queue. The layout is three directories:
///
///     jobs/<job>.json      the manifest — a job EXISTS exactly when this file does
///     media/<job>/<file>   the captured originals, copied byte for byte
///     chunks/<...>.part    the single slice currently with the background session
///
/// The order matters: media is copied first and the manifest is written last, atomically, so a
/// crash mid-capture leaves at worst an unreferenced media directory (swept on the next launch)
/// and never a job whose files are missing.
public actor OutboxRepository {
    private let root: URL

    public init(root: URL) throws {
        self.root = root
        for directory in [jobsRoot, mediaRoot, chunksRoot] {
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
    public func loadJobs() -> [UploadJob] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: jobsRoot, includingPropertiesForKeys: nil))
            ?? []
        return
            contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> UploadJob? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(UploadJob.self, from: data)
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    public func job(_ id: UUID) -> UploadJob? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: manifestURL(id)) else { return nil }
        return try? decoder.decode(UploadJob.self, from: data)
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
        idempotencyKey: UUID = UUID()
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
    public func sweepOrphans() {
        let live = Set(loadJobs().map(\.id.uuidString))
        let directories =
            (try? FileManager.default.contentsOfDirectory(
                at: mediaRoot, includingPropertiesForKeys: nil))
            ?? []
        for directory in directories where !live.contains(directory.lastPathComponent) {
            try? FileManager.default.removeItem(at: directory)
        }
        let chunks =
            (try? FileManager.default.contentsOfDirectory(
                at: chunksRoot, includingPropertiesForKeys: nil))
            ?? []
        for chunk in chunks {
            let owner = String(chunk.lastPathComponent.prefix(36))
            if !live.contains(owner) { try? FileManager.default.removeItem(at: chunk) }
        }
    }
}
