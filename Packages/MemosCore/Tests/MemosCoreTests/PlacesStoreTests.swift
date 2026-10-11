import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let whoamiOperation = "whoami_api_auth_user_get"
private let markersOperation = "list_markers_api_map_markers_get"
private let storedToken = "memos_pat_a"
private let successorToken = "memos_pat_next"
private let storedAddress = "https://memos.example.invalid"

/// The map's one read: what it asks, what it keeps, and what it refuses to say.
///
/// As everywhere in this bundle the server is a script under the REAL generated client, so the
/// request the store builds, the middleware that attaches the credential and the decoding of the
/// answer are all exercised. A stand-in for the store, or for `APIProtocol`, would prove only that
/// the test agrees with itself.
@MainActor
@Suite("The map's markers")
struct PlacesStoreTests {
    /// One row of `GET /api/map/markers`, with every field the contract makes required.
    private nonisolated static func marker(
        uid: String,
        latitude: Double = 47.37,
        longitude: Double = 8.54,
        thumbnail: String = "/api/attachments/x/thumb"
    ) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":"LEHV6n","width":1000,\
        "height":800,"duration":null,"sha256":null,"capture_instant":null,"capture_civil":null,\
        "capture_source":null,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "webReady":true,"renditions":[],\
        "position":null,"thumbnailUrl":"\(thumbnail)",\
        "previewUrl":"/api/attachments/\(uid)/mobile","webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print","memo_uid":"memo-\(uid)",\
        "latitude":\(latitude),"longitude":\(longitude),"taken_at":"2026-09-18T10:11:12Z"}
        """
    }

    private nonisolated static func answer(_ rows: [String]) -> (HTTPResponse, HTTPBody?) {
        Stub.json("{\"markers\":[\(rows.joined(separator: ","))]}")
    }

    // MARK: - what the answer becomes

    @Test("every located file the server sent becomes a pin, tiers resolved against the server")
    func markersAreMapped() async {
        let client = Stub.client { _, _, _ in Self.answer([Self.marker(uid: "a")]) }
        let store = PlacesStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.markers.map(\.uid) == ["a"])
        let pin = store.markers.first
        #expect(pin?.memoUID == "memo-a")
        #expect(pin?.mine == true)
        #expect(pin?.latitude == 47.37)
        #expect(pin?.width == 1000)
        #expect(pin?.blurhash == "LEHV6n")
        #expect(
            pin?.thumbnailURL?.absoluteString == "\(storedAddress)/api/attachments/x/thumb",
            "a tier path was not resolved against the server it came from"
        )
        #expect(
            pin?.downloadURL?.absoluteString == "\(storedAddress)/api/attachments/a/download",
            "the original was not carried, so the viewer opened from the map loses Share and Save"
        )
        #expect(pin?.takenAt == Date(timeIntervalSince1970: 1_789_726_272))
        #expect(store.status == .ready)
        #expect(store.hasSettledOnce)
        #expect(!store.lastLoadFailed)
        #expect(store.lastError == nil)
    }

    @Test("a tier that forms no URL costs that tier, never the marker")
    func anUnusableTierKeepsTheMarker() async {
        let client = Stub.client { _, _, _ in
            Self.answer([Self.marker(uid: "a", thumbnail: "http://[oops")])
        }
        let store = PlacesStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.markers.map(\.uid) == ["a"], "a marker was dropped over one unusable tier")
        #expect(store.markers.first?.thumbnailURL == nil)
        // A nil tier proves nothing unless the tiers that WERE usable really did resolve.
        #expect(store.markers.first?.webURL != nil, "control: the other tiers resolved")
    }

    @Test("an account with nothing located settles empty rather than pending")
    func anEmptyAnswerSettles() async {
        let client = Stub.client { _, _, _ in Self.answer([]) }
        let store = PlacesStore()
        #expect(store.status == .pending, "control: nobody had asked yet")
        await store.load(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.status == .empty)
        #expect(store.hasSettledOnce)
    }

    // MARK: - the four states

    @Test("a first load the server answered 500 reads as an error, and says so")
    func aServerErrorOnTheFirstLoad() async {
        let client = Stub.client { _, _, _ in Stub.empty(.internalServerError) }
        let store = PlacesStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.status == .error)
        #expect(store.lastLoadFailed)
        #expect(store.hasSettledOnce)
        #expect(store.lastError != nil, "the server said something and the map repeated none of it")
        #expect(!store.isLoading)
    }

    @Test("a first load that never reached the server is an error with no sentence of its own")
    func aTransportFailureOnTheFirstLoad() async {
        let client = Stub.client { _, _, _ in throw URLError(.notConnectedToInternet) }
        let store = PlacesStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.status == .error, "a server nobody could reach read as nothing to show")
        #expect(store.lastLoadFailed)
        #expect(store.hasSettledOnce)
        // The banner owns that sentence, once, for every store at a time (`StoreFailure`).
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
    }

    @Test("an unreachable server does not explain itself with the last failure's words")
    func aTransportFailureClearsAnEarlierSentence() async {
        let reachable = LockedValue<Bool>(true)
        let client = Stub.client { _, _, _ in
            guard reachable.get() else { throw URLError(.networkConnectionLost) }
            return Stub.empty(.internalServerError)
        }
        let store = PlacesStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.lastError != nil, "control: the 500 left a sentence")

        reachable.set(false)
        await store.load(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.lastError == nil, "the 500's sentence stood as this failure's explanation")
        #expect(store.status == .error)
    }

    @Test("a failure after a successful load leaves the pins on the map")
    func aFailureAfterSuccessKeepsTheMarkers() async {
        let answering = LockedValue<Bool>(true)
        let client = Stub.client { _, _, _ in
            guard answering.get() else { return Stub.empty(.internalServerError) }
            return Self.answer([Self.marker(uid: "a")])
        }
        let store = PlacesStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.markers.count == 1)

        answering.set(false)
        await store.load(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.markers.map(\.uid) == ["a"], "a refresh that failed emptied the map")
        #expect(store.status == .ready, "pins in hand win over a refresh that failed")
        #expect(store.lastLoadFailed, "and the failure was still recorded as one")
    }

    @Test("a success after a failure is a success")
    func aSuccessAfterFailureClearsTheFailure() async {
        let answering = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in
            guard answering.get() else { return Stub.empty(.internalServerError) }
            return Self.answer([])
        }
        let store = PlacesStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.status == .error, "control: the first attempt failed")

        answering.set(true)
        await store.load(using: client.handle, baseURL: Stub.baseURL)

        #expect(!store.lastLoadFailed)
        #expect(store.lastError == nil)
        #expect(store.status == .empty)
    }

    @Test("a cancelled read settles nothing")
    func aCancellationSettlesNothing() async {
        let client = Stub.client { _, _, _ in throw CancellationError() }
        let store = PlacesStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)

        #expect(!store.hasSettledOnce, "the app's own supersede was read as an answer")
        #expect(!store.lastLoadFailed)
        #expect(store.status == .pending)
        #expect(!store.isLoading, "and the spinner stayed up")
    }

    // MARK: - invariant 1: one question, one request

    @Test("two loads that overlap are one request on the wire")
    func overlappingLoadsMakeOneRequest() async {
        let entered = Signal()
        let release = Signal()
        let requests = Counter()
        let client = Stub.client { _, _, _ in
            requests.increment()
            // Only the first is held: a second request must be able to ANSWER, or the mutation
            // this witness exists to catch would hang the test instead of failing it.
            if requests.count == 1 {
                entered.signal()
                await release.wait()
            }
            return Self.answer([Self.marker(uid: "a")])
        }
        let store = PlacesStore()

        let inFlight = Task { await store.load(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        // The second tap, landing while the first read is still out. A disabled button is never
        // the guard: the store refuses it itself.
        await store.load(using: client.handle, baseURL: Stub.baseURL)
        release.signal()
        await inFlight.value

        #expect(requests.count == 1, "a second request went out for a question already asked")
        #expect(store.markers.map(\.uid) == ["a"])
        #expect(!store.isLoading, "the guard was taken and never released")
    }

    // MARK: - invariant 2: the answer is judged against the session that asked

    @Test("markers answered for a session that has ended are not put on the next one's map")
    func aStaleAnswerIsNotApplied() async throws {
        let entered = Signal()
        let release = Signal()
        let session = await signedIn { _, _, operation in
            guard operation == markersOperation else { return Stub.json(Stub.user) }
            entered.signal()
            await release.wait()
            return Self.answer([Self.marker(uid: "a")])
        }
        let store = PlacesStore()
        store.reports(to: session)
        let underA = try #require(session.activeHandle)

        let inFlight = Task { await store.load(using: underA, baseURL: Stub.baseURL) }
        await entered.wait()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        #expect(session.state.user != nil, "the premise: somebody else owns the session now")
        release.signal()
        await inFlight.value

        #expect(store.markers.isEmpty, "one account's photographs were placed on another's map")
        #expect(!store.hasSettledOnce, "and the question was recorded as settled")
        #expect(!store.isLoading, "and the spinner stayed up")
    }

    // MARK: - invariant 4: a refusal carries the epoch of the credential that earned it

    @Test("a refusal of the credential in hand reaches the session's one decision rule")
    func aRefusalOfTheCurrentCredentialIsForwarded() async throws {
        let refusing = LockedValue<Bool>(false)
        let session = await signedIn { _, _, operation in
            guard operation == markersOperation else { return Stub.json(Stub.user) }
            guard refusing.get() else { return Self.answer([]) }
            return Stub.empty(.unauthorized)
        }
        let seen = LockedValue<[CredentialRefusal]>([])
        let store = forwarding(to: session, recordingInto: seen)
        let handle = try #require(session.activeHandle)
        refusing.set(true)

        await store.load(using: handle, baseURL: Stub.baseURL)

        #expect(seen.get().count == 1, "the refusal never reached the rule that acts on it")
        #expect(
            seen.get().first?.issuedUnder == 0,
            "and it arrived without the epoch of the credential that earned it"
        )
        #expect(session.state == .signedOut, "the session survived a refusal of its own credential")
        #expect(store.lastError != nil)
        #expect(store.status == .error)
    }

    @Test("a refusal answered after the session ended reaches nothing and says nothing")
    func aRefusalForAnEndedSessionIsNotForwarded() async throws {
        let entered = Signal()
        let release = Signal()
        let session = await signedIn { _, _, operation in
            guard operation == markersOperation else { return Stub.json(Stub.user) }
            entered.signal()
            await release.wait()
            return Stub.empty(.unauthorized)
        }
        let seen = LockedValue<[CredentialRefusal]>([])
        let store = forwarding(to: session, recordingInto: seen)
        let underA = try #require(session.activeHandle)

        let inFlight = Task { await store.load(using: underA, baseURL: Stub.baseURL) }
        await entered.wait()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        #expect(session.state.user != nil, "the premise: somebody else owns the session now")
        release.signal()
        await inFlight.value

        #expect(seen.get().isEmpty, "one account's 401 was handed the rule that ends a session")
        #expect(session.state.user != nil, "and it ended the session that replaced it")
        #expect(store.lastError == nil, "and wrote one account's sentence over another's map")
        #expect(!store.hasSettledOnce)
        #expect(!store.isLoading)
    }

    @Test("a refusal earned by a credential the session has since renewed is still forwarded")
    func aRefusalOfARenewedCredentialIsForwarded() async throws {
        let refusing = LockedValue<Bool>(false)
        let credential = LockedValue<PresentedCredential?>(nil)
        let session = SessionStore(
            credentials: vault(),
            makeClient: { _, presented in
                credential.set(presented)
                return Stub.client(
                    token: presented,
                    afterRefusal: {
                        // The window itself: the middleware has stamped the presented generation
                        // onto the refusal and thrown it, and the store has not resumed. Whether
                        // that generation is still the current one is nobody's question yet — the
                        // effect asks it, hops later.
                        guard refusing.get() else { return }
                        presented.replace(with: successorToken)
                    }
                ) { _, _, operation in
                    guard operation == markersOperation else { return Stub.json(Stub.user) }
                    guard refusing.get() else { return Self.answer([]) }
                    return Stub.empty(.unauthorized)
                }
            },
            lastKnownUser: boundFile()
        )
        await session.restore()
        let seen = LockedValue<[CredentialRefusal]>([])
        let store = forwarding(to: session, recordingInto: seen)
        let handle = try #require(session.activeHandle)
        refusing.set(true)

        await store.load(using: handle, baseURL: Stub.baseURL)

        #expect(credential.get()?.presented().epoch == 1, "the premise: a renewal landed")
        // Filtering this one out in the store would be the same defect written a third time: the
        // rule that knows what a superseded refusal means lives in one place and is asked here.
        #expect(seen.get().count == 1, "the store decided for itself that this one did not matter")
        #expect(
            seen.get().first?.issuedUnder == 0,
            "and it arrived carrying anything but the epoch that earned it"
        )
        #expect(session.state.user != nil, "a refusal of a replaced token ended the session")
        #expect(store.lastError == nil, "and told a renewed session to sign in again")
        #expect(store.status == .error, "the read still failed, whatever it was about")
    }

    // MARK: - the session behind the witnesses

    /// The store as the signed-in view builds it: the refusal goes to the session's one rule, and
    /// the spy is a record of WHAT was forwarded, not a substitute for the rule.
    private func forwarding(
        to session: SessionStore,
        recordingInto seen: LockedValue<[CredentialRefusal]>
    ) -> PlacesStore {
        let store = PlacesStore(onUnauthorized: { [session] refusal in
            seen.set(seen.get() + [refusal])
            return await session.handle(refusal)
        })
        store.reports(to: session)
        return store
    }

    private func vault() -> InMemoryCredentials {
        let store = InMemoryCredentials()
        try? store.set(storedToken, for: SessionStore.tokenAccount)
        try? store.set(storedAddress, for: SessionStore.serverAccount)
        return store
    }

    /// The last-known-user file a launch admits on, bound to the token the vault holds.
    private func boundFile() -> StubLastKnownUser {
        StubLastKnownUser(
            LastKnownUser(
                subject: "fabian",
                displayName: "Fabian",
                email: "f@example.invalid",
                role: "admin",
                authKind: "oidc",
                serverBaseURL: storedAddress,
                credentialFingerprint: CredentialFingerprint.of(storedToken)
            )
        )
    }

    /// A real session, signed in over the app's own client, answering from the script it is given.
    private func signedIn(handler: @escaping StubTransport.Handler) async -> SessionStore {
        let session = SessionStore(
            credentials: vault(),
            makeClient: { _, presented in Stub.client(token: presented, handler: handler) },
            lastKnownUser: boundFile()
        )
        await session.restore()
        return session
    }
}

/// A one-shot hand-off between a test and the scripted transport it is driving.
///
/// The interleavings this file is about — a read in flight while the session changes under it —
/// need the test to know the request has REACHED the transport, and the transport to be held there
/// until the test says go. `AsyncStream` removes the clock from both directions: the waiter resumes
/// when and only when the other side signals, and because the stream buffers, a signal that arrives
/// before anyone waits is delivered rather than missed. A poll would be the same test written as a
/// race, and on a loaded build host a fence that works perfectly would be reported broken.
private final class Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    /// Called from inside the transport, which the client runs off the main actor.
    func signal() { continuation.yield() }

    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}
