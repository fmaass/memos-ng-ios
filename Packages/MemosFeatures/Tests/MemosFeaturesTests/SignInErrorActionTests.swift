import MemosCore
import Testing

@testable import MemosFeatures

/// Which failure earns a button, and which do not.
///
/// Exactly one of them can be acted on from inside the phone's Settings: the Local Network
/// permission the first sign-in on a home LAN trips over. Offering the same button for a timeout
/// or an offline phone would send someone to a switch that is already right.
@Suite("The sign-in screen's failure affordance")
struct SignInErrorActionTests {
    @Test("the local-network denial is the one failure Settings can fix")
    func denialOffersSettings() {
        #expect(signInErrorAction(for: .transport(.localNetworkDenied)) == .openSettings)
    }

    @Test(
        "no other failure sends anyone to Settings",
        arguments: [
            NativeLoginError.transport(.offline),
            .transport(.other("NSURLErrorDomain -1001")),
            .answerLost,
            .cancelled,
            .malformedCallback,
            .exchangeRejected(.codeExpired),
            .api(.server(status: 500)),
        ]
    )
    func everythingElseOffersNothing(_ failure: NativeLoginError) {
        #expect(signInErrorAction(for: failure) == .nothing)
    }

    @Test("a sign-in that has not failed offers nothing")
    func noFailureOffersNothing() {
        #expect(signInErrorAction(for: nil) == .nothing)
    }
}
