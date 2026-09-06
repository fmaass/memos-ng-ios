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

/// The same rule for the launch screen, which parks on its own failure type.
///
/// It is the same single exception — the Local Network permission — and it matters more here than
/// on the sign-in screen: the server is a host on the home LAN, so a denial is what a first launch
/// after an install runs into, and "Try again" cannot fix it.
@Suite("The launch screen's failure affordance")
struct SessionRestoreErrorActionTests {
    @Test("the local-network denial is the one launch failure Settings can fix")
    func denialOffersSettings() {
        #expect(restoreErrorAction(for: .localNetworkDenied) == .openSettings)
    }

    @Test(
        "no other launch failure sends anyone to Settings",
        arguments: [
            SessionRestoreFailure.offline(host: "memos.example.invalid"),
            .unreachable(host: "memos.example.invalid", detail: "NSURLErrorDomain -1001"),
            .server(.server(status: 500)),
        ]
    )
    func everythingElseOffersNothing(_ failure: SessionRestoreFailure) {
        #expect(restoreErrorAction(for: failure) == .nothing)
    }

    @Test("a launch that has not parked offers nothing")
    func noFailureOffersNothing() {
        #expect(restoreErrorAction(for: nil) == .nothing)
    }
}
