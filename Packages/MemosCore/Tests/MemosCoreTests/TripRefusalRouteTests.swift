import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let routeToken = "memos_pat_trips"
private let routeAddress = "https://memos.example.invalid"

/// A 401 on every collection route reaches the session's ONE decision rule, `SessionStore.handle`,
/// carrying the epoch of the credential that earned it — through a real signed-in session and the
/// app's own client, so the middleware that stamps the epoch is the one that runs.
@MainActor
@Suite("Trip refusals")
struct TripRefusalRouteTests {
    nonisolated static let routes = [
        TripWire.list, TripWire.get, TripWire.create, TripWire.patch, TripWire.delete,
        TripWire.exclude, TripWire.include, TripWire.members,
    ]

    @Test(
        "a 401 on each collection route reaches SessionStore.handle with the issuing generation",
        arguments: routes)
    func refusalReachesTheSession(route: String) async throws {
        let presented = LockedValue<PresentedCredential?>(nil)
        let session = SessionStore(
            credentials: vault(),
            makeClient: { _, credential in
                presented.set(credential)
                return Stub.client(token: credential) { _, _, operation in
                    switch operation {
                    case route: return Stub.empty(.unauthorized)
                    case TripWire.get: return Stub.json(TripWire.collection("t1"))
                    default: return Stub.json(Stub.user)
                    }
                }
            },
            lastKnownUser: boundFile()
        )
        await session.restore()
        let handle = try #require(session.activeHandle, "the premise: a signed-in session")
        let issued = try #require(presented.get()).presented().epoch
        let seen = LockedValue<[CredentialRefusal]>([])
        let forward: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome = { refusal in
            seen.set(seen.get() + [refusal])
            return await session.handle(refusal)
        }
        let trips = TripStore(
            identity: TripWire.alice, root: TripWire.root(), onUnauthorized: forward)
        trips.reports(to: session)
        let members = TripMemberStore(trips: trips, onUnauthorized: forward)
        members.reports(to: session)

        await Self.ask(route, trips: trips, members: members, handle: handle)

        #expect(seen.get().count == 1, "the \(route) refusal never reached the rule acting on it")
        #expect(
            seen.get().first?.issuedUnder == issued,
            "and it arrived without the epoch of the credential that earned it")
        #expect(session.state == .signedOut, "the session survived a refusal of its own credential")
    }

    private static func ask(
        _ route: String, trips: TripStore, members: TripMemberStore, handle: SessionHandle
    ) async {
        let trip = Trip(
            uid: "t1", title: "Trip", tag: "trip", createdAt: Date(), updatedAt: Date())
        let base = Stub.baseURL
        switch route {
        case TripWire.list:
            await trips.refresh(using: handle, baseURL: base)
        case TripWire.get:
            _ = try? await trips.reload(uid: "t1", using: handle, baseURL: base)
        case TripWire.create:
            let frozen = NewTripRequest(scope: TripWire.alice, title: "Trip")
            _ = try? await trips.create(frozen, using: handle, baseURL: base)
        case TripWire.patch:
            _ = try? await trips.update(
                uid: "t1", patch: TripPatch(title: .set("x")), using: handle, baseURL: base)
        case TripWire.delete:
            _ = try? await trips.delete(uid: "t1", using: handle)
        case TripWire.exclude:
            _ = try? await trips.exclude(
                uid: "t1", attachment: "p0001", using: handle, baseURL: base)
        case TripWire.include:
            _ = try? await trips.include(
                uid: "t1", attachment: "p0001", using: handle, baseURL: base)
        case TripWire.members:
            await members.drain(trip, using: handle, baseURL: base)
        default:
            Issue.record("no entry point for \(route)")
        }
    }

    private func vault() -> InMemoryCredentials {
        let store = InMemoryCredentials()
        try? store.set(routeToken, for: SessionStore.tokenAccount)
        try? store.set(routeAddress, for: SessionStore.serverAccount)
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
                serverBaseURL: routeAddress,
                credentialFingerprint: CredentialFingerprint.of(routeToken)
            )
        )
    }
}
