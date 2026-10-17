import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A member drain that fails is not read again by itself: the screen's re-drain asks
/// `needsDrain(for:)`, and a failure standing for the lineage that issued the drain says no.
/// Asked again only by what asks on purpose — an explicit drain, an invalidation, a forget, a new
/// session or a moved revision. The REAL `TripMemberStore` over the generated client; every
/// request counted at the transport.
@MainActor
@Suite("Trip members — a failed drain is not retried by itself")
struct TripMemberDrainFailureTests {
    private let seeder = TripSeeder()

    /// What the screen's re-drain task does, as `TripView` writes it: read only while the store
    /// says the members need reading.
    private func screenRedrain(
        _ members: TripMemberStore, _ scope: CollectionScope, _ handle: SessionHandle
    ) async {
        guard members.needsDrain(for: scope) else { return }
        await members.drain(scope, using: handle, baseURL: Stub.baseURL)
    }

    /// A transport counting every request and answering through `answer`.
    private nonisolated static func counting(
        _ calls: LockedValue<Int>,
        answer: @escaping @Sendable () throws -> (HTTPResponse, HTTPBody?)
    ) -> any APIProtocol {
        Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            return try answer()
        }
    }

    /// A seeded trip, as the trip store lists it, and the member store over it.
    private func trip(
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) async throws -> (CollectionScope, TripStore, TripMemberStore) {
        let uid = seeder.server.seed(title: "Portugal 2026", tag: "portugal2026", pictures: [])
        let (trips, members) = await seeder.members(onUnauthorized: onUnauthorized)
        let trip = try #require(trips.trips.first { $0.uid == uid })
        return (.trip(trip), trips, members)
    }

    private static var tag: CollectionScope { CollectionScopeDrainTests.scope(.tag("lisbon")) }

    // MARK: - the loop stops

    @Test("a trip drain answered 503 on every page is not read again by the screen's re-drain")
    func aPersistentFailureStopsTheTripLoop() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (scope, _, members) = try await trip()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 1, "control: the first drain sent one request")
        #expect(members.state(for: scope) == .notLoaded, "control: nothing was held")
        #expect(members.lastError != nil, "control: the 503 was reported")

        #expect(members.drainFailed(for: scope), "the failure was not recorded")
        #expect(!members.needsDrain(for: scope), "the screen is told to read again by itself")
        await screenRedrain(members, scope, client.handle)
        await screenRedrain(members, scope, client.handle)
        #expect(calls.get() == 1, "the re-drain kept asking: \(calls.get()) requests")
    }

    @Test("a tag's drain answered 503 on every page is not read again by the screen's re-drain")
    func aPersistentFailureStopsTheTagLoop() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (_, members) = await seeder.members()
        await members.drain(Self.tag, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 1, "control: the first drain sent one request")

        #expect(members.drainFailed(for: Self.tag), "the failure was not recorded")
        #expect(!members.needsDrain(for: Self.tag))
        await screenRedrain(members, Self.tag, client.handle)
        #expect(calls.get() == 1, "the re-drain kept asking: \(calls.get()) requests")
    }

    @Test("an offline trip drain is not read again by the screen's re-drain either")
    func anOfflineFailureStopsTheLoop() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { throw URLError(.notConnectedToInternet) }
        let (scope, _, members) = try await trip()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 1, "control: the first drain sent one request")
        #expect(members.lastError == nil, "control: an offline failure is no sentence")

        #expect(members.drainFailed(for: scope), "the offline failure was not recorded")
        await screenRedrain(members, scope, client.handle)
        #expect(calls.get() == 1, "the re-drain kept asking: \(calls.get()) requests")
    }

    // MARK: - what asks again

    @Test("an explicit drain after the failure reads again, once, and the failure stands again")
    func anExplicitDrainReadsAgain() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (scope, _, members) = try await trip()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(!members.needsDrain(for: scope), "control: the failure stands")

        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 2, "the explicit drain did not read: \(calls.get()) requests")
        #expect(members.drainFailed(for: scope), "the second failure was not recorded")
        await screenRedrain(members, scope, client.handle)
        #expect(calls.get() == 2, "the re-drain asked after the second failure")
    }

    @Test("invalidating the trip after the failure lets the screen read it again, once")
    func anInvalidationReadsAgain() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (scope, _, members) = try await trip()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(!members.needsDrain(for: scope), "control: the failure stands")

        members.invalidate(uid: scope.id)
        #expect(!members.drainFailed(for: scope), "the invalidation kept the failure")
        await screenRedrain(members, scope, client.handle)
        #expect(calls.get() == 2, "the invalidated trip was not read: \(calls.get()) requests")
    }

    @Test("invalidating every trip after the failure lets the screen read it again, once")
    func anInvalidationOfAllReadsAgain() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (scope, _, members) = try await trip()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(!members.needsDrain(for: scope), "control: the failure stands")

        members.invalidate(uid: nil)
        await screenRedrain(members, scope, client.handle)
        #expect(calls.get() == 2, "the invalidated trip was not read: \(calls.get()) requests")
    }

    @Test("forgetting a tag after the failure lets the screen read it again, once")
    func aForgetReadsTheTagAgain() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (_, members) = await seeder.members()
        await members.drain(Self.tag, using: client.handle, baseURL: Stub.baseURL)
        #expect(!members.needsDrain(for: Self.tag), "control: the failure stands")

        members.forget(Self.tag)
        await screenRedrain(members, Self.tag, client.handle)
        #expect(calls.get() == 2, "the forgotten tag was not read: \(calls.get()) requests")
    }

    @Test("an explicit drain of the tag after the failure reads again, once")
    func anExplicitDrainReadsTheTagAgain() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (_, members) = await seeder.members()
        await members.drain(Self.tag, using: client.handle, baseURL: Stub.baseURL)
        #expect(!members.needsDrain(for: Self.tag), "control: the failure stands")

        await members.drain(Self.tag, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 2, "the explicit drain did not read: \(calls.get()) requests")
    }

    @Test("a failure under one session does not hold the next one's re-drain")
    func aNewSessionReadsAgain() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (scope, _, members) = try await trip()
        let first = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: first)
        members.reports(to: session)
        await members.drain(scope, using: first, baseURL: Stub.baseURL)
        #expect(!members.needsDrain(for: scope), "control: the failure stands")

        let second = SessionHandle(client: client, generation: 2)
        session.activeHandle = second
        #expect(!members.drainFailed(for: scope), "the old session's failure still applies")
        await screenRedrain(members, scope, second)
        #expect(calls.get() == 2, "the new session's re-drain did not read: \(calls.get())")
    }

    @Test("a failure before the trips moved does not hold the re-drain after a refresh")
    func aMovedRevisionReadsAgain() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (scope, trips, members) = try await trip()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(!members.needsDrain(for: scope), "control: the failure stands")

        let before = trips.revision
        await trips.refresh(using: seeder.server.client.handle, baseURL: Stub.baseURL)
        #expect(trips.revision != before, "control: the refresh moved the revision")
        await screenRedrain(members, scope, client.handle)
        #expect(calls.get() == 2, "the moved trip was not read again: \(calls.get()) requests")
    }

    @Test("a drain that lands after a failure ends it")
    func aSuccessEndsTheFailure() async throws {
        let failing = LockedValue(true)
        let client = Stub.client { _, _, _ in
            failing.get() ? Stub.empty(.serviceUnavailable) : TripWire.page([0, 1])
        }
        let (scope, _, members) = try await trip()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.drainFailed(for: scope), "control: the failure stands")

        failing.set(false)
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.state(for: scope) == .complete)
        #expect(!members.drainFailed(for: scope), "a landed drain left the failure standing")
        members.invalidate(uid: scope.id)
        #expect(members.needsDrain(for: scope), "the invalidated trip is held back")
    }

    // MARK: - fences

    @Test("a failure answered after an invalidation records nothing")
    func aStaleFailureRecordsNothing() async throws {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.open()
                await release.wait()
            }
            return Stub.empty(.serviceUnavailable)
        }
        let (scope, _, members) = try await trip()
        let inFlight = Task {
            await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        members.invalidate(uid: scope.id)
        release.open()
        await inFlight.value

        #expect(!members.drainFailed(for: scope), "a failure that outlived its slot was recorded")
        await screenRedrain(members, scope, client.handle)
        #expect(calls.get() == 2, "the invalidated trip was not read: \(calls.get()) requests")
    }

    @Test("a failure answered after the session was replaced records nothing for the new one")
    func aFailureAfterASessionChangeRecordsNothing() async throws {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.open()
                await release.wait()
            }
            return Stub.empty(.serviceUnavailable)
        }
        let (scope, _, members) = try await trip()
        let first = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: first)
        members.reports(to: session)
        let inFlight = Task { await members.drain(scope, using: first, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        let second = SessionHandle(client: client, generation: 2)
        session.activeHandle = second
        release.open()
        await inFlight.value

        #expect(!members.drainFailed(for: scope), "the old session's failure holds the new one")
        await screenRedrain(members, scope, second)
        #expect(calls.get() == 2, "the new session's re-drain did not read: \(calls.get())")
    }

    @Test("an old drain failing after a newer one landed in its slot records nothing")
    func aFailureOutlivedByANewerDrainRecordsNothing() async throws {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            guard calls.get() == 1 else { return TripWire.page([0, 1]) }
            entered.open()
            await release.wait()
            return Stub.empty(.serviceUnavailable)
        }
        let (scope, _, members) = try await trip()
        let old = Task { await members.drain(scope, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        // The same lineage asked again after the slot was let go: a new flight, a new token.
        members.invalidate(uid: scope.id)
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.state(for: scope) == .complete, "control: the newer drain landed")
        release.open()
        await old.value

        #expect(!members.drainFailed(for: scope), "the outlived drain's failure was recorded")
        #expect(members.state(for: scope) == .complete, "the outlived failure took the members")
        #expect(calls.get() == 2)
    }

    @Test("a month's failure in one zone holds no read of the same month in another")
    func aFailureIsPerRequest() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (_, members) = await seeder.members()
        let zurich = CollectionScopeDrainTests.scope(.month("2026-09"))
        let tokyo = CollectionScope.automatic(
            AutomaticCollection(
                kind: .month("2026-09"), count: 9, cover: nil,
                zone: try #require(TimeZone(identifier: "Asia/Tokyo"))))
        #expect(zurich.id == tokyo.id, "control: one key for both zones")
        await members.drain(zurich, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.drainFailed(for: zurich), "control: the failure stands")

        #expect(!members.drainFailed(for: tokyo), "another zone's request is held back")
        await screenRedrain(members, tokyo, client.handle)
        #expect(calls.get() == 2, "the other zone was not read: \(calls.get()) requests")
    }

    @Test("a refused credential is not recorded as a failure: the next credential reads again")
    func aRefusalIsNotAFailure() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) {
            Stub.detail("Not authenticated", status: .unauthorized)
        }
        let handled = LockedValue(0)
        let (scope, _, members) = try await trip { _ in
            handled.set(handled.get() + 1)
            return .superseded
        }
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 1, "control: the first drain sent one request")
        #expect(handled.get() == 1, "the refusal no longer reaches the session")

        #expect(!members.drainFailed(for: scope), "a refusal was held as a failure")
        await screenRedrain(members, scope, client.handle)
        #expect(calls.get() == 2, "the re-drain after a superseded refusal did not read")
    }

    @Test("a failure of one tag holds no other tag, and no trip")
    func aFailureIsPerKey() async throws {
        let calls = LockedValue(0)
        let client = Self.counting(calls) { Stub.empty(.serviceUnavailable) }
        let (scope, _, members) = try await trip()
        await members.drain(Self.tag, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.drainFailed(for: Self.tag), "control: the failure stands")

        let other = CollectionScopeDrainTests.scope(.tag("porto"))
        #expect(!members.drainFailed(for: other))
        #expect(!members.drainFailed(for: scope))
        await screenRedrain(members, other, client.handle)
        await screenRedrain(members, scope, client.handle)
        #expect(calls.get() == 3, "another key was held back: \(calls.get()) requests")
    }
}
