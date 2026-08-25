import MemosCore
import SwiftUI

/// The sign-out conversation, owned once and startable from anywhere.
///
/// Two surfaces can begin it — the account menu in the timeline's toolbar, and the Account section
/// of the Settings screen pushed from it — and both have to be the SAME conversation. Not for
/// tidiness: `SignOutFlow` guarantees that exactly one revoke leaves the device however many times
/// a tap arrives, and that guarantee is about ONE machine. Two screens each keeping a stage of
/// their own would be two machines, each correct, and between them two revokes.
///
/// So the stage lives here, the alerts are attached once at the navigation stack (`signOutAlerts`),
/// and the screens only send events.
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
    func send(_ event: SignOutFlow.Event, to session: SessionStore) {
        let previous = stage
        stage = SignOutFlow.next(previous, on: event)
        guard SignOutFlow.revokes(stage), !SignOutFlow.revokes(previous) else { return }
        Task {
            let outcome = await session.signOut()
            send(.revokeReturned(outcome), to: session)
        }
    }

    func settle() { stage = .idle }
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
    /// Attached to the navigation STACK, so neither the question nor its answer is drawn under the
    /// anchor that opened the menu, and so the Settings screen pushed inside that stack shares the
    /// one conversation instead of starting a second.
    func signOutAlerts(_ conversation: SignOutConversation, session: SessionStore) -> some View {
        self
            .alert(
                "Sign out?",
                isPresented: .init(
                    get: { conversation.isAsking },
                    set: { if !$0 { conversation.send(.cancelled, to: session) } }
                )
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
                isPresented: .init(
                    get: { conversation.explanation != nil },
                    set: { if !$0 { conversation.send(.cancelled, to: session) } }
                ),
                presenting: conversation.explanation
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
