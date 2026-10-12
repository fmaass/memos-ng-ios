import MemosCore

/// Signing out, as a state machine rather than a button that does it.
///
/// The machine exists because of a real incident: the overflow menu held exactly one item, a
/// destructive "Sign out", and a menu opens with its first row directly under the anchor that
/// opened it. A second tap on `⋯` — the ordinary human reflex when a tap seems not to have
/// registered — landed on that row and revoked a live credential.
///
/// So the tap that opens the conversation and the tap that ends the session are different events,
/// and only one of them reaches the server. `requested` can be delivered any number of times and
/// never revokes anything; nothing is sent until `confirmed` arrives from an alert that is not
/// under the control that asked. `SignOutFlowTests` asserts exactly that, which is the part a
/// screenshot could never show.
///
/// The second decision the flow can demand is older and unchanged: a revoke that could NOT be
/// delivered is a real choice, because throwing the token away anyway leaves the server honouring
/// it. The person makes that one, not the error handler.
public enum SignOutFlow {
    public struct Decision: Equatable, Sendable {
        public let message: String
        public let discardTitle: String
    }

    /// How far the conversation has got. `revoking` is the ONLY stage in which the app is allowed
    /// to talk to the server.
    public enum Stage: Equatable, Sendable {
        case idle
        case asking
        case revoking
        case explaining(Decision)
    }

    public enum Event: Equatable, Sendable {
        /// Somebody asked to sign out — today from the row at the bottom of Settings, and the
        /// name says nothing about which surface, because the machine's promise does not depend
        /// on that. Deliberately harmless.
        case requested
        /// The question was answered yes — in the alert, or "Try again" after a failed revoke.
        case confirmed
        /// The question was answered no, by its Cancel button. An alert's own dismissal sends
        /// nothing (`SignOutConversation.askingPresented`): a question the sheet leaves behind is
        /// asked again by the level underneath.
        case cancelled
        case revokeReturned(SignOutOutcome)
    }

    public static func next(_ stage: Stage, on event: Event) -> Stage {
        switch event {
        case .requested:
            // Idempotent on purpose. A double-tap is one question, asked once, and it cannot
            // reach past `asking` — nor restart a revoke that is already in flight.
            return stage == .idle ? .asking : stage
        case .confirmed:
            // A confirmation is only meaningful for a question that was actually asked. One that
            // arrives out of nowhere is ignored rather than obeyed.
            switch stage {
            case .asking, .explaining: return .revoking
            case .idle, .revoking: return stage
            }
        case .cancelled:
            // Dismissal cannot abort a revoke that has already been sent: the request is gone,
            // and pretending otherwise would leave the screen disagreeing with the server.
            switch stage {
            case .asking, .explaining, .idle: return .idle
            case .revoking: return .revoking
            }
        case .revokeReturned(let outcome):
            guard stage == .revoking else { return stage }
            return decision(for: outcome).map(Stage.explaining) ?? .idle
        }
    }

    /// The one stage that is allowed to reach the network. The view starts the request when the
    /// machine ENTERS it, so there is exactly one place a revoke can begin.
    public static func revokes(_ stage: Stage) -> Bool { stage == .revoking }

    /// The heading over the destructive row. It names the account being signed out of, which is
    /// worth saying in its own right — and, being a heading, it also occupies the row the anchor
    /// sits over, so the destructive item is no longer the thing directly under a second tap.
    public static func accountHeading(name: String?) -> String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Signed in"
        }
        return "Signed in as \(name)"
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
