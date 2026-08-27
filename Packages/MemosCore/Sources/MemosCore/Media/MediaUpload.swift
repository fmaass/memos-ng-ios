import Foundation
import MemosAPI
import MemosOutbox
import OpenAPIRuntime

/// Why a foreground upload did not finish.
public enum MediaUploadError: Error, Equatable, LocalizedError {
    /// The file could not be read off the disk it was exported to.
    case unreadable(String)
    /// The server answered, and the answer was not "I have it".
    case refused(APIError)
    /// The server took a chunk and then said it holds fewer bytes than before, or the same. Sending
    /// again from there would be an infinite loop, so it stops and says so.
    case stalled

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): "A file could not be read: \(detail)"
        case .refused(let error): error.errorDescription
        case .stalled: "The upload stopped making progress and was abandoned."
        }
    }
}

extension MediaUploadError: APIErrorCarrying {
    /// A refusal is the server's answer and keeps its identity — above all a 401, which ends the
    /// session wherever it happens. The other two are this device's own trouble and carry none.
    public var apiError: APIError? {
        guard case .refused(let error) = self else { return nil }
        return error
    }
}

/// Putting a file on the server from the FOREGROUND, while somebody waits.
///
/// This is deliberately not the outbox. The outbox owns every capture: it survives the app being
/// killed, it resumes from the server's own offset, it drains on a background session and it is
/// keyed by an idempotency token. All of that exists because a NEW memo must not be lost. An edit
/// is a different bargain — the memo already exists, the person is looking at the sheet, and a
/// media edit that were queued would land minutes later with nothing on screen to say so. So this
/// lane is small on purpose: it runs while the sheet is open, it reports what went wrong, and
/// nothing it started outlives the attempt. (The queued version of the same edit waits on the
/// idempotent-edit enabler; without an edit key a retry cannot be made safe.)
///
/// It goes through the GENERATED client, unlike the outbox's hand-built requests — the outbox has
/// to hand its bodies to a background `URLSession`, and this does not.
public enum MediaUpload {
    /// How much of a file is held in memory at once when the server names no size of its own.
    ///
    /// Only a fallback: the server states its own `chunk_size` on the answer to every chunk, and
    /// that is what the loop actually follows.
    static let fallbackChunkSize = 4 * 1024 * 1024

    /// Uploads one file and answers the UPLOAD session's uid — not an attachment uid.
    ///
    /// Nothing is finalized here, and that is the contract rather than an omission: memos-ng
    /// finalizes pending uploads as part of the memo write that names them
    /// (`app/routers/memos.py`, "finalize-on-post"), so a client that called `/finalize` itself
    /// would produce an attachment belonging to no memo — an orphan in the library.
    public static func upload(
        _ source: StagedSource,
        using client: any APIProtocol,
        fileManager: FileManager = .default
    ) async throws -> String {
        let size = try byteSize(of: source.url, fileManager: fileManager)
        let started = try await start(source, size: size, using: client)
        guard size > 0 else { return started.uploadUid }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: source.url)
        } catch {
            throw MediaUploadError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        var offset = Int64(started.bytesReceived)
        var chunkSize = usableChunkSize(started.chunkSize)
        while offset < size {
            let piece = try read(handle, at: offset, length: chunkSize)
            // A file that is shorter than it measured a moment ago has been changed under us; the
            // declared size can no longer be reached and the server will never call it complete.
            guard !piece.isEmpty else { throw MediaUploadError.stalled }
            let answer = try await append(
                piece, to: started.uploadUid, at: offset, using: client
            )
            // The SERVER's count is the position, never this loop's arithmetic: it is what a
            // resume would read, and the one number that cannot disagree with what it holds.
            guard Int64(answer.bytesReceived) > offset else { throw MediaUploadError.stalled }
            offset = Int64(answer.bytesReceived)
            chunkSize = usableChunkSize(answer.chunkSize)
        }
        return started.uploadUid
    }

    /// The size to read next. A server that names no size of its own — or an impossible one — must
    /// not turn into a loop that sends nothing: zero bytes would be refused for ever, and a
    /// negative one is not a length at all.
    static func usableChunkSize(_ stated: Int) -> Int {
        stated > 0 ? stated : fallbackChunkSize
    }

    /// Every file, in order, as upload uids ready to be named by a memo write.
    ///
    /// It stops at the FIRST failure and throws. The uploads that already landed are left as
    /// pending sessions on the server, which expire on their own (`reap_expired`) — deliberately
    /// not finalized and never linked, so an edit that failed halfway attaches nothing at all
    /// rather than half of what was picked.
    public static func uploadAll(
        _ sources: [StagedSource],
        using client: any APIProtocol,
        fileManager: FileManager = .default
    ) async throws -> [String] {
        var uids: [String] = []
        for source in sources {
            uids.append(try await upload(source, using: client, fileManager: fileManager))
        }
        return uids
    }

    static func byteSize(of url: URL, fileManager: FileManager) throws -> Int64 {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw MediaUploadError.unreadable(error.localizedDescription)
        }
    }

    static func read(_ handle: FileHandle, at offset: Int64, length: Int) throws -> Data {
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            throw MediaUploadError.unreadable(error.localizedDescription)
        }
    }

    static func start(
        _ source: StagedSource,
        size: Int64,
        using client: any APIProtocol
    ) async throws -> Components.Schemas.UploadOut {
        let response = try await client.startUploadApiUploadsPost(
            .init(
                body: .json(
                    .init(
                        filename: source.filename,
                        // The server takes epoch MILLISECONDS here, the shape a browser's
                        // `File.lastModified` has; the outbox sends the same thing.
                        lastModified: source.lastModified.map {
                            Int(($0.timeIntervalSince1970 * 1000).rounded())
                        },
                        mime: source.mime,
                        size: Int(size)
                    )
                )
            )
        )
        switch response {
        case .created(let created):
            return try created.body.json
        case .unprocessableContent:
            throw MediaUploadError.refused(.server(status: 422))
        case .undocumented(let statusCode, _):
            throw MediaUploadError.refused(.fromStatus(statusCode))
        }
    }

    static func append(
        _ piece: Data,
        to uploadUID: String,
        at offset: Int64,
        using client: any APIProtocol
    ) async throws -> Components.Schemas.UploadOut {
        let response = try await client.appendChunkApiUploadsUploadUidPatch(
            .init(
                path: .init(uploadUid: uploadUID),
                headers: .init(uploadOffset: Int(offset)),
                body: .binary(HTTPBody([UInt8](piece)))
            )
        )
        switch response {
        case .ok(let ok):
            return try ok.body.json
        // The offset gap. It is not recovered from here: this lane uploads a freshly exported file
        // once, from the beginning, with nothing else writing to the same session — so a gap means
        // something this client does not model, and resuming into it would be guesswork. The
        // outbox is where resume lives, because that is where a half-sent file survives a launch.
        case .conflict:
            throw MediaUploadError.refused(.server(status: 409))
        case .unprocessableContent:
            throw MediaUploadError.refused(.server(status: 422))
        case .undocumented(let statusCode, _):
            throw MediaUploadError.refused(.fromStatus(statusCode))
        }
    }
}
