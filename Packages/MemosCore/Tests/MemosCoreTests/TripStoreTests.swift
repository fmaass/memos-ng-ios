import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The server-backed trip store (MEMNG-751 Phase 2): `/api/collections` through the REAL generated
/// client over a scripted transport, so the request the store builds, the body bytes and the
/// decoding are all exercised. `@testable` for the join seam only.
@MainActor
@Suite("Trip store")
struct TripStoreTests {
    private let root = TripWire.root()

    private func store(
        _ identity: TimelineSnapshotIdentity? = TripWire.alice,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) -> TripStore {
        TripStore(identity: identity, root: root, onUnauthorized: onUnauthorized)
    }

    private nonisolated static func instant(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    private nonisolated static func uid(of request: HTTPRequest) -> String {
        String((request.path ?? "").split(separator: "/").last ?? "")
    }

    @Test("list decodes a Portugal-shaped fixture")
    func listDecodesPortugal() async throws {
        let client = Stub.client { _, _, operation in
            operation == TripWire.list
                ? Stub.json("[\(TripWire.portugal)]") : Stub.empty(.notFound)
        }
        let store = store()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let trip = try #require(store.trips.first, "the list applied nothing")
        #expect(store.trips.count == 1)
        #expect(trip.uid == "ptaVEyvr0EcqHDBh")
        #expect(trip.title == "Portugal 2026")
        #expect(trip.tag == "portugal2026")
        #expect(trip.spanStart == Self.instant("2026-09-12T22:00:00Z"))
        #expect(trip.spanEnd == Self.instant("2026-09-20T21:59:59Z"))
        #expect(trip.tz == "Europe/Zurich")
        #expect(trip.cover == nil)
        #expect(trip.memberCount == 157)
        #expect(store.lastError == nil)
    }

    @Test("create sends the key and a retry sends the byte-identical body")
    func createRetrySendsTheFrozenBody() async throws {
        let calls = TripCalls()
        let client = Stub.client { request, body, operation in
            let index = await calls.record(request, body, operation)
            return index == 0
                ? Stub.validationError("busy")
                : Stub.json(
                    TripWire.collection("t1", title: "Lisbon", tag: "lisbon"), status: .created)
        }
        let store = store()
        let frozen = NewTripRequest(
            scope: TripWire.alice, title: "Lisbon", tag: "lisbon", idempotencyKey: "key-0001")

        await #expect(throws: TripStore.Failure.server(status: 422)) {
            try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
        }
        let trip = try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)

        let posts = calls.of(TripWire.create)
        #expect(posts.count == 2, "a retry was \(posts.count) POSTs")
        #expect(posts.first?.body == posts.last?.body, "the retry's body was not byte-identical")
        #expect(Stub.object(posts.first?.body)["idempotencyKey"] as? String == "key-0001")
        #expect(trip.uid == "t1")
        #expect(store.trips.map(\.uid) == ["t1"])
    }

    /// The store joins overlapping Creates of one frozen request itself, whatever its caller
    /// does: the second caller waits on the first POST and sends none of its own.
    @Test("two Creates of one frozen request at once are one POST, and both get its trip")
    func identicalCreatesJoin() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let joined = TripLatch()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            entered.open()
            await release.wait()
            return Stub.json(
                TripWire.collection("t1", title: "Lisbon", tag: "lisbon"), status: .created)
        }
        let store = store()
        store.onJoin = { joined.open() }
        let frozen = NewTripRequest(
            scope: TripWire.alice, title: "Lisbon", tag: "lisbon", idempotencyKey: "key-0002")
        let first = Task {
            try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first POST never reached the wire")
        let second = Task {
            try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "the second caller never joined")
        release.open()
        let one = try await first.value
        let other = try await second.value

        #expect(calls.of(TripWire.create).count == 1, "overlapping Creates sent more than one POST")
        #expect(one == other)
        #expect(one.uid == "t1")
        #expect(store.trips.map(\.uid) == ["t1"])
    }

    @Test("an identity change with a create in flight drops the answer and bumps the revision")
    func identityChangeDropsACreate() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in
            entered.open()
            await release.wait()
            return Stub.json(TripWire.collection("t1"), status: .created)
        }
        let store = store()
        let frozen = NewTripRequest(scope: TripWire.alice, title: "Trip")
        let creating = Task {
            try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the create never reached the wire")
        let before = store.revision
        store.sessionIdentityChanged(to: TripWire.bob)
        #expect(store.revision > before, "an identity change did not move the revision")
        release.open()
        let result = await creating.result

        #expect(store.trips.isEmpty, "a create of the old scope landed in the new one")
        if case .failure(let error) = result {
            #expect(error as? TripStore.Failure == .superseded)
        } else {
            Issue.record("a create that outlived its scope returned a trip")
        }
    }

    @Test("a create answered after a scope switch is dropped and throws superseded")
    func createAfterScopeSwitchIsSuperseded() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in
            entered.open()
            await release.wait()
            return Stub.json(TripWire.collection("t1"), status: .created)
        }
        let store = store()
        let frozen = NewTripRequest(scope: TripWire.alice, title: "Trip")
        let creating = Task {
            try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the create never reached the wire")
        // Away and back: the scope the answer finds is equal to the one that issued it, but the
        // slot it was issued in is gone.
        store.sessionIdentityChanged(to: TripWire.bob)
        store.sessionIdentityChanged(to: TripWire.alice)
        release.open()
        let result = await creating.result

        #expect(store.trips.isEmpty, "a create from before the switch was applied")
        guard case .failure(let error) = result else {
            Issue.record("a create answered after a scope switch returned a trip")
            return
        }
        #expect(error as? TripStore.Failure == .superseded)
    }

    @Test("patch encodes leave as an absent key and set as the value")
    func patchEncodesLeaveAndSet() async throws {
        let calls = TripCalls()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            return Stub.json(TripWire.collection("t1", title: "Renamed"))
        }
        let store = store()
        let patch = TripPatch(title: .set("Renamed"), cover: .set("p0001"))
        let trip = try await store.update(
            uid: "t1", patch: patch, using: client.handle, baseURL: Stub.baseURL)

        let sent = try #require(calls.of(TripWire.patch).first, "no PATCH was sent")
        #expect(sent.path == "/api/collections/t1")
        let object = Stub.object(sent.body)
        #expect(object["title"] as? String == "Renamed")
        #expect(object["coverAttachmentUid"] as? String == "p0001")
        for left in ["tag", "spanStart", "spanEnd", "tz"] {
            #expect(object[left] == nil, "\(left) was sent although it was left")
        }
        #expect(!String(decoding: sent.body, as: UTF8.self).contains("null"))
        #expect(trip.title == "Renamed")
    }

    @Test("two identical-payload PATCHes are one request and both callers get the same result")
    func identicalPatchesJoin() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let joined = TripLatch()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            let answer = Stub.json(TripWire.collection("t1", title: "Renamed"))
            guard operation == TripWire.patch else { return answer }
            entered.open()
            await release.wait()
            return answer
        }
        let store = store()
        store.onJoin = { joined.open() }
        let patch = TripPatch(title: .set("Renamed"))
        let first = Task {
            try await store.update(
                uid: "t1", patch: patch, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first PATCH never reached the wire")
        let second = Task {
            try await store.update(
                uid: "t1", patch: patch, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "the second caller never joined")
        release.open()
        let one = try await first.value
        let other = try await second.value

        #expect(calls.of(TripWire.patch).count == 1)
        #expect(one == other)
        #expect(one.title == "Renamed")
    }

    @Test("two different payloads on one uid are one request and one busy")
    func differentPatchesRefuse() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            let answer = Stub.json(TripWire.collection("t1", title: "First"))
            guard operation == TripWire.patch else { return answer }
            entered.open()
            await release.wait()
            return answer
        }
        let store = store()
        let first = Task {
            try await store.update(
                uid: "t1", patch: TripPatch(title: .set("First")), using: client.handle,
                baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first PATCH never reached the wire")
        await #expect(throws: TripStore.Failure.busy) {
            try await store.update(
                uid: "t1", patch: TripPatch(title: .set("Second")), using: client.handle,
                baseURL: Stub.baseURL)
        }
        release.open()
        let trip = try await first.value

        #expect(calls.of(TripWire.patch).count == 1, "the refused PATCH reached the wire")
        #expect(trip.title == "First")
    }

    @Test("two PATCHes on two different trips both apply")
    func patchesOnTwoTripsBothApply() async throws {
        let enteredOne = TripLatch()
        let enteredTwo = TripLatch()
        let releaseOne = TripLatch()
        let releaseTwo = TripLatch()
        let client = Stub.client { request, _, operation in
            guard operation == TripWire.patch else {
                return Stub.json("[\(TripWire.collection("t1")),\(TripWire.collection("t2"))]")
            }
            let uid = Self.uid(of: request)
            (uid == "t1" ? enteredOne : enteredTwo).open()
            await (uid == "t1" ? releaseOne : releaseTwo).wait()
            return Stub.json(TripWire.collection(uid, title: "New \(uid)"))
        }
        let store = store()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let one = Task {
            try await store.update(
                uid: "t1", patch: TripPatch(title: .set("New t1")), using: client.handle,
                baseURL: Stub.baseURL)
        }
        let two = Task {
            try await store.update(
                uid: "t2", patch: TripPatch(title: .set("New t2")), using: client.handle,
                baseURL: Stub.baseURL)
        }
        #expect(await enteredOne.wait())
        #expect(await enteredTwo.wait())
        releaseTwo.open()
        releaseOne.open()

        #expect(try await one.value.title == "New t1")
        #expect(try await two.value.title == "New t2")
        #expect(store.trips.map(\.title) == ["New t1", "New t2"])
    }

    @Test("a held GET released after a successful DELETE leaves trips without the trip")
    func heldListAfterDelete() async throws {
        let lists = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, operation in
            if operation == TripWire.delete { return Stub.empty(.noContent) }
            lists.set(lists.get() + 1)
            if lists.get() == 2 {
                entered.open()
                await release.wait()
            }
            return Stub.json("[\(TripWire.collection("t1"))]")
        }
        let store = store()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.trips.map(\.uid) == ["t1"], "control: the seed list landed")
        let reading = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "the second list never reached the wire")
        try await store.delete(uid: "t1", using: client.handle)
        #expect(store.trips.isEmpty, "the delete did not apply")
        release.open()
        await reading.value

        #expect(store.trips.isEmpty, "a list asked before the delete brought the trip back")
    }

    @Test("a refusal reaches the session's handle with its generation, silent after a switch")
    func refusalCarriesTheIssuingGeneration() async {
        let credential = PresentedCredential("memos_pat_first")
        credential.install()
        credential.replace(with: "memos_pat_second")
        let issued = credential.presented().epoch
        let client = Stub.client(token: credential) { _, _, _ in Stub.empty(.unauthorized) }
        let seen = LockedValue<[CredentialRefusal]>([])
        let entered = TripLatch()
        let release = TripLatch()
        let store = store { refusal in
            seen.set(seen.get() + [refusal])
            entered.open()
            await release.wait()
            return .endedSession
        }
        let updating = Task {
            try await store.update(
                uid: "t1", patch: TripPatch(title: .set("x")), using: client.handle,
                baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the refusal never reached the session")
        #expect(seen.get().map(\.issuedUnder) == [issued])
        store.sessionIdentityChanged(to: TripWire.bob)
        release.open()
        let result = await updating.result

        guard case .failure(let error) = result else {
            Issue.record("a refused PATCH returned a trip")
            return
        }
        #expect(error as? TripStore.Failure == .superseded)
        #expect((error as? LocalizedError)?.errorDescription == nil, "a sentence after a switch")
        #expect(store.lastError == nil)

        // Control: without the switch the refusal is the caller's answer, with its sentence.
        let control = self.store { _ in .endedSession }
        await #expect(throws: TripStore.Failure.refusal(CredentialRefusal(issuedUnder: issued))) {
            try await control.update(
                uid: "t1", patch: TripPatch(title: .set("x")), using: client.handle,
                baseURL: Stub.baseURL)
        }
    }

    @Test("noteTransportSuccess is reported per answered request, an answered failure included")
    func transportSuccessPerRequest() async throws {
        let client = Stub.client { request, _, operation in
            let uid = Self.uid(of: request)
            switch (operation, uid) {
            case (TripWire.list, _): return Stub.json("[\(TripWire.collection("t1"))]")
            case (TripWire.create, _):
                return Stub.json(TripWire.collection("t2"), status: .created)
            case (TripWire.get, _): return Stub.json(TripWire.collection(uid))
            case (TripWire.patch, "t9"): return Stub.validationError("no")
            case (TripWire.patch, _): return Stub.json(TripWire.collection(uid, title: "x"))
            case (TripWire.delete, "t404"): return Stub.detail("Not found", status: .notFound)
            case (TripWire.delete, "offline"): throw URLError(.notConnectedToInternet)
            case (TripWire.delete, _): return Stub.empty(.noContent)
            default: return Stub.validationError("no")
            }
        }
        let handle = SessionHandle(client: client, generation: 7)
        let session = TripTestSession(for: handle)
        let store = store()
        store.reports(to: session)

        await store.refresh(using: handle, baseURL: Stub.baseURL)
        try await store.create(
            NewTripRequest(scope: TripWire.alice, title: "t2"), using: handle,
            baseURL: Stub.baseURL)
        try await store.update(
            uid: "t1", patch: TripPatch(title: .set("x")), using: handle, baseURL: Stub.baseURL)
        try await store.delete(uid: "t2", using: handle)
        #expect(session.successes == [7, 7, 7, 7, 7, 7], "answered: \(session.successes)")

        // An answered failure is an answered request; an unreachable server is not.
        await #expect(throws: TripStore.Failure.self) {
            try await store.update(
                uid: "t9", patch: TripPatch(title: .set("x")), using: handle,
                baseURL: Stub.baseURL)
        }
        await #expect(throws: TripStore.Failure.self) {
            try await store.delete(uid: "t404", using: handle)
        }
        await #expect(throws: TripStore.Failure.transport) {
            try await store.delete(uid: "offline", using: handle)
        }
        #expect(session.successes.count == 8, "an answered 422 or 404 went unreported")
        #expect(session.failures == 1, "control: the unreachable request was a failure")
    }

    /// Moved with the scope's directory from the pin's store, which is gone (MEMNG-781): the same
    /// identity must find the same directory, so the digest cannot change.
    @Test("the scope key is a stable SHA-256 of server and subject")
    func scopeKeyIsStable() {
        let alice = TimelineSnapshotIdentity(
            server: URL(string: "https://memos.example.org")!, subject: "alice")
        let bob = TimelineSnapshotIdentity(
            server: URL(string: "https://memos.example.org")!, subject: "bob")
        #expect(
            TripStore.scopeKey(for: alice)
                == "2fadd696398bbc1c29a8a5a985567f0c09974af439ccf5ea7555c859d734b177")
        #expect(
            TripStore.scopeKey(for: bob)
                == "14113c8d6747916a0cf6def8f590493e2bc8c0ab4dd40e9192fddd6e9d4bb317")
        let otherServer = TimelineSnapshotIdentity(
            server: URL(string: "https://other.example.org")!, subject: "alice")
        #expect(TripStore.scopeKey(for: otherServer) != TripStore.scopeKey(for: alice))
    }

    @Test(
        "each legacy file is removed on first load and never read",
        arguments: TripStore.legacyFileNames)
    func legacyFileIsRemoved(name: String) throws {
        // The pilot's trips file as 2.2 wrote it, and the composer pin's file (MEMNG-781): one
        // per scope.
        let file = { (identity: TimelineSnapshotIdentity) in
            root.appending(path: TripStore.scopeKey(for: identity)).appending(path: name).path
        }
        for identity in [TripWire.alice, TripWire.bob] {
            let url = URL(filePath: file(identity))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"formatVersion":1,"records":[{"title":"Old trip"}]}"#.utf8).write(to: url)
        }
        #expect(FileManager.default.fileExists(atPath: file(TripWire.alice)), "control: written")

        let store = store()
        #expect(!FileManager.default.fileExists(atPath: file(TripWire.alice)))
        #expect(store.trips.isEmpty, "the legacy file was read")
        #expect(FileManager.default.fileExists(atPath: file(TripWire.bob)), "another scope's went")
        store.sessionIdentityChanged(to: TripWire.bob)
        #expect(!FileManager.default.fileExists(atPath: file(TripWire.bob)))
        #expect(store.trips.isEmpty)
    }
}
