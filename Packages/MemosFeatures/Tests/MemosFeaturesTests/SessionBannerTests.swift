import MemosCore
@testable import MemosFeatures
import Testing

@Suite("The unconfirmed-session banner")
struct SessionBannerTests {
    @Test("it says the session's own sentence when the credential is unconfirmed")
    func showsTheSentenceWhenUnverified() {
        #expect(SessionBanner.text(for: .unverified("Can't reach home.")) == "Can't reach home.")
    }

    /// The first check of a launch is not a failure, and a banner there would flash on every cold
    /// start of a session that turns out to be perfectly fine.
    @Test("it says nothing while the first check is still out")
    func saysNothingWhileVerifying() {
        #expect(SessionBanner.text(for: .verifying) == nil)
    }

    @Test("and nothing at all once the server has confirmed the credential")
    func saysNothingWhenVerified() {
        #expect(SessionBanner.text(for: .verified) == nil)
    }

    /// The older-server line is the one card a confirmed session can carry: it is about the
    /// server's contract, not the credential, and it says exactly the sentence the app promises.
    @Test("a confirmed session on an older server says so, in exactly one sentence")
    func aConfirmedSessionCarriesTheOlderServerLine() {
        let notice = SessionBanner.notice(
            showingUnreachable: false,
            verification: .verified,
            showingOlderServer: true
        )
        #expect(notice == .olderServer("This server is older than the app expects."))
    }

    /// One card, and the more urgent one: an unreachable server outranks the older-server line,
    /// and so does a credential not yet confirmed.
    @Test("the older-server line yields to the unreachable notice and to the unconfirmed line")
    func theOlderServerLineYields() {
        let unreachable = SessionBanner.notice(
            showingUnreachable: true,
            verification: .unverified("Can't reach home."),
            showingOlderServer: true
        )
        #expect(unreachable == .unreachable("Can't reach home."))
        let unverified = SessionBanner.notice(
            showingUnreachable: false,
            verification: .unverified("Can't reach home."),
            showingOlderServer: true
        )
        #expect(unverified == .unverified("Can't reach home."))
    }

    @Test("without the flag a confirmed session still says nothing")
    func noFlagNoLine() {
        #expect(
            SessionBanner.notice(
                showingUnreachable: false, verification: .verified, showingOlderServer: false
            ) == nil
        )
    }
}
