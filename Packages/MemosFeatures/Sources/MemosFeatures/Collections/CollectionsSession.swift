import MemosCore
import SwiftUI

/// What the session's collections do when the session becomes somebody else's, or nobody's.
enum CollectionsSession {
    /// The trips belong to `identity` from now on — the outgoing scope's trips and writes leave
    /// memory — and every member list, journal,
    /// count and span read under the outgoing identity is forgotten and drops on arrival. Called
    /// beside the timeline's own move (`TimelineView`), with the same identity.
    static func identityChanged(
        to identity: TimelineSnapshotIdentity?,
        trips: TripStore?,
        members: TripMemberStore?
    ) {
        trips?.sessionIdentityChanged(to: identity)
        members?.sessionIdentityChanged()
    }
}

extension View {
    /// Calls `perform` with the session's identity whenever it changes: the server, the subject or
    /// both. The whole pair is watched, because the same subject on another server is another
    /// account — a watch on the subject alone would keep one account's collections on screen for
    /// the other whenever a session moved servers without passing through nobody.
    func onSessionIdentityChange(
        _ identity: TimelineSnapshotIdentity?,
        perform: @escaping (TimelineSnapshotIdentity?) -> Void
    ) -> some View {
        onChange(of: identity) { _, identity in perform(identity) }
    }
}

extension View {
    /// Reads the session's trip list as soon as there is a store, an identity and a way to read,
    /// and again whenever the identity changes (MEMNG-781) — so a capture opened from the
    /// Timeline at a cold launch is offered today's trip without the Collections tab ever having
    /// appeared.
    ///
    /// `task(id:)` is the initial delivery `onSessionIdentityChange` does not make: it runs when
    /// the view appears and again for every new key. Each run first moves the store to the
    /// identity it reads for (idempotent — the Timeline's own move may have come first, or may
    /// come after), so the list is issued under that identity and judged against it on arrival:
    /// an answer for an identity that has gone drops (`TripStore.refresh`), and a list already
    /// on the wire for the same scope is joined, not sent twice.
    func readsTrips(
        _ trips: TripStore?, under identity: TimelineSnapshotIdentity?,
        access: @escaping () -> CollectionsAccess?
    ) -> some View {
        task(
            id: TripsReading(
                identity: identity, store: trips.map(ObjectIdentifier.init),
                canRead: access() != nil)
        ) {
            guard let trips, identity != nil, let access = access() else { return }
            trips.sessionIdentityChanged(to: identity)
            await trips.refresh(using: access.handle, baseURL: access.baseURL)
        }
    }
}

/// What a read of the trip list is issued for: a new identity, the store being made, or a means
/// of reading arriving is a new read.
private struct TripsReading: Equatable {
    let identity: TimelineSnapshotIdentity?
    let store: ObjectIdentifier?
    let canRead: Bool
}
