import MemosCore
import SwiftUI

/// What signing out needs from the session, and nothing besides.
///
/// A protocol rather than `SessionStore` itself, so the conversation can be DRIVEN in a test: this
/// module's test bundle cannot construct a `SessionStore` (its defaults reach into MemosAPI, which
/// Features does not link — see `SettingsRenderTests`), and since MEMNG-185 the row on the
/// account sheet (the Settings screen until 2026-10-10) is the only way to sign out at all. A
/// wiring no test can drive is a wiring that can be cut without anything going red, and this is
/// not the one to leave in that state.
@MainActor
protocol SignOutRevoking {
    func signOut() async -> SignOutOutcome
    func signOutWithoutRevoking() async
}

extension SessionStore: SignOutRevoking {}

/// The sign-out conversation, owned once and startable from anywhere.
///
/// One conversation, not one per screen. `SignOutFlow` guarantees that exactly one revoke leaves
/// the device however many times a tap arrives, and that guarantee is about ONE machine: two
/// screens each keeping a stage of their own would be two machines, each correct, and between them
/// two revokes. Signing out is started from the row at the bottom of the account sheet and nowhere
/// else (MEMNG-185, chrome trim 2026-10-10), but a revoke can outlive that sheet, so the stage has
/// to outlive it too — which is what this object is for.
///
/// So the stage lives here, handed to the sheet by the Timeline that owns it; the alerts
/// (`signOutAlerts`) ask from whichever level is on top; and the views only send events.
@MainActor
@Observable
final class SignOutConversation {
    private(set) var stage = SignOutFlow.Stage.idle

    var isAsking: Bool { stage == .asking }

    var explanation: SignOutFlow.Decision? {
        guard case .explaining(let decision) = stage else { return nil }
        return decision
    }

    /// The single place a sign-out can start. The revoke is fired on the TRANSITION into
    /// `revoking`, never on an event, so no repeat of any tap can send a second one.
    func send(_ event: SignOutFlow.Event, to session: any SignOutRevoking) {
        let previous = stage
        stage = SignOutFlow.next(previous, on: event)
        guard SignOutFlow.revokes(stage), !SignOutFlow.revokes(previous) else { return }
        Task {
            let outcome = await session.signOut()
            send(.revokeReturned(outcome), to: session)
        }
    }

    func settle() { stage = .idle }

    // The alerts' presentation bindings, with setters that send nothing. A setter used to send
    // `.cancelled`, but it fires when its alert has GONE — after that alert's own button — so a
    // "Sign out?" put away after a revoke that failed at once cancelled the explanation asked in
    // the meantime, and the retry was lost; a second fast failure did the same to its own next
    // question. Every button sends its own answer, Cancel included, so the buttons are the
    // answers and a dismissal says nothing.
    func askingPresented(muted: Bool) -> Binding<Bool> {
        Binding(get: { !muted && self.isAsking }, set: { _ in })
    }

    func explanationPresented(muted: Bool) -> Binding<Bool> {
        Binding(get: { !muted && self.explanation != nil }, set: { _ in })
    }
}

extension View {
    /// The two questions a sign-out can ask, attached once.
    ///
    /// ALERTS rather than confirmation dialogs, and that is not a style choice: a dialog rendered
    /// here as a glass card that dimmed nothing, left the timeline legible underneath, and put its
    /// Cancel button neither on screen nor in the accessibility tree — so the only visible answer
    /// to "Sign out?" was "Sign out". An alert dims, shows both answers, and hands both to
    /// VoiceOver.
    ///
    /// Attached once per presentation level, every one asking the SAME conversation: the
    /// Timeline's stack, and the account sheet's own stack while that sheet is up — an alert
    /// raised under a presented sheet does not appear. `muted` is how the level underneath stands
    /// aside meanwhile (`accountSheet`), so exactly one level ever asks, and a question still
    /// outstanding when the sheet goes is asked by the level the sheet leaves behind.
    func signOutAlerts(
        _ conversation: SignOutConversation,
        session: any SignOutRevoking,
        muted: Bool = false
    ) -> some View {
        self
            .alert(
                "Sign out?",
                isPresented: conversation.askingPresented(muted: muted)
            ) {
                Button("Sign out", role: .destructive) {
                    conversation.send(.confirmed, to: session)
                }
                Button("Cancel", role: .cancel) { conversation.send(.cancelled, to: session) }
            } message: {
                Text("This device's access is revoked. Anything still queued stays on the phone.")
            }
            .alert(
                "Could not sign out",
                isPresented: conversation.explanationPresented(muted: muted),
                presenting: muted ? nil : conversation.explanation
            ) { decision in
                Button("Try again") { conversation.send(.confirmed, to: session) }
                Button(decision.discardTitle, role: .destructive) {
                    Task {
                        await session.signOutWithoutRevoking()
                        conversation.settle()
                    }
                }
                Button("Cancel", role: .cancel) { conversation.send(.cancelled, to: session) }
            } message: { decision in
                Text(decision.message)
            }
    }
}
