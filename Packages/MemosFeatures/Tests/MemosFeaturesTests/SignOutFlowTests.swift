import MemosCore
import Testing

@testable import MemosFeatures

struct SignOutFlowTests {
    @Test func settledOutcomesAskNothing() {
        #expect(SignOutFlow.decision(for: .revoked) == nil)
        #expect(SignOutFlow.decision(for: .alreadyRevoked) == nil)
    }

    @Test func failedRevokeDemandsADecision() throws {
        let decision = try #require(
            SignOutFlow.decision(for: .revokeFailed(.transport(description: "offline")))
        )
        #expect(decision.message.contains("offline"))
        #expect(decision.discardTitle == "Sign out anyway")
    }

    @Test func decisionNamesTheConsequenceNotTheMechanism() throws {
        let decision = try #require(
            SignOutFlow.decision(for: .revokeFailed(.server(status: 502)))
        )
        #expect(decision.message.contains("valid on the server"))
    }
}

/// MEMNG-119. The overflow menu's only row was a destructive "Sign out", and a menu opens with
/// that row under the anchor that opened it — so a second tap on `⋯`, the reflex when a tap seems
/// not to have registered, revoked a live credential during a screenshot tour.
///
/// These are the assertions that make that impossible, and they are about the MACHINE rather than
/// the menu because menu geometry is not something a test can hold. What a test can hold is that
/// the tap which opens the conversation never reaches the server, however many times it arrives.
@Suite("Sign-out cannot happen by accident")
struct SignOutConfirmationTests {
    private let failure = SignOutOutcome.revokeFailed(.server(status: 502))

    @Test("tapping the menu item asks, and asking is not signing out")
    func oneTapOnlyAsks() {
        let asked = SignOutFlow.next(.idle, on: .menuTapped)
        #expect(asked == .asking)
        #expect(!SignOutFlow.revokes(asked))
        #expect(SignOutFlow.revokes(.revoking))
    }

    /// The incident itself: the same tap, twice, because the first seemed to do nothing.
    @Test("a double tap on the anchor is one question, not a sign-out")
    func aDoubleTapIsHarmless() {
        var stage = SignOutFlow.Stage.idle
        for _ in 0..<5 {
            stage = SignOutFlow.next(stage, on: .menuTapped)
            #expect(!SignOutFlow.revokes(stage))
        }
        #expect(stage == .asking)
    }

    /// The general form of the same promise: no sequence of taps on the anchor, with or without
    /// dismissals, ever reaches the stage that talks to the server. Only an answer to the question
    /// does — and the question is asked somewhere the anchor is not.
    @Test("no amount of tapping and dismissing can reach the server")
    func onlyAnAnswerRevokes() {
        let harmless: [SignOutFlow.Event] = [.menuTapped, .cancelled]
        var reached: Set<String> = []
        func walk(_ stage: SignOutFlow.Stage, depth: Int) {
            #expect(!SignOutFlow.revokes(stage), "reached \(stage) without confirming")
            reached.insert("\(stage)")
            guard depth < 7 else { return }
            for event in harmless {
                walk(SignOutFlow.next(stage, on: event), depth: depth + 1)
            }
        }
        walk(.idle, depth: 0)
        // Positive control: the walk really did move the machine around rather than sitting still.
        #expect(reached.count > 1)
        // And the one event it never used is the one that does reach the server.
        #expect(SignOutFlow.revokes(SignOutFlow.next(.asking, on: .confirmed)))
    }

    @Test("a confirmation nobody asked for is ignored rather than obeyed")
    func strayConfirmationDoesNothing() {
        #expect(SignOutFlow.next(.idle, on: .confirmed) == .idle)
        #expect(!SignOutFlow.revokes(SignOutFlow.next(.idle, on: .confirmed)))
    }

    @Test("cancelling the question ends it")
    func cancellingReturnsToIdle() {
        #expect(SignOutFlow.next(.asking, on: .cancelled) == .idle)
        #expect(SignOutFlow.next(.idle, on: .cancelled) == .idle)
    }

    /// The dialog sets its binding to false the moment the destructive button is tapped, so the
    /// dismissal arrives AFTER the confirmation. If that dismissal reset the machine, the screen
    /// would go back to idle while the revoke was still in flight and the outcome would land
    /// nowhere.
    @Test("the sheet going away does not abort a revoke already sent")
    func dismissalCannotAbortAnInFlightRevoke() {
        let revoking = SignOutFlow.next(.asking, on: .confirmed)
        #expect(revoking == .revoking)
        #expect(SignOutFlow.next(revoking, on: .cancelled) == .revoking)
        // Nor can another tap on the anchor start a second one.
        #expect(SignOutFlow.next(revoking, on: .menuTapped) == .revoking)
    }

    @Test("a settled revoke ends the conversation, a failed one explains itself")
    func outcomesLand() throws {
        #expect(SignOutFlow.next(.revoking, on: .revokeReturned(.revoked)) == .idle)
        #expect(SignOutFlow.next(.revoking, on: .revokeReturned(.alreadyRevoked)) == .idle)
        let decision = try #require(SignOutFlow.decision(for: failure))
        #expect(
            SignOutFlow.next(.revoking, on: .revokeReturned(failure)) == .explaining(decision)
        )
    }

    @Test("an outcome for a revoke this screen never sent is ignored")
    func strayOutcomeIsIgnored() {
        #expect(SignOutFlow.next(.idle, on: .revokeReturned(.revoked)) == .idle)
        #expect(SignOutFlow.next(.asking, on: .revokeReturned(.revoked)) == .asking)
    }

    @Test("\"Try again\" after a failed revoke sends another one")
    func retryFromTheExplanation() throws {
        let decision = try #require(SignOutFlow.decision(for: failure))
        #expect(SignOutFlow.next(.explaining(decision), on: .confirmed) == .revoking)
        #expect(SignOutFlow.next(.explaining(decision), on: .cancelled) == .idle)
    }

    @Test("the menu names the account it would sign out of")
    func accountHeading() {
        #expect(SignOutFlow.accountHeading(name: "fabian") == "Signed in as fabian")
        #expect(SignOutFlow.accountHeading(name: nil) == "Signed in")
        #expect(SignOutFlow.accountHeading(name: "   ") == "Signed in")
        #expect(SignOutFlow.accountHeading(name: "") == "Signed in")
    }
}
