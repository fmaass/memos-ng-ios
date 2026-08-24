import MemosCore

/// The one decision sign-out can demand, kept out of the view so it is asserted, not eyeballed.
///
/// A revoke that reached the server (or found the token already dead) needs no conversation. A
/// revoke that could NOT be delivered does: throwing the token away anyway is a real choice with
/// a real consequence — the server goes on honouring it — and the person gets to make that
/// choice, not the error handler.
public enum SignOutFlow {
    public struct Decision: Equatable, Sendable {
        public let message: String
        public let discardTitle: String
    }

    /// `nil` means the sign-out is settled and there is nothing to ask.
    public static func decision(for outcome: SignOutOutcome) -> Decision? {
        guard case .revokeFailed = outcome else { return nil }
        let failure = outcome.failureDescription ?? "no details"
        return Decision(
            message:
                "The server could not be reached to revoke this device's access"
                + " (\(failure))."
                + " Signing out anyway leaves the credential valid on the server"
                + " until it expires or is revoked from the web app.",
            discardTitle: "Sign out anyway"
        )
    }
}
