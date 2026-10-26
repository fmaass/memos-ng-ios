import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// Add to Album (MEMNG-805): `TripStore.addMembers` over the batch route, in chunks of the route's
/// limit, under the album's slot, summed into one outcome, and the end of the app's record of a
/// picture it took out of THAT album as each chunk is applied.
@MainActor
@Suite("Album — Add to Album")
struct AlbumAddTests {
    /// An album on `server` holding `pictures`, and the stores over it.
    private func album(
        _ server: TripServer, pictures: [Int] = []
    ) async throws -> (album: Trip, trips: TripStore, members: TripMemberStore) {
        let uid = server.seed(title: "At the sea", pictures: pictures)
        server.edit(uid) { $0.kind = "album" }
        let (trips, members) = await TripSeeder(server: server).members()
        let album = try #require(trips.trips.first { $0.uid == uid })
        #expect(album.kind == .album, "control: the seeded row is an album")
        return (album, trips, members)
    }

    private func sent(_ call: TripCalls.Call) -> [String] {
        Stub.object(call.body)["attachmentUids"] as? [String] ?? []
    }

    @Test("500 pictures are one POST, 501 are two in order, and the outcomes are summed")
    func chunksOfFiveHundred() async throws {
        let server = TripServer()
        let (first, trips, _) = try await album(server)
        let five = (1...500).map(TripWire.uid)
        let one = try await trips.addMembers(
            five, to: first, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(server.calls.of(TripWire.add).count == 1, "500 pictures took more than one POST")
        #expect(server.calls.of(TripWire.add).map(sent) == [five])
        #expect(one.added == five)

        // A second album already holding the first picture: its answer is summed with the rest.
        let uid = server.seed(title: "Lake", pictures: [1])
        server.edit(uid) { $0.kind = "album" }
        await trips.refresh(using: server.client.handle, baseURL: Stub.baseURL)
        let lake = try #require(trips.trips.first { $0.uid == uid })
        let more = (1...501).map(TripWire.uid)
        let two = try await trips.addMembers(
            more, to: lake, using: server.client.handle, baseURL: Stub.baseURL)

        let posts = server.calls.of(TripWire.add).dropFirst().map(sent)
        #expect(
            posts == [Array(more.prefix(500)), [more[500]]], "the chunks: \(posts.map(\.count))")
        #expect(two.alreadyMember == [TripWire.uid(1)])
        #expect(two.added == Array(more.dropFirst()))
        #expect(two.answered == 501 && two.stopped == nil)
    }

    @Test("an overlapping add of the same pictures joins; of other pictures it is refused busy")
    func overlappingAddsJoinOrAreRefused() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = TripServer(hold: { operation, _ in
            guard operation == TripWire.add else { return }
            entered.open()
            _ = await release.wait()
        })
        let (album, trips, _) = try await album(server)
        let joined = TripLatch()
        trips.onJoin = { joined.open() }
        let uids = [TripWire.uid(1), TripWire.uid(2)]
        let handle = server.client.handle
        let first = Task {
            try await trips.addMembers(uids, to: album, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first POST never reached the wire")
        let second = Task {
            try await trips.addMembers(uids, to: album, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "the identical add never joined")
        await #expect(throws: TripStore.Failure.busy) {
            try await trips.addMembers(
                [TripWire.uid(3)], to: album, using: handle, baseURL: Stub.baseURL)
        }
        release.open()
        let one = try await first.value
        let other = try await second.value

        #expect(server.calls.of(TripWire.add).count == 1, "overlapping adds sent two POSTs")
        #expect(one == other)
        #expect(one.added == uids)
    }

    @Test("a chunk failing after one that went reports both and moves the revision")
    func aFailedChunkReportsBoth() async throws {
        let adds = AddCounter()
        let server = TripServer(answer: { _, operation in
            guard operation == TripWire.add else { return nil }
            return adds.next() == 2 ? Stub.empty(.internalServerError) : nil
        })
        // The member store is the reconciler (a weak hook): it must outlive the add to drain.
        let (album, trips, members) = try await album(server)
        let revision = trips.revision
        let drains = server.calls.of(TripWire.members).count
        let outcome = try await trips.addMembers(
            (1...501).map(TripWire.uid), to: album, using: server.client.handle,
            baseURL: Stub.baseURL)

        #expect(outcome.added.count == 500, "the first chunk's answers were lost")
        #expect(outcome.stopped == .server(status: 500))
        #expect(outcome.unanswered == 1)
        #expect(trips.revision > revision, "the revision stood still after a partial add")
        #expect(server.calls.of(TripWire.members).count > drains, "no drain followed the add")
        withExtendedLifetime(members) {}
    }

    @Test(
        "a re-add ends the removal record as its chunk is applied, before its drain answers",
        arguments: ["added", "alreadyMember"])
    func aReAddEndsTheRemovalRecord(answer: String) async throws {
        let drain = DrainHold()
        let server = TripServer(hold: { operation, _ in await drain.hold(operation) })
        let (album, trips, members) = try await album(server, pictures: [0, 1])
        let handle = server.client.handle
        await members.drain(album, using: handle, baseURL: Stub.baseURL)
        let picture = try #require(members.members(for: album).first { $0.id == TripWire.uid(1) })
        try await trips.removeMember(
            uid: album.uid, attachments: [picture.id], using: handle, baseURL: Stub.baseURL)
        #expect(
            members.stillMembers([picture], of: album).isEmpty,
            "control: the record hides the removed picture")
        if answer == "alreadyMember" {
            // Somebody else put it back meanwhile, so the server answers it is a member already.
            server.edit(album.uid) { $0.pictures.append(1) }
        }

        // The drain that follows the add is held on the wire and then fails: nothing reconciles.
        server.fail([TripWire.members])
        drain.arm()
        let adding = Task {
            try await trips.addMembers(
                [picture.id], to: album, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await drain.onWire.wait(), "no drain followed the add")
        #expect(
            members.ownExclusions[album.uid]?[picture.id] == nil,
            "the removal record outlived the chunk that answered \(answer)")
        #expect(
            members.stillMembers([picture], of: album).map(\.id) == [picture.id],
            "the re-added picture stays hidden while its drain is out")
        drain.release.open()
        let outcome = try await adding.value

        let named = answer == "added" ? outcome.added : outcome.alreadyMember
        #expect(named == [picture.id], "control: the server answered \(answer)")
        #expect(members.members(for: album).isEmpty, "control: the reconciling drain failed")
        #expect(
            members.stillMembers([picture], of: album).map(\.id) == [picture.id],
            "the re-added picture is hidden again once its drain failed")
    }

    /// The screen keeps the rows its last good drain read — the ones after the removal — and the
    /// add moved the revision, so nothing the store holds lists the picture until a drain answers.
    @Test("a picture put back stays among the kept members across a failed drain, at its place")
    func aReAddIsKeptAcrossAFailedDrain() async throws {
        let server = TripServer()
        let (album, trips, members) = try await album(server, pictures: [0, 1, 2])
        let handle = server.client.handle
        await members.drain(album, using: handle, baseURL: Stub.baseURL)
        let picture = TripWire.uid(1)
        try await trips.removeMember(
            uid: album.uid, attachments: [picture], using: handle, baseURL: Stub.baseURL)
        let kept = members.members(for: album)
        #expect(
            kept.map(\.id) == [TripWire.uid(0), TripWire.uid(2)],
            "control: the drain after the removal answered without the picture")

        server.fail([TripWire.members])
        let outcome = try await trips.addMembers(
            [picture], to: album, using: handle, baseURL: Stub.baseURL)
        #expect(outcome.added == [picture], "control: the server took the picture back")
        #expect(members.members(for: album).isEmpty, "control: the reconciling drain failed")
        #expect(
            members.keptMembers(kept, of: album).map(\.id)
                == [TripWire.uid(0), picture, TripWire.uid(2)],
            "the picture put back is missing from the kept members after the failed drain")

        // Another phone took it out again; a drain asked after the add is the server's word.
        server.edit(album.uid) { $0.pictures.removeAll { $0 == 1 } }
        server.fail([])
        await members.drain(album, using: handle, baseURL: Stub.baseURL)
        #expect(
            members.members(for: album).map(\.id) == [TripWire.uid(0), TripWire.uid(2)],
            "control: the later drain landed without the picture")
        #expect(
            members.keptMembers(kept, of: album).map(\.id) == kept.map(\.id),
            "a drain asked after the add left the carried picture standing")
    }

    @Test("a picture put back is carried for its own account only")
    func aReAddIsNotCarriedAcrossAnIdentityChange() async throws {
        let server = TripServer()
        let (album, trips, members) = try await album(server, pictures: [0, 1])
        let handle = server.client.handle
        await members.drain(album, using: handle, baseURL: Stub.baseURL)
        let picture = TripWire.uid(1)
        try await trips.removeMember(
            uid: album.uid, attachments: [picture], using: handle, baseURL: Stub.baseURL)
        let kept = members.members(for: album)
        server.fail([TripWire.members])
        try await trips.addMembers([picture], to: album, using: handle, baseURL: Stub.baseURL)
        #expect(
            members.keptMembers(kept, of: album).map(\.id) == [TripWire.uid(0), picture],
            "control: the picture put back is carried")

        members.sessionIdentityChanged()
        #expect(
            members.keptMembers(kept, of: album).map(\.id) == [TripWire.uid(0)],
            "the outgoing account's put-back picture outlived the identity change")
    }
}

/// Holds the first member drain asked after `arm()` on the wire until `release` opens.
private final class DrainHold: @unchecked Sendable {
    let onWire = TripLatch()
    let release = TripLatch()
    private let lock = NSLock()
    private var armed = false

    func arm() { lock.withLock { armed = true } }

    func hold(_ operation: String) async {
        guard operation == TripWire.members else { return }
        let taken = lock.withLock {
            defer { armed = false }
            return armed
        }
        guard taken else { return }
        onWire.open()
        await release.wait()
    }
}

/// Counts one operation's requests across the transport's tasks.
private final class AddCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
