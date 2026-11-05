import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A trip read again when what it holds may be behind the server (MEMNG-1160): pictures a guest,
/// another member or the web added after the first drain were invisible until relaunch. The REAL
/// `TripMemberStore` over a `TripStore` a real refresh filled, with its clock in the test's hand,
/// and the REAL `TripGuestStore` for the Guest Uploads read — every request through the generated
/// client.
@MainActor
@Suite("Trip members — read again when stale", .timeLimit(.minutes(1)))
struct TripMemberRedrainTests {
    private nonisolated static let threshold: TimeInterval = 60

    private static func instant(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    @MainActor
    private struct Rig {
        let trip: Trip
        let trips: TripStore
        let members: TripMemberStore
        let server: TripServer
        let now: LockedValue<Date>

        var handle: SessionHandle { server.client.handle }
        var memberReads: Int { server.calls.of(TripWire.members).count }

        func ask() async -> Bool {
            await members.drainIfStale(.trip(trip), using: handle, baseURL: Stub.baseURL)
        }

        func later(_ seconds: TimeInterval, than start: Date) { now.set(start + seconds) }
    }

    /// One trip with pictures 0 and 1 on a server answering as `answer` scripts, the clock at
    /// `start`.
    private func rig(
        start: Date, answer: TripServer.Answer? = nil, hold: TripServer.Hold? = nil
    ) async throws -> Rig {
        let server = TripServer(answer: answer, hold: hold)
        let uid = server.seed(title: "Portugal 2026", tag: "portugal2026", pictures: [0, 1])
        let trips = await TripSeeder(server: server).store()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        let now = LockedValue(start)
        let members = TripMemberStore(
            trips: trips, clock: { now.get() }, staleAfter: Self.threshold)
        return Rig(trip: trip, trips: trips, members: members, server: server, now: now)
    }

    /// Guest Uploads answering one pass whose pictures are `contributions`.
    private nonisolated static func guests(_ contributions: [String]) -> TripServer.Answer {
        { _, operation in
            switch operation {
            case TripGuestStoreTests.listOp:
                return TripGuestStoreTests.passes(TripGuestStoreTests.pass("pa"))
            case TripGuestStoreTests.contributionsOp:
                return Stub.json("[\(contributions.joined(separator: ","))]")
            default: return nil
            }
        }
    }

    /// The trip's Guest Uploads store, telling the trip what each read listed — as the trip
    /// screen wires it.
    private func guestStore(_ rig: Rig) -> TripGuestStore {
        let members = rig.members
        let trip = rig.trip
        let handle = rig.handle
        return TripGuestStore(
            collectionUid: trip.uid,
            onContributions: { listed in
                await members.drainIfNewer(
                    trip, contributions: listed, using: handle, baseURL: Stub.baseURL)
            })
    }

    // MARK: - the age gate

    @Test("an appearance reads nothing within the threshold and reads again once past it")
    func readAgainPastTheThreshold() async throws {
        let start = try Self.instant("2026-10-31T19:00:00Z")
        let rig = try await rig(start: start)
        #expect(await rig.ask(), "nothing held, yet the first appearance did not read")
        #expect(rig.memberReads == 1)

        rig.later(Self.threshold - 1, than: start)
        #expect(!(await rig.ask()), "a drain inside the threshold was read again")
        #expect(rig.memberReads == 1, "an appearance inside the threshold sent a request")

        rig.later(Self.threshold, than: start)
        #expect(await rig.ask(), "a drain as old as the threshold was not read again")
        #expect(rig.memberReads == 2, "the stale trip sent no second member read")
    }

    @Test("two appearances of the same lineage within the threshold are one request")
    func twoAsksWithinTheThresholdAreOne() async throws {
        let start = try Self.instant("2026-10-31T19:00:00Z")
        let rig = try await rig(start: start)
        _ = await rig.ask()
        rig.later(30, than: start)
        _ = await rig.ask()
        #expect(rig.memberReads == 1, "two asks within the threshold were \(rig.memberReads)")
        #expect(rig.members.state(for: rig.trip) == .complete)
    }

    @Test("two overlapping appearances join one drain on the wire")
    func overlappingAsksJoin() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let start = try Self.instant("2026-10-31T19:00:00Z")
        let rig = try await rig(
            start: start,
            hold: { operation, count in
                guard operation == TripWire.members, count == 1 else { return }
                entered.open()
                await release.wait()
            })
        let first = Task { await rig.ask() }
        #expect(await entered.wait(), "no request was sent")
        let started = TripLatch()
        // Main-actor work runs without a suspension from the latch to the join, so once the test
        // sees the latch the second ask is parked on the first one's flight.
        let second = Task {
            started.open()
            return await rig.ask()
        }
        #expect(await started.wait(), "the second ask never started")
        release.open()
        _ = await first.value
        _ = await second.value
        #expect(rig.memberReads == 1, "two overlapping asks were \(rig.memberReads) requests")
        #expect(rig.members.members(for: rig.trip).count == 2)
    }

    @Test("a pull-to-refresh reads again within the threshold")
    func refreshReadsWithinTheThreshold() async throws {
        let start = try Self.instant("2026-10-31T19:00:00Z")
        let rig = try await rig(start: start)
        _ = await rig.ask()
        rig.later(5, than: start)
        await rig.members.drain(.trip(rig.trip), using: rig.handle, baseURL: Stub.baseURL)
        #expect(rig.memberReads == 2, "the refresh was held to the age gate")
    }

    @Test("another trip's fresh drain does not make this one fresh")
    func freshnessIsPerTrip() async throws {
        let start = try Self.instant("2026-10-31T19:00:00Z")
        let rig = try await rig(start: start)
        let otherUid = rig.server.seed(title: "Lisbon", tag: "lisbon", pictures: [2])
        await rig.trips.refresh(using: rig.handle, baseURL: Stub.baseURL)
        let other = try #require(rig.trips.trips.first { $0.uid == otherUid })
        let trip = try #require(rig.trips.trips.first { $0.uid == rig.trip.uid })
        await rig.members.drain(.trip(other), using: rig.handle, baseURL: Stub.baseURL)
        #expect(
            await rig.members.drainIfStale(.trip(trip), using: rig.handle, baseURL: Stub.baseURL),
            "a trip never read was taken as fresh")
        #expect(rig.memberReads == 2)
    }

    @Test("an invalidation within the threshold is read again")
    func invalidationIsReadAgain() async throws {
        let start = try Self.instant("2026-10-31T19:00:00Z")
        let rig = try await rig(start: start)
        _ = await rig.ask()
        rig.members.invalidate(uid: rig.trip.uid)
        rig.later(1, than: start)
        #expect(await rig.ask(), "a dropped drain was taken as fresh")
        #expect(rig.memberReads == 2)
    }

    @Test("a failed drain is asked again within the threshold")
    func failureIsAskedAgain() async throws {
        let start = try Self.instant("2026-10-31T19:00:00Z")
        let rig = try await rig(start: start)
        rig.server.fail([TripWire.members])
        _ = await rig.ask()
        #expect(rig.members.drainFailed(for: .trip(rig.trip)))
        rig.server.fail([])
        rig.later(1, than: start)
        #expect(await rig.ask(), "a failure was taken for a fresh drain")
        #expect(rig.memberReads == 2)
        #expect(rig.members.members(for: rig.trip).count == 2)
    }

    @Test("the rows on screen stay while the trip is read again, until the new ones land")
    func rowsStayDuringTheReread() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let served = LockedValue(0)
        let start = try Self.instant("2026-10-31T19:00:00Z")
        let rig = try await rig(
            start: start,
            answer: { _, operation in
                guard operation == TripWire.members else { return nil }
                served.set(served.get() + 1)
                return TripWire.page(served.get() == 1 ? [0, 1] : [0, 1, 2])
            },
            hold: { operation, count in
                guard operation == TripWire.members, count == 2 else { return }
                entered.open()
                await release.wait()
            })
        _ = await rig.ask()
        rig.later(Self.threshold + 1, than: start)
        let again = Task { await rig.ask() }
        #expect(await entered.wait(), "the stale trip was not read again")
        #expect(
            rig.members.members(for: rig.trip).map(\.id) == [0, 1].map(TripWire.uid),
            "the held rows left the screen while the re-read was out")
        release.open()
        _ = await again.value
        #expect(rig.members.members(for: rig.trip).map(\.id) == [0, 1, 2].map(TripWire.uid))
    }

    // MARK: - the Guest Uploads read

    @Test("a Guest Uploads read listing a picture newer than the drain reads the trip again")
    func newerContributionReadsAgain() async throws {
        let start = try Self.instant("2026-10-10T12:00:00Z")
        let rig = try await rig(
            start: start,
            answer: Self.guests([
                TripGuestStoreTests.contribution("g1", at: 11),
                TripGuestStoreTests.contribution("g2", at: 2),
            ]))
        _ = await rig.ask()
        rig.later(5, than: start)
        await guestStore(rig).loadContributions(using: rig.handle)
        #expect(rig.memberReads == 2, "a picture newer than the drain did not read the trip again")
    }

    @Test("a Guest Uploads read listing nothing newer than the drain reads nothing")
    func olderContributionsReadNothing() async throws {
        let start = try Self.instant("2026-10-10T12:00:00Z")
        let rig = try await rig(
            start: start,
            answer: Self.guests([TripGuestStoreTests.contribution("g1", at: 10)]))
        _ = await rig.ask()
        await guestStore(rig).loadContributions(using: rig.handle)
        #expect(rig.memberReads == 1, "an older picture read the trip again")
    }

    @Test("a picture listed at the drain's own instant, or none at all, reads nothing")
    func boundaryContributionsReadNothing() async throws {
        let start = try Self.instant("2026-10-10T00:00:00Z")
        let rig = try await rig(start: start)
        _ = await rig.ask()
        let atTheInstant = try #require(
            await TripGuestStoreTests.contributions(
                TripGuestStoreTests.contribution("g1", at: 10)))
        #expect(atTheInstant.first?.createdAt == start)
        let none: [TripContribution] = []
        for listed in [atTheInstant, none] {
            let read = await rig.members.drainIfNewer(
                rig.trip, contributions: listed, using: rig.handle, baseURL: Stub.baseURL)
            #expect(!read, "\(listed.count) contributions read the trip again")
        }
        #expect(rig.memberReads == 1)
    }

    @Test("a Guest Uploads read before any drain reads the trip")
    func contributionBeforeAnyDrainReads() async throws {
        let start = try Self.instant("2026-10-10T12:00:00Z")
        let rig = try await rig(
            start: start, answer: Self.guests([TripGuestStoreTests.contribution("g1", at: 2)]))
        await guestStore(rig).loadContributions(using: rig.handle)
        #expect(rig.memberReads == 1, "a trip never read stayed unread")
    }
}

extension TripGuestStoreTests {
    /// `rows` as the REAL guest store decodes them from the inbox's read.
    static func contributions(_ rows: String...) async -> [TripContribution]? {
        let client = Stub.client { _, _, operation in
            switch operation {
            case listOp: return passes(pass("pa"))
            case contributionsOp: return Stub.json("[\(rows.joined(separator: ","))]")
            default: return Stub.empty(.notFound)
            }
        }
        let store = TripGuestStore(collectionUid: "t1")
        await store.loadContributions(using: client.handle)
        return store.contributions
    }
}
