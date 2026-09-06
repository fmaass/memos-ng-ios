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
}
