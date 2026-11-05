import Foundation
import MemosAPI
import MemosOutbox
import Testing

@testable import MemosCore

/// A download that answers from a file it wrote itself, the way the URL loading system does.
///
/// It writes into the process's temporary directory and hands back that URL: what the production
/// code then has to do — MOVE it before the loading system deletes it — is exactly what is being
/// asserted, so the stub has to behave like the thing that deletes it.
private struct StubDownloads: MediaDownloadTransport {
    let bytes: Data
    let status: Int
    /// Where the last temporary file was put, so a test can ask whether it was moved away.
    let temporary = LockedValue<URL?>(nil)
    let seen = LockedValue<URLRequest?>(nil)

    init(bytes: Data = Data("original".utf8), status: Int = 200) {
        self.bytes = bytes
        self.status = status
    }

    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        seen.set(request)
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: url)
        temporary.set(url)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (url, response)
    }
}

/// A transport that never answers — the phone with no network.
private struct FailingDownloads: MediaDownloadTransport {
    struct Offline: Error {}

    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        throw Offline()
    }
}

/// A download that answers with a file that is not there.
///
/// The shape of the one failure that can strike AFTER the enclosure has been made: the URL loading
/// system's temporary copy is its own, and it deletes it the moment `download` returns — so a
/// caller that is a moment too late finds nothing to move.
private struct VanishingDownloads: MediaDownloadTransport {
    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (url, response)
    }
}

/// A download held open until the test lets it go, so the account can be changed underneath it.
///
/// The wait polls rather than blocks: a semaphore inside an async function parks a cooperative
/// thread, and the test that has to run in the meantime is on the same executor.
private final class GatedDownloads: MediaDownloadTransport, @unchecked Sendable {
    let entered = LockedValue<Bool>(false)
    let release = LockedValue<Bool>(false)
    let calls = LockedValue<Int>(0)
    private let status: Int
    private let bytes: Data

    init(status: Int = 200, bytes: Data = Data("original".utf8)) {
        self.status = status
        self.bytes = bytes
    }

    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        calls.set(calls.get() + 1)
        entered.set(true)
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: url)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (url, response)
    }
}

/// A transport that records what it was asked for and answers nothing — for the assertions that
/// are about a request NOT being made.
private final class CountingDownloads: MediaDownloadTransport, @unchecked Sendable {
    struct Unused: Error {}

    let calls = LockedValue<Int>(0)

    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        calls.set(calls.get() + 1)
        throw Unused()
    }
}

/// Fetching the file somebody actually uploaded.
///
/// The original is the one thing this app deliberately never draws (ADR-0008 — screens get the
/// derived tiers), so everything about this lane is about handing the FILE to somebody: the
/// credential it needs, the name it is saved under, and the fact that it survives the loading
/// system deleting its own copy.
@Suite("Downloading an original")
struct OriginalMediaTests {
    private let url = URL(string: "https://memos.example.invalid/api/attachments/a1/original")!

    @Test("the request presents the device credential, because the original tier is not signed")
    func requestCarriesTheCredential() {
        let request = OriginalMedia.request(url: url, token: "memos_pat_secret")

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer memos_pat_secret")
        // The derived tiers are fetched with no header at all — a signature in the URL is what
        // authorises those. This one has no signature to carry.
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("the saved name carries the extension the mime type implies")
    func filenameFollowsTheMime() {
        #expect(OriginalMedia.filename(uid: "a1", mime: "image/jpeg") == "a1.jpeg")
        #expect(OriginalMedia.filename(uid: "a1", mime: "image/heic") == "a1.heic")
        #expect(OriginalMedia.filename(uid: "a1", mime: "video/quicktime") == "a1.mov")
        // Nothing is invented for a type the system does not know: a wrong extension is what
        // makes the share sheet offer the wrong destinations.
        #expect(OriginalMedia.filename(uid: "a1", mime: "application/x-nonsense") == "a1")
    }

    @Test("the file is moved out of the loading system's own copy")
    func theFileIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubDownloads(bytes: Data("the whole photograph".utf8))

        let saved = try await OriginalMedia.fetch(
            url: url,
            token: "t",
            uid: "a1",
            mime: "image/jpeg",
            server: Stub.baseURL,
            transport: transport,
            into: directory
        )

        // The name a person sees in the share sheet is the file's own, not a scratch name.
        #expect(saved.lastPathComponent == "a1.jpeg")
        #expect(try Data(contentsOf: saved) == Data("the whole photograph".utf8))
        // Inside a directory of its own, one level down: that is what lets two downloads of one
        // attachment keep the same filename and still never share a path — see
        // `everyDownloadGetsItsOwnPath`. Read back off the filesystem rather than compared as
        // URLs, which differ by a trailing slash for the same directory.
        let enclosures = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(enclosures == [saved.deletingLastPathComponent().lastPathComponent])
        // The loading system deletes its temporary copy the moment `download` returns, so a
        // version of this that only remembered the path would hand the share sheet nothing.
        let loaderCopy = try #require(transport.temporary.get())
        #expect(!FileManager.default.fileExists(atPath: loaderCopy.path))
    }

    /// Two downloads of ONE attachment must never name the same file.
    ///
    /// They keep the same human-readable name — that is what the share sheet shows — so without a
    /// directory apiece they would land on one path. Two such requests really can overlap: a second
    /// tap on a tile whose first download is still running, or one made in a session that has since
    /// ended and is about to tidy itself up. Sharing a path, that tidy-up unlinks a file the other
    /// request has already handed to the share sheet.
    @Test("two downloads of the same file write disjoint paths, and both survive")
    func everyDownloadGetsItsOwnPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await OriginalMedia.fetch(
            url: url, token: "t", uid: "a1", mime: "image/jpeg", server: Stub.baseURL,
            transport: StubDownloads(bytes: Data("first".utf8)), into: directory
        )
        let second = try await OriginalMedia.fetch(
            url: url, token: "t", uid: "a1", mime: "image/jpeg", server: Stub.baseURL,
            transport: StubDownloads(bytes: Data("second".utf8)), into: directory
        )

        #expect(first != second, "two downloads of one file landed on the same path")
        // Both are still there, each with its own bytes: neither request overwrote the other.
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("second".utf8))
        // And the name a person sees is the same for both — the disjointness is in the enclosure,
        // which is exactly where it belongs.
        #expect(first.lastPathComponent == second.lastPathComponent)
    }

    /// A download that fails after its directory exists must not leave the directory.
    ///
    /// It is the one window where the enclosure outlives its reason: made, and then nothing to put
    /// in it. Rare, and a leak per occurrence in a place nothing else ever tidies.
    @Test("a download that cannot be stored leaves no empty directory behind")
    func aFailedMoveLeavesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: OriginalMediaError.self) {
            try await OriginalMedia.fetch(
                url: url, token: "t", uid: "a1", mime: "image/jpeg", server: Stub.baseURL,
                transport: VanishingDownloads(), into: directory
            )
        }

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.isEmpty, "a failed download left its directory behind: \(left)")
        // The control: a download that WORKS does leave one, so the emptiness above is the failure
        // path cleaning up rather than nothing ever being created.
        _ = try await OriginalMedia.fetch(
            url: url, token: "t", uid: "a1", mime: "image/jpeg", server: Stub.baseURL,
            transport: StubDownloads(), into: directory
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    /// The other half of the enclosure: throwing one download away leaves the other alone.
    @Test("discarding a download removes its own directory and nothing else")
    func discardingRemovesOnlyItsOwn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let kept = try await OriginalMedia.fetch(
            url: url, token: "t", uid: "a1", mime: "image/jpeg", server: Stub.baseURL,
            transport: StubDownloads(bytes: Data("kept".utf8)), into: directory
        )
        let thrownAway = try await OriginalMedia.fetch(
            url: url, token: "t", uid: "a1", mime: "image/jpeg", server: Stub.baseURL,
            transport: StubDownloads(bytes: Data("gone".utf8)), into: directory
        )

        OriginalMedia.discard(thrownAway)

        #expect(!FileManager.default.fileExists(atPath: thrownAway.path))
        // The DIRECTORY goes too, or every abandoned download leaves an empty one behind for ever.
        #expect(
            !FileManager.default.fileExists(
                atPath: thrownAway.deletingLastPathComponent().path
            )
        )
        // And the file somebody may already be sharing is untouched.
        #expect(try Data(contentsOf: kept) == Data("kept".utf8))
    }

    @Test("a refusal keeps the identity of the status it was")
    func refusalKeepsItsStatus() async {
        let transport = StubDownloads(status: 401)

        // Nothing asked this fetch's authority for a credential, so there is no generation to
        // name — and unknown is treated as current, which ends a session exactly as a 401 always
        // did.
        let refused = OriginalMediaError.credentialRefused(CredentialRefusal(issuedUnder: nil))
        await #expect(throws: refused) {
            try await OriginalMedia.fetch(
                url: url, token: "t", uid: "a1", mime: "image/jpeg", server: Stub.baseURL,
                transport: transport
            )
        }
    }

    @Test("a transport that never answers is a refusal, not a crash")
    func transportFailureIsReported() async {
        await #expect(throws: OriginalMediaError.self) {
            try await OriginalMedia.fetch(
                url: url, token: "t", uid: "a1", mime: "image/jpeg", server: Stub.baseURL,
                transport: FailingDownloads()
            )
        }
    }

    // MARK: - the credential goes to one server and no other

    @Test("an origin is the scheme, the host and the port, with the default port resolved")
    func origins() {
        let server = URL(string: "https://memos.example.invalid")!
        func pinned(_ address: String) -> Bool {
            OriginalMedia.sameOrigin(URL(string: address)!, as: server)
        }

        #expect(pinned("https://memos.example.invalid/a"))
        // The port the scheme implies is the port it has: these two are one origin.
        #expect(pinned("https://memos.example.invalid:443/a"))
        // Hosts are compared without case, because DNS does not have any.
        #expect(pinned("https://MEMOS.example.invalid/a"))

        // Everything that is a DIFFERENT origin, one axis at a time.
        #expect(!pinned("https://evil.example.invalid/a"))
        #expect(!pinned("http://memos.example.invalid/a"))
        #expect(!pinned("https://memos.example.invalid:8443/a"))
        // A host the server's name is a suffix of is not the server: the comparison is the whole
        // host, not a prefix or a suffix of one.
        #expect(!pinned("https://notmemos.example.invalid/a"))
        // Nothing with no origin to compare matches anything.
        #expect(!pinned("ftp://memos.example.invalid/a"))
        #expect(!OriginalMedia.sameOrigin(URL(fileURLWithPath: "/etc/passwd"), as: server))
    }

    @Test("the device credential is never offered to a host other than the signed-in server")
    func aForeignHostGetsNoRequestAtAll() async {
        let transport = CountingDownloads()
        let foreign = URL(string: "https://evil.example.invalid/api/attachments/a1/original")!

        await #expect(throws: OriginalMediaError.foreignHost) {
            try await OriginalMedia.fetch(
                url: foreign, token: "memos_pat_secret", uid: "a1", mime: "image/jpeg",
                server: Stub.baseURL, transport: transport
            )
        }

        // Refused BEFORE the request exists: a token that reaches a foreign host has leaked
        // whether or not the answer is thrown away.
        #expect(transport.calls.get() == 0)
    }

    @Test("the same file on the server's own origin still fetches")
    func theSameOriginStillFetches() async throws {
        // The control for the refusal above: the pin refuses another host, not every host.
        let transport = StubDownloads(bytes: Data("kept".utf8))

        let saved = try await OriginalMedia.fetch(
            url: url, token: "t", uid: "a1", mime: "image/jpeg", server: Stub.baseURL,
            transport: transport
        )

        #expect(try Data(contentsOf: saved) == Data("kept".utf8))
        try? FileManager.default.removeItem(at: saved)
    }

    /// The shape an upload against a session's own client actually throws — the generated client's
    /// envelope around a `CredentialRefusal` — read back through the rule every store reports by.
    /// A `reportable` that stopped reaching through that envelope would answer `.unexpected(…)`,
    /// and a dead credential would stop ending the session.
    @Test("a 401 from an installed client is still the API's own 401 to every store")
    func anInstalledClientsRefusalIsUnwrappedForTheStores() async throws {
        let thrown = try #require(
            await Stub.uploadRefusalFromAnInstalledClient(),
            "the upload was not refused, so this asserts nothing"
        )

        #expect(StoreFailure.reportable(thrown) == .unauthorized)
        #expect(StoreFailure.refusal(thrown) == CredentialRefusal(issuedUnder: 0))
        #expect(StoreFailure.transportFailure(thrown) == nil, "a refusal is not a dead network")
    }

    @Test("a 401 inside a download is still the API's own 401")
    func theErrorIsUnwrappedForTheStores() {
        // The wrapping is how this lane says which step failed; it must not cost a dead credential
        // the rule that ends the session (`StoreFailure.reportable`).
        #expect(
            StoreFailure.reportable(
                OriginalMediaError.credentialRefused(CredentialRefusal(issuedUnder: nil))
            ) == .unauthorized
        )
        #expect(StoreFailure.reportable(OriginalMediaError.refused(.unauthorized)) == .unauthorized)
    }
}

/// Which of an attachment's files goes to somebody else, and why it is not always the master.
///
/// The rule exists because the payload cannot be read at face value: memos-ng signs a URL for
/// every derived tier of every attachment, from the uid alone, whether the file behind it was ever
/// written (`app/services/asset_urls.py`) — and only a VIDEO has a `web` tier, which is why the
/// link this used to hand a recipient of a PICTURE pointed at an mp4 that does not exist.
@Suite("Which file is handed over")
struct AttachmentRenditionTests {
    private func picture(
        original: URL? = URL(string: "https://memos.example.invalid/api/attachments/a1/original")
    ) -> MemoAttachment {
        MemoAttachment(
            uid: "a1",
            mime: "image/heic",
            status: .ready,
            thumbnailURL: URL(string: "https://memos.example.invalid/api/attachments/a1/thumb"),
            previewURL: URL(string: "https://memos.example.invalid/api/attachments/a1/mobile"),
            webURL: URL(string: "https://memos.example.invalid/api/attachments/a1/web"),
            downloadURL: original
        )
    }

    private func clip(
        web: URL? = URL(string: "https://memos.example.invalid/api/attachments/v1/web")
    ) -> MemoAttachment {
        MemoAttachment(
            uid: "v1",
            mime: "video/quicktime",
            status: .ready,
            webURL: web,
            posterURL: URL(string: "https://memos.example.invalid/api/attachments/v1/poster"),
            downloadURL: URL(string: "https://memos.example.invalid/api/attachments/v1/original")
        )
    }

    @Test("a picture is handed on as its mobile tier, never the original (MEMNG-874)")
    func aPictureIsSharedAsItsMobileTier() throws {
        let file = picture()
        let shared = try #require(file.file(.shared))

        #expect(shared.url == file.previewURL)
        #expect(shared != file.file(.original))
        #expect(shared.url != file.downloadURL)
        // The mobile tier is a JPEG whatever was uploaded, so a HEIC is handed on as `.jpeg`.
        #expect(shared.mime == "image/jpeg")
        #expect(OriginalMedia.filename(uid: "a1", mime: shared.mime) == "a1.jpeg")
        #expect(shared.url != file.webURL)
        #expect(shared.url != file.thumbnailURL)
    }

    @Test("a document is handed on as its own file too")
    func aDocumentIsSharedAsItsOriginal() throws {
        let pdf = MemoAttachment(
            uid: "d1",
            mime: "application/pdf",
            status: .ready,
            webURL: URL(string: "https://memos.example.invalid/api/attachments/d1/web"),
            downloadURL: URL(string: "https://memos.example.invalid/api/attachments/d1/original")
        )

        let shared = try #require(pdf.file(.shared))

        #expect(shared.url == pdf.downloadURL)
        #expect(shared.mime == "application/pdf")
        #expect(OriginalMedia.filename(uid: "d1", mime: shared.mime) == "d1.pdf")
    }

    @Test("a clip is handed on as the derived mp4, under the mp4's own type")
    func aClipIsSharedAsTheDerivedTier() throws {
        let video = clip()
        let shared = try #require(video.file(.shared))

        #expect(shared.url == video.webURL)
        // A different file from the master, which is what keeps Save Original a row of its own on
        // a clip: the master is what the camera wrote, and it can be gigabytes.
        #expect(shared != video.file(.original))
        // What it is CALLED follows the tier's own type rather than the upload's. A `.mov`
        // extension on an mp4 is the share sheet being told the wrong thing about the file.
        #expect(shared.mime == "video/mp4")
        #expect(OriginalMedia.filename(uid: "v1", mime: shared.mime) == "v1.mp4")
    }

    @Test("a clip whose mp4 the server has not made yet is handed on as its master")
    func aClipWithNoDerivedTier() throws {
        let pending = clip(web: nil)

        #expect(pending.file(.shared) == pending.file(.original))
        // The control: with the derived tier present the two differ.
        #expect(clip().file(.shared) != clip().file(.original))
    }

    @Test("a picture naming no mobile tier has nothing to hand over, and never falls back")
    func nothingToHandOver() {
        var bare = picture()
        bare.previewURL = nil

        // Not the original, which it does carry: a picture is never shared as its master. Not the
        // web URL either — for a picture there is no file behind it at all.
        #expect(bare.file(.shared) == nil)
        #expect(bare.file(.original) != nil)
        // The control: the same picture WITH a mobile tier does have one, original or not.
        #expect(picture().file(.shared) != nil)
        #expect(picture(original: nil).file(.shared)?.url == picture().previewURL)
    }
}

/// The session's half of it: whose credential, and what a refusal does to the session.
@MainActor
@Suite("The session's original download")
struct SessionOriginalDownloadTests {
    private func signedIn(
        handler: @escaping StubTransport.Handler = { _, _, _ in Stub.json(Stub.user) }
    ) async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    private func attachment(downloadURL: URL?) -> MemoAttachment {
        MemoAttachment(
            uid: "a1", mime: "image/jpeg", status: .ready, downloadURL: downloadURL
        )
    }

    @Test("the download presents the signed-in device's own token")
    func theSessionsTokenIsPresented() async throws {
        let session = await signedIn()
        let transport = StubDownloads()

        _ = try await session.download(
            attachment(downloadURL: URL(string: "https://memos.example.invalid/x/original")!),
            transport: transport
        )

        let request = try #require(transport.seen.get())
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer memos_pat_good")
    }

    @Test("sharing a picture fetches the mobile tier over the fenced lane, never the original")
    func sharingAPictureFetchesTheMobileTier() async throws {
        let session = await signedIn()
        let transport = StubDownloads()
        let file = MemoAttachment(
            uid: "a1",
            mime: "image/png",
            status: .ready,
            previewURL: URL(string: "https://memos.example.invalid/api/attachments/a1/mobile"),
            webURL: URL(string: "https://memos.example.invalid/api/attachments/a1/web?sig=abc"),
            downloadURL: URL(string: "https://memos.example.invalid/api/attachments/a1/original")
        )

        let saved = try await session.download(file, .shared, transport: transport)

        let request = try #require(transport.seen.get())
        #expect(request.url?.path == "/api/attachments/a1/mobile")
        #expect(request.url?.path != "/api/attachments/a1/original")
        // Named for the JPEG that arrived, not for the PNG that was uploaded.
        #expect(saved.lastPathComponent == "a1.jpeg")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer memos_pat_good")
    }

    @Test("Save Original on a picture still fetches the file that was uploaded")
    func savingAPictureOriginalFetchesTheOriginal() async throws {
        let session = await signedIn()
        let transport = StubDownloads()
        let file = MemoAttachment(
            uid: "a1",
            mime: "image/png",
            status: .ready,
            previewURL: URL(string: "https://memos.example.invalid/api/attachments/a1/mobile"),
            downloadURL: URL(string: "https://memos.example.invalid/api/attachments/a1/original")
        )

        let saved = try await session.download(file, .original, transport: transport)

        let request = try #require(transport.seen.get())
        #expect(request.url?.path == "/api/attachments/a1/original")
        #expect(saved.lastPathComponent == "a1.png")
    }

    @Test("sharing a clip fetches the derived mp4 over this same fenced lane")
    func sharingAClipFetchesTheDerivedTier() async throws {
        let session = await signedIn()
        let transport = StubDownloads()
        let clip = MemoAttachment(
            uid: "v1",
            mime: "video/quicktime",
            status: .ready,
            webURL: URL(string: "https://memos.example.invalid/api/attachments/v1/web?sig=abc"),
            downloadURL: URL(string: "https://memos.example.invalid/api/attachments/v1/original")
        )

        let saved = try await session.download(clip, .shared, transport: transport)

        let request = try #require(transport.seen.get())
        #expect(request.url?.path == "/api/attachments/v1/web")
        // The master is precisely what a shared clip must not drag over a household connection.
        #expect(request.url?.path != "/api/attachments/v1/original")
        #expect(saved.lastPathComponent == "v1.mp4")
        // One lane, not a second one: same credential, and so the same origin pin and the same
        // session fence as every other download this store makes.
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer memos_pat_good")
    }

    @Test("an attachment with no original refuses before anything is asked for")
    func nothingToDownload() async {
        let session = await signedIn()

        await #expect(throws: OriginalMediaError.unavailable) {
            try await session.download(
                self.attachment(downloadURL: nil), transport: StubDownloads()
            )
        }
    }

    @Test("a 401 on a download ends the session")
    func unauthorizedDownloadEndsTheSession() async throws {
        let session = await signedIn()
        #expect(session.state.user != nil)

        await #expect(throws: OriginalMediaError.self) {
            try await session.download(
                self.attachment(downloadURL: URL(string: "https://memos.example.invalid/x")!),
                transport: StubDownloads(status: 401)
            )
        }

        #expect(session.state == .signedOut)
    }

    // MARK: - a download that outlives the session that asked for it

    /// A scratch directory of its own, so "the file was thrown away" can be asserted by looking at
    /// what is in it rather than at a path the test computed.
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a file that arrives after the account changed is thrown away, not handed over")
    func aLateFileIsDiscarded() async throws {
        let session = await signedIn()
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = GatedDownloads(status: 200)
        let file = attachment(downloadURL: URL(string: "https://memos.example.invalid/x/original"))

        let download = Task {
            try await session.download(file, transport: transport, into: directory)
        }
        while !transport.entered.get() {
            await Task.yield()
        }
        // The account changes while the original is still on the wire — the case a download is
        // likeliest of all to meet, because it is the longest request this app makes.
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_second")
        transport.release.set(true)

        await #expect(throws: OriginalMediaError.superseded) { try await download.value }
        // Not merely unreturned: the previous account's photograph is not left sitting in a
        // directory the next account's downloads are written to.
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.isEmpty, "the previous account's file was left behind: \(left)")
    }

    @Test("a 401 from the credential that has already been replaced does not end the new session")
    func aLateUnauthorizedIsNotObeyed() async throws {
        let session = await signedIn()
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = GatedDownloads(status: 401)
        let file = attachment(downloadURL: URL(string: "https://memos.example.invalid/x/original"))

        let download = Task {
            try await session.download(file, transport: transport, into: directory)
        }
        while !transport.entered.get() {
            await Task.yield()
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_second")
        #expect(session.state.user != nil, "control: the second sign-in worked")
        transport.release.set(true)

        await #expect(throws: OriginalMediaError.superseded) { try await download.value }
        // The 401 belongs to a credential that is already gone. Obeyed, it would sign the person
        // out of the session that replaced it — a dead token ending a live one.
        #expect(session.state.user != nil, "a stale 401 ended the session that succeeded it")
    }

    @Test("a signed-out session has no credential to present and says so")
    func signedOutCannotDownload() async {
        let session = SessionStore(credentials: InMemoryCredentials())

        await #expect(throws: OriginalMediaError.notSignedIn) {
            try await session.download(
                MemoAttachment(
                    uid: "a1",
                    mime: "image/jpeg",
                    status: .ready,
                    downloadURL: URL(string: "https://memos.example.invalid/x")!
                ),
                transport: StubDownloads()
            )
        }
    }
}
