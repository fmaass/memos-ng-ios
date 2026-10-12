import MemosCore
import SwiftUI

/// What the session's collections do when the session becomes somebody else's, or nobody's.
enum CollectionsSession {
    /// The trips belong to `identity` from now on — the outgoing scope's trips, writes and pins
    /// leave memory and the incoming scope's pins are read — and every member list, journal,
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
    func readsTrips(
        _ trips: TripStore?, under identity: TimelineSnapshotIdentity?,
        access: @escaping () -> CollectionsAccess?
    ) -> some View {
        self
    }
}
