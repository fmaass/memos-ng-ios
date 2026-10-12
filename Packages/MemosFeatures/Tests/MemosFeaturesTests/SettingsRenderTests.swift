import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A session that records what was asked of it and nothing more.
///
/// The narrow protocol (`SignOutRevoking`) exists so this can stand in for a `SessionStore`, which
/// this bundle cannot construct.
@MainActor
private final class SignOutSpy: SignOutRevoking {
    private(set) var revokes = 0
    private(set) var discards = 0
    var outcome = SignOutOutcome.revoked

    func signOut() async -> SignOutOutcome {
        revokes += 1
        return outcome
    }

    func signOutWithoutRevoking() async { discards += 1 }

    /// Returns once a revoke has actually been asked for, and gives up rather than hanging if one
    /// never is. A fence on the thing under test rather than a wait of a chosen length: the test
    /// cannot pass by having slept long enough, and it does not slow down when the machine is
    /// fast.
    func revokeAsked() async {
        for _ in 0..<200 where revokes == 0 { await Task.yield() }
    }
}

/// The row at the bottom of the account sheet — the Settings screen's until the chrome trim
/// (2026-10-10) — which since MEMNG-185 is the app's ONLY way to sign out.
///
/// Held on its own as well as on the sheet (`AccountSheetSignOutTests`): before `SignOutSection`
/// was a view of its own, emptying the row or cutting the line inside it left every test green
/// while the app had no way out of the account at all.
@MainActor
@Suite("The sign-out row on the account sheet")
struct SignOutSectionTests {
    private func row(_ conversation: SignOutConversation, _ session: SignOutSpy) -> SignOutSection {
        SignOutSection(conversation: conversation, session: session)
    }

    @Test("the row puts a Sign out button on the screen")
    func theRowDraws() {
        let drawn = PressProbe.withElement(
            labelled: "Sign out",
            in: row(SignOutConversation(), SignOutSpy())
        ) { $0 != nil }

        #expect(drawn, "no Sign out button on the screen")
    }

    /// The probe's own control. Without this, "it found Sign out" would be worth nothing — a probe
    /// that answered yes to anything would say the same.
    @Test("the probe answers no to a label the row does not have")
    func theProbeCanAnswerNo() {
        let drawn = PressProbe.withElement(
            labelled: "Sign in",
            in: row(SignOutConversation(), SignOutSpy())
        ) { $0 != nil }

        #expect(!drawn)
    }

    /// The wiring, pressed rather than inspected: the button the screen ships, activated the way a
    /// screen reader activates it, moving the shared conversation the alerts are attached to.
    @Test("pressing the row asks the shared conversation, and asking revokes nothing")
    func pressingTheRowAsks() {
        let conversation = SignOutConversation()
        let session = SignOutSpy()
        #expect(conversation.stage == .idle)

        let pressed = PressProbe.withElement(labelled: "Sign out", in: row(conversation, session)) {
            $0?.accessibilityActivate() ?? false
        }

        #expect(pressed, "the Sign out button did not accept an activation")
        #expect(conversation.stage == .asking)
        // The whole point of the machine: the question is a question, and nothing has been sent.
        #expect(session.revokes == 0)
    }

    /// And the answer to that question does reach the server — asked through the conversation the
    /// row itself started, so this is the row's own path rather than a machine driven from
    /// nowhere.
    @Test("answering yes to the row's question revokes exactly once")
    func answeringYesRevokes() async {
        let conversation = SignOutConversation()
        let session = SignOutSpy()
        PressProbe.withElement(labelled: "Sign out", in: row(conversation, session)) {
            $0?.accessibilityActivate()
        }

        conversation.send(.confirmed, to: session)
        await session.revokeAsked()

        #expect(session.revokes == 1)
        #expect(session.discards == 0)
    }
}

/// What putting a sign-out alert away says: nothing. Against setters that send `.cancelled` this
/// fails, because a stale dismissal cancelled a later question — a "Sign out?" put away after a
/// revoke that failed at once took the explanation, and its Try again, with it.
@MainActor
@Suite("A sign-out alert put away answers nothing")
struct SignOutAlertDismissalTests {
    @Test("dismissing either alert leaves the question and the explanation standing")
    func aDismissalAnswersNothing() async {
        let conversation = SignOutConversation()
        let session = SignOutSpy()
        session.outcome = .revokeFailed(.server(status: 502))

        conversation.send(.requested, to: session)
        #expect(conversation.isAsking, "precondition: the question was asked")
        conversation.askingPresented(muted: false).wrappedValue = false
        #expect(conversation.isAsking, "putting the question away answered it")

        conversation.send(.confirmed, to: session)
        for _ in 0..<200 where conversation.explanation == nil { await Task.yield() }
        #expect(conversation.explanation != nil, "precondition: the failed revoke was explained")

        conversation.askingPresented(muted: false).wrappedValue = false
        #expect(conversation.explanation != nil, "the question's late dismissal cancelled it")
        conversation.explanationPresented(muted: false).wrappedValue = false
        #expect(conversation.explanation != nil, "the explanation's dismissal answered it")
        #expect(session.revokes == 1)
    }
}
