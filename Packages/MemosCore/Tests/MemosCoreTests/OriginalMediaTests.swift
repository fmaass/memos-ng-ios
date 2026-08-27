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
            transport: transport,
            into: directory
        )

        #expect(saved.lastPathComponent == "a1.jpeg")
        #expect(try Data(contentsOf: saved) == Data("the whole photograph".utf8))
        // The loading system deletes its temporary copy the moment `download` returns, so a
        // version of this that only remembered the path would hand the share sheet nothing.
        let loaderCopy = try #require(transport.temporary.get())
        #expect(!FileManager.default.fileExists(atPath: loaderCopy.path))
    }

    @Test("the same file downloaded twice replaces the copy that was there")
    func theSecondDownloadWins() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await OriginalMedia.fetch(
            url: url, token: "t", uid: "a1", mime: "image/jpeg",
            transport: StubDownloads(bytes: Data("first".utf8)), into: directory
        )
        let second = try await OriginalMedia.fetch(
            url: url, token: "t", uid: "a1", mime: "image/jpeg",
            transport: StubDownloads(bytes: Data("second".utf8)), into: directory
        )

        #expect(try Data(contentsOf: second) == Data("second".utf8))
    }

    @Test("a refusal keeps the identity of the status it was")
    func refusalKeepsItsStatus() async {
        let transport = StubDownloads(status: 401)

        await #expect(throws: OriginalMediaError.refused(.unauthorized)) {
            try await OriginalMedia.fetch(
                url: url, token: "t", uid: "a1", mime: "image/jpeg", transport: transport
            )
        }
    }

    @Test("a transport that never answers is a refusal, not a crash")
    func transportFailureIsReported() async {
        await #expect(throws: OriginalMediaError.self) {
            try await OriginalMedia.fetch(
                url: url, token: "t", uid: "a1", mime: "image/jpeg",
                transport: FailingDownloads()
            )
        }
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
