import Foundation
import MemosAPI
import MemosOutbox
import UniformTypeIdentifiers

/// What streams a response to a FILE rather than into memory.
///
/// A second seam beside `MediaTransport` rather than another method on it, because the two answer
/// different questions. A tier is a picture a screen is about to draw, so it arrives as bytes; an
/// original is the archive master — a 60 MP HEIC, or a clip of several gigabytes — and holding one
/// of those in a `Data` is how an app is jetsammed for a file it only ever wanted to hand to the
/// share sheet. `URLSession.download(for:)` writes it to disk as it arrives.
public protocol MediaDownloadTransport: Sendable {
    /// The URL loading system's own temporary copy, which it deletes as soon as this call returns
    /// — so a caller that wants the file has to move it before then.
    /// - Parameter authority: asked INSIDE this transport, immediately before the request goes
    ///   out. The caller fences the answer on both ways back, but the send itself happens on
    ///   another executor and an original is the longest-lived request this app makes — the one
    ///   most likely to leave under an account the device no longer holds (`SendAuthority`).
    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
}

extension MediaSession: MediaDownloadTransport {
    public func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        // On the executor that sends, with nothing between the answer and the request.
        guard authority.holds() else { throw SendAuthorityWithdrawn() }
        return try await session.download(for: authority.presenting(request))
    }
}

/// Why an original did not arrive.
public enum OriginalMediaError: Error, Equatable, LocalizedError {
    /// The payload carried no download URL for this file — nothing was asked for.
    case unavailable
    /// Nobody is signed in, so there is no credential to present. The original tier is not signed:
    /// without a token there is no request to make.
    case notSignedIn
    /// The URL is not served by the server this device is signed in to, so the credential was not
    /// offered to it and no request was made. See `sameOrigin`.
    case foreignHost
    /// The server answered, and the answer was not the file.
    case refused(APIError)
    /// The server REFUSED the credential, and this is which credential it refused. Its own case
    /// rather than a `refused(.unauthorized)`, because the epoch is what the effect needs and a
    /// bare `APIError` has thrown it away by the time anything can act on it (MEMNG-270).
    case credentialRefused(CredentialRefusal)
    /// It arrived and could not be kept.
    case notStored(String)
    /// The sign-in that asked for it moved on while it was on its way. Two ways that happens: the
    /// session ended, so the file was thrown away; or a renewal replaced the credential the request
    /// presented, so the refusal that came back is about a token this device no longer holds.
    /// Neither is a failure of the download and neither is a rejection of the credential in hand —
    /// it is an answer to a question nobody is asking any more.
    case superseded

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This file has no original to download."
        case .notSignedIn: "Sign in again to download this file."
        case .foreignHost:
            "This file is hosted somewhere other than the server you are signed in to."
        case .refused(let error): error.errorDescription
        case .credentialRefused(let refusal): refusal.errorDescription
        case .notStored(let detail): "The download could not be saved: \(detail)"
        case .superseded: "The download was cancelled because this device's sign-in changed."
        }
    }
}

extension OriginalMediaError: APIErrorCarrying {
    /// Only a refusal is the server's word; the rest describe this device.
    public var apiError: APIError? {
        switch self {
        case .refused(let error): error
        // The status it stands for, so `StoreFailure.reportable` and `ComposeOutcome` keep
        // reading this lane exactly as they did.
        case .credentialRefused: .unauthorized
        default: nil
        }
    }
}

/// Which of an attachment's files a download asks the server for.
///
/// Two, because the app has two different questions about one upload. Somebody keeping a
/// photograph wants the file as it was taken; somebody sending a clip to a friend wants something
/// that will actually arrive. Naming them once here, rather than picking a URL at each call site,
/// is what stops a tile menu and the viewer's overlay from disagreeing about which file "Share"
/// means.
public enum AttachmentRendition: Sendable, Equatable {
    /// The file as it was uploaded — the archive master (ADR-0008).
    case original
    /// The copy this app hands to somebody else. See `MemoAttachment.file(_:)` for what that is,
    /// and why it is the master nearly every time.
    case shared
}

/// One fetchable file of an attachment: where it is, and what it is.
///
/// The mime travels WITH the URL because a derived rendition is not the mime the upload carries: a
/// clip uploaded as `video/quicktime` is handed on as the `video/mp4` the server made of it, and
/// the extension the share sheet reads comes off THIS mime, not off the attachment's.
public struct AttachmentFile: Sendable, Equatable {
    public let url: URL
    public let mime: String

    public init(url: URL, mime: String) {
        self.url = url
        self.mime = mime
    }
}

extension MemoAttachment {
    /// Where a rendition of this file is, or nil when the payload names no such file.
    ///
    /// `shared` is the archive master for everything except a clip, and what decides that is what
    /// the server actually holds. Only three derived tiers are real files — `thumb` and `mobile`
    /// are JPEGs of a PICTURE, `web` is the mp4 of a VIDEO — yet every payload carries a signed
    /// URL for all four whether the file behind it exists or not (memos-ng
    /// `app/services/asset_urls.py` signs the set unconditionally, from the uid alone). A derived
    /// URL is therefore a guess, and `downloadUrl` is the one file every attachment really has.
    /// For a picture or a document that settles it twice over: the thing somebody asked to send IS
    /// the file they are looking at, and it is the tier certain to be there.
    ///
    /// A clip is the exception, on size. Its master is what the camera wrote — HEVC, often
    /// gigabytes — while the mp4 beside it is the rendition this app already plays and small
    /// enough for a message to carry. That is the difference between a share that completes and
    /// one that never does.
    public func file(_ rendition: AttachmentRendition) -> AttachmentFile? {
        switch rendition {
        case .original:
            return downloadURL.map { AttachmentFile(url: $0, mime: mime) }
        case .shared:
            guard isVideo, let webURL else { return file(.original) }
            // Not a guess about this upload: the web tier IS an mp4, whatever was uploaded
            // (memos-ng `app/services/asset_paths.py`).
            return AttachmentFile(url: webURL, mime: "video/mp4")
        }
    }
}

/// Fetching the file somebody actually uploaded.
///
/// Everything else in this app deliberately reads DERIVED tiers: `MemoPresentation.fullScreenTier`
/// says so, and ADR-0008 is why — the original is the archive master and no screen is better for
/// having it. This is the one deliberate exception, and it is an exception because it is not a
/// screen: somebody asked for the file itself, to keep or to send on, and the derived copy is not
/// the thing they asked for.
///
/// It does NOT go through the generated client. The route that serves it is declared as
/// `application/json` with an empty schema (it returns a `FileResponse`, which FastAPI cannot
/// describe), so a generated call would try to decode a photograph as JSON. Media bytes have always
/// been fetched outside the client in this app — every tier a tile draws is — and this rides the
/// same lane, with the one difference that matters: the original tier is UNSIGNED and
/// authenticated (memos-ng `app/routers/assets.py`, the unsigned/auth branch), so the request
/// carries the device credential instead of a signature.
public enum OriginalMedia {
    /// Whether a URL is served by the SAME origin as the server this device is signed in to —
    /// scheme, host and port, with the scheme's default port resolved.
    ///
    /// This is the pin on the bearer lane, and it is the reason it exists. Every other media URL in
    /// this app is fetched with no credential at all: a derived tier carries its authorisation in
    /// its own signature, so a URL pointing anywhere is at worst a picture that does not load. This
    /// one carries the DEVICE TOKEN in a header, and a token is only safe on the host it was
    /// minted for — so a `downloadUrl` naming another host would hand the household's credential to
    /// that host. In practice these URLs are relative and resolve against the session's own base;
    /// the pin is what makes "in practice" unnecessary.
    ///
    /// Anything that is not `http`/`https`, or has no host, matches nothing: a `file:` URL has no
    /// origin to compare, and refusing is the only answer that cannot be wrong.
    public static func sameOrigin(_ url: URL, as server: URL) -> Bool {
        guard let one = origin(of: url), let other = origin(of: server) else { return false }
        return one == other
    }

    private static func origin(of url: URL) -> Origin? {
        guard let scheme = url.scheme?.lowercased(),
            let host = url.host()?.lowercased(),
            !host.isEmpty,
            let port = url.port ?? defaultPort(for: scheme)
        else { return nil }
        return Origin(scheme: scheme, host: host, port: port)
    }

    private struct Origin: Equatable {
        var scheme: String
        var host: String
        var port: Int
    }

    /// Only the two schemes this app ever talks over. A scheme with no default here is a scheme
    /// with no origin, which is refused above.
    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    /// The request that fetches one. `Accept: */*` is stated rather than left to the URL loading
    /// system's default, which asks for HTML first — this route serves whatever the file is.
    ///
    /// It does not decide WHETHER the token may go: `fetch` pins the origin before anything is
    /// built, so this is never reached for a URL the credential must not be offered to.
    public static func request(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // The archive master is fetched once, on purpose, and it is far too big to be worth a
        // slot in a cache sized for thumbnails.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// What the file is saved as.
    ///
    /// The uid is the name because it is the only name there is: neither `AttachmentRef` nor
    /// `AttachmentListItem` carries the original filename (only `AttachmentOut` does, and that is
    /// the upload's own answer, not the memo's). The EXTENSION is the part that has to be right —
    /// it is what tells the share sheet whether this is something Photos can take — so it comes
    /// from the mime type the payload does carry.
    public static func filename(uid: String, mime: String) -> String {
        guard let suffix = UTType(mimeType: mime)?.preferredFilenameExtension else { return uid }
        return "\(uid).\(suffix)"
    }

    /// The status the response has to have carried. Anything else is reported as the API error it
    /// is, so a 401 here reaches the same rule a 401 anywhere else does.
    static func accept(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OriginalMediaError.refused(
                .unexpected(description: "the download did not answer with a status")
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OriginalMediaError.refused(.fromStatus(http.statusCode))
        }
    }

    /// Fetches the original and leaves it in a directory of its OWN, under `filename(uid:mime:)`.
    ///
    /// The move is the reason this is not two lines at a call site: the URL loading system deletes
    /// its temporary copy the moment `download` returns, so the file has to be moved inside this
    /// function or it is already gone.
    ///
    /// The enclosing directory is fresh for every request, and that is not tidiness. The file has
    /// to keep a name a person will recognise in the share sheet — `filename(uid:mime:)`, which is
    /// derived from the file rather than made up — so two downloads of the SAME attachment would
    /// otherwise land on the same path. Two such requests can be in the air at once (a second tap
    /// on a tile whose first download is still going, or one made in a session that has since
    /// ended), and then one of them tidying up would unlink the very file the other has already
    /// handed to the share sheet. A directory apiece makes that impossible by construction rather
    /// than by timing: no two requests ever name the same path.
    ///
    /// It is also what `discard` removes, which is why the two live next to each other.
    public static func fetch(
        url: URL,
        token: String,
        uid: String,
        mime: String,
        server: URL,
        transport: any MediaDownloadTransport,
        into directory: URL = .temporaryDirectory,
        fileManager: FileManager = .default,
        under authority: SendAuthority = .unfenced
    ) async throws -> URL {
        // BEFORE the request is built, so a URL the credential may not be offered to produces no
        // request at all rather than one that is thrown away afterwards.
        guard sameOrigin(url, as: server) else { throw OriginalMediaError.foreignHost }
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await transport.download(
                request(url: url, token: token), under: authority
            )
        } catch is SendAuthorityWithdrawn {
            throw OriginalMediaError.superseded
        } catch {
            throw OriginalMediaError.refused(.transport(description: error.localizedDescription))
        }
        do {
            try accept(response)
        } catch OriginalMediaError.refused(.unauthorized) {
            // Minted HERE rather than in `accept`, which has no authority to read an epoch from.
            // What the send actually PRESENTED is the only number this refusal is about, and the
            // grant is the one thing that recorded it (`SendAuthority.presented`).
            throw OriginalMediaError.credentialRefused(
                CredentialRefusal(issuedUnder: authority.presented()?.epoch)
            )
        }
        let enclosure = directory.appending(path: UUID().uuidString)
        let destination = enclosure.appending(path: filename(uid: uid, mime: mime))
        do {
            try fileManager.createDirectory(at: enclosure, withIntermediateDirectories: true)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            // The directory was made for THIS download and nothing else will ever look in it, so a
            // move that fails after it exists would leave an empty one behind for good. Rare —
            // the loading system's copy vanishing early, a full disk — but it is a leak per
            // failure, in a directory nothing else ever tidies.
            try? fileManager.removeItem(at: enclosure)
            throw OriginalMediaError.notStored(error.localizedDescription)
        }
        return destination
    }

    /// Throws away a file `fetch` produced, and the directory it made for it.
    ///
    /// The pair is why this exists rather than a `removeItem` at the call site: what has to go is
    /// the enclosure as well as the file, and the fact that a downloaded original always HAS an
    /// enclosure of its own is this type's guarantee (see `fetch`) — not something a caller
    /// somewhere else should have to know, or be trusted to remember.
    public static func discard(_ file: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: file.deletingLastPathComponent())
    }
}
