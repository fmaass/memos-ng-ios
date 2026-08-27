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
/// any one surface, because where a control sits is not something a test can hold. What a test can
/// hold is that the tap which opens the conversation never reaches the server, however many times
/// it arrives — which is why they did not have to change when MEMNG-185 moved the control out of
/// the menu and down to the bottom of Settings.
@Suite("Sign-out cannot happen by accident")
struct SignOutConfirmationTests {
    private let failure = SignOutOutcome.revokeFailed(.server(status: 502))

    @Test("tapping the row asks, and asking is not signing out")
    func oneTapOnlyAsks() {
        let asked = SignOutFlow.next(.idle, on: .requested)
        #expect(asked == .asking)
        #expect(!SignOutFlow.revokes(asked))
        #expect(SignOutFlow.revokes(.revoking))
    }

    /// The incident itself: the same tap, twice, because the first seemed to do nothing.
    @Test("a double tap is one question, not a sign-out")
    func aDoubleTapIsHarmless() {
        var stage = SignOutFlow.Stage.idle
        for _ in 0..<5 {
            stage = SignOutFlow.next(stage, on: .requested)
            #expect(!SignOutFlow.revokes(stage))
        }
        #expect(stage == .asking)
    }

    /// The general form of the same promise, over the WHOLE event alphabet bar one.
    ///
    /// Every event the machine can receive is injected at every stage it can be in — taps,
    /// dismissals, and each of the three revoke outcomes, including outcomes for revokes this
    /// screen never asked for. The single event left out is `confirmed`, which is the answer to
    /// the question and the only thing that is ALLOWED to reach the server. If any other
    /// sequence, at any depth, arrives at `revoking`, this fails.
    @Test("no sequence of events short of an answer can reach the server")
    func onlyAnAnswerRevokes() {
        let failure = SignOutOutcome.revokeFailed(.server(status: 502))
        let unauthorised: [SignOutFlow.Event] = [
            .requested,
            .cancelled,
            .revokeReturned(.revoked),
            .revokeReturned(.alreadyRevoked),
            .revokeReturned(failure),
        ]
        var reached: Set<String> = []
        func walk(_ stage: SignOutFlow.Stage, depth: Int) {
            #expect(!SignOutFlow.revokes(stage), "reached \(stage) without an answer")
            reached.insert("\(stage)")
            guard depth < 5 else { return }
            for event in unauthorised {
                walk(SignOutFlow.next(stage, on: event), depth: depth + 1)
            }
        }
        walk(.idle, depth: 0)
        // Positive control: the walk really did move the machine around rather than sit still,
        // and it did reach the stage where a failed revoke is being explained.
        #expect(reached.count > 1)
        #expect(reached.contains("asking"))
        // And the one event it never used is the one that does reach the server.
        #expect(SignOutFlow.revokes(SignOutFlow.next(.asking, on: .confirmed)))
    }

    /// An outcome is only ever the answer to a request this screen made. One that arrives in any
    /// other stage — a late reply, a duplicate, anything a confused caller might deliver — leaves
    /// the machine exactly where it was, and in particular never moves it toward revoking.
    @Test("an unsolicited revoke outcome moves nothing, from any stage")
    func unsolicitedOutcomesAreInert() throws {
        let failure = SignOutOutcome.revokeFailed(.server(status: 502))
        let decision = try #require(SignOutFlow.decision(for: failure))
        let outcomes: [SignOutOutcome] = [.revoked, .alreadyRevoked, failure]
        let idleStages: [SignOutFlow.Stage] = [.idle, .asking, .explaining(decision)]
        for stage in idleStages {
            for outcome in outcomes {
                let next = SignOutFlow.next(stage, on: .revokeReturned(outcome))
                #expect(next == stage, "\(outcome) moved \(stage) to \(next)")
                #expect(!SignOutFlow.revokes(next))
            }
        }
        // Positive control: the SOLICITED case does move, so the assertions above are about
        // provenance rather than about outcomes never doing anything.
        #expect(SignOutFlow.next(.revoking, on: .revokeReturned(.revoked)) == .idle)
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

    /// The alert sets its binding to false the moment the destructive button is tapped, so the
    /// dismissal arrives AFTER the confirmation. If that dismissal reset the machine, the screen
    /// would go back to idle while the revoke was still in flight and the outcome would land
    /// nowhere.
    @Test("the alert going away does not abort a revoke already sent")
    func dismissalCannotAbortAnInFlightRevoke() {
        let revoking = SignOutFlow.next(.asking, on: .confirmed)
        #expect(revoking == .revoking)
        #expect(SignOutFlow.next(revoking, on: .cancelled) == .revoking)
        // Nor can another tap on the row start a second one.
        #expect(SignOutFlow.next(revoking, on: .requested) == .revoking)
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

    /// Still in use after MEMNG-185: the Settings screen's account section prints this sentence
    /// at the top, over the avatar. Nothing else does — the menu that also showed it is gone.
    @Test("the account heading names who is signed in")
    func accountHeading() {
        #expect(SignOutFlow.accountHeading(name: "fabian") == "Signed in as fabian")
        #expect(SignOutFlow.accountHeading(name: nil) == "Signed in")
        #expect(SignOutFlow.accountHeading(name: "   ") == "Signed in")
        #expect(SignOutFlow.accountHeading(name: "") == "Signed in")
    }
}
