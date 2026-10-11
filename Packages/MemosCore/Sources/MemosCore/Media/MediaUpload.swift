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
    /// A refusal is the server's answer and keeps its identity — above all a rejected credential,
    /// which ends the
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
    /// - Parameter authority: asked immediately before EVERY request this makes — the start, each
    ///   chunk, and the offset HEAD a gap recovers through. A chunked upload is the longest-lived
    ///   thing this app sends and the one most likely to still be going when a session ends, and
    ///   it runs off the main actor, so the check travels with it rather than being made once by
    ///   the caller (`SendAuthority`).
    public static func upload(
        _ source: StagedSource,
        using client: any APIProtocol,
        fileManager: FileManager = .default,
        offsetDeadline deadline: Duration = offsetDeadline,
        under authority: SendAuthority = .unfenced
    ) async throws -> String {
        let size = try byteSize(of: source.url, fileManager: fileManager)
        let started = try await start(source, size: size, using: client, under: authority)
        guard size > 0 else { return started.uploadUid }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: source.url)
        } catch {
            throw MediaUploadError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        var offset = try position(started.bytesReceived, atMost: size)
        var chunkSize = usableChunkSize(started.chunkSize)
        var resyncs = 0
        while offset < size {
            let piece = try read(handle, at: offset, length: chunkSize)
            // A file that is shorter than it measured a moment ago has been changed underneath;
            // the declared size can no longer be reached and the server will never call it
            // complete.
            guard !piece.isEmpty else { throw MediaUploadError.stalled }
            switch try await append(
                piece, to: started.uploadUid, at: offset, using: client, under: authority
            ) {
            case .accepted(let answer):
                // The SERVER's count is the position, never this loop's arithmetic: it is what a
                // resume would read, and the one number that cannot disagree with what it holds —
                // as far as the bytes this chunk actually carried, and no further.
                let received = try position(
                    answer.bytesReceived, atMost: offset + Int64(piece.count)
                )
                guard received > offset else { throw MediaUploadError.stalled }
                offset = received
                chunkSize = usableChunkSize(answer.chunkSize)
            case .offsetGap:
                // The contract's own answer to a gap, and the outbox's: ask the session where it
                // stands and resend from there (`app/routers/uploads.py` — "Offset gap; re-sync
                // via HEAD"). Same semantics as the background lane, over the generated client.
                //
                // The ask is on a DEADLINE. The failure it meets is not always prompt: an answer
                // this client cannot read fails as soon as it is parsed, but a session that simply
                // does not answer is bounded only by the URL loading system's own request timeout
                // — a minute of a Save sitting frozen on a screen somebody is waiting at. A few
                // seconds is the whole of what a resume is worth here.
                //
                // An answer that does not arrive, or does not say a number, ends the upload
                // instead, which is safe: no memo patch is sent, nothing is half-attached, and the
                // retry the person makes carries the same edit key (`TimelineStore.edit`).
                resyncs += 1
                let reported: Int64
                do {
                    reported = try await self.offset(
                        of: started.uploadUid, using: client, within: deadline, under: authority
                    )
                } catch let ours as MediaUploadError where ours.apiError == nil {
                    // Flattened ONLY where the trouble is positively this device's own and named
                    // by this type: the deadline elapsing, or a session that answered without
                    // saying where it stands. There is nothing to resume from either way, so the
                    // gap stands.
                    //
                    // Everything else travels on untouched, and that is the point of the shape:
                    // an INSTALLED credential rejected by the server is minted where the
                    // credential is attached, inside the generated client's envelope, so it is
                    // not a `MediaUploadError` at all and never reaches this clause. Caught and
                    // renamed, it would reach no store, the epoch of the credential that earned
                    // it would be lost, and a verdict would be taken here about an instant that
                    // has passed by the time the effect runs. An answer this client cannot parse
                    // fails inside that same envelope and keeps its own sentence too — nothing
                    // here reads any of them.
                    throw MediaUploadError.refused(.server(status: 409))
                }
                // A position no session of ours can be at is refused by the shared bounds rule
                // below; two ways are left to stop instead of carrying on. A server that reports
                // the very offset it just refused is not converging, and a run of gaps on a
                // session nothing else is writing to means something is wrong that resending
                // cannot fix.
                let synced = try position(reported, atMost: offset + Int64(piece.count))
                guard synced != offset, resyncs <= maximumResyncs else {
                    throw MediaUploadError.stalled
                }
                offset = synced
            }
        }
        return started.uploadUid
    }

    /// How long the session gets to say where it stands before the gap is given up on.
    ///
    /// Short, because of what is waiting on it: somebody is looking at a Save that has not come
    /// back yet. The alternative is not "the resume eventually works" — it is the URL loading
    /// system's request timeout, about a minute, at the end of which the upload is abandoned
    /// anyway. A few seconds buys every re-sync that was ever going to succeed.
    public static let offsetDeadline = Duration.seconds(3)

    /// How many offset gaps one upload will answer before giving up.
    ///
    /// A gap is already close to impossible on this lane — the session is created inside the call
    /// and nothing else can append to it — so a run of them is a server disagreeing with itself,
    /// not a resumable upload. The outbox is the lane built for genuinely long-lived sessions.
    static let maximumResyncs = 3

    /// A position the SERVER reported, taken only where this upload could actually be.
    ///
    /// Every one of these numbers arrives as a plain `integer` with no minimum in the contract, and
    /// the one the loop adopts is fed to `FileHandle.seek(toOffset:)` — a `UInt64`. A negative one
    /// is therefore not a failed upload but a dead process, taking the sheet and the words somebody
    /// was writing with it. Past `ceiling` is the other half: resuming there would skip bytes
    /// nobody ever sent, call the upload whole and patch the memo to an attachment with a hole in
    /// the middle.
    ///
    /// `.stalled` because that is what happened — the answer arrived and cannot be resumed from —
    /// and because it carries no `apiError`: nothing the server says about a number ends a session.
    static func position(_ reported: some BinaryInteger, atMost ceiling: Int64) throws -> Int64 {
        guard let position = Int64(exactly: reported), position >= 0, position <= ceiling else {
            throw MediaUploadError.stalled
        }
        return position
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
        fileManager: FileManager = .default,
        under authority: SendAuthority = .unfenced
    ) async throws -> [String] {
        var uids: [String] = []
        for source in sources {
            uids.append(
                try await upload(
                    source, using: client, fileManager: fileManager, under: authority
                )
            )
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
        using client: any APIProtocol,
        under authority: SendAuthority = .unfenced
    ) async throws -> Components.Schemas.UploadOut {
        // Immediately before the send, on the executor doing it.
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
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
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw MediaUploadError.refused(.fromStatus(503))
        case .undocumented(let statusCode, _):
            throw MediaUploadError.refused(.fromStatus(statusCode))
        }
    }

    /// What one chunk came back as. The gap is a case rather than an error because it is a step in
    /// the protocol — the server telling the client where to carry on from — and modelling it as a
    /// failure is what would make the abort look like the only option.
    enum ChunkOutcome {
        case accepted(Components.Schemas.UploadOut)
        case offsetGap
    }

    /// Where the server says this session stands.
    ///
    /// The answer is a HEADER on a bodyless response — `Upload-Offset` — which is why the route
    /// exists at all: it is the one question that can be asked without moving any bytes. It IS
    /// published in the contract (`upload_offset_api_uploads__upload_uid__head`), so it is asked
    /// through the generated client like everything else here; the outbox builds the same request
    /// by hand only because its own requests must go on a background `URLSession`.
    /// The ask, given only `deadline` to answer in.
    ///
    /// A race rather than a timeout on the request, because the request is the generated client's
    /// to build and it has no timeout of its own to set — and because the losing side is
    /// cancelled, so a session that answers a second too late is not left running.
    static func offset(
        of uploadUID: String,
        using client: any APIProtocol,
        within deadline: Duration = offsetDeadline,
        under authority: SendAuthority = .unfenced
    ) async throws -> Int64 {
        try await withThrowingTaskGroup(of: Int64.self) { group in
            group.addTask { try await read(offsetOf: uploadUID, using: client, under: authority) }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw MediaUploadError.stalled
            }
            defer { group.cancelAll() }
            guard let answer = try await group.next() else { throw MediaUploadError.stalled }
            return answer
        }
    }

    private static func read(
        offsetOf uploadUID: String,
        using client: any APIProtocol,
        under authority: SendAuthority = .unfenced
    ) async throws -> Int64 {
        // Immediately before the send, on the executor doing it.
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        let response = try await client.uploadOffsetApiUploadsUploadUidHead(
            .init(path: .init(uploadUid: uploadUID))
        )
        switch response {
        case .ok(let ok):
            guard let offset = ok.headers.uploadOffset else {
                // A re-sync that cannot read the offset has nothing to resume from, and guessing
                // one would resend into the very gap this call exists to close. Named as THIS
                // device's trouble rather than as an answer the server gave: the server said
                // nothing here, and only an error carrying no `apiError` can be flattened by the
                // gap branch without that branch having to read an answer to tell them apart.
                throw MediaUploadError.stalled
            }
            return Int64(offset)
        case .unprocessableContent:
            throw MediaUploadError.refused(.server(status: 422))
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw MediaUploadError.refused(.fromStatus(503))
        case .undocumented(let statusCode, _):
            throw MediaUploadError.refused(.fromStatus(statusCode))
        }
    }

    static func append(
        _ piece: Data,
        to uploadUID: String,
        at offset: Int64,
        using client: any APIProtocol,
        under authority: SendAuthority = .unfenced
    ) async throws -> ChunkOutcome {
        // Immediately before the send, on the executor doing it — every chunk, not only the first.
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        let response = try await client.appendChunkApiUploadsUploadUidPatch(
            .init(
                path: .init(uploadUid: uploadUID),
                headers: .init(uploadOffset: Int(offset)),
                body: .binary(HTTPBody([UInt8](piece)))
            )
        )
        switch response {
        case .ok(let ok):
            return .accepted(try ok.body.json)
        // The offset gap: not a failure but an instruction — re-sync with the session and resend
        // from the offset it reports. Answered in `upload`, where the loop that would resend is.
        case .conflict:
            return .offsetGap
        case .unprocessableContent:
            throw MediaUploadError.refused(.server(status: 422))
        // Documented since v2.1.0; thrown exactly as its `.undocumented(429)` was.
        case .tooManyRequests:
            throw MediaUploadError.refused(.fromStatus(429))
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw MediaUploadError.refused(.fromStatus(503))
        case .undocumented(let statusCode, _):
            throw MediaUploadError.refused(.fromStatus(statusCode))
        }
    }
}
