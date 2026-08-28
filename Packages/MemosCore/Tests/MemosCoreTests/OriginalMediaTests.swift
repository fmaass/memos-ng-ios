import Foundation
import MemosAPI
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

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
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

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) { throw Offline() }
}

/// A download held open until the test lets it go, so the account can be changed underneath it.
///
/// The wait polls rather than blocks, which is how every other held request in this bundle is
/// written (`HeatmapStoreTests.hold`): a semaphore inside an async function parks a cooperative
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

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
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

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
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

        await #expect(throws: OriginalMediaError.refused(.unauthorized)) {
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

    @Test("a 401 inside a download is still the API's own 401")
    func theErrorIsUnwrappedForTheStores() {
        // The wrapping is how this lane says which step failed; it must not cost a dead credential
        // the rule that ends the session (`StoreFailure.reportable`).
        #expect(StoreFailure.reportable(OriginalMediaError.refused(.unauthorized)) == .unauthorized)
        #expect(StoreFailure.reportable(MediaUploadError.refused(.unauthorized)) == .unauthorized)
        // Something that is NOT the server's word keeps its own sentence instead.
        #expect(StoreFailure.reportable(MediaUploadError.stalled) != .unauthorized)
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

        _ = try await session.downloadOriginal(
            attachment(downloadURL: URL(string: "https://memos.example.invalid/x/original")!),
            transport: transport
        )

        let request = try #require(transport.seen.get())
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer memos_pat_good")
    }

    @Test("an attachment with no original refuses before anything is asked for")
    func nothingToDownload() async {
        let session = await signedIn()

        await #expect(throws: OriginalMediaError.unavailable) {
            try await session.downloadOriginal(
                self.attachment(downloadURL: nil), transport: StubDownloads()
            )
        }
    }

    @Test("a 401 on a download ends the session")
    func unauthorizedDownloadEndsTheSession() async throws {
        let session = await signedIn()
        #expect(session.state.user != nil)

        await #expect(throws: OriginalMediaError.self) {
            try await session.downloadOriginal(
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
            try await session.downloadOriginal(file, transport: transport, into: directory)
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
            try await session.downloadOriginal(file, transport: transport, into: directory)
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
            try await session.downloadOriginal(
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
