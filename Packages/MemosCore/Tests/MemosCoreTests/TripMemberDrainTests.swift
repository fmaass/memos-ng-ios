import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A trip's members read from the server, held to what the device-local membership was held to
/// (MEMNG-754 adapted that suite's drain, cover and fence cases here): the REAL `TripMemberStore`
/// over a `TripStore` a real refresh filled, every page through the generated client.
@MainActor
@Suite("Trip members — drain and fences")
struct TripMemberDrainTests {
    private let seeder = TripSeeder()
    private var server: TripServer { seeder.server }
    private nonisolated static let tag = "portugal2026"

    /// A trip listed on the server, and the stores over it.
    private func seeded(
        _ title: String = "Portugal 2026", tag: String? = Self.tag, pictures: [Int] = [],
        memberCap: Int = TripMemberStore.memberCap,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) async -> (trip: Trip, trips: TripStore, members: TripMemberStore) {
        let uid = server.seed(title: title, tag: tag, pictures: pictures)
        let (trips, members) = await seeder.members(
            memberCap: memberCap, onUnauthorized: onUnauthorized)
        let trip = trips.trips.first { $0.uid == uid }
        let fallback = Trip(uid: uid, title: title, createdAt: .now, updatedAt: .now)
        return (trip ?? fallback, trips, members)
    }

    /// A transport whose first `holdAt`-th call waits for `release` after opening `entered`.
    private nonisolated static func held(
        at holdAt: Int, entered: TripLatch, release: TripLatch, calls: LockedValue<Int>,
        answer: @escaping @Sendable (Int) -> (HTTPResponse, HTTPBody?)
    ) -> any APIProtocol {
        Stub.client { _, _, _ in
            let call = calls.get() + 1
            calls.set(call)
            if call == holdAt {
                entered.open()
                await release.wait()
            }
            return answer(call)
        }
    }

    // MARK: - the drain

    @Test("three pages are drained in order, the 61st picture after the 60th")
    func threePagesInOrder() async throws {
        let (trip, trips, members) = await seeded(pictures: Array(0..<125))
        server.seed(title: "Another trip", tag: Self.tag, pictures: [0])
        await trips.refresh(using: server.client.handle, baseURL: Stub.baseURL)
        let other = try #require(trips.trips.last)
        let current = try #require(trips.trips.first)
        await members.drain(current, using: server.client.handle, baseURL: Stub.baseURL)

        let rows = members.members(for: current)
        #expect(rows.map(\.id) == (0..<125).map(TripWire.uid), "not the three pages in order")
        #expect(members.state(for: other) == .notLoaded, "another trip was drained")
        let sixtieth = try #require(rows[59].takenAt)
        let sixtyFirst = try #require(rows[60].takenAt)
        #expect(sixtyFirst > sixtieth, "the second page did not follow the first")
        #expect(members.state(for: current) == .complete)
        #expect(members.lastError == nil)

        let sent = server.calls.of(TripWire.members).map(\.path)
        #expect(sent.count == 3, "not one request per page: \(sent)")
        for path in sent {
            #expect(path.hasPrefix("/api/collections/\(trip.uid)/attachments"), "\(path)")
            #expect(!TripWire.hasQuery(path, "type"), "not every kind of file: \(path)")
            #expect(TripWire.query(path, "order") == "taken_asc", "not oldest first: \(path)")
            #expect(TripWire.query(path, "limit") == "60", "not pages of 60: \(path)")
        }
        #expect(!TripWire.hasQuery(sent[0], "cursor"), "the first page carried a cursor")
        #expect(TripWire.query(sent[1], "cursor") == "60")
        #expect(TripWire.query(sent[2], "cursor") == "120")

        let summary = try #require(members.summary(for: current))
        #expect(summary.count == 125)
        #expect(summary.firstTaken == TripWire.taken(0))
        #expect(summary.lastTaken == TripWire.taken(124))
        #expect(summary.cover?.id == TripWire.uid(0))
    }

    @Test("a video member is a member, and the drain asks with no type at all")
    func aVideoIsAMember() async throws {
        let paths = LockedValue<[String]>([])
        let clip = TripWire.item("clip", taken: TripWire.taken(0))
            .replacingOccurrences(of: "image/jpeg", with: "video/mp4")
        let pictures = [1, 2].map { TripWire.item(TripWire.uid($0), taken: TripWire.taken($0)) }
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json("[\(([clip] + pictures).joined(separator: ","))]")
        }
        let (trip, _, members) = await seeded()
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)

        let rows = members.members(for: trip)
        #expect(rows.map(\.id) == ["clip", TripWire.uid(1), TripWire.uid(2)], "\(rows.map(\.id))")
        #expect(rows.first?.attachment.mediaKind == .video, "the clip is not a video")
        #expect(members.summary(for: trip)?.cover?.id == "clip")
        #expect(paths.get().count == 1)
        #expect(!TripWire.hasQuery(paths.get().first ?? "", "type"), "the drain named a kind")
    }

    @Test("a tag that spells a kind travels nowhere: the drain names the trip, never a kind")
    func aTagThatSpellsAKind() async throws {
        let (trip, _, members) = await seeded("Odd", tag: "x&type=image", pictures: [0])
        await members.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        let path = try #require(server.calls.of(TripWire.members).first?.path)
        #expect(!TripWire.hasQuery(path, "type"), "the tag's text stood in for a kind: \(path)")
        #expect(!TripWire.hasQuery(path, "tag"), "the member route was sent a tag: \(path)")
        #expect(members.members(for: trip).count == 1, "control: the drain landed")
    }

    @Test("a drain stops at 2000 members and says it was truncated")
    func aDrainStopsAtTheCap() async throws {
        #expect(TripMemberStore.memberCap == 2000)
        #expect(TripMemberStore.pageSize == 60)
        let (trip, _, members) = await seeded(pictures: Array(0..<2100))
        await members.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        let rows = members.members(for: trip)
        #expect(rows.count == 2000, "not capped at 2000: \(rows.count)")
        #expect(rows.last?.id == TripWire.uid(1999), "the cap kept the wrong end")
        #expect(members.state(for: trip) == .truncated)
        let pages = server.calls.of(TripWire.members).count
        #expect(pages == 34, "the drain read past the cap: \(pages) pages")
    }

    @Test("exactly the cap with no cursor after it is complete, not truncated")
    func exactlyTheCapIsComplete() async throws {
        let (trip, _, members) = await seeded(pictures: Array(0..<120), memberCap: 120)
        await members.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 120)
        #expect(members.state(for: trip) == .complete, "the last page was called a truncation")
    }

    @Test("a trip with no tag reads its own member listing, never the whole library")
    func anUntaggedTripReadsItsOwnListing() async throws {
        let (trip, _, members) = await seeded("Span only", tag: nil, pictures: [0, 1, 2])
        await members.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(server.calls.of(TripWire.library).isEmpty, "an untagged trip read the library")
        #expect(server.calls.of(TripWire.members).count == 1)
        #expect(members.members(for: trip).count == 3)
        #expect(members.state(for: trip) == .complete)
    }

    @Test("a failure on a later page applies nothing and leaves the previous list standing")
    func aLaterPageFailureKeepsThePreviousList() async throws {
        let failing = LockedValue(false)
        let client = Stub.client { request, _, _ in
            if TripWire.query(request.path ?? "", "cursor") == nil {
                return TripWire.page(Array(0..<60), next: "c1")
            }
            guard !failing.get() else { return Stub.empty(.internalServerError) }
            return TripWire.page(Array(60..<70))
        }
        let (trip, _, members) = await seeded()
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 70, "control: the first drain landed")
        failing.set(true)
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 70, "a failed drain replaced the list")
        #expect(members.state(for: trip) == .complete)
        #expect(members.lastError != nil, "the failure was swallowed")
    }

    // MARK: - exclusions and the cover

    @Test("a removed picture is absent from the members and from the summary")
    func aRemovedPictureIsAbsent() async throws {
        let (trip, trips, members) = await seeded(pictures: [0, 1, 2])
        let handle = server.client.handle
        try await members.remove(
            [TripWire.uid(0)], from: trip, using: handle, baseURL: Stub.baseURL)
        let current = try #require(trips.trips.first)
        #expect(members.members(for: current).map(\.id) == [TripWire.uid(1), TripWire.uid(2)])
        let summary = try #require(members.summary(for: current))
        #expect(summary.count == 2, "the removed picture was counted")
        #expect(summary.firstTaken == TripWire.taken(1), "the span began at the removed picture")
        #expect(summary.lastTaken == TripWire.taken(2))
        #expect(summary.cover?.id == TripWire.uid(1), "the removed picture is the cover")

        try await members.remove(
            [TripWire.uid(2)], from: current, using: handle, baseURL: Stub.baseURL)
        let after = try #require(trips.trips.first)
        #expect(members.members(for: after).map(\.id) == [TripWire.uid(1)])
        #expect(members.summary(for: after)?.count == 1)
    }

    @Test("the chosen cover stands while it is a member and falls back to the first when removed")
    func theChosenCoverFallsBack() async throws {
        let (trip, trips, members) = await seeded(pictures: [0, 1, 2])
        let handle = server.client.handle
        try await trips.update(
            uid: trip.uid, patch: TripPatch(cover: .set(TripWire.uid(2))), using: handle,
            baseURL: Stub.baseURL)
        let chosen = try #require(trips.trips.first)
        await members.drain(chosen, using: handle, baseURL: Stub.baseURL)
        #expect(members.summary(for: chosen)?.cover?.id == TripWire.uid(2), "control")

        try await members.remove(
            [TripWire.uid(2)], from: chosen, using: handle, baseURL: Stub.baseURL)
        let after = try #require(trips.trips.first)
        #expect(
            members.summary(for: after)?.cover?.id == TripWire.uid(0),
            "a removed cover is still the cover")
    }

    @Test("the summary of no members is a zero count with no span and no cover")
    func theSummaryOfNothing() async throws {
        let (trip, _, members) = await seeded()
        await members.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(
            members.summary(for: trip)
                == TripMemberSummary(count: 0, firstTaken: nil, lastTaken: nil, cover: nil))
    }

    @Test("the summary is nil until a drain applied, then reflects the drained members")
    func theSummaryIsComputedNotStored() async throws {
        let (trip, _, members) = await seeded(pictures: [3, 4])
        #expect(members.summary(for: trip) == nil, "a summary before any drain")
        await members.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        let summary = try #require(members.summary(for: trip))
        #expect(summary.count == 2)
        #expect(summary.firstTaken == TripWire.taken(3) && summary.lastTaken == TripWire.taken(4))
        members.invalidate(uid: trip.uid)
        #expect(members.summary(for: trip) == nil, "an invalidated trip kept its summary")
    }

    // MARK: - fences

    @Test("a page answered for a session that has ended is dropped whole")
    func aStaleGenerationIsDropped() async {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.held(at: 1, entered: entered, release: release, calls: calls) { call in
            call == 1 ? TripWire.page(Array(0..<60), next: "c1") : TripWire.page([60])
        }
        let (trip, _, members) = await seeded()
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: issued)
        members.reports(to: session)

        let inFlight = Task { await members.drain(trip, using: issued, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.open()
        await inFlight.value

        #expect(members.members(for: trip).isEmpty, "a stale answer was applied")
        #expect(members.state(for: trip) == .notLoaded)
        #expect(calls.get() == 1, "the stale drain read on: \(calls.get()) pages")
    }

    @Test("a page answered for a trip deleted while it was out publishes nothing")
    func aDeletedTripsPageIsDropped() async throws {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.held(at: 1, entered: entered, release: release, calls: calls) { call in
            call == 1 ? TripWire.page(Array(0..<60), next: "c1") : TripWire.page([60])
        }
        let (trip, trips, members) = await seeded()

        let inFlight = Task {
            await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        try await trips.delete(uid: trip.uid, using: server.client.handle)
        release.open()
        await inFlight.value

        #expect(members.members(for: trip).isEmpty, "a deleted trip's members came back")
        #expect(members.summary(for: trip) == nil, "a deleted trip's summary came back")
        #expect(members.state(for: trip) == .notLoaded)
        #expect(calls.get() == 1, "the drain read on for a trip that is gone: \(calls.get())")
    }

    @Test("a trip deleted after its drain keeps no readable membership")
    func aDeletedTripsMembershipIsForgotten() async throws {
        let (trip, trips, members) = await seeded(pictures: [0, 1, 2])
        await members.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 3, "precondition: the drain applied")
        try await trips.delete(uid: trip.uid, using: server.client.handle)
        #expect(members.members(for: trip).isEmpty, "a deleted trip's members are still readable")
        #expect(members.summary(for: trip) == nil)
        #expect(members.state(for: trip) == .notLoaded)
    }

    @Test("an invalidated trip's membership is gone, and its drain in flight lands nothing")
    func anInvalidatedTripHoldsNothing() async throws {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.held(at: 2, entered: entered, release: release, calls: calls) { _ in
            TripWire.page([0, 1, 2])
        }
        let (trip, trips, members) = await seeded()
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 3, "precondition: the drain applied")

        let again = Task {
            await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the second drain was not sent")
        members.invalidate(uid: trip.uid)
        #expect(members.members(for: trip).isEmpty, "an invalidated trip's members are readable")
        #expect(members.state(for: trip) == .notLoaded, "it still reads as draining")
        try await trips.delete(uid: trip.uid, using: server.client.handle)
        release.open()
        await again.value
        #expect(members.members(for: trip).isEmpty, "the drain in flight landed")
    }

    @Test("a drain held across an invalidation of a trip that stays publishes nothing")
    func anInvalidatedDrainOfAKeptTripPublishesNothing() async throws {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.held(at: 1, entered: entered, release: release, calls: calls) { _ in
            TripWire.page([0, 1, 2])
        }
        let (trip, trips, members) = await seeded()
        let inFlight = Task {
            await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        members.invalidate(uid: trip.uid)
        release.open()
        await inFlight.value
        #expect(trips.trips.map(\.uid) == [trip.uid], "control: the trip stays")
        #expect(members.members(for: trip).isEmpty, "the invalidated drain published")
        #expect(members.state(for: trip) == .notLoaded)
    }

    @Test("a drain after an invalidation supersedes the held one: it neither lands nor clears it")
    func aDrainAfterInvalidationSupersedes() async {
        let calls = LockedValue(0)
        let firstIn = TripLatch()
        let firstOut = TripLatch()
        let secondIn = TripLatch()
        let secondOut = TripLatch()
        let client = Stub.client { _, _, _ in
            let call = calls.get() + 1
            calls.set(call)
            if call == 1 {
                firstIn.open()
                await firstOut.wait()
                return TripWire.page([0, 1, 2])
            }
            secondIn.open()
            await secondOut.wait()
            return TripWire.page([0, 1, 2, 3, 4])
        }
        let (trip, _, members) = await seeded()
        let old = Task { await members.drain(trip, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await firstIn.wait(), "the first drain sent nothing")
        members.invalidate(uid: trip.uid)
        let new = Task { await members.drain(trip, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await secondIn.wait(), "the drain after the invalidation sent nothing")
        firstOut.open()
        await old.value

        #expect(members.members(for: trip).isEmpty, "the superseded drain published")
        #expect(members.state(for: trip) == .draining, "the superseded drain cleared the new slot")
        secondOut.open()
        await new.value
        #expect(members.members(for: trip).count == 5, "the later drain did not land")
        #expect(members.state(for: trip) == .complete)
    }

    @Test("invalidating one trip leaves every other trip's membership as it was")
    func invalidatingOneLeavesTheOthers() async throws {
        let (first, trips, members) = await seeded("One", pictures: [0, 1])
        server.seed(title: "Two", tag: Self.tag, pictures: [2, 3, 4])
        await trips.refresh(using: server.client.handle, baseURL: Stub.baseURL)
        let one = try #require(trips.trips.first { $0.uid == first.uid })
        let two = try #require(trips.trips.last)
        await members.drain(one, using: server.client.handle, baseURL: Stub.baseURL)
        await members.drain(two, using: server.client.handle, baseURL: Stub.baseURL)
        members.invalidate(uid: one.uid)
        #expect(members.members(for: one).isEmpty)
        #expect(members.members(for: two).map(\.id) == [2, 3, 4].map(TripWire.uid))
        #expect(members.state(for: two) == .complete)
    }

    @Test("a drain that outlived a change of identity is dropped whole")
    func aDrainAcrossAnIdentityChangeIsDropped() async {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.held(at: 1, entered: entered, release: release, calls: calls) { _ in
            TripWire.page([0, 1, 2])
        }
        let (trip, trips, members) = await seeded()
        let inFlight = Task {
            await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        trips.sessionIdentityChanged(to: TripWire.bob)
        release.open()
        await inFlight.value
        #expect(members.members(for: trip).isEmpty, "the outgoing identity's drain landed")
        #expect(members.state(for: trip) == .notLoaded)
    }

    @Test("a second drain of a trip in flight waits for the first and sends nothing of its own")
    func aSecondDrainJoins() async {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.held(at: 1, entered: entered, release: release, calls: calls) { _ in
            TripWire.page([0, 1, 2])
        }
        let (trip, _, members) = await seeded()
        let started = TripLatch()
        let secondDone = LockedValue(false)
        let first = Task { await members.drain(trip, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        // Main-actor work runs without a suspension from the latch to the join, so once the test
        // sees the latch the second drain is parked on the first one's task.
        let second = Task {
            started.open()
            await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
            secondDone.set(true)
            return members.members(for: trip).count
        }
        #expect(await started.wait(), "the second drain never started")
        #expect(!secondDone.get(), "the second drain returned while the first was still out")
        #expect(members.state(for: trip) == .draining)
        release.open()
        await first.value
        #expect(await second.value == 3, "the joined caller did not see the chain's result")
        #expect(calls.get() == 1, "two overlapping drains were \(calls.get()) requests")
        #expect(members.state(for: trip) == .complete)
    }

    @Test("a refused credential goes to the session as one typed refusal")
    func aRefusalReachesTheSession() async {
        let handled = LockedValue(0)
        let client = Stub.client { _, _, operation in
            operation == TripWire.members
                ? Stub.detail("Not authenticated", status: .unauthorized)
                : Stub.detail("Not Found", status: .notFound)
        }
        let (trip, _, ended) = await seeded(onUnauthorized: { _ in
            handled.set(handled.get() + 1)
            return .endedSession
        })
        await ended.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        #expect(handled.get() == 1, "the refusal did not reach the session")
        #expect(ended.lastError != nil, "an ended session said nothing")
        #expect(ended.state(for: trip) == .notLoaded)

        // A refusal of a credential already replaced ends nothing and earns no sentence.
        let (other, _, superseded) = await seeded("Other", onUnauthorized: { _ in .superseded })
        await superseded.drain(other, using: client.handle, baseURL: Stub.baseURL)
        #expect(superseded.lastError == nil, "a stale refusal wrote a sentence")
    }

    @Test("a refusal the session decides after an invalidation writes nothing over the photos")
    func aRefusalDecidedAfterInvalidationSaysNothing() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in
            Stub.detail("Not authenticated", status: .unauthorized)
        }
        let (trip, _, members) = await seeded(onUnauthorized: { _ in
            entered.open()
            await release.wait()
            return .endedSession
        })
        let inFlight = Task {
            await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the refusal never reached the session")
        members.invalidate(uid: trip.uid)
        release.open()
        await inFlight.value
        let said = members.lastError
        #expect(said == nil, "an invalidated drain said its refusal: \(said ?? "")")
    }
}
