import Foundation
import MemosAPI
import Testing

/// The pure halves of the device login: the URL that starts it and the callback that ends it.
@Suite("NativeLogin")
struct NativeLoginTests {
    private let configuration = ServerConfiguration(
        baseURL: URL(string: "https://memos.example.invalid")!
    )
    private let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("the authorize URL is the server's own login route in ios mode")
    func authorizeURLShape() throws {
        let url = try #require(
            NativeLogin.authorizeURL(
                configuration: configuration, codeChallenge: challenge, device: "Fabian's iPhone"
            )
        )

        #expect(url.scheme == "https")
        #expect(url.host() == "memos.example.invalid")
        #expect(url.path() == "/api/auth/login")
        #expect(
            query(url) == [
                "client": "ios",
                "code_challenge": challenge,
                "device": "Fabian's iPhone",
            ])
    }

    @Test("a device name is trimmed and its apostrophes survive percent-encoding")
    func deviceNameIsTrimmed() throws {
        let url = try #require(
            NativeLogin.authorizeURL(
                configuration: configuration, codeChallenge: challenge, device: "  iPhone  "
            )
        )
        #expect(query(url)["device"] == "iPhone")
    }

    @Test(
        "a device name the server would reject never leaves the device",
        arguments: ["", "   ", String(repeating: "x", count: 65)]
    )
    func refusesUnusableDeviceName(_ device: String) {
        #expect(
            NativeLogin.authorizeURL(
                configuration: configuration, codeChallenge: challenge, device: device
            ) == nil
        )
    }

    @Test("a device name of exactly the server's maximum is accepted")
    func acceptsMaximumDeviceName() {
        let device = String(repeating: "x", count: NativeLogin.deviceNameMaxLength)
        #expect(
            NativeLogin.authorizeURL(
                configuration: configuration, codeChallenge: challenge, device: device
            ) != nil
        )
    }

    @Test(
        "a code challenge outside RFC 7636's alphabet or bounds is refused",
        arguments: [
            String(repeating: "a", count: 42),
            String(repeating: "a", count: 129),
            String(repeating: "a", count: 42) + "+",
            String(repeating: "a", count: 42) + "=",
            String(repeating: "a", count: 42) + " ",
        ]
    )
    func refusesInvalidChallenge(_ candidate: String) {
        #expect(!NativeLogin.isValidCodeChallenge(candidate))
        #expect(
            NativeLogin.authorizeURL(
                configuration: configuration, codeChallenge: candidate, device: "iPhone"
            ) == nil
        )
    }

    @Test("an S256 challenge of the documented length is accepted")
    func acceptsRealChallenge() {
        #expect(NativeLogin.isValidCodeChallenge(challenge))
        #expect(NativeLogin.isValidCodeChallenge(String(repeating: "-", count: 43)))
        #expect(NativeLogin.isValidCodeChallenge(String(repeating: "_", count: 128)))
    }

    @Test("the callback host is the server's own, because the BFF redirects to itself")
    func callbackHost() {
        #expect(NativeLogin.callbackHost(for: configuration) == "memos.example.invalid")
    }

    @Test("a callback carrying a code yields the code")
    func readsCode() {
        let url = URL(string: "https://memos.example.invalid/ios/auth/callback?code=abc123")!
        #expect(NativeLogin.callback(from: url) == .code("abc123"))
    }

    /// The callback comes back on one of two lanes now — the server's https route, or the
    /// tap-to-return link the callback page carries on the app's own scheme, which under this
    /// estate's internal-only DNS is the only lane that can fire at all. The server builds the
    /// second from the first by construction, so what is ON the URL is identical and is read by
    /// this one parser either way.
    @Test("the tap-to-return lane carries the same parameters and is read the same way")
    func readsCodeFromTheCustomScheme() {
        let url = URL(string: "memosng://auth-callback?code=abc123")!
        #expect(NativeLogin.callback(from: url) == .code("abc123"))
    }

    @Test("a refusal on the tap-to-return lane is a refusal, not a malformed callback")
    func readsErrorFromTheCustomScheme() {
        let raw = "memosng://auth-callback?error=access_denied"
        #expect(NativeLogin.callback(from: URL(string: raw)!) == .failed(reason: "access_denied"))
    }

    @Test("a refused login comes back as an error parameter, not an HTTP status")
    func readsError() {
        let raw = "https://memos.example.invalid/ios/auth/callback?error=access_denied"
        #expect(NativeLogin.callback(from: URL(string: raw)!) == .failed(reason: "access_denied"))
    }

    @Test(
        "a callback with no usable parameter is malformed rather than silently successful",
        arguments: [
            "https://memos.example.invalid/ios/auth/callback",
            "https://memos.example.invalid/ios/auth/callback?code=",
            "https://memos.example.invalid/ios/auth/callback?error=",
            "https://memos.example.invalid/ios/auth/callback?state=xyz",
            "memosng://auth-callback",
            "memosng://auth-callback?code=",
            "memosng://auth-callback?error=",
        ]
    )
    func readsMalformed(_ raw: String) {
        #expect(NativeLogin.callback(from: URL(string: raw)!) == .malformed)
    }

    @Test(
        "each of the server's four exchange failures is recognised",
        arguments: zip(
            ["code_invalid", "code_expired", "code_consumed", "verifier_mismatch"],
            [
                NativeExchangeFailure.codeInvalid, .codeExpired, .codeConsumed,
                .verifierMismatch,
            ]
        )
    )
    func readsExchangeFailure(_ detail: String, _ expected: NativeExchangeFailure) {
        let body = Data(#"{"detail":"\#(detail)"}"#.utf8)
        #expect(NativeExchangeFailure.fromDetailBody(body) == expected)
    }

    @Test("a validation error's list-shaped detail is not read as an exchange failure")
    func ignoresValidationDetail() {
        let body = Data(#"{"detail":[{"loc":["body","code"],"msg":"field required"}]}"#.utf8)
        #expect(NativeExchangeFailure.fromDetailBody(body) == nil)
        #expect(NativeExchangeFailure.fromDetailBody(Data("not json".utf8)) == nil)
        #expect(NativeExchangeFailure.fromDetailBody(Data(#"{"detail":"nonsense"}"#.utf8)) == nil)
    }

    @Test("every failure says what to do next")
    func everyFailureHasAMessage() {
        for failure in NativeExchangeFailure.allCases {
            #expect(failure.message.contains("sign in again"))
        }
    }
}
