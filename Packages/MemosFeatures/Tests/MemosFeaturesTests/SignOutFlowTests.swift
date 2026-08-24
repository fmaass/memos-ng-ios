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
