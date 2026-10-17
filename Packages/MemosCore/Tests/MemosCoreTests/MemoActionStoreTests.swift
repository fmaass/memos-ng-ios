import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

/// Select mode's memo actions (MEMNG-788): Set visibility, one PATCH per distinct memo of the
/// caller's with `visibility` alone in its body, and Add to trip, ONE inclusion request — each in
/// its kind's slot (an identical call joins, a differing one is refused), each fenced by the
/// session generation that issued it, each re-reading the trips it touched.
@MainActor
@Suite("Memo actions — Set visibility and Add to trip")
struct MemoActionStoreTests {
    nonisolated static let patchMemo = "patch_memo_api_memos__uid__patch"
    nonisolated static let inclusion = "include_attachments_api_collections__uid__attachments_post"

    /// A server that answers the memo PATCH with the memo and the inclusion with `outcomes` (by
    /// picture uid; `added` for any other), or with `inclusionStatus` when one is given.
    private static func server(
        outcomes: [String: String] = [:], inclusionStatus: HTTPResponse.Status? = nil,
        hold: TripServer.Hold? = nil
    ) -> TripServer {
        let box = ServerBox()
        let server = TripServer(
            answer: { request, operation in
                let path = (request.path ?? "").split(separator: "?").first ?? ""
                let uid = path.split(separator: "/").map(String.init).dropFirst(2).first ?? ""
                switch operation {
                case Self.patchMemo:
                    return Stub.json(Stub.memo(uid: uid))
                case Self.inclusion:
                    if let inclusionStatus {
                        return Stub.detail("refused", status: inclusionStatus)
                    }
                    let sent = box.server?.calls.of(Self.inclusion).last?.body
                    let names = Stub.object(sent)["attachmentUids"] as? [String] ?? []
                    let results = names.map {
                        #"{"attachmentUid":"\#($0)","outcome":"\#(outcomes[$0] ?? "added")"}"#
                    }
                    return Stub.json(#"{"results":[\#(results.joined(separator: ","))]}"#)
                default:
                    return nil
                }
            }, hold: hold)
        box.server = server
        return server
    }

    private func bodies(_ server: TripServer, _ operation: String) -> [[String: Any]] {
        server.calls.of(operation).map { Stub.object($0.body) }
    }

    private func paths(_ server: TripServer, _ operation: String) -> [String] {
        server.calls.of(operation).map(\.path)
    }

    private static let chosen = [
        MemoActionPicture(uid: "p1", memoUID: "m1", mine: true),
        MemoActionPicture(uid: "p2", memoUID: "m1", mine: true),
        MemoActionPicture(uid: "p3", memoUID: "m2", mine: true),
        MemoActionPicture(uid: "p4", memoUID: "m3", mine: false),
        MemoActionPicture(uid: "p5", memoUID: nil, mine: true),
    ]

    // MARK: - Set visibility

    @Test("Set visibility names each distinct memo of the caller's once: no other's, no orphan")
    func theMemosOfAChoice() {
        #expect(MemoActionPicture.memos(of: Self.chosen) == ["m1", "m2"])
        #expect(MemoActionPicture.memos(of: []) == [])
        #expect(MemoActionPicture.memos(of: [Self.chosen[3], Self.chosen[4]]) == [])
    }

    @Test("one PATCH per memo, two pictures of one memo deduplicated, visibility alone in a body")
    func onePatchPerMemo() async throws {
        let server = Self.server()
        let store = MemoActionStore(trips: nil)
        let memos = MemoActionPicture.memos(of: Self.chosen) + ["m1"]
        let result = await store.setVisibility(
            .public, forMemos: memos, using: server.client.handle, baseURL: Stub.baseURL)

        #expect(paths(server, Self.patchMemo) == ["/api/memos/m1", "/api/memos/m2"])
        for body in bodies(server, Self.patchMemo) {
            #expect(Array(body.keys) == ["visibility"], "the body carried more: \(body)")
            #expect(body["visibility"] as? String == "PUBLIC")
        }
        #expect(
            result == .finished(.init(action: .visibility(.public), asked: 2, changed: 2)))
        #expect(server.calls.of(Self.inclusion).isEmpty)
    }

    @Test("one chosen picture of a protected memo with an unselected sibling changes that one memo")
    func aSiblingRidesAlong() async throws {
        let server = Self.server()
        let store = MemoActionStore(trips: nil)
        // p1 is chosen; its sibling p2 on the same memo m1 is not. The memo is what changes —
        // its text and p2 with it — which is what the confirmation discloses.
        let memos = MemoActionPicture.memos(of: [Self.chosen[0]])
        #expect(memos == ["m1"])
        _ = await store.setVisibility(
            .public, forMemos: memos, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(paths(server, Self.patchMemo) == ["/api/memos/m1"])
    }

    @Test("a memo the server refuses is counted out and the others still change: N of M")
    func aPartialRun() async throws {
        let server = TripServer(answer: { request, operation in
            guard operation == Self.patchMemo else { return nil }
            if request.path == "/api/memos/m1" { return Stub.detail("gone", status: .notFound) }
            return Stub.json(Stub.memo(uid: "m2"))
        })
        let result = await MemoActionStore(trips: nil).setVisibility(
            .protected, forMemos: ["m1", "m2"], using: server.client.handle,
            baseURL: Stub.baseURL)
        guard case .finished(let outcome) = result else {
            Issue.record("not finished: \(result)")
            return
        }
        #expect(outcome.asked == 2)
        #expect(outcome.changed == 1)
        #expect(outcome.failure != nil)
        #expect(server.calls.of(Self.patchMemo).count == 2)
    }

    @Test("an identical call while one runs joins it: one request per memo on the wire")
    func anIdenticalCallJoins() async throws {
        let gate = ActionGate()
        let server = Self.server(hold: { operation, count in
            if operation == Self.patchMemo, count == 1 { await gate.wait() }
        })
        let store = MemoActionStore(trips: nil)
        var joined = 0
        store.onJoin = { joined += 1 }
        let handle = server.client.handle
        let first = Task {
            await store.setVisibility(
                .public, forMemos: ["m1", "m2"], using: handle, baseURL: Stub.baseURL)
        }
        await arrival(of: Self.patchMemo, in: server)
        let second = Task {
            await store.setVisibility(
                .public, forMemos: ["m2", "m1"], using: handle, baseURL: Stub.baseURL)
        }
        for _ in 0..<10_000 where joined == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        await gate.open()
        let (a, b) = (await first.value, await second.value)

        #expect(joined == 1, "the second call did not join")
        #expect(a == b)
        #expect(paths(server, Self.patchMemo) == ["/api/memos/m1", "/api/memos/m2"])
    }

    @Test("a differing call while one runs is refused, sends nothing and gets no other's result")
    func aDifferingCallIsRefused() async throws {
        let gate = ActionGate()
        let server = Self.server(hold: { operation, count in
            if operation == Self.patchMemo, count == 1 { await gate.wait() }
        })
        let store = MemoActionStore(trips: nil)
        let handle = server.client.handle
        let first = Task {
            await store.setVisibility(
                .public, forMemos: ["m1"], using: handle, baseURL: Stub.baseURL)
        }
        await arrival(of: Self.patchMemo, in: server)
        // Each differing call runs on its own task and is waited for with a bound, so a store
        // that made it wait on the running call fails here instead of holding the suite.
        let answered = LockedValue<Int>(0)
        let otherValue = Task {
            let result = await store.setVisibility(
                .protected, forMemos: ["m1"], using: handle, baseURL: Stub.baseURL)
            answered.set(answered.get() + 1)
            return result
        }
        let otherMemos = Task {
            let result = await store.setVisibility(
                .public, forMemos: ["m1", "m2"], using: handle, baseURL: Stub.baseURL)
            answered.set(answered.get() + 1)
            return result
        }
        for _ in 0..<2_000 where answered.get() < 2 { try? await Task.sleep(for: .milliseconds(1)) }
        let answeredWhileRunning = answered.get()
        await gate.open()
        _ = await first.value

        #expect(answeredWhileRunning == 2, "a differing call waited on the running one")
        #expect(await otherValue.value == .refused)
        #expect(await otherMemos.value == .refused)
        #expect(MemoActionStore.busySentence == "Another change is still running")
        #expect(paths(server, Self.patchMemo) == ["/api/memos/m1"])
        let after = await store.setVisibility(
            .protected, forMemos: ["m1"], using: handle, baseURL: Stub.baseURL)
        #expect(after != .refused, "the slot was not given back")
    }

    @Test("a run answered after sign-out is dropped: nothing more sent, no outcome, no re-read")
    func theGenerationFence() async throws {
        let gate = ActionGate()
        let server = Self.server(hold: { operation, count in
            if operation == Self.patchMemo, count == 1 { await gate.wait() }
        })
        let issued = SessionHandle(client: server.client, generation: 1)
        let session = TripTestSession(for: issued)
        let (trips, members) = await TripSeeder(server: server).members()
        let store = MemoActionStore(trips: trips)
        store.reports(to: session)
        let revision = trips.revision
        let run = Task {
            await store.setVisibility(
                .public, forMemos: ["m1", "m2"], using: issued, baseURL: Stub.baseURL)
        }
        await arrival(of: Self.patchMemo, in: server)
        session.activeHandle = nil
        await gate.open()
        let result = await run.value

        #expect(result == .superseded)
        #expect(paths(server, Self.patchMemo) == ["/api/memos/m1"], "a PATCH outlived the session")
        #expect(trips.revision == revision, "the trips were re-read under no session")
        _ = members
    }

    @Test("Set visibility drops the trips' members and filtered reads, so the screens read again")
    func visibilityRereadsTrips() async throws {
        let server = Self.server()
        let uid = server.seed(title: "Portugal", tag: "portugal", pictures: [0, 1])
        let (trips, members) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        let handle = server.client.handle
        await members.drain(trip, using: handle, baseURL: Stub.baseURL)
        let query = TripMemberQuery(filter: .images)
        await members.drainFiltered(trip, query: query, using: handle, baseURL: Stub.baseURL)
        #expect(members.state(for: trip) != .notLoaded, "control: the drain landed")

        _ = await MemoActionStore(trips: trips).setVisibility(
            .public, forMemos: ["m-p0000"], using: handle, baseURL: Stub.baseURL)

        #expect(members.state(for: trip) == .notLoaded)
        #expect(members.filteredState(for: trip, query: query) == .notLoaded)
    }

    // MARK: - Add to trip

    @Test("Add to trip is ONE inclusion of the caller's pictures on a memo, and says N of M added")
    func oneInclusion() async throws {
        let server = Self.server(outcomes: ["p2": "alreadyMember"])
        let uid = server.seed(title: "Portugal", tag: "portugal", pictures: [0])
        let (trips, _) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        let result = await MemoActionStore(trips: trips).add(
            attachments: Self.chosen + [Self.chosen[0]], toTrip: trip,
            using: server.client.handle, baseURL: Stub.baseURL)

        #expect(paths(server, Self.inclusion) == ["/api/collections/\(uid)/attachments"])
        let body = try #require(bodies(server, Self.inclusion).first)
        #expect(Array(body.keys) == ["attachmentUids"])
        #expect(body["attachmentUids"] as? [String] == ["p1", "p2", "p3"])
        #expect(result == .finished(.init(action: .addToTrip(uid), asked: 5, changed: 2)))
        #expect(server.calls.of(Self.patchMemo).isEmpty, "Add to trip wrote a memo itself")
    }

    @Test("a picture whose memo the outbox still owes an edit is held back and counted")
    func theOutboxHoldsAPicture() async throws {
        let server = Self.server()
        let uid = server.seed(title: "Portugal", tag: "portugal", pictures: [0])
        let (trips, _) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        let store = MemoActionStore(
            trips: trips, outboxCheck: { memo, _ in memo == "m2" ? .owesEdit : .clear })
        let result = await store.add(
            attachments: Self.chosen, toTrip: trip, using: server.client.handle,
            baseURL: Stub.baseURL)
        let body = try #require(bodies(server, Self.inclusion).first)
        #expect(body["attachmentUids"] as? [String] == ["p1", "p2"])
        #expect(
            result
                == .finished(
                    .init(action: .addToTrip(uid), asked: 5, changed: 2, heldByOutbox: 1)))
    }

    @Test("the outbox owes an edit to a memo whose capture resolved to it with an edit pending")
    func theOutboxQuery() {
        var job = UploadJob(
            content: "x", capturedAt: Date(timeIntervalSince1970: 0),
            files: [
                OutboxFile(
                    relativePath: "f", filename: "f.heic", mime: "image/heic", byteSize: 1,
                    attachmentUID: "p9")
            ],
            binding: AccountBinding(serverBaseURL: Stub.baseURL, ownerSubject: "fabian"))
        job.resolvedMemoUID = "m1"
        #expect(!MemoActionStore.owesEdit(in: [job], memoUID: "m1", attachmentUID: "p1"))
        job.pendingEdit = PendingEdit(
            content: "y", visibility: nil, capturedAt: Date(timeIntervalSince1970: 0), fileIDs: [])
        #expect(MemoActionStore.owesEdit(in: [job], memoUID: "m1", attachmentUID: "p1"))
        #expect(MemoActionStore.owesEdit(in: [job], memoUID: nil, attachmentUID: "p9"))
        #expect(!MemoActionStore.owesEdit(in: [job], memoUID: "m2", attachmentUID: "p2"))
        #expect(!MemoActionStore.owesEdit(in: [], memoUID: "m1", attachmentUID: "p1"))
    }

    @Test("a trip without a tag is refused by the server: nothing added, and said so")
    func aTripWithoutATag() async throws {
        let server = Self.server(inclusionStatus: .conflict)
        let uid = server.seed(title: "Span only")
        let (trips, _) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        let result = await MemoActionStore(trips: trips).add(
            attachments: Self.chosen, toTrip: trip, using: server.client.handle,
            baseURL: Stub.baseURL)
        guard case .finished(let outcome) = result else {
            Issue.record("not finished: \(result)")
            return
        }
        #expect(outcome.changed == 0)
        #expect(outcome.failure?.contains("no tag") == true, "\(String(describing: outcome))")
    }

    @Test("Add to trip re-reads the trip after the inclusion: its record and its members")
    func addRereadsTheTrip() async throws {
        let server = Self.server()
        let uid = server.seed(title: "Portugal", tag: "portugal", pictures: [0])
        let (trips, members) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        let handle = server.client.handle
        await members.drain(trip, using: handle, baseURL: Stub.baseURL)
        let query = TripMemberQuery(filter: .images)
        await members.drainFiltered(trip, query: query, using: handle, baseURL: Stub.baseURL)
        server.edit(uid) { $0.pictures = [0, 1] }

        _ = await MemoActionStore(trips: trips).add(
            attachments: [MemoActionPicture(uid: TripWire.uid(1), memoUID: "m", mine: true)],
            toTrip: trip, using: handle, baseURL: Stub.baseURL)

        let operations = server.calls.all.map(\.operation)
        let posted = try #require(operations.firstIndex(of: Self.inclusion))
        let after = operations[(posted + 1)...]
        #expect(after.contains(TripWire.get), "the record was not read again: \(after)")
        #expect(after.contains(TripWire.members), "the members were not drained again: \(after)")
        let live = try #require(trips.trips.first { $0.uid == uid })
        #expect(members.members(for: live).map(\.id) == [TripWire.uid(0), TripWire.uid(1)])
        #expect(members.filteredState(for: live, query: query) == .notLoaded)
    }

    // MARK: - Edges

    @Test("at most 500 pictures go in one inclusion: 500 is one POST, 501 is refused unsent")
    func theInclusionCap() async throws {
        let server = Self.server()
        let uid = server.seed(title: "Portugal", tag: "portugal", pictures: [0])
        let (trips, _) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        let store = MemoActionStore(trips: trips)
        let cap = MemoActionStore.inclusionCap
        func pictures(_ count: Int) -> [MemoActionPicture] {
            (0..<count).map { MemoActionPicture(uid: "c\($0)", memoUID: "m\($0)", mine: true) }
        }

        let full = await store.add(
            attachments: pictures(cap), toTrip: trip, using: server.client.handle,
            baseURL: Stub.baseURL)
        #expect(full == .finished(.init(action: .addToTrip(uid), asked: cap, changed: cap)))
        #expect(server.calls.of(Self.inclusion).count == 1)

        let over = await store.add(
            attachments: pictures(cap + 1), toTrip: trip, using: server.client.handle,
            baseURL: Stub.baseURL)
        guard case .finished(let outcome) = over else {
            Issue.record("not finished: \(over)")
            return
        }
        #expect(outcome.changed == 0)
        #expect(outcome.failure?.contains("at most 500") == true, "\(String(describing: outcome))")
        #expect(server.calls.of(Self.inclusion).count == 1, "an inclusion over the cap was sent")
    }

    @Test("a refused credential reaches the session once and stops the run: no PATCH after it")
    func aRefusedCredential() async {
        let handled = LockedValue<Int>(0)
        let server = TripServer(answer: { _, operation in
            operation == Self.patchMemo ? Stub.empty(.unauthorized) : nil
        })
        let store = MemoActionStore(
            trips: nil,
            onUnauthorized: { _ in
                handled.set(handled.get() + 1)
                return .endedSession
            })
        let result = await store.setVisibility(
            .public, forMemos: ["m1", "m2"], using: server.client.handle, baseURL: Stub.baseURL)

        #expect(handled.get() == 1, "the refusal did not reach the session exactly once")
        #expect(server.calls.of(Self.patchMemo).count == 1, "a PATCH went out after the refusal")
        guard case .finished(let outcome) = result else {
            Issue.record("not finished: \(result)")
            return
        }
        #expect(outcome.changed == 0)
        #expect(outcome.failure != nil, "a refused run said nothing")
    }

    // MARK: - The outbox, as the app wires it

    @Test("the app's wiring over a real outbox owing an edit holds the picture until it is sent")
    func theRealOutboxHoldsAPicture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = SignedOut()
        let repository = try OutboxRepository(
            root: root, stillCurrent: { credentials.stillCurrent(epoch: $0) })
        let outbox = Outbox(
            repository: repository, credentials: credentials, http: Unsent(),
            scheduler: NoChunkSession(), completion: MemoCompletionEndpoint(http: Unsent()),
            network: UsablePath(), preferences: UploadPreferences(defaults: Self.scratchDefaults()))
        let edited = UploadJob(
            content: "Lisbon", capturedAt: Date(timeIntervalSince1970: 0),
            files: [
                OutboxFile(
                    relativePath: "a.jpg", filename: "a.jpg", mime: "image/jpeg", byteSize: 1,
                    attachmentUID: "p1")
            ],
            binding: AccountBinding(serverBaseURL: Stub.baseURL, ownerSubject: "alice"),
            resolvedMemoUID: "m1",
            pendingEdit: PendingEdit(
                content: "Lisbon at dusk", visibility: nil,
                capturedAt: Date(timeIntervalSince1970: 0), fileIDs: []))
        try await repository.save(edited)
        await outbox.refresh()
        #expect(outbox.jobs.map(\.id) == [edited.id], "positive control: the queue holds the edit")

        let server = Self.server()
        let trip = Trip(
            uid: "t1", title: "Portugal", tag: "portugal", createdAt: Date(), updatedAt: Date())
        let store = MemoActionStore(trips: nil, outboxCheck: MemoActionStore.outboxCheck(outbox))
        let picture = [MemoActionPicture(uid: "p1", memoUID: "m1", mine: true)]
        let owed = await store.add(
            attachments: picture, toTrip: trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(
            owed
                == .finished(
                    .init(action: .addToTrip("t1"), asked: 1, changed: 0, heldByOutbox: 1)))
        #expect(server.calls.of(Self.inclusion).isEmpty, "a picture whose memo is owed was sent")

        // The edit is sent: the capture leaves the queue, as a confirmed memo does.
        await repository.delete(edited)
        await outbox.refresh()
        let sent = await store.add(
            attachments: picture, toTrip: trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(sent == .finished(.init(action: .addToTrip("t1"), asked: 1, changed: 1)))
        #expect(bodies(server, Self.inclusion).first?["attachmentUids"] as? [String] == ["p1"])
    }

    @Test("with no outbox to ask, the app's wiring cannot tell: the picture is held, and said so")
    func noOutboxCannotTell() async {
        let server = Self.server()
        let trip = Trip(
            uid: "t1", title: "Portugal", tag: "portugal", createdAt: Date(), updatedAt: Date())
        let store = MemoActionStore(trips: nil, outboxCheck: MemoActionStore.outboxCheck(nil))
        let result = await store.add(
            attachments: [MemoActionPicture(uid: "p1", memoUID: "m1", mine: true)], toTrip: trip,
            using: server.client.handle, baseURL: Stub.baseURL)
        #expect(
            result
                == .finished(
                    .init(action: .addToTrip("t1"), asked: 1, changed: 0, heldUnchecked: 1)))
        #expect(server.calls.of(Self.inclusion).isEmpty, "an unchecked picture was sent")
    }

    private static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "memo-actions-\(UUID().uuidString)") ?? .standard
    }
}

// MARK: - A real outbox that sends nothing

/// No account: the outbox this suite builds never acquires credentials, so it sends nothing.
private struct SignedOut: OutboxCredentialsProviding {
    func currentCredentials() async -> OutboxCredentials? { nil }
    func isCurrent(_ credentials: OutboxCredentials) -> Bool { false }
    func stillCurrent(epoch: Int) -> Bool { false }
}

/// The network of that outbox, never reached; a server error if it were.
private struct Unsent: OutboxHTTPPerforming {
    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        OutboxHTTPResponse(statusCode: 500)
    }
}

/// No background transfers.
private struct NoChunkSession: OutboxChunkScheduling {
    func inFlight() async -> [OutboxTaskIdentity] { [] }
    func upload(
        _ request: URLRequest, fromFile file: URL, identity: OutboxTaskIdentity,
        under authority: SendAuthority, issuedUnder epoch: Int
    ) async {}
    func cancel(_ identities: [OutboxTaskIdentity]) async {}
    func cancelEveryTask() async {}
}

/// A path the outbox would find usable, never changing.
private struct UsablePath: NetworkPathProviding {
    func currentPath() -> NetworkPath {
        NetworkPath(usesCellular: false, isExpensive: false, isConstrained: false)
    }
    func onPathChange(_ handler: @escaping OutboxTrigger) {}
}

/// Lets the scripted answer reach the server it belongs to, made after it.
private final class ServerBox: @unchecked Sendable {
    var server: TripServer?
}

/// Waits until `server` has seen a request of `operation`, yielding between looks.
@MainActor
private func arrival(of operation: String, in server: TripServer) async {
    for _ in 0..<10_000 where server.calls.of(operation).isEmpty {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Holds a scripted answer until the test opens it; once open, every wait passes.
private actor ActionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
