import Foundation

/// Bytes read a bounded amount at a time: the original's file handle in production, and in the
/// tests a wrapper that records every read, which is how the copy is held to its buffer.
public protocol TailReading {
    mutating func read(upToCount count: Int) throws -> Data?
}

extension FileHandle: TailReading {}

/// A tail staged for a resumed whole-lane file, as its name on disk describes it.
public struct WholeStagedTail: Sendable, Equatable, Hashable {
    public var ref: WholeFileRef
    public var attempt: Int
    public var url: URL

    public init(ref: WholeFileRef, attempt: Int, url: URL) {
        self.ref = ref
        self.attempt = attempt
        self.url = url
    }

    /// What a task's description can claim: the file and the term, never the path.
    static func key(_ ref: WholeFileRef, attempt: Int) -> String {
        "\(ref.jobID.uuidString)|\(ref.fileID.uuidString)|\(attempt)"
    }
}

/// Where the rest of a resumed file is staged: the bytes from the offset the server reported to
/// the end, as a file of its own, because a background upload task sends a whole file and the
/// original must stay untouched.
///
/// It lives in the outbox's chunk directory and each name begins with the job's UUID, so the
/// orphan sweep reaps a tail whose capture is gone and a job's removal takes its tails with it.
/// The name is the job, the file and the attempt term the tail task is sent under — never the
/// offset, which lives in the request's header — so a relaunch finds the tail its task claims by
/// the task's own description.
public struct WholeTailStaging: Sendable {
    /// One read's worth: the most of the original that is ever in memory at once.
    public static let bufferSize = 1 << 20

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func url(for ref: WholeFileRef, attempt: Int) -> URL {
        directory.appending(
            path: "\(ref.jobID.uuidString)-\(ref.fileID.uuidString)-a\(attempt).tail")
    }

    /// Copies `source` from `offset` to its end into the tail for `ref` at `attempt`, replacing any
    /// tail already there, and returns where it is.
    ///
    /// Throws when fewer bytes arrive than `byteSize - offset`: a short tail sent at that offset
    /// would complete a different file.
    public func stage(
        from source: URL, offset: Int64, byteSize: Int64, for ref: WholeFileRef, attempt: Int
    ) throws -> URL {
        let destination = url(for: ref, attempt: attempt)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var reader = handle
        let written = try Self.copy(from: &reader, to: destination)
        guard written == byteSize - offset else {
            try? FileManager.default.removeItem(at: destination)
            throw OutboxStorageError.shortRead(expected: Int(byteSize - offset), got: Int(written))
        }
        return destination
    }

    /// The bounded copy: `bufferSize` bytes per read at most, written as they arrive, and the
    /// destination appears only once every byte is in it.
    /// - Returns: how many bytes were copied.
    @discardableResult
    public static func copy<Reader: TailReading>(
        from reader: inout Reader, to destination: URL, bufferSize: Int = bufferSize
    ) throws -> Int64 {
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let created = FileManager.default.createFile(
            atPath: partial.path(percentEncoded: false), contents: nil)
        guard created else { throw CocoaError(.fileWriteUnknown) }
        let out = try FileHandle(forWritingTo: partial)
        var written: Int64 = 0
        do {
            while let chunk = try reader.read(upToCount: bufferSize), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return written
    }

    /// Every tail on disk, a copy left half-written included — nothing claims one of those.
    public func staged() -> [WholeStagedTail] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil))
            ?? []
        return contents.compactMap { url in
            var name = url.lastPathComponent
            if name.hasSuffix(".partial") { name = String(name.dropLast(".partial".count)) }
            guard name.hasSuffix(".tail") else { return nil }
            name = String(name.dropLast(".tail".count))
            // <job>-<file>-a<attempt>: two UUIDs of 36 characters, then the term.
            guard name.count > 75,
                let jobID = UUID(uuidString: String(name.prefix(36))),
                let fileID = UUID(uuidString: String(name.dropFirst(37).prefix(36))),
                name.dropFirst(73).hasPrefix("-a"),
                let attempt = Int(name.dropFirst(75)), attempt >= 0
            else { return nil }
            return WholeStagedTail(
                ref: WholeFileRef(jobID: jobID, fileID: fileID), attempt: attempt, url: url)
        }
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Every tail of one capture, or of one of its files.
    public func removeAll(jobID: UUID, fileID: UUID? = nil) {
        for tail in staged() where tail.ref.jobID == jobID {
            if let fileID, tail.ref.fileID != fileID { continue }
            remove(tail.url)
        }
    }
}
