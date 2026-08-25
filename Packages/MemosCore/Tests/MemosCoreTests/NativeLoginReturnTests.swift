import Foundation
import MemosCore
import Testing

/// Which URLs are this sign-in's callback, and — the half that matters more — which are not.
///
/// The app presents the browser view itself now, so nothing decides this for it any more. Every
/// URL the app is ever opened with reaches this function: a shared memo link, anything anybody
/// taps, a URL another app sent. One of them resolving a waiting sign-in would be a sign-in
/// completed by a stranger; one of them being rejected wrongly is the dead button coming back.
@Suite("Which URLs are the sign-in's callback")
struct NativeLoginReturnTests {
    private let host = "memos.example.invalid"
    private let path = "/ios/auth/callback"

    private func lane(_ raw: String) -> NativeLoginReturn.Lane? {
        guard let url = URL(string: raw) else {
            Issue.record("the test's own URL did not parse: \(raw)")
            return nil
        }
        return NativeLoginReturn.lane(of: url, callbackHost: host, callbackPath: path)
    }

    @Test("the server's own https callback is the universal-link lane")
    func httpsCallback() {
        #expect(lane("https://memos.example.invalid/ios/auth/callback?code=abc") == .universalLink)
    }

    @Test("the association declares /ios/auth/callback*, so a deeper segment is still ours")
    func httpsCallbackWithSegment() {
        let deeper = "https://memos.example.invalid/ios/auth/callback/done?code=abc"
        #expect(lane(deeper) == .universalLink)
    }

    @Test("a path that merely starts with the same letters is a different route, not the callback")
    func siblingPathIsNotTheCallback() {
        #expect(lane("https://memos.example.invalid/ios/auth/callbackery?code=abc") == nil)
    }

    @Test(
        "no other https URL of the same server resolves a sign-in",
        arguments: [
            "https://memos.example.invalid/m/abc123",
            "https://memos.example.invalid/",
            "https://memos.example.invalid/ios/auth",
        ]
    )
    func otherRoutesOfTheSameServer(_ raw: String) {
        #expect(lane(raw) == nil)
    }

    @Test(
        "another host, or a scheme that is not https, is never the universal-link lane",
        arguments: [
            "https://evil.example.invalid/ios/auth/callback?code=abc",
            "http://memos.example.invalid/ios/auth/callback?code=abc",
        ]
    )
    func wrongHostOrScheme(_ raw: String) {
        #expect(lane(raw) == nil)
    }

    /// The lane that carries every sign-in in this deployment. The server is on internal-only
    /// DNS, so Apple's CDN can never fetch the domain association and the https lane above cannot
    /// fire at all: the link the callback page carries on this scheme is the only way back into
    /// the app, and a person tapping it is the whole return trip.
    @Test("the callback page's tap-to-return link is the custom-scheme lane")
    func customScheme() {
        #expect(lane("memosng://auth-callback?code=abc") == .customScheme)
    }

    @Test("a scheme URL written without the slashes names the same host")
    func customSchemeWithoutSlashes() {
        #expect(lane("memosng:auth-callback?code=abc") == .customScheme)
    }

    @Test("the app answers to exactly one name under its scheme")
    func customSchemeOtherHost() {
        #expect(lane("memosng://something-else?code=abc") == nil)
        #expect(lane("memosng://auth-callback-2?code=abc") == nil)
    }

    @Test("another app's scheme is not ours however it is spelled")
    func foreignScheme() {
        #expect(lane("memos://auth-callback?code=abc") == nil)
        #expect(lane("memosngx://auth-callback?code=abc") == nil)
    }

    /// iOS lowercases a scheme it opens and a host is case-insensitive by RFC 3986, so neither
    /// may be compared literally — a callback refused over its capitalisation is a sign-in that
    /// silently never comes back.
    @Test("scheme and host are matched without regard to case")
    func caseInsensitive() {
        #expect(lane("MEMOSNG://AUTH-CALLBACK?code=abc") == .customScheme)
        #expect(lane("HTTPS://MEMOS.EXAMPLE.INVALID/ios/auth/callback?code=abc") == .universalLink)
    }

    /// A lane says the URL is ours; what is ON it is still read the same way, by the same parser,
    /// whichever lane it came in on. The two halves are separate on purpose.
    @Test("a lane is recognised whatever the parameters say, including a refusal")
    func laneIsIndependentOfTheParameters() {
        #expect(lane("memosng://auth-callback?error=access_denied") == .customScheme)
        #expect(lane("https://memos.example.invalid/ios/auth/callback") == .universalLink)
    }

    @Test("both lanes have a name for the log that says which one a sign-in came back on")
    func everyLaneIsNamed() {
        for lane in NativeLoginReturn.Lane.allCases {
            #expect(!lane.description.isEmpty)
        }
        #expect(
            Set(NativeLoginReturn.Lane.allCases.map(\.description)).count
                == NativeLoginReturn.Lane.allCases.count
        )
    }
}
