import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

private let deleteOperation = "delete_attachment_api_attachments__uid__delete"
private let listOperation = "list_attachments_api_attachments_get"
private let whoamiOperation = "whoami_api_auth_user_get"

/// Deleting the Library's selection (MEMNG-589): one `DELETE /api/attachments/{uid}` per chosen
/// picture, in the order they were chosen, one after the other, stopping at the first failure.
///
/// Every case reads what the scripted transport actually SAW, through the real generated client:
/// a delete loop is judged by the requests it sends and the ones it does not, and an outcome it
/// reports about requests that never left would pass any assertion made on the outcome alone.
@MainActor
@Suite("Library selection delete")
struct LibraryDeleteTests {
    /// How long a held request or a wait on one may last before the test gives up rather than hang.
    private nonisolated static let patience: Duration = .seconds(10)

    /// Keeps a request open until the test lets it go — or until `patience` runs out, when it
    /// fails the request instead of hanging the suite.
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        let deadline = ContinuousClock.now + patience
        while !release.get() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Whether `flag` came up within `patience`.
    private static func arrived(_ flag: LockedValue<Bool>) async -> Bool {
        let deadline = ContinuousClock.now + patience
        while !flag.get() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    private nonisolated static func page(_ uids: [String]) -> (HTTPResponse, HTTPBody?) {
        Stub.json("[\(uids.map(Stub.libraryItem(uid:)).joined(separator: ","))]")
    }

    /// The uid a DELETE named, read off the path the client built.
    private nonisolated static func target(_ request: HTTPRequest) -> String {
        "\(request.method.rawValue) \(request.path ?? "")"
    }

    private static func deletes(_ uids: [String]) -> [String] {
        uids.map { "DELETE /api/attachments/\($0)" }
    }

    /// A store holding `grid`, read through `client`.
    private static func loaded(
        _ client: any APIProtocol,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) async -> MediaLibraryStore {
        let store = MediaLibraryStore(onUnauthorized: onUnauthorized)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        return store
    }

    private static func signedIn(handler: @escaping StubTransport.Handler) async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            sleeper: { _ in throw CancellationError() }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    // MARK: - the run

    @Test("every chosen picture answered 204 is deleted, with the token on it, and leaves the grid")
    func everyNoContentIsDeleted() async {
        let seen = LockedValue<[String]>([])
        let authorization = LockedValue<[String?]>([])
        let client = Stub.client(token: { "memos_pat_abc" }) { request, _, operation in
            guard operation == deleteOperation else { return Self.page(["a", "b", "c", "d"]) }
            seen.set(seen.get() + [Self.target(request)])
            authorization.set(authorization.get() + [request.headerFields[.authorization]])
            return Stub.empty(.noContent)
        }
        let store = await Self.loaded(client)
        #expect(store.items.map(\.id) == ["a", "b", "c", "d"], "control: the grid landed")

        let outcome = await store.delete(["a", "b", "c"], using: client.handle)

        #expect(seen.get() == Self.deletes(["a", "b", "c"]), "the store sent \(seen.get())")
        #expect(authorization.get() == Array(repeating: "Bearer memos_pat_abc", count: 3))
        let expected = LibraryDeleteOutcome(
            deleted: ["a", "b", "c"], failed: nil, notAttempted: [], stoppedForSessionChange: false
        )
        #expect(outcome == expected)
        #expect(store.items.map(\.id) == ["d"], "a picture that was not chosen left the grid too")
        #expect(!store.isDeleting)
    }

    @Test("the wire order is the order the pictures were chosen, not the grid's")
    func theWireOrderIsTheSelectionOrder() async {
        let seen = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            guard operation == deleteOperation else { return Self.page(["a", "b", "c", "d"]) }
            seen.set(seen.get() + [Self.target(request)])
            return Stub.empty(.noContent)
        }
        let store = await Self.loaded(client)

        let outcome = await store.delete(["d", "a", "c"], using: client.handle)

        #expect(seen.get() == Self.deletes(["d", "a", "c"]), "the store sent \(seen.get())")
        #expect(outcome?.deleted == ["d", "a", "c"])
        #expect(store.items.map(\.id) == ["b"])
    }

    @Test("a 404 in the middle counts as deleted and the run goes on")
    func aNotFoundCountsAsDone() async {
        let seen = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            guard operation == deleteOperation else { return Self.page(["a", "b", "c"]) }
            seen.set(seen.get() + [Self.target(request)])
            return request.path?.hasSuffix("/b") == true
                ? Stub.empty(.notFound) : Stub.empty(.noContent)
        }
        let store = await Self.loaded(client)

        let outcome = await store.delete(["a", "b", "c"], using: client.handle)

        #expect(seen.get() == Self.deletes(["a", "b", "c"]), "the run stopped at the 404")
        #expect(outcome?.deleted == ["a", "b", "c"])
        #expect(outcome?.failedCount == 0)
        #expect(store.items.isEmpty, "a picture the server no longer has is still on the grid")
        #expect(store.lastError == nil, "a 404 was reported as a failure")
    }

    @Test("the first server error stops the run and the later pictures never reach the wire")
    func theFirstErrorStopsTheRun() async {
        let seen = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            guard operation == deleteOperation else { return Self.page(["a", "b", "c", "d"]) }
            seen.set(seen.get() + [Self.target(request)])
            return request.path?.hasSuffix("/b") == true
                ? Stub.empty(.internalServerError) : Stub.empty(.noContent)
        }
        let store = await Self.loaded(client)

        let outcome = await store.delete(["a", "b", "c", "d"], using: client.handle)

        #expect(seen.get() == Self.deletes(["a", "b"]), "the store sent \(seen.get())")
        let expected = LibraryDeleteOutcome(
            deleted: ["a"], failed: "b", notAttempted: ["c", "d"], stoppedForSessionChange: false
        )
        #expect(outcome == expected)
        #expect(outcome?.deletedCount == 1)
        #expect(outcome?.failedCount == 1)
        #expect(outcome?.notAttemptedCount == 2)
        #expect(store.items.map(\.id) == ["b", "c", "d"], "only the one that went may leave")
        // The screen's message reports the run; a sentence over the grid would say it twice.
        #expect(store.lastError == nil)
    }

    @Test("a refused credential stops the run and goes to the session's funnel, never counted done")
    func aRefusalStopsTheRunThroughTheTypedPath() async {
        let seen = LockedValue<[String]>([])
        let refusals = Counter()
        let client = Stub.client { request, _, operation in
            guard operation == deleteOperation else { return Self.page(["a", "b", "c"]) }
            seen.set(seen.get() + [Self.target(request)])
            return request.path?.hasSuffix("/b") == true
                ? Stub.empty(.unauthorized) : Stub.empty(.noContent)
        }
        let store = await Self.loaded(client) { _ in
            refusals.increment()
            return .superseded
        }

        let outcome = await store.delete(["a", "b", "c"], using: client.handle)

        #expect(refusals.count == 1, "the refusal reached the funnel \(refusals.count) times")
        #expect(seen.get() == Self.deletes(["a", "b"]), "the store sent \(seen.get())")
        #expect(outcome?.deleted == ["a"])
        #expect(outcome?.failed == "b")
        #expect(outcome?.notAttempted == ["c"])
        #expect(store.items.map(\.id) == ["b", "c"])
    }

    @Test("a server that never answered stops the run and goes to the session's banner")
    func aTransportFailureGoesToTheSession() async throws {
        let seen = LockedValue<[String]>([])
        let session = await Self.signedIn { request, _, operation in
            switch operation {
            case whoamiOperation: return Stub.json(Stub.user)
            case listOperation: return Self.page(["a", "b", "c"])
            default:
                seen.set(seen.get() + [Self.target(request)])
                guard request.path?.hasSuffix("/b") != true else {
                    throw URLError(.notConnectedToInternet)
                }
                return Stub.empty(.noContent)
            }
        }
        let store = MediaLibraryStore()
        store.reports(to: session)
        let handle = try #require(session.activeHandle)
        await store.refresh(using: handle, baseURL: Stub.baseURL)
        #expect(session.verification == .verified, "control: the session stood before the run")

        let outcome = await store.delete(["a", "b", "c"], using: handle)

        #expect(seen.get() == Self.deletes(["a", "b"]), "the store sent \(seen.get())")
        #expect(outcome?.failed == "b")
        #expect(outcome?.notAttempted == ["c"])
        #expect(store.lastError == nil, "an unreachable server is the banner's to say")
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
    }

    // MARK: - the fences

    /// The operation-wide session fence. The run captured ONE handle; somebody else signs in while
    /// its first DELETE is out. Nothing after that may be sent under the old client, and nothing
    /// the run learned may be applied to a grid the new account is about to read.
    @Test("a session change between two deletes sends no further delete and applies nothing")
    func aSessionChangeStopsTheRun() async throws {
        let seen = LockedValue<[String]>([])
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        defer { release.set(true) }
        let session = await Self.signedIn { request, _, operation in
            switch operation {
            case whoamiOperation: return Stub.json(Stub.user)
            case listOperation: return Self.page(["a", "b", "c"])
            default:
                seen.set(seen.get() + [Self.target(request)])
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.empty(.noContent)
            }
        }
        let store = MediaLibraryStore()
        store.reports(to: session)
        let underA = try #require(session.activeHandle)
        await store.refresh(using: underA, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["a", "b", "c"], "control: the grid landed")

        let run = Task { await store.delete(["a", "b", "c"], using: underA) }
        #expect(await Self.arrived(entered), "the first DELETE never went out")
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        let underB = try #require(session.activeHandle)
        #expect(underB.generation != underA.generation, "control: the generation moved")
        release.set(true)
        let outcome = await run.value

        #expect(seen.get() == Self.deletes(["a"]), "a DELETE went out for a session that ended")
        #expect(outcome?.stoppedForSessionChange == true)
        #expect(outcome?.notAttempted == ["b", "c"])
        #expect(store.items.map(\.id) == ["a", "b", "c"], "a stale run changed the grid")
    }

    /// Refused, not joined: a second selection is a different list of files, so there is nothing to
    /// join it TO, and running it beside the first would be two deletes on the wire at once.
    @Test("a second delete while one runs is refused and sends nothing")
    func aSecondDeleteIsRefused() async {
        let seen = LockedValue<[String]>([])
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        defer { release.set(true) }
        let client = Stub.client { request, _, operation in
            guard operation == deleteOperation else { return Self.page(["a", "b", "c"]) }
            seen.set(seen.get() + [Self.target(request)])
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.empty(.noContent)
        }
        let store = await Self.loaded(client)
        let handle = client.handle

        let first = Task { await store.delete(["a", "b"], using: handle) }
        #expect(await Self.arrived(entered), "the first DELETE never went out")
        #expect(store.isDeleting)
        let second = await store.delete(["c"], using: handle)
        release.set(true)
        let outcome = await first.value

        #expect(second == nil, "the second run was not refused")
        #expect(outcome?.deleted == ["a", "b"])
        #expect(seen.get() == Self.deletes(["a", "b"]), "the store sent \(seen.get())")
        #expect(store.items.map(\.id) == ["c"])
        #expect(!store.isDeleting)
    }

    /// A page read before the delete, answered after it, still lists the picture. Merged as it
    /// stands, it would put a file the server no longer has back on the grid.
    @Test("a page read before the delete cannot bring a deleted picture back")
    func aStalePageCannotResurrect() async {
        let holdPage = LockedValue<Bool>(false)
        let pageOut = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        defer { release.set(true) }
        let client = Stub.client { _, _, operation in
            guard operation == deleteOperation else {
                if holdPage.get() {
                    pageOut.set(true)
                    try await Self.hold(until: release)
                }
                return Self.page(["a", "b", "c"])
            }
            return Stub.empty(.noContent)
        }
        let store = await Self.loaded(client)
        let handle = client.handle
        holdPage.set(true)

        let reread = Task { await store.refresh(using: handle, baseURL: Stub.baseURL) }
        #expect(await Self.arrived(pageOut), "the reread never went out")
        let outcome = await store.delete(["a"], using: handle)
        #expect(outcome?.deleted == ["a"])
        release.set(true)
        await reread.value

        #expect(store.items.map(\.id) == ["b", "c"], "the stale page put a deleted picture back")
    }

    /// A picture taken at `takenAt`, for the reads that look for a day.
    private nonisolated static func dated(_ uid: String, _ takenAt: String) -> String {
        let item = Stub.libraryItem(uid: uid)
        return item.replacingOccurrences(of: "2026-09-26T10:00:00Z", with: takenAt)
    }

    /// A page of dated rows with its continuation token in the header, where the server puts it.
    private nonisolated static func datedPage(
        _ rows: [(String, String)],
        nextCursor: String? = nil
    ) -> (HTTPResponse, HTTPBody?) {
        var (response, _) = Stub.json("[]")
        if let nextCursor, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = nextCursor
        }
        let body = rows.map { dated($0.0, $0.1) }.joined(separator: ",")
        return (response, HTTPBody("[\(body)]"))
    }

    /// A jump gathers its pages before it installs them. A picture it gathered from the first page
    /// and deleted while the second is still out must not ride back in when the jump lands.
    @Test("a jump that gathered a picture before its delete landed does not bring it back")
    func aJumpCannotResurrect() async {
        let secondPageOut = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        defer { release.set(true) }
        let client = Stub.client { request, _, operation in
            guard operation == listOperation else { return Stub.empty(.noContent) }
            let query = URLComponents(string: request.path ?? "")?.queryItems ?? []
            guard query.contains(where: { $0.name == "cursor" && $0.value == "c2" }) else {
                let day = "2026-09-20T10:00:00Z"
                return Self.datedPage([("x", day), ("y", day)], nextCursor: "c2")
            }
            secondPageOut.set(true)
            try await Self.hold(until: release)
            return Self.datedPage([("z", "2026-09-13T10:00:00Z")])
        }
        let store = await Self.loaded(client)
        let handle = client.handle
        #expect(store.items.map(\.id) == ["x", "y"], "control: the grid landed")

        let jump = Task {
            await store.jump(
                toDay: "2026-09-13",
                in: "Europe/Zurich",
                using: handle,
                baseURL: Stub.baseURL
            )
        }
        #expect(await Self.arrived(secondPageOut), "the jump never asked for its second page")
        let outcome = await store.delete(["x"], using: handle)
        #expect(outcome?.deleted == ["x"])
        release.set(true)
        await jump.value

        #expect(store.landing != nil, "control: the jump landed")
        #expect(store.items.map(\.id) == ["y", "z"], "the jump put a deleted picture back")
    }

    /// The session changes while the run's LAST request is out. No further send is asked about,
    /// so only a check after the answer can tell the run it is stale.
    @Test("a session change during the last delete marks the run stale and applies nothing")
    func aSessionChangeDuringTheLastDelete() async throws {
        let run = try await Self.runAcrossASignIn(["a"], answer: .noContent)

        #expect(run.outcome?.stoppedForSessionChange == true, "a stale run was reported current")
        #expect(run.outcome?.deleted == ["a"])
        #expect(run.items == ["a", "b", "c"], "a stale run changed the grid")
    }

    /// The same, when the answer that arrives after the change is a failure.
    @Test("a session change during a failing delete marks the run stale")
    func aSessionChangeDuringAFailingDelete() async throws {
        let run = try await Self.runAcrossASignIn(["a", "b"], answer: .internalServerError)

        #expect(run.outcome?.stoppedForSessionChange == true, "a stale run was reported current")
        #expect(run.outcome?.failed == "a")
        #expect(run.outcome?.notAttempted == ["b"])
        #expect(run.sent == Self.deletes(["a"]))
        #expect(run.items == ["a", "b", "c"])
    }

    /// Runs `uids` with the FIRST delete held until somebody else has signed in, then answered
    /// with `answer`. What the run returned, what the wire saw and what the grid holds afterwards.
    private static func runAcrossASignIn(
        _ uids: [String],
        answer status: HTTPResponse.Status
    ) async throws -> (outcome: LibraryDeleteOutcome?, sent: [String], items: [String]) {
        let seen = LockedValue<[String]>([])
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        defer { release.set(true) }
        let session = await Self.signedIn { request, _, operation in
            switch operation {
            case whoamiOperation: return Stub.json(Stub.user)
            case listOperation: return Self.page(["a", "b", "c"])
            default:
                seen.set(seen.get() + [Self.target(request)])
                entered.set(true)
                try await Self.hold(until: release)
                return Stub.empty(status)
            }
        }
        let store = MediaLibraryStore()
        store.reports(to: session)
        let underA = try #require(session.activeHandle)
        await store.refresh(using: underA, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["a", "b", "c"], "control: the grid landed")

        let run = Task { await store.delete(uids, using: underA) }
        #expect(await Self.arrived(entered), "the first DELETE never went out")
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        #expect(session.activeHandle?.generation != underA.generation, "control: it moved")
        release.set(true)
        let outcome = await run.value
        return (outcome, seen.get(), store.items.map(\.id))
    }

    @Test("an empty selection sends nothing")
    func anEmptySelectionSendsNothing() async {
        let sends = Counter()
        let client = Stub.client { _, _, operation in
            guard operation == deleteOperation else { return Self.page(["a"]) }
            sends.increment()
            return Stub.empty(.noContent)
        }
        let store = await Self.loaded(client)

        let outcome = await store.delete([], using: client.handle)

        #expect(sends.count == 0)
        let expected = LibraryDeleteOutcome(
            deleted: [], failed: nil, notAttempted: [], stoppedForSessionChange: false
        )
        #expect(outcome == expected)
        #expect(store.items.map(\.id) == ["a"])
        #expect(!store.isDeleting)
    }
}

// MARK: - a newly documented 503 is answered as its undocumented self was

extension LibraryDeleteTests {
    /// Only a 404 counts as gone; a 503 stops the run on that picture as it did before v2.1.0.
    @Test("a 503 on one picture fails it and stops the run, as before v2.1.0")
    func aServiceUnavailableStopsTheRun() async {
        let client = Stub.client { request, _, operation in
            guard operation == deleteOperation else { return Self.page(["a", "b", "c"]) }
            return request.path?.hasSuffix("/b") == true
                ? Stub.databaseBusy() : Stub.empty(.noContent)
        }
        let store = await Self.loaded(client)

        let outcome = await store.delete(["a", "b", "c"], using: client.handle)

        let expected = LibraryDeleteOutcome(
            deleted: ["a"], failed: "b", notAttempted: ["c"], stoppedForSessionChange: false
        )
        #expect(outcome == expected)
        #expect(store.items.map(\.id) == ["b", "c"])
    }
}
