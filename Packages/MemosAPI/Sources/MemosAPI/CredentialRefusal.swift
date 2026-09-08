import Foundation

/// A refusal the server answered a credential with, and WHICH credential earned it.
///
/// The epoch travels because the refusal outlives the instant it was earned in. A renewal
/// destroys the presenting token as it mints the successor, so a 401 already on the wire is a
/// true answer about a token that no longer exists — and the effect it triggers (a sign-out, a
/// wipe, a hold) happens one or more actor hops later, by which time "is this about the
/// credential in hand" has a different answer. Judged at the answer, the app signs somebody out
/// of a session they renewed a second ago; judged at the effect, it does not.
///
/// It is the one thing thrown for a 401 through the generated client, so no caller re-derives
/// the classification and none of them can forget the epoch (MEMNG-270).
public struct CredentialRefusal: Error, Equatable, Sendable, LocalizedError {
    /// The generation of the credential the refused request PRESENTED (`PresentedCredential`).
    ///
    /// `nil` where the client carries no generation — a client built from a bare token closure
    /// (the share extension's, and the tests that are about the header). Unknown is treated as
    /// CURRENT everywhere, which is the same convention `ChunkResult.epoch` already carries and
    /// the same direction of safety: an unknown refusal ends the session exactly as it did
    /// before this type existed.
    public let issuedUnder: UInt64?

    public init(issuedUnder: UInt64?) { self.issuedUnder = issuedUnder }

    /// Whether this refusal is about the credential the device is holding RIGHT NOW.
    ///
    /// THE decision rule, in one place. Asked SYNCHRONOUSLY at the effect site and nowhere else:
    /// asked before an await it answers about an instant that has passed, which is the whole of
    /// what this type exists to stop.
    public func concernsCurrentCredential(of credential: PresentedCredential?) -> Bool {
        guard let issuedUnder, let credential else { return true }
        return credential.isCurrent(issuedUnder)
    }

    /// The same rule for a lane that holds a generation rather than the credential object.
    ///
    /// The hand-rolled lanes read their epoch off the grant the send recorded (`SendAuthority`)
    /// and never see a `PresentedCredential` at all. One rule, two ways in — not two rules: the
    /// comparison below is the one `PresentedCredential.isCurrent` makes.
    ///
    /// A `nil` `currentEpoch` is a grant that names no credential any more, which no known
    /// `issuedUnder` can equal — so such a refusal is about a token this lane has already let go
    /// of. That is the opposite direction from an unknown `issuedUnder`, and deliberately: unknown
    /// is only ever read as current on the side that would otherwise let a refusal be ignored.
    public func concernsCurrentCredential(ofEpoch currentEpoch: UInt64?) -> Bool {
        guard let issuedUnder else { return true }
        return issuedUnder == currentEpoch
    }

    public var errorDescription: String? { APIError.unauthorized.errorDescription }
}
