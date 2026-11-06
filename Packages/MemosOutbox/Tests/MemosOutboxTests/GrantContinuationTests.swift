import Foundation
@testable import MemosOutbox
import Testing

/// A capture whose upload sessions the share extension opened with the capture grant, continued by
/// the app under its OWN credential once the extension's transfers have ended (MEMNG-946).
///
/// The server records an upload session's owner, not the token that opened it, so the app's offset
/// HEAD and its PATCH of the tail go to the session the grant opened — no second session. A refusal
/// of that tail is the typed `OutboxRefusal` carrying the epoch the tail PRESENTED, judged on
/// `OutboxRepository` where the hold is written: it holds the capture behind "Sign in again" and
/// ends nothing else — the outbox has no way to sign the app out, and the credential it was handed
/// is still the device's.
@Suite("Grant-opened uploads continue under the app's credential")
struct GrantContinuationTests {
    private static let grant = ShareUploadCredential(
        token: "grant", epoch: 3, binding: Fixture.binding())

    /// The extension opened `g1` (the picture) and `g2` (the video) with the grant and handed both
    /// bodies over; the grant was then revoked mid-transfer, so both tasks ended, with the server
    /// holding 400 of the picture's 1000 bytes and all of the video. The app reattaches and drains.
    private static func continued() async throws -> WholeRig {
        let registryRoot = try Fixture.temporaryDirectory()
        let sessions = SessionRegistry(root: registryRoot)
        let rig = try await WholeRig.make(
            answerHead: { request in
                request.url?.lastPathComponent == "g1"
                    ? OutboxHTTPResponse(statusCode: 200, headers: ["Upload-Offset": "400"])
                    : OutboxHTTPResponse(statusCode: 200, headers: ["Upload-Offset": "3000"])
            },
            carriedElsewhere: { sessions.carries(jobID: $0) }
        )
        let opened = Counter()
        let extensionHTTP = ScriptedHTTP { _ in
            opened.increment()
            return ScriptedHTTP.session(
                uid: "g\(opened.count)", chunkSize: 5 * 1024 * 1024, received: 0)
        }
        let shareSession = ScriptedUploadTaskSession()
        let started = await ShareTransfer.start(
            jobID: rig.job.id, credential: grant, registry: sessions,
            repository: rig.repository, http: extensionHTTP, allowsMobileData: false,
            stillCurrent: { _ in true }, session: { @Sendable _ in shareSession })
        let identifier = ShareSession.identifier(jobID: rig.job.id)
        #expect(started == .started(identifier: identifier, tasks: 2))
        #expect(
            shareSession.createdTasks.allSatisfy {
                $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer grant"
            }, "precondition: the extension's bodies present the grant")

        // Nothing of the extension's is still sending: the share session is handed back.
        let verdicts = await ShareSessions(registry: sessions) { _ in
            ScriptedUploadTaskSession(listing: [])
        }.wake(repository: rig.repository)
        #expect(verdicts[identifier] == .retired)

        await rig.engine.drain()
        return rig
    }

    @Test("the app HEADs and PATCHes the tail of the grant's session with its own token")
    func continuesUnderTheAppsCredential() async throws {
        let rig = try await Self.continued()
        defer { rig.cleanUp() }
        let own = "Bearer \(Fixture.credentials().token)"

        let heads = rig.http.requests(method: "HEAD")
        #expect(Set(heads.compactMap { $0.url?.lastPathComponent }) == ["g1", "g2"])
        #expect(heads.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == own })
        #expect(rig.attemptedUploadPosts == 0, "a second upload session was opened")
        let tail = try rig.task(for: rig.picture.id, attempt: 1)
        #expect(tail.request.httpMethod == "PATCH")
        #expect(tail.request.url?.path() == "/api/uploads/g1")
        #expect(tail.request.value(forHTTPHeaderField: "Upload-Offset") == "400")
        #expect(tail.request.value(forHTTPHeaderField: "Authorization") == own)
        #expect(try await rig.reload().files[1].isComplete, "the video was confirmed by its HEAD")
    }

    @Test("a refused tail holds 'sign in again' and leaves the app's credential standing")
    func refusedTailHoldsAndSignsNothingOut() async throws {
        let rig = try await Self.continued()
        defer { rig.cleanUp() }
        let tail = try rig.task(for: rig.picture.id, attempt: 1)

        await rig.engine.handle(try rig.answer(tail, status: 401))

        let held = try await rig.reload()
        #expect(held.state == .held)
        #expect(held.holdReason == .signInRequired)
        #expect(held.lastError == "Sign in again to send this memo.")
        #expect(await rig.credentials.currentCredentials() != nil, "the app was signed out")
        #expect(rig.attemptedUploadPosts == 0)
    }

    @Test("a tail refused under a credential renewed meanwhile waits for it, never holds")
    func tailRefusedUnderAReplacedCredentialBacksOff() async throws {
        let rig = try await Self.continued()
        defer { rig.cleanUp() }
        let tail = try rig.task(for: rig.picture.id, attempt: 1)
        rig.credentials.supersede()

        await rig.engine.handle(try rig.answer(tail, status: 401))

        let waiting = try await rig.reload()
        #expect(waiting.state != .held)
        #expect(waiting.holdReason == nil)
        let superseded = OutboxRefusal(statusCode: 0, issuedUnder: nil, what: "upload")
        #expect(waiting.lastError == superseded.supersededMessage)
    }
}
