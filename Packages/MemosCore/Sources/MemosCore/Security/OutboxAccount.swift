import Foundation
import MemosAPI
import MemosOutbox

/// What the outbox is allowed to upload as — the session's own authority, handed over as one
/// value.
///
/// The outbox deliberately knows nothing about sessions, keychains or servers, so the one thing it
/// does need — a base URL, who is signed in, and a bearer token — is handed to it through this.
/// The token is fetched per drain and never stored in a queued job: a credential written into a
/// queue file is a credential in the next backup.
///
/// It used to assemble those three facts itself, from two places: the subject from the session and
/// the token and address from the keychain. That is what this no longer does, and the reason is
/// not the number of awaits. Three reads across two sources can produce a pair that was never
/// true — a sign-in as B whose credential would not store leaves B established in memory and A's
/// token in the keychain, and an assembly across them hands the drain B's identity with A's
/// credential. An incarnation counter cannot see it: nothing changed between the reads. So the
/// authority has ONE source, `SessionStore.credentialGrant()`, which builds it from one object
/// graph in one instant.
///
/// The app is the only process that drains (`ShareRootView` enqueues and stops there), so there is
/// no session-free caller of this left: the share extension's own path reads the account licence
/// and never comes through here.
public struct DeviceOutboxCredentials: OutboxCredentialsProviding {
    /// The session's grant, or nil when it has no authority to give.
    private let grant: @Sendable () async -> CredentialGrant?
    /// The authority epoch, read SYNCHRONOUSLY — which is what `isCurrent` has to be, and what a
    /// hop to the main actor could not be.
    private let epoch: @Sendable () -> Int

    /// - Parameters:
    ///   - epoch: `SessionStore.epoch`, whose value moves whenever the identity or the presented
    ///     credential changes.
    ///   - grant: `SessionStore.credentialGrant()`, hopped to the main actor once per acquisition.
    public init(
        epoch: @escaping @Sendable () -> Int,
        grant: @escaping @Sendable () async -> CredentialGrant?
    ) {
        self.epoch = epoch
        self.grant = grant
    }

    /// One hop, one value. Nothing is assembled here: what comes back was already coherent when
    /// the session built it.
    public func currentCredentials() async -> OutboxCredentials? {
        guard let grant = await grant() else { return nil }
        return OutboxCredentials(
            serverBaseURL: grant.serverBaseURL,
            ownerSubject: grant.subject,
            token: grant.token,
            epoch: grant.epoch,
            uploadLimit: grant.uploadLimit
        )
    }

    /// Whether a grant taken earlier still stands — asked immediately before every request the
    /// drain sends with it.
    ///
    /// Read from the lock-protected box rather than by asking the session again, because the
    /// answer has to arrive without a suspension: an `await` here is one more instant for the
    /// switch this exists to catch. Every withdrawal and every replacement of authority moves that
    /// number in the same synchronous step, so an unchanged epoch IS the session saying the grant
    /// still names what it named.
    public func isCurrent(_ credentials: OutboxCredentials) -> Bool {
        epoch() == credentials.epoch
    }

    /// The same question of a number kept without the credential it came with — see
    /// `OutboxCredentialsProviding.stillCurrent(epoch:)`. Same box, same synchronous read.
    public func stillCurrent(epoch: Int) -> Bool {
        self.epoch() == epoch
    }

    /// The limit the session holds now, asked of the same grant the drain acquired from and
    /// judged by the epoch that grant carries: a limit read after the session was replaced
    /// belongs to someone else's server and answers nothing about these credentials.
    public func currentUploadLimit(for credentials: OutboxCredentials) async -> Int64? {
        guard let grant = await grant(), grant.epoch == credentials.epoch else { return nil }
        return grant.uploadLimit
    }
}
