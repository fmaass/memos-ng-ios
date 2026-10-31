import Foundation

/// Which queue a share made outside the app goes into, and the licence that stamps it.
///
/// The share extension reads two licences — the member's in the member outbox, a guest's trip pass
/// in the guest outbox — and never a token: each licence is a binding the app published, and the
/// queue it sits beside is the only queue a capture stamped with it may enter. Kept here, as a
/// pure answer over the two files' contents, because the extension target has no test bundle and
/// the decision is the one place a guest capture could be sent home or a member's to the trip.
public struct ShareRoute: Sendable, Equatable {
    public let kind: CredentialKind
    public let licence: PublishedLicence

    /// The route a share takes with these two licences standing, or nil when neither may stamp one.
    ///
    /// A guest pass WINS while it stands. A phone carries a guest pass only for the length of a
    /// trip somebody was invited to, and a household member shares from the app itself; a share
    /// sheet opened while the pass is live is the guest's. (Stated assumption, MEMNG-1011 slice i;
    /// the owner may course-correct.)
    ///
    /// Each licence is honoured only for the kind its own queue drains as: a binding of the other
    /// kind in either file is no licence at all, so a member binding can never be stamped into the
    /// guest queue, nor a guest binding into the member one.
    public static func resolve(member: PublishedLicence?, guest: PublishedLicence?) -> ShareRoute? {
        if let guest, guest.binding.credentialKind == .guest {
            return ShareRoute(kind: .guest, licence: guest)
        }
        if let member, member.binding.credentialKind == .member {
            return ShareRoute(kind: .member, licence: member)
        }
        return nil
    }

    /// The licence a share opened for `kind` may still be stamped with: what the two files say
    /// NOW, and only while they still route to that kind. Nil when the pass ended, the member
    /// signed out, or the route moved to the other queue — a capture composed for the trip is not
    /// posted home because the pass ran out under the sheet, and one composed for home (with its
    /// visibility) does not become a guest's because a pass arrived.
    public static func licence(
        for kind: CredentialKind, member: PublishedLicence?, guest: PublishedLicence?
    ) -> PublishedLicence? {
        guard let route = resolve(member: member, guest: guest), route.kind == kind else {
            return nil
        }
        return route.licence
    }

    /// The route as the two app-group licence files say it now. Read at each call, never kept:
    /// the files are the only truth the app and the extension share.
    public static func live(appGroup: String = OutboxDefaults.appGroup) -> ShareRoute? {
        resolve(
            member: OutboxAccountStore.live(appGroup: appGroup)?.currentLicence(),
            guest: OutboxAccountStore.guestLive(appGroup: appGroup)?.currentLicence()
        )
    }

    /// `licence(for:member:guest:)` over the app-group files, read at the moment of the call.
    public static func liveLicence(
        for kind: CredentialKind, appGroup: String = OutboxDefaults.appGroup
    ) -> PublishedLicence? {
        licence(
            for: kind,
            member: OutboxAccountStore.live(appGroup: appGroup)?.currentLicence(),
            guest: OutboxAccountStore.guestLive(appGroup: appGroup)?.currentLicence()
        )
    }

    /// The queue directory this route's captures are written to, or nil when the app group is not
    /// reachable — and then nothing is written: only the app drains, and only from the app group.
    public static func appGroupRoot(
        for kind: CredentialKind, appGroup: String = OutboxDefaults.appGroup
    ) -> URL? {
        switch kind {
        case .member: OutboxRepository.appGroupRoot(appGroup: appGroup)
        case .guest: OutboxRepository.guestAppGroupRoot(appGroup: appGroup)
        }
    }
}
