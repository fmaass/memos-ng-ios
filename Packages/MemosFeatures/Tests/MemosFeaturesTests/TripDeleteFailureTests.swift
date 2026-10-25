import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore
@testable import MemosFeatures

/// A trip delete that failed — the server answered 500, or the request never reached it — leaves
/// the trip as it was: its record (what its card draws), its drained members and the server's
/// row; and the user hears of it. A delete the server answered 204 takes that trip and no other
/// (MEMNG-766). The scripted server is the transport under the real generated client; the stores
/// are the units under test.
@MainActor
@Suite("Trip delete failure")
struct TripDeleteFailureTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "trip-delete-failure").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")

    /// How the DELETE fails.
    nonisolated enum Answer: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The server answers 500.
        case server500
        /// The request never reaches the server: the device is offline.
        case unreachable

        var testDescription: String { rawValue }
    }

    /// The stores, the wire and the session a delete runs against.
    private struct World {
        let trips: TripStore
        let members: TripMemberStore
        let transport: TripDeleteTransport
        let reporter: TripDeleteReporter
        let access: CollectionsAccess
    }

    static let portugal = "Portugal 2026"
    static let spain = "Spain 2025"
    /// `portugal2026`'s pictures as the drain lists them; `spain2025`'s one.
    static let portugalFiles = ["p0", "p1", "p2", "p3", "p4"]
    static let spainFiles = ["s0"]

    /// `titles` on the scripted server, listed by a real refresh, and every one's members drained
    /// before anything is deleted.
    private func makeWorld(
        _ titles: [String] = [TripDeleteFailureTests.portugal, TripDeleteFailureTests.spain]
    ) async throws -> World {
        let transport = TripDeleteTransport()
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: TripWire.baseURL),
            token: { "memos_pat_trip_delete" },
            transport: transport)
        let handle = SessionHandle(client: client, generation: 1)
        let reporter = TripDeleteReporter()
        reporter.activeHandle = handle
        let tags = [Self.portugal: "portugal2026", Self.spain: "spain2025"]
        for title in titles { transport.server.trips.seed(title, tag: tags[title]) }
        let trips = TripStore(identity: alice, root: root)
        trips.reports(to: reporter)
        let members = TripMemberStore(trips: trips, pageSize: 2)
        await trips.refresh(using: handle, baseURL: TripWire.baseURL)
        try #require(trips.trips.map(\.title).sorted() == titles.sorted())
        for trip in trips.trips {
            await members.drain(trip, using: handle, baseURL: TripWire.baseURL)
            try #require(members.state(for: trip) == .complete, "\(trip.title) did not drain")
        }
        return World(
            trips: trips, members: members, transport: transport, reporter: reporter,
            access: CollectionsAccess(handle: handle, baseURL: TripWire.baseURL))
    }

    private func trip(_ title: String, in world: World) throws -> Trip {
        try #require(world.trips.trips.first { $0.title == title })
    }

    private func files(of title: String, in world: World) throws -> [String] {
        world.members.members(for: try trip(title, in: world)).map(\.id)
    }

    private func arm(_ answer: Answer, on world: World) {
        switch answer {
        case .server500: world.transport.server.trips.fail([TripRows.delete])
        case .unreachable: world.transport.cutDeletes()
        }
    }

    /// The failure the user is shown: the store's sentence for a 500; for an unreachable server,
    /// no sentence of the manage menu's own — the session's banner says it, so the report must
    /// have reached the session (`TripStore.Failure.transport`).
    private func expectHeard(_ answer: Answer, _ manage: TripManage, _ world: World) {
        switch answer {
        case .server500:
            #expect(manage.failure != nil, "a failed delete said nothing")
            #expect(manage.failure == TripStore.Failure.server(status: 500).errorDescription)
            #expect(world.reporter.unreachable.isEmpty)
        case .unreachable:
            // Reported under the incarnation that issued the DELETE, which is the current one.
            let issued = world.access.handle.generation
            #expect(world.reporter.activeHandle?.generation == issued)
            #expect(
                world.reporter.unreachable == [.init(reason: .offline, generation: issued)],
                "the session never heard")
            #expect(manage.failure == nil, "\(manage.failure ?? "")")
        }
    }

    @Test(
        "a failed delete keeps the trip, its card and its drained members, and the user hears it",
        arguments: Answer.allCases)
    func failedDeleteKeepsTheTrip(_ answer: Answer) async throws {
        let world = try await makeWorld()
        let before = world.trips.trips
        let portugal = try trip(Self.portugal, in: world)
        arm(answer, on: world)
        let manage = TripManage()
        manage.askDelete()
        let write = try #require(
            manage.confirmDelete(portugal.uid, in: world.trips, using: world.access))
        #expect(await write.value == false)
        // The record, as its card draws it: title, cover and count.
        #expect(world.trips.trips == before)
        // Its membership, and the other trip's.
        #expect(try files(of: Self.portugal, in: world) == Self.portugalFiles)
        #expect(world.members.state(for: portugal) == .complete)
        #expect(try files(of: Self.spain, in: world) == Self.spainFiles)
        // The server still holds it, and it was asked once.
        #expect(world.transport.server.trips.rows.contains { $0.uid == portugal.uid })
        switch answer {
        case .server500: #expect(world.transport.server.trips.calls(TripRows.delete).count == 1)
        case .unreachable: #expect(world.transport.deletesCut == 1)
        }
        expectHeard(answer, manage, world)
        #expect(!manage.isSaving)

        // The failure released the trip's write slot: asked again with the server back, the
        // delete goes through.
        world.transport.server.trips.fail([])
        world.transport.restoreDeletes()
        manage.askDelete()
        let retry = manage.confirmDelete(portugal.uid, in: world.trips, using: world.access)
        #expect(await retry?.value == true)
        #expect(world.trips.trips.map(\.title) == [Self.spain])
        #expect(manage.failure == nil)
    }

    @Test("a delete answered 204 takes that trip, its card and its members, and no other")
    func answeredDeleteTakesTheTrip() async throws {
        let world = try await makeWorld()
        let portugal = try trip(Self.portugal, in: world)
        let spain = try trip(Self.spain, in: world)
        let manage = TripManage()
        manage.askDelete()
        let write = try #require(
            manage.confirmDelete(portugal.uid, in: world.trips, using: world.access))
        #expect(await write.value == true)
        #expect(world.trips.trips == [spain])
        #expect(world.members.members(for: portugal).isEmpty)
        #expect(world.members.state(for: portugal) == .notLoaded)
        // Every trip's drain is fenced by the store's revision, which the delete moved: the other
        // trip's members are read again, and are all still there.
        await world.members.drain(spain, using: world.access.handle, baseURL: TripWire.baseURL)
        #expect(try files(of: Self.spain, in: world) == Self.spainFiles)
        #expect(world.members.state(for: spain) == .complete)
        #expect(!world.transport.server.trips.rows.contains { $0.uid == portugal.uid })
        #expect(world.transport.server.trips.calls(TripRows.delete).count == 1)
        #expect(manage.failure == nil)
    }

    @Test(
        "a failed delete of the only trip leaves a store of one, its members drained",
        arguments: Answer.allCases)
    func failedDeleteOfTheOnlyTrip(_ answer: Answer) async throws {
        let world = try await makeWorld([Self.portugal])
        let before = world.trips.trips
        let portugal = try trip(Self.portugal, in: world)
        arm(answer, on: world)
        let manage = TripManage()
        manage.askDelete()
        let write = manage.confirmDelete(portugal.uid, in: world.trips, using: world.access)
        #expect(await write?.value == false)
        #expect(world.trips.trips == before)
        #expect(try files(of: Self.portugal, in: world) == Self.portugalFiles)
        expectHeard(answer, manage, world)
    }

    @Test("two deletes of one trip while the first is out are one request; its 500 keeps the trip")
    func joinedDeletesShareTheFailure() async throws {
        let world = try await makeWorld()
        let before = world.trips.trips
        let portugal = try trip(Self.portugal, in: world)
        let rows = world.transport.server.trips
        rows.fail([TripRows.delete])
        rows.hold(TripRows.delete)
        // The trip open twice — two screens, two menus, each with its own claim.
        let first = TripManage()
        let second = TripManage()
        first.askDelete()
        second.askDelete()
        // The store's own join point: called synchronously when a second write of the same
        // operation finds the first on the wire, before it waits on it.
        let joins = JoinCount()
        world.trips.onJoin = { joins.count += 1 }
        let one = try #require(
            first.confirmDelete(portugal.uid, in: world.trips, using: world.access))
        let sent = await Self.until { rows.calls(TripRows.delete).count == 1 }
        #expect(sent, "never sent")
        // While the DELETE is out, unanswered, nothing has moved.
        #expect(world.trips.trips == before, "the trip left before its DELETE answered")
        #expect(try files(of: Self.portugal, in: world) == Self.portugalFiles)
        let two = try #require(
            second.confirmDelete(portugal.uid, in: world.trips, using: world.access))
        let joined = await Self.until { joins.count == 1 }
        #expect(joined, "the second delete never reached the join")
        // Joined, and still unanswered: nothing has moved.
        #expect(world.trips.trips == before)
        #expect(try files(of: Self.portugal, in: world) == Self.portugalFiles)
        #expect(world.members.state(for: portugal) == .complete)
        rows.release(TripRows.delete)
        #expect(await one.value == false)
        #expect(await two.value == false)
        #expect(joins.count == 1)
        #expect(rows.calls(TripRows.delete).count == 1, "the second delete was not joined")
        #expect(world.trips.trips == before)
        #expect(try files(of: Self.portugal, in: world) == Self.portugalFiles)
        let said = TripStore.Failure.server(status: 500).errorDescription
        #expect(first.failure == said)
        #expect(second.failure == said, "the joined menu said \(second.failure ?? "nothing")")
    }

    /// Waits up to five seconds for `condition`.
    private static func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

/// The trip suites' scripted server, whose DELETE of a trip can be cut off before it reaches
/// it: from `cutDeletes` on, that request throws as an offline device's would.
private nonisolated final class TripDeleteTransport: ClientTransport, @unchecked Sendable {
    let server = TripTransport()
    private let lock = NSLock()
    private var cut = false
    private var thrown = 0

    func cutDeletes() { lock.withLock { cut = true } }
    func restoreDeletes() { lock.withLock { cut = false } }
    /// How many trip DELETEs never reached the server.
    var deletesCut: Int { lock.withLock { thrown } }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let unreachable: Bool = lock.withLock {
            guard cut, operationID == TripRows.delete else { return false }
            thrown += 1
            return true
        }
        if unreachable { throw URLError(.notConnectedToInternet) }
        return try await server.send(
            request, body: body, baseURL: baseURL, operationID: operationID)
    }
}

/// How many times a write joined one already on the wire.
@MainActor
private final class JoinCount {
    var count = 0
}

/// A session that records the transport failures reported to it: what its banner would say.
@MainActor
private final class TripDeleteReporter: SessionReporting {
    var activeHandle: SessionHandle?
    nonisolated let sessionIncarnation = SessionEpoch()
    /// A transport failure as reported: why, and under which session incarnation.
    struct Report: Equatable {
        let reason: ServerReachability.Reason
        let generation: Int
    }

    private(set) var unreachable: [Report] = []

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }
    func nothingEstablishedSince(_ handle: SessionHandle) -> Bool { true }
    func noteTransportFailure(_ failure: ServerReachability.Reason, issuedUnder generation: Int) {
        unreachable.append(Report(reason: failure, generation: generation))
    }
    func noteTransportSuccess(issuedUnder generation: Int) {}
}
